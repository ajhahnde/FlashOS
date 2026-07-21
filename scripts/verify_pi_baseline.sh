#!/usr/bin/env bash
# Verify the rpi4b kernel8.img + armstub8.bin against
# scripts/pi_baseline.sha256. Stashes crates/kernel/generated/symbol_area.S to HEAD first
# (the populate-syms M-state would yield a different hash). Idempotent:
# safe to re-run; restores the working tree on exit.
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BASELINE="scripts/pi_baseline.sha256"
if [ ! -f "$BASELINE" ]; then
    echo "missing $BASELINE" >&2
    exit 2
fi

TOOLCHAIN=$(sed -n 's/^channel = "\([^"]*\)"/\1/p' rust-toolchain.toml | head -1)
if [ -z "$TOOLCHAIN" ] || ! command -v rustup >/dev/null 2>&1; then
    echo "cannot resolve the pinned rustup toolchain" >&2
    exit 2
fi
RUSTC_BIN=$(rustup which --toolchain "$TOOLCHAIN" rustc)
RUST_BIN=$(dirname "$RUSTC_BIN")
CARGO=(env "PATH=$RUST_BIN:$PATH" rustup run "$TOOLCHAIN" cargo)

STASHED=0
if ! git diff --quiet HEAD -- crates/kernel/generated/symbol_area.S; then
    git stash push --quiet -m "verify_pi_baseline" -- crates/kernel/generated/symbol_area.S
    STASHED=1
fi
restore_stash() {
    if [ "$STASHED" -eq 1 ]; then
        git stash pop --quiet || true
    fi
}
trap restore_stash EXIT

"${CARGO[@]}" xtask clean >/dev/null
"${CARGO[@]}" xtask build --board rpi4b >/dev/null
"${CARGO[@]}" xtask armstub >/dev/null

ACTUAL=$(mktemp -t flashos_pi_check.XXXXXX)
trap 'rm -f "$ACTUAL"; restore_stash' EXIT
shasum -a 256 rust-out/rpi4b/kernel8.img rust-out/rpi4b/armstub8.bin > "$ACTUAL"

if diff -u "$BASELINE" "$ACTUAL"; then
    echo "Pi baseline OK"
    exit 0
else
    echo "Pi baseline DRIFT — see diff above" >&2
    exit 1
fi
