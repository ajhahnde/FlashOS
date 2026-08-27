#!/usr/bin/env fsh

# Show repository changes for every component in the FlashOS image.

def report_repository(name: String, repository: String, mode: String, timestamp: String) {
    if $mode == 'summary' {
        ^printf '\n### %s\n\n' $name || exit
    } else if $mode == 'mdlinks' {
        ^printf -- '- [%s]' $name || exit
    } else {
        ^printf '\033[1m%s:\033[0m ' $name || exit
    }

    if ^test -e "$repository/.git" {
        let remote = "$(^git -C $repository remote get-url origin)"
        if !$status.ok {
            exit
        }
        let website = "$(^sh -c 'value=$1; printf %s "${value%.*}"' flash-changelog-remote $remote)"
        let before = "$(^git -C $repository log "--until=$timestamp" --format=%h -1)"
        if !$status.ok {
            exit
        }
        let after = "$(^git -C $repository log "--since=$timestamp" --format=%h -1)"
        if !$status.ok {
            exit
        }
        if $before == '' {
            ^printf 'New repository at %s\n' $website || exit
        } else if $after == '' {
            ^printf '%s\n' 'No changes' || exit
        } else if $mode == 'summary' {
            ^git -C $repository log "$before...$after" --oneline || exit
        } else if $mode == 'mdlinks' {
            ^printf '(%s/-/compare/%s...%s)\n' $website $before $after || exit
        } else {
            ^printf '%s/-/compare/%s...%s\n' $website $before $after || exit
        }
    } else {
        ^printf '%s\n' 'Not a git repository' || exit
    }
}

if $args != [] && $args[0] == '--internal-resolve' {
    let output = $args[1]
    let raw_argument_count = "$(^printf '.%.0s' marker ...$args | ^wc -c | ^tr -d ' ')"
    let argument_count = "$(^expr $raw_argument_count - 1)"
    mut index = 2
    while ^test $index -lt $argument_count {
        let package = $args[$index]
        let package_source = "$(^target/release/repo find $package)"
        if !$status.ok {
            exit
        }
        ^printf '%s %s\n' $package "$package_source/source" >> $output || exit
        $index = $index + 1
    }
    exit 0
}

if $args != [] && $args[0] == '--internal-report' {
    let raw_argument_count = "$(^printf '.%.0s' marker ...$args | ^wc -c | ^tr -d ' ')"
    let argument_count = "$(^expr $raw_argument_count - 1)"
    mut index = 3
    while ^test $index -lt $argument_count {
        let repository_index = $index + 1
        report_repository($args[$index], $args[$repository_index], $args[1], $args[2])
        $index = $index + 2
    }
    exit 0
}

let last_release_tag = "$(^git describe --tags --abbrev=0)"
if !$status.ok {
    exit
}
let last_release_timestamp = "$(^git log --format=%ct -1 $last_release_tag)"
if !$status.ok {
    exit
}
^printf 'Last release: %s at %s\n' $last_release_tag $last_release_timestamp || exit

mut mode = 'plain'
if $args != [] {
    if $args[0] == '--summary' {
        $mode = 'summary'
    } else if $args[0] == '--mdlinks' {
        $mode = 'mdlinks'
    }
}

let architecture = "$(^uname -m)"
if !$status.ok {
    exit
}
let packages = "$(^installer/target/release/redox_installer --list-packages -c "config/$architecture/flashos.toml")"
if !$status.ok {
    exit
}
let temporary = "$(^mktemp -d)"
if !$status.ok {
    exit
}
let repositories = "$temporary/repositories"
^printf '%s' '' > $repositories || exit
^printf '%s\n' $packages \
| ^xargs -n 100 fsh scripts/changelog.fsh --internal-resolve $repositories || exit

# TODO: resolve dependencies instead of manually adding these initfs packages.
for package in ['init', 'logd', 'ramfs', 'randd', 'zerod'] {
    let package_source = "$(^target/release/repo find $package)"
    if !$status.ok {
        exit
    }
    ^printf '%s %s\n' $package "$package_source/source" >> $repositories || exit
}

report_repository('flashos', '.', $mode, $last_release_timestamp)
report_repository('cookbook', 'cookbook', $mode, $last_release_timestamp)
report_repository('rust', 'rust', $mode, $last_release_timestamp)
^xargs -n 100 fsh scripts/changelog.fsh --internal-report $mode $last_release_timestamp < $repositories || exit
^rm -rf $temporary || exit
exit 0
