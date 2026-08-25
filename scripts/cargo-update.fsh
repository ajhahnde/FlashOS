#!/usr/bin/env fsh

# Update one recipe source. Flash owns recipe selection, build ordering,
# working-directory selection, and the final Cargo status.

mut recipe_name = ''
if $args != [] {
    $recipe_name = $args[0]
}

let recipe_path = "$(^target/release/repo find $recipe_name)"
^make "f.$recipe_name"
cd "$recipe_path/source"
^cargo update
exit
