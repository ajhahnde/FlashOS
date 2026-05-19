#!/usr/bin/env sh
# check_comment_hygiene: fail on tool/AI-attribution strings in shipped
# sources and docs.
#
# Read-only gate for CI and pre-commit. Scope mirrors the shipped tree:
# src, lib, user_space, tools, tests, armstub/src, scripts,
# .github/workflows, top-level docs, and build files. src/symbol_area.S
# is generated and excluded; fix its generator if it ever carries a
# hit. This script self-excludes because it must name the forbidden
# patterns to match them.
#
# Exit 1 on any hit, 0 when clean.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PATHS="src lib user_space tools tests armstub/src scripts .github/workflows
README.md DOCUMENTATION.md MIGRATION.md SETUP.md CHANGELOG.md LICENSE.md
build.zig build.zig.zon build.sh config.txt"

PATTERN='claude|anthropic|co-?authored|generated with claude|noreply@anthropic'

hits="$(grep -rniE "$PATTERN" $PATHS \
    --include='*.zig' --include='*.S' --include='*.inc' \
    --include='*.md' --include='*.sh' --include='*.zon' \
    --include='*.yml' --include='*.txt' --include='*.ld' \
    2>/dev/null \
    | grep -vE '^(src/symbol_area\.S|scripts/check_comment_hygiene\.sh):' \
    || true)"

if [ -n "$hits" ]; then
    echo "check_comment_hygiene: forbidden strings found:" >&2
    printf '%s\n' "$hits" >&2
    exit 1
fi

echo "check_comment_hygiene: clean"
