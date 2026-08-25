#!/usr/bin/env fsh

for recipe in $args {
    ^find recipes -maxdepth 4 -name $recipe
}
exit
