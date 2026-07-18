#!/usr/bin/env bash
# OPERATOR-RUN, DESTRUCTIVE: repartition an SD card as a single whole-disk
# FAT32 BOOT partition (MBR partition table), matching the hardware
# procedure that booted FlashOS off EMMC2 + passed [TEST] emmc2-block
# on real Pi-4 hardware.
#
# Layout:
#   - MBR with one FAT32 primary partition labelled `BOOT`
#   - holds RPi firmware (start4.elf, fixup4.dat, bcm2711-rpi-4-b.dtb,
#     config.txt), kernel8.img, armstub8.bin
#   - plus two FAT32 seed files for [TEST] fs-roundtrip (Variant B):
#     ROUNDTR.DAT (4 KiB of zero) + ROUNDTR.MAG (1 byte of zero).
#     8.3 short names are mandatory — fat32.encode8_3 rejects a
#     basename longer than 8 characters.
#   - the [TEST] emmc2-block target is LBA 2064, in the FAT32
#     reserved-sector window (between the BPB at LBA 2048 and FAT1
#     ~LBA 2080) — no FAT32 driver reads or writes it, so it never
#     collides with file contents
#
# NOTE: the macOS GUI Disk Utility only offers FAT32 for cards ≤32 GB;
# SDXC cards (≥64 GB) need the CLI form below to get FAT32 instead of
# the default ExFAT. The 2-partition (BOOT + SCRATCH) layout earlier
# revisions of this script produced silently fell back to FAT16 for
# the 16 MiB BOOT partition (diskutil's FAT32 floor is ~256 MiB) and
# did not match the hardware path the driver was verified against.
#
# Usage:
#   scripts/format_sd.sh /dev/diskN          # macOS
#   scripts/format_sd.sh /dev/mmcblkN        # Linux SD reader
#   scripts/format_sd.sh /dev/sdX            # Linux USB SD adapter
#
# Refuses to operate without explicit "ja" confirmation. Refuses
# device paths that don't match the expected SD-reader patterns.
# Not invoked by the `build` helper; this is a one-shot operator command.
set -eu

if [ -z "$1" ]; then
    echo "usage: $0 <device>" >&2
    echo "  e.g. $0 /dev/diskN         # macOS; replace N after diskutil list" >&2
    echo "       $0 /dev/mmcblk0       # Linux" >&2
    exit 2
fi

DEV="$1"

case "$DEV" in
    /dev/disk[0-9]|/dev/disk[0-9][0-9]|/dev/sd[a-z]|/dev/mmcblk[0-9])
        ;;
    *)
        echo "refusing to operate on $DEV" >&2
        echo "expected /dev/diskN, /dev/sdX, or /dev/mmcblkN" >&2
        exit 2
        ;;
esac

if [ ! -b "$DEV" ] && [ ! -e "$DEV" ]; then
    echo "$DEV does not exist" >&2
    exit 2
fi

echo "================================================================"
echo "ABOUT TO REPARTITION $DEV"
echo "ALL DATA ON THIS DEVICE WILL BE LOST PERMANENTLY."
echo "================================================================"
echo "Type 'ja' (exact, lowercase) to proceed:"
read -r REPLY
if [ "$REPLY" != "ja" ]; then
    echo "aborted." >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin)
        diskutil unmountDisk "$DEV"
        # Whole-disk single FAT32 BOOT partition with MBR partition table.
        # Equivalent to `diskutil eraseDisk FAT32 BOOT MBRFormat $DEV`,
        # but spelled via partitionDisk for symmetry with the Linux path.
        diskutil partitionDisk "$DEV" 1 MBR \
            "MS-DOS FAT32" BOOT R
        ;;
    Linux)
        # Unmount any auto-mounted partitions first.
        for part in "${DEV}"*; do
            [ "$part" = "$DEV" ] && continue
            sudo umount "$part" 2>/dev/null || true
        done
        # MBR, single FAT32-LBA (type 0x0c) partition spanning the disk
        # starting at LBA 2048.
        sudo sfdisk "$DEV" <<EOF
label: dos
start=2048,type=c
EOF
        # Linux device-node suffix differs: /dev/sdX1 vs /dev/mmcblkNp1.
        case "$DEV" in
            /dev/mmcblk*) P1="${DEV}p1" ;;
            *)            P1="${DEV}1"  ;;
        esac
        sudo mkfs.vfat -F32 -n BOOT "$P1"
        ;;
    *)
        echo "unsupported platform $(uname -s)" >&2
        exit 2
        ;;
esac

echo
echo "Repartition done. Next steps (operator):"
echo "  1. Copy RPi firmware blobs (start4.elf, fixup4.dat, bcm2711-rpi-4-b.dtb,"
echo "     config.txt) to the BOOT partition."
echo "  2. Run the 'build -d' helper, or copy rust-out/rpi4b/kernel8.img + rust-out/rpi4b/armstub8.bin"
echo "     to the BOOT partition."
echo "  3. Seed the two [TEST] fs-roundtrip files into the FAT32 root"
echo "     (8.3 short names are mandatory):"
echo "       dd if=/dev/zero of=<mnt>/ROUNDTR.DAT bs=4096 count=1"
echo "       dd if=/dev/zero of=<mnt>/ROUNDTR.MAG bs=1    count=1"
echo "  4. Eject the SD card; insert into the Pi; run picapture."
