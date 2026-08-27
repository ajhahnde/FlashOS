#!/usr/bin/env fsh

# Install FlashOS into an explicitly selected block device and add a
# systemd-boot entry. Device identification and approval remain operator work.

mut disk = '/dev/disk/by-partlabel/REDOX_INSTALL'
if $args != [] && $args[0] != '' {
    $disk = $args[0]
}

if ^test -b $disk {
} else {
    ^printf "scripts/dual-boot.fsh: '%s' is not a block device\n" $disk 1>&2 || exit
    exit 1
}

let settings = "$(^make setenv)"
if !$status.ok {
    exit
}
let architecture = "$(^printf '%s\n' $settings | ^sed -n "s/^export ARCH='\\([^']*\\)'$/\\1/p")"
let build = "$(^printf '%s\n' $settings | ^sed -n "s/^BUILD='\\([^']*\\)'$/\\1/p")"
if $architecture == '' || $build == '' {
    ^printf '%s\n' 'scripts/dual-boot.fsh: make setenv returned incomplete build settings' 1>&2 || exit
    exit 1
}

let image = "$build/filesystem.img"
^printf '+ rm -f %s\n' $image 1>&2 || exit
^rm -f $image || exit
^printf '+ make %s\n' $image 1>&2 || exit
^make $image || exit
^printf '+ sudo popsicle %s %s\n' $image $disk 1>&2 || exit
^sudo popsicle $image $disk || exit
^printf '%s\n' '+ set +x' 1>&2 || exit

let esp = "$(^bootctl --print-esp-path)"
if !$status.ok {
    exit
}
if $esp == '' {
    ^printf '%s\n' 'scripts/dual-boot.fsh: no ESP found' 1>&2 || exit
    exit 1
}

let bootloader = "recipes/core/bootloader/target/$architecture-unknown-redox/stage/usr/lib/boot/bootloader.efi"
^printf '+ sudo mkdir -pv %s/EFI %s/loader/entries\n' $esp $esp 1>&2 || exit
^sudo mkdir -pv "$esp/EFI" "$esp/loader/entries" || exit
^printf '+ sudo cp -v %s %s/EFI/flashos.efi\n' $bootloader $esp 1>&2 || exit
^sudo cp -v $bootloader "$esp/EFI/flashos.efi" || exit
^printf '+ sudo tee %s/loader/entries/flashos.conf\n' $esp 1>&2 || exit
^printf '%s\n' 'title FlashOS' 'efi /EFI/flashos.efi' \
| ^sudo tee "$esp/loader/entries/flashos.conf" || exit
^printf '%s\n' '+ set +x' 1>&2 || exit

^sync || exit

^printf '%s\n' \
'Finished installing FlashOS dual boot' \
'' \
'To mount the RedoxFS partition, run:' \
"  ./scripts/mount-redoxfs.fsh $disk" || exit
exit 0
