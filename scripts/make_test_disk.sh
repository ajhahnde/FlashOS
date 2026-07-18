#!/usr/bin/env bash
# Create the 64 MiB SD-card backing image for QEMU raspi4b runs
# (-drive if=sd,file=rust-out/test_sd.img,format=raw). Used by the native
# rpi4b run/watchdog helpers.
#
# Args (both optional, passed by the caller):
#   $1 — generated shadow file (the shadow generator output) → seeded as ::/SHADOW
#   $2 — permission-overlay seed (rootfs/etc/perms.tab) → ::/PERMS.TAB
# Without them the identity seeds are skipped and the kernel runs the
# initramfs-fallback path (auth works, [TEST] passwd SKIPs).
#
# The image is a real FAT32 volume, not a zero fill. Layout matches
# scripts/format_sd.sh (MBR, one FAT32 partition at LBA 2048 = the
# 1 MiB alignment offset), so the native FAT32 backend
# (FAT32_PARTITION_LBA = 2048) mounts it. Two seed files are
# pre-created in the FAT32 root for [TEST] fs-roundtrip (Variant B,
# magic-file): ROUNDTR.DAT (4 KiB zero) + ROUNDTR.MAG (1 byte zero).
# 8.3 names — fat32.encode8_3 rejects basenames > 8. The identity
# seeds SHADOW (the writable password database [TEST] passwd rewrites
# and the boot login reads first) and PERMS.TAB (the permission overlay
# protecting it, 0600 root:root) are also included.
#
# Toolchain: mtools (mformat / mmd / mcopy), NOT mkfs.fat. dosfstools
# is absent on the dev box; mtools needs no sudo/loopback and formats
# straight into a file at a byte offset (img@@1M = LBA 2048). The
# canonical mkfs.fat -F 32 -s 1 -S 512 maps byte-equivalent onto
# mformat -F -c 1 under the available tool. One sector per cluster
# (not 8): at 64 MiB only -c 1 yields ≥65525 data clusters, the FAT32
# spec minimum that newer mtools enforces (older builds let an
# undersized "FAT32" slide). The kernel reads SecPerClus from the BPB
# at mount time, so cluster size is not wired in anywhere.
#
# CREATE-IF-ABSENT (NOT idempotent-overwrite). The Variant-B roundtrip
# needs the disk to PERSIST across two consecutive QEMU runs
# invocations (run 1 writes magic=1, run 2 verifies + resets). Because
# make_test_disk.sh is a dependency of every rpi4b run/watchdog invocation, so an
# unconditional re-format would reset magic=0 every run and PASS_VERIFY
# could never be reached. So: if a valid FAT32 image with every seed
# file already exists, leave it untouched ([TEST] passwd is self-healing
# against the password drift this allows — it root-resets the flash
# record first). Removing rust-out/test_sd.img starts a fresh
# cycle (magic=0 → PASS_WRITE). An image missing SHADOW/PERMS.TAB
# fails the probe and is regenerated automatically.
#
# Reproducibility: a fresh build is byte-deterministic
# — pinned volume serial (-N 12345678), pinned label (-v SCRATCH),
# SOURCE_DATE_EPOCH=0 and fixed seed-file mtimes so mtools writes
# stable directory timestamps (the shadow generator output is itself a
# pure function of its constants). Verify with:
#   rm -f rust-out/test_sd.img && scripts/make_test_disk.sh && \
#     shasum rust-out/test_sd.img && rm -f rust-out/test_sd.img && \
#     scripts/make_test_disk.sh && shasum rust-out/test_sd.img
set -eu

# $0 (not ${BASH_SOURCE[0]}): CI invokes this via `sh …`, so the shebang is
# bypassed and on Ubuntu CI the interpreter is dash, which has
# no BASH_SOURCE array — ${BASH_SOURCE[0]} is a "Bad substitution" there.
# $0 is POSIX and resolves the same under both dash and bash.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SHADOW_SRC="${1:-}"
PERMS_SRC="${2:-}"

IMG=rust-out/test_sd.img
TOTAL_SECTORS=131072         # 64 MiB / 512
PART_LBA=2048                # 1 MiB MBR offset (matches format_sd.sh)
PART_SECTORS=$((TOTAL_SECTORS - PART_LBA))   # 129024 = 0x1F800

export MTOOLS_SKIP_CHECK=1
export SOURCE_DATE_EPOCH=0

mkdir -p rust-out

# ---- create-if-absent guard ----
# Preserve an existing populated image so the two-run roundtrip can
# persist its magic byte. Probe with minfo (valid FAT32 at LBA 2048)
# + mdir for every seed file; any failure → regenerate from scratch.
# The SHADOW / PERMS.TAB probes only gate when identity seeds were
# requested (args present), so a bare script run keeps accepting
# roundtrip-only images.
probe_ok=1
if [ -f "$IMG" ] \
   && minfo  -i "$IMG@@1M" ::            >/dev/null 2>&1 \
   && mdir   -i "$IMG@@1M" ::/ROUNDTR.DAT >/dev/null 2>&1 \
   && mdir   -i "$IMG@@1M" ::/ROUNDTR.MAG >/dev/null 2>&1 \
   && mdir   -i "$IMG@@1M" ::/EMPTY.TXT   >/dev/null 2>&1; then
    if [ -n "$SHADOW_SRC" ]; then
        mdir -i "$IMG@@1M" ::/SHADOW    >/dev/null 2>&1 || probe_ok=0
        mdir -i "$IMG@@1M" ::/PERMS.TAB >/dev/null 2>&1 || probe_ok=0
    fi
else
    probe_ok=0
fi
if [ "$probe_ok" = 1 ]; then
    echo "make_test_disk: keeping existing FAT32 image (roundtrip persistence)"
    exit 0
fi

echo "make_test_disk: creating fresh 64 MiB FAT32 image"
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count=64 status=none

# ---- MBR: one FAT32-LBA partition (type 0x0C) at LBA 2048 ----
# Partition entry @ 0x1BE (446): status=00 CHS=FEFFFF type=0C CHS=FEFFFF
#   LBA-start=2048 (00 08 00 00)  sectors=129024 (00 F8 01 00)
# Boot signature 55 AA @ 0x1FE (510). Rest of sector 0 stays zero.
printf '\x00\xFE\xFF\xFF\x0C\xFE\xFF\xFF\x00\x08\x00\x00\x00\xF8\x01\x00' \
    | dd of="$IMG" bs=1 seek=446 conv=notrunc status=none
printf '\x55\xAA' | dd of="$IMG" bs=1 seek=510 conv=notrunc status=none

# ---- FAT32 filesystem at byte offset 1 MiB (LBA 2048) ----
#   -F      force FAT32
#   -c 1    1 sector/cluster = 512 B; only this keeps ≥65525 clusters
#           at 64 MiB so newer mtools accepts it as valid FAT32
#   -T n    total sectors of the filesystem (= partition size)
#   -N hex  pinned volume serial (reproducible)
#   -v lbl  pinned volume label
mformat -i "$IMG@@1M" -F -c 1 -T "$PART_SECTORS" -N 12345678 -v SCRATCH ::

# ---- seed files (deterministic content + mtime) ----
TMP_DAT="$(mktemp -t roundtr_dat.XXXXXX)"
TMP_MAG="$(mktemp -t roundtr_mag.XXXXXX)"
TMP_EMP="$(mktemp -t empty_seed.XXXXXX)"
TMP_SHD="$(mktemp -t shadow_seed.XXXXXX)"
TMP_PRM="$(mktemp -t perms_seed.XXXXXX)"
trap 'rm -f "$TMP_DAT" "$TMP_MAG" "$TMP_EMP" "$TMP_SHD" "$TMP_PRM"' EXIT
dd if=/dev/zero of="$TMP_DAT" bs=4096 count=1 status=none   # 4 KiB zero
dd if=/dev/zero of="$TMP_MAG" bs=1    count=1 status=none   # 1 byte zero
: > "$TMP_EMP"                                              # 0 bytes -> first_cluster 0
touch -t 197001010000.00 "$TMP_DAT" "$TMP_MAG" "$TMP_EMP"
mcopy -i "$IMG@@1M" "$TMP_DAT" ::/ROUNDTR.DAT
mcopy -i "$IMG@@1M" "$TMP_MAG" ::/ROUNDTR.MAG
# 0-byte seed for [TEST] fs-empty-write: the first write must allocate
# its first data cluster (fat32_backend.write step 0). Pi-only; under
# QEMU /mnt never mounts so the scenario SKIPs and this stays 0 bytes.
mcopy -i "$IMG@@1M" "$TMP_EMP" ::/EMPTY.TXT

# ---- identity seeds: SHADOW + PERMS.TAB ----
# The shadow file is the shadow-generator build artifact (same content as the
# initramfs /etc/shadow seed); the overlay is the repo seed file. Both
# get the pinned mtime so the image stays byte-deterministic.
if [ -n "$SHADOW_SRC" ] && [ -n "$PERMS_SRC" ]; then
    cp "$SHADOW_SRC" "$TMP_SHD"
    cp "$PERMS_SRC" "$TMP_PRM"
    touch -t 197001010000.00 "$TMP_SHD" "$TMP_PRM"
    mcopy -i "$IMG@@1M" "$TMP_SHD" ::/SHADOW
    mcopy -i "$IMG@@1M" "$TMP_PRM" ::/PERMS.TAB
    echo "make_test_disk: FAT32 image ready (ROUNDTR + SHADOW + PERMS.TAB, magic=0)"
else
    echo "make_test_disk: FAT32 image ready (ROUNDTR only — no identity seeds, magic=0)"
fi
