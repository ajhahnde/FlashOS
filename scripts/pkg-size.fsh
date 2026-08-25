#!/usr/bin/env fsh

# Show built package sizes for selected recipes or for the complete tree.

def usage() {
    ^printf '%s\n' \
    'Usage: scripts/pkg-size.fsh [recipe] ...' \
    "       For the recipe(s), prints the size of 'stage.pkgar' and 'stage.tar.gz'." \
    '       If no recipe is given, then all packages are listed.' || exit
    exit 0
}

if $args != [] && $args[0] == '--internal-recipe' {
    let argument_shape = "$(^printf '.%.0s' marker ...$args)"
    if $argument_shape == '.' {
        exit 0
    }
    let recipe_path = $args[1]
    if ^test -f "$recipe_path/recipe.toml" || ^test -f "$recipe_path/recipe.sh" {
        ^find $recipe_path '(' -name stage.pkgar -o -name stage.tar.gz ')' -exec ls -hs '{}' ';'
    }
    exit 0
}

if $args == [] {
    ^find recipes '(' -name stage.pkgar -o -name stage.tar.gz ')' -exec ls -hs '{}' ';'
    if !$status.ok {
        exit
    }
    exit 0
}

for recipe in $args {
    if $recipe in ['-h', '--help'] {
        usage()
    }
    ^find recipes -name $recipe \
    | ^xargs -n 1 fsh scripts/pkg-size.fsh --internal-recipe || exit
}
exit 0
