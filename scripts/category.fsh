#!/usr/bin/env fsh

def usage() {
    ^printf '%s\n' \
    'Build or clean all recipe directories in a category' \
    'Usage: scripts/category.fsh <action> <recipe-category>' \
    '<action> can be f, r, c, u, p, or combinations that "make" understands' \
    '<category> can be path of category you want to run e.g. "core", "wip", "wip/dev"' \
    1>&2 || exit
    exit 1
}

if $args == [] || $args[0] == '' {
    usage()
}

let argument_shape = "$(^printf '.%.0s' marker ...$args)"
if $argument_shape == '.' || $args[1] == '' {
    usage()
}

mut action = $args[0]
if $action[0] == '-' {
    $action = "$(^printf '%s' $action | ^cut -c 2-)"
}
let category_argument = $args[1]
let category = "$(^printf '%s' $category_argument | ^tr '/' '.')"
^make "$action.--category-$category"
exit
