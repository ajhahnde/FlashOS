#!/usr/bin/env fsh

mut pattern = ''
if $args != [] {
    $pattern = $args[0]
}

let recipe_files = "$(^rg $pattern -li --sort=path recipes)"
if $recipe_files == '' {
    ^bat --decorations=always
} else {
    ^printf '%s' $recipe_files | ^xargs bat --decorations=always
}
exit
