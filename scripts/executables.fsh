#!/usr/bin/env fsh

# List staged recipe executables to expose name conflicts.

def usage() {
    ^printf '%s\n' \
    'List executable names to find duplicates' \
    'Usage: scripts/executables.fsh [-h] [-a] [-arm64 | -i686] [recipes]' \
    'Default architecture is x86_64, -arm64 is aarch64, -i686 is i686' \
    'Only duplicates are listed unless -a is specified' \
    '-h is this message' || exit
    exit 0
}

if $args != [] && $args[0] == '--internal-command' {
    let argument_shape = "$(^printf '.%.0s' marker ...$args)"
    if $argument_shape == '..' {
        exit 0
    }
    let recipe_path = $args[1]
    let command_path = $args[2]
    let short_name = "$(^basename $command_path)"
    ^printf '%s %s\n' $recipe_path $short_name || exit
    exit 0
}

if $args != [] && $args[0] == '--internal-recipe' {
    let argument_shape = "$(^printf '.%.0s' marker ...$args)"
    if $argument_shape == '..' {
        exit 0
    }
    let target = $args[1]
    let recipe = $args[2]
    mut recipe_path = ''
    if ^printf '%s' $recipe | ^grep -q '/' {
        $recipe_path = "recipes/$recipe"
    } else {
        $recipe_path = "$(^target/release/repo find $recipe)"
        if !$status.ok {
            exit
        }
    }
    ^find \
    "$recipe_path/target/$target/stage/usr/bin" \
    "$recipe_path/target/$target/stage/bin" \
    -type f 2>/dev/null \
    | ^xargs -n 1 fsh scripts/executables.fsh --internal-command $recipe_path
    exit 0
}

mut target = 'x86_64-unknown-redox'
mut show_all = false
mut has_recipes = false

for argument in $args {
    if $argument == '-arm64' {
        $target = 'aarch64-unknown-redox'
    } else if $argument == '-i686' {
        $target = 'i686-unknown-redox'
    } else if $argument == '-a' {
        $show_all = true
    } else if $argument == '-h' {
        usage()
    } else {
        $has_recipes = true
    }
}

if $has_recipes {
    if $show_all {
        ^printf '%s\n' ...$args \
        | ^grep -v -E '^(-arm64|-i686|-a|-h)$' \
        | ^xargs -n 1 fsh scripts/executables.fsh --internal-recipe $target \
        | ^sort \
        | ^cat
    } else {
        ^printf '%s\n' ...$args \
        | ^grep -v -E '^(-arm64|-i686|-a|-h)$' \
        | ^xargs -n 1 fsh scripts/executables.fsh --internal-recipe $target \
        | ^sort \
        | ^uniq -D --skip-fields=1
    }
} else if $show_all {
    ^target/release/list_recipes \
    | ^xargs -n 1 fsh scripts/executables.fsh --internal-recipe $target \
    | ^sort \
    | ^cat
} else {
    ^target/release/list_recipes \
    | ^xargs -n 1 fsh scripts/executables.fsh --internal-recipe $target \
    | ^sort \
    | ^uniq -D --skip-fields=1
}
if !$status.ok {
    exit
}
exit 0
