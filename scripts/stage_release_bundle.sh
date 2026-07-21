#!/usr/bin/env bash
# Assemble the production Raspberry Pi 4B release bundle into a deterministic
# staging tree. This is the flashable set a user copies onto the FAT boot
# partition — NOT the CI boot-test artifact (which carries --ci-login-seed /
# --boot-selftest and is never released).
#
# The kernel and armstub must already be built (cargo xtask guard --board rpi4b
# --full, then cargo xtask armstub); this script only collects and describes.
# Provenance values come from the environment so the same script works in CI and
# in a local dry run.
#
# Usage:
#   scripts/stage_release_bundle.sh <version> <staging-root>
#
# Environment (optional):
#   GITHUB_REF_NAME  git tag           GITHUB_SHA  commit
#   SOURCE_DATE_EPOCH reproducible ts   FLASHOS_QEMU_VERSION  CI qualification QEMU
set -euo pipefail

version=${1:?usage: stage_release_bundle.sh <version> <staging-root>}
root=${2:?missing staging root}

dest="$root/FlashOS-${version}-rpi4b"
kernel="rust-out/rpi4b/kernel8.img"
armstub="rust-out/rpi4b/armstub8.bin"

fw=vendor/raspberrypi-firmware/rpi4b
for f in "$kernel" "$armstub" config.txt LICENSE NOTICE \
         "$fw/start4.elf" "$fw/fixup4.dat" \
         "$fw/bcm2711-rpi-4-b.dtb" "$fw/overlays/miniuart-bt.dtbo"; do
  [ -f "$f" ] || { printf 'stage-release: missing %s\n' "$f" >&2; exit 1; }
done

rm -rf "$dest"
mkdir -p "$dest/overlays"

# The bootable set the RPi firmware expects on the FAT partition.
cp "$kernel"                          "$dest/kernel8.img"
cp "$armstub"                         "$dest/armstub8.bin"
cp config.txt                         "$dest/config.txt"
cp "$fw/start4.elf"                    "$dest/start4.elf"
cp "$fw/fixup4.dat"                    "$dest/fixup4.dat"
cp "$fw/bcm2711-rpi-4-b.dtb"           "$dest/bcm2711-rpi-4-b.dtb"
cp "$fw/overlays/miniuart-bt.dtbo"     "$dest/overlays/miniuart-bt.dtbo"
cp LICENSE                            "$dest/LICENSE"
cp NOTICE                             "$dest/NOTICE"

epoch=${SOURCE_DATE_EPOCH:-$(date -u +%s)}
if date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
  built_at=$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)   # GNU date (CI)
else
  built_at=$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ)    # BSD date (local macOS)
fi
rustver=$(rustc --version 2>/dev/null | awk '{print $2}')

cat > "$dest/build-info.json" <<EOF
{
  "product": "FlashOS",
  "release_version": "${version}",
  "git_tag": "${GITHUB_REF_NAME:-unknown}",
  "commit": "${GITHUB_SHA:-unknown}",
  "board": "rpi4b",
  "target": "aarch64-unknown-none-softfloat",
  "rust_version": "${rustver:-unknown}",
  "qemu_qualification_version": "${FLASHOS_QEMU_VERSION:-unknown}",
  "build_type": "production",
  "built_at": "${built_at}",
  "files": [
    "kernel8.img", "armstub8.bin", "config.txt", "start4.elf", "fixup4.dat",
    "bcm2711-rpi-4-b.dtb", "overlays/miniuart-bt.dtbo", "LICENSE", "NOTICE"
  ]
}
EOF

cat > "$dest/INSTALL.md" <<EOF
# FlashOS ${version} — Raspberry Pi 4B install

1. Format a microSD card with a single FAT32 boot partition.
2. Copy every file in this bundle (including \`overlays/\`) to the partition root.
3. Insert the card and power on the Pi 4B. Serial console is on the Mini-UART
   (GPIO14/15, 115200 8N1).

These are production binaries: they boot to the interactive \`login:\` prompt.
The CI boot-test image (with an auto-seeded login and in-kernel self-test) is a
separate artifact and is never shipped in a release.
EOF

printf 'staged release bundle in %s:\n' "$dest"
find "$dest" -type f | sort
