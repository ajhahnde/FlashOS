#!/usr/bin/env fsh

mut recipe = ''
if $args != [] {
    $recipe = $args[0]
}

let recipe_directory = "$(^target/release/repo find $recipe)"
let recipe_files = glob("$recipe_directory/recipe.*")
if $recipe_files == [] {
    ^cat "$recipe_directory/recipe.*"
} else {
    ^cat ...$recipe_files
}
exit
