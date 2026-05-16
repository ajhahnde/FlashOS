#!/usr/bin/env bash
# Create the 64 MiB SD-card backing image for QEMU raspi4b runs
# (-drive if=sd,file=zig-out/test_sd.img,format=raw). Used by build.zig
# as a prerequisite of the rpi4b `run` and `test-rpi4b` steps.
#
# v0.4.0: the image is now a real FAT32 volume, not a
# zero fill. Layout matches scripts/format_sd.sh (MBR, one FAT32
# partition at LBA 2048 = the 1 MiB alignment offset), so
# src/fat32_backend.zig (FAT32_PARTITION_LBA = 2048) mounts it. Two
# seed files are pre-created in the FAT32 root for [TEST] fs-roundtrip
# (Variant B, magic-file): ROUNDTR.DAT (4 KiB zero) + ROUNDTR.MAG
# (1 byte zero). 8.3 names — fat32.encode8_3 rejects basenames > 8.
#
# Toolchain: mtools (mformat / mmd / mcopy), NOT mkfs.fat. dosfstools
# is absent on the dev box; mtools needs no sudo/loopback and formats
# straight into a file at a byte offset (img@@1M = LBA 2048). The
# canonical mkfs.fat -F 32 -s 8 -S 512 maps byte-equivalent onto
# mformat -F -c 8 under the available tool.
#
# CREATE-IF-ABSENT (NOT idempotent-overwrite). The Variant-B roundtrip
# needs the disk to PERSIST across two consecutive `zig build run`
# invocations (run 1 writes magic=1, run 2 verifies + resets). Because
# make_test_disk.sh is a build dependency of every run/test-rpi4b, an
# unconditional re-format would reset magic=0 every run and PASS_VERIFY
# could never be reached. So: if a valid FAT32 image with both seed
# files already exists, leave it untouched. `zig build clean` removes
# zig-out and starts a fresh cycle (magic=0 → PASS_WRITE).
#
# Reproducibility: a fresh build is byte-deterministic
# — pinned volume serial (-N 12345678), pinned label (-v SCRATCH),
# SOURCE_DATE_EPOCH=0 and fixed seed-file mtimes so mtools writes
# stable directory timestamps. Verify with:
#   rm -f zig-out/test_sd.img && scripts/make_test_disk.sh && \
#     shasum zig-out/test_sd.img && rm -f zig-out/test_sd.img && \
#     scripts/make_test_disk.sh && shasum zig-out/test_sd.img
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

IMG=zig-out/test_sd.img
TOTAL_SECTORS=131072         # 64 MiB / 512
PART_LBA=2048                # 1 MiB MBR offset (matches format_sd.sh)
PART_SECTORS=$((TOTAL_SECTORS - PART_LBA))   # 129024 = 0x1F800

export MTOOLS_SKIP_CHECK=1
export SOURCE_DATE_EPOCH=0

mkdir -p zig-out

# ---- create-if-absent guard ----
# Preserve an existing populated image so the two-run roundtrip can
# persist its magic byte. Probe with minfo (valid FAT32 at LBA 2048)
# + mdir for both seed files; any failure → regenerate from scratch.
if [ -f "$IMG" ] \
   && minfo  -i "$IMG@@1M" ::            >/dev/null 2>&1 \
   && mdir   -i "$IMG@@1M" ::/ROUNDTR.DAT >/dev/null 2>&1 \
   && mdir   -i "$IMG@@1M" ::/ROUNDTR.MAG >/dev/null 2>&1; then
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
#   -c 8    8 sectors/cluster = 4 KiB (plan's mkfs.fat -s 8)
#   -T n    total sectors of the filesystem (= partition size)
#   -N hex  pinned volume serial (reproducible)
#   -v lbl  pinned volume label
mformat -i "$IMG@@1M" -F -c 8 -T "$PART_SECTORS" -N 12345678 -v SCRATCH ::

# ---- seed files (deterministic content + mtime) ----
TMP_DAT="$(mktemp -t roundtr_dat.XXXXXX)"
TMP_MAG="$(mktemp -t roundtr_mag.XXXXXX)"
trap 'rm -f "$TMP_DAT" "$TMP_MAG"' EXIT
dd if=/dev/zero of="$TMP_DAT" bs=4096 count=1 status=none   # 4 KiB zero
dd if=/dev/zero of="$TMP_MAG" bs=1    count=1 status=none   # 1 byte zero
touch -t 197001010000.00 "$TMP_DAT" "$TMP_MAG"
mcopy -i "$IMG@@1M" "$TMP_DAT" ::/ROUNDTR.DAT
mcopy -i "$IMG@@1M" "$TMP_MAG" ::/ROUNDTR.MAG

echo "make_test_disk: FAT32 image ready (ROUNDTR.DAT 4096 / ROUNDTR.MAG 1, magic=0)"
