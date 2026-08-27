#!/usr/bin/env fsh

# Fetch the default base and rebuild every recipe changed from that base.

if $args != [] && $args[0] == '--internal-package' {
    if $args == [$args[0]] || $args[1] == '' {
        exit 0
    }
    let recipe_toml = $args[1]
    let recipe_directory = "$(^dirname $recipe_toml)"
    ^basename $recipe_directory
    exit
}

mut base_ref = "$(^git symbolic-ref --quiet --short refs/remotes/origin/HEAD)"
if !$status.ok {
    $base_ref = 'origin/main'
}
let base_branch = "$(^printf '%s' $base_ref | ^sed 's#^origin/##')"
let diff_range = "$base_ref..."

^git fetch origin $base_branch
if !$status.ok {
    exit
}

let packages = "$(^git diff --name-only $diff_range \
| ^grep '/recipe.toml$' \
| ^sort \
| ^uniq \
| ^xargs -n 1 fsh scripts/fetch-changed.fsh --internal-package \
| ^paste -sd, -)"

if $packages == '' {
    ^printf '%s\n' 'No recipe.toml changes found'
} else {
    ^make "f.$packages"
}
exit
