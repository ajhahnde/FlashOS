#!/usr/bin/env fsh

# The private xargs mode keeps the baseline's streaming, line-oriented walk
# without handing policy to a shell callback.
if $args != [] && $args[0] == '--internal-path' {
    let path = $args[1]
    if $path == '' {
        exit 0
    }

    let architecture = env('ARCH')
    let config_name = env('CONFIG_NAME')
    let providers = glob("recipes/*/target/${$architecture}-unknown-redox/stage/$path")
    if $providers != [] {
        let packages = "$(^printf '%s\n' ...$providers | ^cut -d/ -f3 | ^tr '\n' ' ' | ^sort | ^uniq)"
        ^printf '%s: %s\n' $path $packages || exit
    } else {
        ^printf '%s: no packages, see config/%s/%s.toml\n' $path $architecture $config_name || exit
    }
    exit 0
}

let architecture = "$(^uname -m)"
let config_name = 'flashos'
export ARCH = $architecture
export CONFIG_NAME = $config_name

^make unmount > /dev/null 2>&1
^make mount > /dev/null

^find "build/$architecture/$config_name/" -type f \
| ^cut -d / -f5- \
| ^sort \
| ^uniq \
| ^xargs -I '{}' fsh scripts/find-recipe.fsh --internal-path '{}'

^make unmount > /dev/null 2>&1
exit 0
