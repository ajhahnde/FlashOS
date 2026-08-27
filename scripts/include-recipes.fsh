#!/usr/bin/env fsh

def usage() {
    ^printf '%s\n' \
    'Find matching recipes, and format for inclusion in config' \
    'Usage: scripts/include-recipes.fsh "pattern"' \
    'Must be run from the FlashOS repository root' \
    'e.g. scripts/include-recipes.fsh "TODO.*error"' || exit
    exit 1
}

# xargs invokes this private mode once per matching recipe. Flash still owns
# selection and formatting; the mode only preserves the predecessor's
# whitespace-normalized command-substitution boundary.
if $args != [] && $args[0] == '--internal-recipe' {
    let pattern = $args[1]
    let recipe_path = $args[2]
    let recipe_directory = "$(^dirname $recipe_path)"
    let recipe_name = "$(^basename $recipe_directory)"
    let matches = "$(^grep $pattern $recipe_path \
    | ^awk '{ for (i = 1; i <= NF; i++) { if (seen) printf " "; printf "%s", $i; seen = 1 } } END { if (seen) printf "\n" }')"
    ^printf '%s = {}    #  %s\n' $recipe_name $matches
    exit
}

if $args == [] {
    usage()
}
let pattern = "$(^printf '%s\n' ...$args | ^paste -sd ' ' -)"
if $pattern == '' {
    usage()
}

let recipe_paths = "$(^grep -rl $pattern recipes --include recipe.toml)"
^printf '%s' $recipe_paths \
| ^xargs -I '{}' fsh scripts/include-recipes.fsh --internal-recipe $pattern '{}'
exit
