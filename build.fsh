#!/usr/bin/env fsh

# Primary source-build interface. Flash owns option parsing, defaults,
# environment selection, diagnostics, status propagation, and Make dispatch.

def usage() {
    ^printf '%s\n' \
    'build.fsh:     Invoke make for a particular architecture and configuration.' \
    'Usage:' \
    './build.fsh [-X | -A | -5 | -R | -a ARCH] [-c CONFIG] [-f FILESYSTEM_CONFIG] TARGET...' \
    '    -X         Equivalent to -a x86_64.' \
    '    -A         Equivalent to -a aarch64.' \
    '    -5         Equivalent to -a i586.' \
    '    -6         Equivalent to -a i586 (deprecated, use -5 instead).' \
    '    -R         Equivalent to -a riscv64gc.' \
    '    -a ARCH:   Processor Architecture. Normally one of x86_64, aarch64 or' \
    '               i686. ARCH is not checked, so you can add a new architecture.' \
    '               Defaults to the directory containing the FILESYSTEM_CONFIG file,' \
    '               or x86_64 if no FILESYSTEM_CONFIG is specified.' \
    '    -c CONFIG: The name of the config, e.g. flashos.' \
    '               Determines the name of the image, build/ARCH/CONFIG/harddrive.img' \
    '               e.g. build/x86_64/flashos/harddrive.img' \
    '               Determines the name of FILESYSTEM_CONFIG if none is specified.' \
    "               Defaults to the basename of FILESYSTEM_CONFIG, or 'flashos'" \
    '               if FILESYSTEM_CONFIG is not specified.' \
    '    -f FILESYSTEM_CONFIG:' \
    '               The config file to use. It can be in any location.' \
    '               However, if the file is not in a directory named x86_64, aarch64' \
    '               or i686, you must specify the architecture.' \
    '               If -f is not specified, FILESYSTEM_CONFIG is set to' \
    '               config/ARCH/CONFIG.toml' \
    '               If you specify both CONFIG and FILESYSTEM_CONFIG, it is not' \
    '               necessary that they match, but it is recommended.' \
    '    Examples:  ./build.fsh -c flashos live - make build/x86_64/flashos/redox-live.iso' \
    '               ./build.fsh qemu - make build/x86_64/flashos/harddrive.img and' \
    '                                  run it in qemu' \
    '    NOTE:      If you do not change ARCH or CONFIG very often, edit mk/config.mk' \
    '               and set ARCH and FILESYSTEM_CONFIG. You only need to use this' \
    '               script when you want to override them.' || exit
}

if $args != [] {
    if $args[0] in ['-h', '--help'] {
        usage()
        exit 0
    }
}

mut architecture = ''
mut config_name = ''
mut filesystem_config = ''

mut argument_index = 0
mut parsing_options = true
mut pending_option = ''

for argument in $args {
    if !$parsing_options {
        continue
    }

    if $pending_option != '' {
        if $pending_option == 'a' {
            $architecture = $argument
        } else if $pending_option == 'c' {
            $config_name = $argument
        } else {
            $filesystem_config = $argument
        }
        $pending_option = ''
        $argument_index = $argument_index + 1
        continue
    }

    if $argument == '--' {
        $argument_index = $argument_index + 1
        $parsing_options = false
        continue
    }
    if $argument == '' || $argument == '-' || $argument[0] != '-' {
        $parsing_options = false
        continue
    }

    mut option_text = "$(^printf '%s' $argument | ^cut -c 2-)"
    while $option_text != '' {
        let option = $option_text[0]
        $option_text = "$(^printf '%s' $option_text | ^cut -c 2-)"
        if $option in ['a', 'c', 'f'] {
            if $option_text != '' {
                if $option == 'a' {
                    $architecture = $option_text
                } else if $option == 'c' {
                    $config_name = $option_text
                } else {
                    $filesystem_config = $option_text
                }
                $option_text = ''
            } else {
                $pending_option = $option
            }
            continue
        }

        if $option == 'X' {
            $architecture = 'x86_64'
        } else if $option == 'A' {
            $architecture = 'aarch64'
        } else if $option == '6' {
            $architecture = 'i586'
        } else if $option == 'd' {
        } else if $option == 'h' {
            usage()
        } else {
            ^printf 'Unknown option -%s, try -h for help\n' $option || exit
            exit 0
        }
    }
    $argument_index = $argument_index + 1
}

if $pending_option != '' {
    ^printf -- '-%s requires a value\n' $pending_option || exit
    exit 0
}

if $architecture == '' && $filesystem_config != '' {
    let config_directory = "$(^dirname $filesystem_config)"
    $architecture = "$(^basename $config_directory)"
    if $architecture == '?' {
        $architecture = ''
        ^printf '%s\n' 'Unknown Architecture, please specify x86_64, aarch64, riscv64gc or i586' || exit
    }
}

# The predecessor always derived CONFIG_NAME from an explicit filesystem
# configuration, even when -c was also supplied. Preserve that behavior.
if $filesystem_config != '' {
    $config_name = "$(^basename $filesystem_config .toml)"
}

if $architecture == '' {
    $architecture = 'x86_64'
}
if $config_name == '' {
    $config_name = 'flashos'
}
if $filesystem_config == '' {
    $filesystem_config = "config/$architecture/$config_name.toml"
}

export ARCH = $architecture
export CONFIG_NAME = $config_name
export FILESYSTEM_CONFIG = $filesystem_config

# Flash 1.0 has no list-slice expression. This fixed transport shim removes
# the already parsed option prefix and immediately execs Make; all build
# arguments, policy, environment, and orchestration remain owned above.
^sh -c 'remaining=$1; shift; while [ "$remaining" -gt 0 ]; do shift; remaining=$((remaining - 1)); done; exec make "$@"' flash-build-argv $argument_index ...$args
exit
