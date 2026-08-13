#!/usr/bin/env bash

set -e

base_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD || printf '%s\n' origin/main)"
base_branch="${base_ref#origin/}"
git fetch origin "${base_branch}"
packages=""
for toml in $(git diff --name-only "${base_ref}"... | grep '/recipe.toml$' | sort | uniq)
do
    package="$(basename "$(dirname "${toml}")")"
    if [ -n "${packages}" ]
    then
        packages="${packages},"
    fi
    packages="${packages}${package}"
done
if [ -n "${packages}" ]
then
    make f."${packages}"
else
    echo "No recipe.toml changes found"
fi

