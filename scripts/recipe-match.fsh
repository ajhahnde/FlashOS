#!/usr/bin/env fsh

mut pattern = ''
if $args != [] {
    $pattern = $args[0]
}

mut rg = env('FLASH_AUTOMATION_RG')
if $rg == null || $rg == '' {
    $rg = 'rg'
}
let recipe_files = "$(^env $rg $pattern -li --sort=path recipes)"
if $recipe_files == '' {
    ^bat --decorations=always
} else {
    ^printf '%s' $recipe_files | ^xargs bat --decorations=always
}
exit
