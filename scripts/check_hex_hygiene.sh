#!/usr/bin/env sh
# check_hex_hygiene: fail on lowercase hex literals in shipped kernel sources.
#
# Read-only gate for CI and pre-commit. Sibling of
# scripts/check_whitespace_hygiene.sh; scope: src/.
#
# The project posture is UPPERCASE for hex constants (0xABCD)
# to distinguish them from lowercase data or symbols.
#
# Exit 1 on any hit, 0 when clean.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Search src/ for hex literals with lowercase a-f (0x[0-9]*[a-f][0-9a-f]*).
# Ignore comments (lines starting with // or /* or *) and strings.
# This is a heuristic gate; it may have false positives in multi-line comments.
# Using a positive lookbehind if available, but standard grep doesn't support it.
# We'll just look for the pattern and exclude known false-positive paths.

# Exclude .DS_Store, non-source files, and the generated symbol_area.S.
hits="$(grep -rnE "0x[0-9a-f]*[a-f][0-9a-f]*" src/ --include="*.S" --include="*.inc" \
    | grep -vE "^crates/kernel/generated/symbol_area\.S:" \
    | grep -vE ":[[:space:]]*(\/\/|\*)" \
    || true)"

if [ -n "$hits" ]; then
    echo "check_hex_hygiene: lowercase hex literals found in src/:" >&2
    printf '%s\n' "$hits" >&2
    echo "-> Use UPPERCASE for hex constants (e.g., 0xFFFF instead of 0xffff)." >&2
    exit 1
fi

