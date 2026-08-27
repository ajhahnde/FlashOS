#!/usr/bin/env fsh

# Decode a FlashOS Rust backtrace with symbols from one built recipe.

def usage() {
    ^printf '%s\n' \
    'Usage: scripts/backtrace.fsh -r recipe [ -e command_name ] [ -R ] [ -X | -6 | -A ] [[ -b backtracefile ] | [ addr1 ... ]]' \
    '' \
    'Print the backtrace contained in the backtracefile.' \
    'Symbols are taken from the executable for the given recipe.' \
    'If no backtracefile is given, decode the given addresses instead.' \
    'This command must be run from the FlashOS repository root.' \
    '' \
    '-X for x86_64, -6 for i686, -A for aarch64 (x86_64 is the default).' \
    "To read from stdin, use '-b -'" \
    'The name of the executable must match what Cargo believes it to be.' \
    "If the executalbe is named 'recipe_command', just use 'command' as the name." \
    'The debug version of the executable is used if available.' \
    'The release version is used if no debug version exists.' \
    "-R to force the use of the 'release' version of the executable." \
    'Make sure the executable is the one that produced the backtrace.' || exit
    exit 1
}

mut architecture = 'x86_64'
mut input_file = ''
mut command_name = ''
mut recipe_name = ''
mut release = false
mut argument_index = 0
mut parsing_options = true
mut pending_option = ''

for argument in $args {
    if !$parsing_options {
        continue
    }

    if $pending_option != '' {
        if $pending_option == 'b' {
            $input_file = $argument
        } else if $pending_option == 'e' {
            $command_name = $argument
        } else {
            $recipe_name = $argument
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
        if $option in ['b', 'e', 'r'] {
            if $option_text != '' {
                if $option == 'b' {
                    $input_file = $option_text
                } else if $option == 'e' {
                    $command_name = $option_text
                } else {
                    $recipe_name = $option_text
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
            $architecture = 'i686'
        } else if $option == 'R' {
            $release = true
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

if $recipe_name == '' {
    usage()
}

let raw_argument_count = "$(^printf '.%.0s' marker ...$args | ^wc -c | ^tr -d ' ')"
let argument_count = "$(^expr $raw_argument_count - 1)"
if $input_file == '' {
    if ^test $argument_index -eq $argument_count {
        usage()
    }
}

let recipe_directory = "$(^target/release/repo find $recipe_name)"
if !$status.ok {
    exit
}
if $command_name == '' {
    $command_name = $recipe_name
}

mut executable = "$recipe_directory/target/$architecture-unknown-redox/build/target/$architecture-unknown-redox/debug/$command_name"
mut use_release = $release
if !$use_release {
    ^test -f $executable
    $use_release = !$status.ok
}
if $use_release {
    $executable = "$recipe_directory/target/$architecture-unknown-redox/build/target/$architecture-unknown-redox/release/$command_name"
}

if ^test $argument_index -lt $argument_count {
    # Flash 1.0 has no list-slice expression. This fixed shim removes only the
    # parsed option prefix; executable selection and addr2line policy stay here.
    ^sh -c 'remaining=$1; executable=$2; shift 2; while [ "$remaining" -gt 0 ]; do shift; remaining=$((remaining - 1)); done; exec addr2line --demangle=rust --inlines --pretty-print --functions --exe="$executable" $@' flash-backtrace-argv $argument_index $executable ...$args || exit
} else {
    ^sed '/^\s*$/d; s/^.*0x\([0-9a-f]*\).*$/\1/g' $input_file \
    | ^addr2line --demangle=rust --inlines --pretty-print --functions "--exe=$executable" || exit
}
exit 0
