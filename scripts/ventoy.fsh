#!/usr/bin/env fsh

# Build and copy the FlashOS live image to a mounted Ventoy filesystem.

let architectures = ['x86_64']
let configurations = ['flashos']
let user = env('USER')
let ventoy = "/media/$user/Ventoy"

if ^test -d $ventoy {
} else {
    ^printf '%s\n' 'Ventoy not mounted' 1>&2 || exit
    exit 1
}

for architecture in $architectures {
    for configuration in $configurations {
        let image = "build/$architecture/$configuration/redox-live.iso"
        ^make "ARCH=$architecture" "CONFIG_NAME=$configuration" $image || exit
        ^cp -v $image "$ventoy/$configuration-$architecture.iso" || exit
    }
}

^sync || exit
^printf '%s\n' 'Finished copying configs (flashos) for archs (x86_64)' || exit
exit 0
