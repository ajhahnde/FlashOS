#!/usr/bin/env fsh

def usage() {
    ^printf '%s\n' \
    'Show the contents of the stage and sysroot folders in recipe(s)' \
    'Usage: scripts/show-package.fsh recipe1 ...' \
    'Must be run from the FlashOS repository root' \
    'e.g. scripts/show-package.fsh kernel' || exit
    exit 1
}

if $args == [] {
    usage()
}

let find_recipe = 'target/release/find_recipe'
if ^test -x $find_recipe {
} else {
    ^printf '%s\n' \
    "$find_recipe not found." \
    "Please run 'make fstools' and try again." || exit
    exit 1
}

for recipe in $args {
    let recipe_directory = "$(^$find_recipe $recipe)"
    let stage_directories = glob("$recipe_directory/target/*/stage")
    let sysroot_directories = glob("$recipe_directory/target/*/sysroot")
    if $stage_directories == [] {
        if $sysroot_directories == [] {
            ^ls -1 "$recipe_directory/target/*/stage" "$recipe_directory/target/*/sysroot"
        } else {
            ^ls -1 "$recipe_directory/target/*/stage" ...$sysroot_directories
        }
    } else if $sysroot_directories == [] {
        ^ls -1 ...$stage_directories "$recipe_directory/target/*/sysroot"
    } else {
        ^ls -1 ...$stage_directories ...$sysroot_directories
    }
}
exit
