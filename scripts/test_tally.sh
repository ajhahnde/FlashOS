#!/bin/sh
# Final pass banner for `zig build test`.
#
# build.zig wires this as the last dependency of the `test` step, depending on
# every host-test run, so it executes only after they all pass. It is handed
# the exact list of source files addHostTest wired (so the count is derived
# from the build graph itself and can never drift from the suite), counts the
# `test "…"` / `test {` blocks across them, and prints one green line. Reaching
# this step means every wired test already ran green, so the count is the
# number that passed. Per-module detail: `zig build test --summary all`.
#
# Args: $1 = active -Dtest-filter substring ("" when none); $2.. = source files.

filter=$1
shift

if [ -t 1 ]; then green='\033[32m'; reset='\033[0m'; else green=''; reset=''; fi

if [ -n "$filter" ]; then
    # A filtered run executes only a subset; an exact count would mislead.
    printf '%btests passed (filter: %s)%b\n' "$green" "$filter" "$reset"
    exit 0
fi

n=$(grep -hE '^test ["{]' "$@" | wc -l | tr -d ' ')
printf '%b%s tests passed%b\n' "$green" "$n" "$reset"
