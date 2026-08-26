#!/usr/bin/env fsh

def show_help() {
    ^printf '%s\n' \
    'Usage: scripts/mount-redoxfs.fsh [options] <device>' \
    '' \
    'Mount or unmount a RedoxFS partition' \
    '' \
    'Options:' \
    '  -u, --unmount    Unmount the RedoxFS partition' \
    '  -m, --mount-point PATH    Custom mount point (default: /mnt/redoxfs)' \
    '  -h, --help       Show this help' \
    '' \
    'Examples:' \
    '  scripts/mount-redoxfs.fsh /dev/sda3                    Mount /dev/sda3' \
    '  scripts/mount-redoxfs.fsh -u                           Unmount from default location' \
    '  scripts/mount-redoxfs.fsh -m /mnt/my-redox /dev/sda3   Mount to custom location' || exit
}

def unmount_fs(mount_point) {
    ^mountpoint -q $mount_point 2>/dev/null
    if $status.ok {
        ^printf 'Unmounting RedoxFS from %s...\n' $mount_point || exit
        ^fusermount -u $mount_point
        if !$status.ok {
            ^fusermount3 -u $mount_point || exit
        }
        ^printf '%s\n' 'Successfully unmounted' || exit
    } else {
        ^printf 'Nothing mounted at %s\n' $mount_point || exit
    }
    exit 0
}

mut mount_point = '/mnt/redoxfs'
mut disk_device = ''
mut unmount = false
mut pending_mount_point = false

for argument in $args {
    if $pending_mount_point {
        $mount_point = $argument
        $pending_mount_point = false
    } else if $argument == '-u' || $argument == '--unmount' {
        $unmount = true
    } else if $argument == '-m' || $argument == '--mount-point' {
        $pending_mount_point = true
    } else if $argument == '-h' || $argument == '--help' {
        show_help()
        exit 0
    } else {
        $disk_device = $argument
    }
}

if $pending_mount_point {
    $mount_point = ''
}

if $unmount {
    unmount_fs($mount_point)
}

if $disk_device == '' {
    $disk_device = '/dev/disk/by-partlabel/REDOX_INSTALL'
    if ^test -b $disk_device {
    } else {
        ^printf '%s\n' 'Error: No device specified and default partition not found' '' || exit
        show_help()
        exit 1
    }
}

if ^test -b $disk_device {
} else if ^test -f $disk_device {
} else {
    ^printf 'Error: %s is not a block device or file\n' $disk_device || exit
    exit 1
}

mut redoxfs = ''
if ^test -x build/fstools/bin/redoxfs {
    $redoxfs = 'build/fstools/bin/redoxfs'
} else if ^test -x scripts/../build/fstools/bin/redoxfs {
    $redoxfs = 'scripts/../build/fstools/bin/redoxfs'
} else if ^sh -c 'command -v redoxfs >/dev/null 2>&1' {
    $redoxfs = 'redoxfs'
}

if $redoxfs == '' {
    ^printf '%s\n' \
    'Error: redoxfs command not found' \
    'Please build it first with: make fstools' || exit
    exit 1
}

^ldconfig -p 2>/dev/null | ^grep -q libfuse3
if !$status.ok {
    ^printf '%s\n' 'Error: libfuse 3.x is not installed' 'Please install it:' || exit
    if ^sh -c 'command -v apt-get >/dev/null 2>&1' {
        ^printf '%s\n' '  sudo apt-get install fuse3 libfuse3-dev' || exit
    } else if ^sh -c 'command -v dnf >/dev/null 2>&1' {
        ^printf '%s\n' '  sudo dnf install fuse3-devel' || exit
    } else if ^sh -c 'command -v pacman >/dev/null 2>&1' {
        ^printf '%s\n' '  sudo pacman -S fuse3' || exit
    } else {
        ^printf '%s\n' '  (check your package manager for fuse3)' || exit
    }
    exit 1
}

^mkdir -p $mount_point || exit
^printf 'Mounting %s to %s...\n' $disk_device $mount_point || exit
^$redoxfs $disk_device $mount_point || exit

^printf '%s\n' \
"RedoxFS successfully mounted at $mount_point" \
'To unmount, run: scripts/mount-redoxfs.fsh -u' || exit
exit 0
