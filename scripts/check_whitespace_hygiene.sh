#!/usr/bin/env sh
# check_whitespace_hygiene: fail on whitespace regressions in shipped
# sources.
#
# Read-only gate for CI and pre-commit. Scope: src, lib, user_space,
# tools, tests, armstub/src, scripts, .github/workflows, top-level
# docs, German translations in docs/de, build files. Checks three
# regressions:
#
#   - trailing spaces on any line ('  $')
#   - hard tabs in *.zig files (project uses 4-space indent)
#   - CRLF line endings anywhere shipped
#
# src/symbol_area.S is generated and excluded; fix its generator if it
# ever carries a hit. This script self-excludes because it must name
# the forbidden patterns to match them.
#
# Exit 1 on any hit, 0 when clean.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PATHS="src lib user_space tools tests armstub/src scripts .github/workflows
README.md DOCUMENTATION.md SETUP.md CHANGELOG.md LICENSE.md
build.zig build.zig.zon config.txt docs/de"

EXTS="--include=*.zig --include=*.S --include=*.inc \
      --include=*.md --include=*.sh --include=*.zon \
      --include=*.yml --include=*.txt --include=*.ld"

SELF_EXCLUDE='^(src/symbol_area\.S|scripts/check_whitespace_hygiene\.sh):'

# shellcheck disable=SC2086
trailing="$(grep -rnE ' +$' $PATHS $EXTS 2>/dev/null \
    | grep -vE "$SELF_EXCLUDE" \
    || true)"

# Literal tab / CR bytes via printf: BSD grep (macOS) has no -P, and a
# swallowed "invalid option" error would make these checks pass silently.
# Plain BRE patterns work on both BSD (local pre-commit) and GNU (CI) grep.
TAB="$(printf '\t')"
CR="$(printf '\r')"

# shellcheck disable=SC2086
tabs="$(grep -rn "$TAB" $PATHS --include='*.zig' 2>/dev/null \
    | grep -vE "$SELF_EXCLUDE" \
    || true)"

# shellcheck disable=SC2086
crlf="$(grep -rn "$CR\$" $PATHS $EXTS 2>/dev/null \
    | grep -vE "$SELF_EXCLUDE" \
    || true)"

status=0

if [ -n "$trailing" ]; then
    echo "check_whitespace_hygiene: trailing whitespace:" >&2
    printf '%s\n' "$trailing" >&2
    status=1
fi

if [ -n "$tabs" ]; then
    echo "check_whitespace_hygiene: hard tabs in *.zig:" >&2
    printf '%s\n' "$tabs" >&2
    status=1
fi

if [ -n "$crlf" ]; then
    echo "check_whitespace_hygiene: CRLF line endings:" >&2
    printf '%s\n' "$crlf" >&2
    status=1
fi

if [ "$status" -ne 0 ]; then
    exit 1
fi


