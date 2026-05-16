#!/usr/bin/env bash
# Verify the rpi4b kernel8.img + armstub8.bin against
# scripts/pi_baseline.sha256. Stashes src/symbol_area.S to HEAD first
# (the populate-syms M-state would yield a different hash). Idempotent:
# safe to re-run; restores the working tree on exit.
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BASELINE="scripts/pi_baseline.sha256"
if [ ! -f "$BASELINE" ]; then
    echo "missing $BASELINE" >&2
    exit 2
fi

STASHED=0
if ! git diff --quiet HEAD -- src/symbol_area.S; then
    git stash push --quiet -m "verify_pi_baseline" -- src/symbol_area.S
    STASHED=1
fi
restore_stash() {
    if [ "$STASHED" -eq 1 ]; then
        git stash pop --quiet || true
    fi
}
trap restore_stash EXIT

zig build clean >/dev/null
zig build -Dboard=rpi4b >/dev/null

ACTUAL=$(mktemp -t flashos_pi_check.XXXXXX)
trap 'rm -f "$ACTUAL"; restore_stash' EXIT
shasum -a 256 zig-out/kernel8.img zig-out/armstub8.bin > "$ACTUAL"

if diff -u "$BASELINE" "$ACTUAL"; then
    echo "Pi baseline OK"
    exit 0
else
    echo "Pi baseline DRIFT — see diff above" >&2
    exit 1
fi
