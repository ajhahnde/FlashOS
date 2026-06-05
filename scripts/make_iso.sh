#!/usr/bin/env bash
#
# Build a GRUB-EFI rescue ISO that boots zig-out/kernel8.img on a
# UEFI arm64 system (VMware Fusion, qemu-system-aarch64 + edk2-aarch64,
# real arm64 hardware with UEFI firmware).
#
# Tooling
# -------
#   * grub-mkrescue + arm64-efi modules
#       Homebrew does not ship a working `grub` formula on Apple
#       Silicon. Build GRUB 2.12 from source against the aarch64-elf
#       cross toolchain and install under $HOME/.local/grub-aarch64-efi.
#       Quick recipe:
#
#         brew install autoconf automake libtool gettext gawk \
#                      help2man pkg-config xorriso mtools
#         curl -LO https://ftp.gnu.org/gnu/grub/grub-2.12.tar.xz
#         tar xf grub-2.12.tar.xz && cd grub-2.12
#         ./configure --target=aarch64 --with-platform=efi \
#                     --prefix="$HOME/.local/grub-aarch64-efi" \
#                     --disable-werror \
#                     TARGET_CC=aarch64-elf-gcc \
#                     TARGET_OBJCOPY=aarch64-elf-objcopy \
#                     TARGET_STRIP=aarch64-elf-strip \
#                     TARGET_NM=aarch64-elf-nm \
#                     TARGET_RANLIB=aarch64-elf-ranlib \
#                     LIBTOOL=glibtool
#         make -j8 && make install
#
#   * xorriso (ISO9660 backend grub-mkrescue calls)
#   * mtools  (FAT image manipulation for the EFI System Partition)
#       brew install xorriso mtools
#
# Output
# ------
#   zig-out/iso/         staging tree (boot/flashos, boot/grub/grub.cfg)
#   zig-out/flashos.iso  the resulting bootable ISO9660 image
#
# Override the GRUB install location with FLASHOS_GRUB_PREFIX if it is
# installed elsewhere than $HOME/.local/grub-aarch64-efi.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/zig-out/kernel8.img"
STAGE="$ROOT/zig-out/iso"
ISO_OUT="$ROOT/zig-out/flashos.iso"

GRUB_PREFIX="${FLASHOS_GRUB_PREFIX:-$HOME/.local/grub-aarch64-efi}"
GRUB_MKRESCUE="$GRUB_PREFIX/bin/grub-mkrescue"

if [ ! -x "$GRUB_MKRESCUE" ]; then
    echo "make_iso.sh: $GRUB_MKRESCUE not found." >&2
    echo "  Build GRUB for arm64-efi (see header comment), or set" >&2
    echo "  FLASHOS_GRUB_PREFIX to its install prefix." >&2
    exit 1
fi
for tool in xorriso mformat mcopy; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "make_iso.sh: $tool not found in PATH." >&2
        echo "  brew install xorriso mtools" >&2
        exit 1
    fi
done
if [ ! -f "$KERNEL" ]; then
    echo "make_iso.sh: $KERNEL missing — run \`zig build -Dboard=virt\` first." >&2
    exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/boot/grub"
cp "$KERNEL" "$STAGE/boot/flashos"
cat > "$STAGE/boot/grub/grub.cfg" <<'CFG'
set timeout=0
menuentry "FlashOS" {
    linux /boot/flashos
}
CFG

"$GRUB_MKRESCUE" -o "$ISO_OUT" "$STAGE"

echo "make_iso.sh: wrote $ISO_OUT"
