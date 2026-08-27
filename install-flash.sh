#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 0 ]]; then
    printf '%s\n' 'usage: ./install-flash.sh' >&2
    exit 2
fi

if [[ -z "${HOME:-}" ]]; then
    printf '%s\n' 'install-flash: HOME is required' >&2
    exit 1
fi

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
prefix="${FLASH_INSTALL_PREFIX:-$HOME/.local}"
work="$(mktemp -d "${TMPDIR:-/tmp}/flash-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM

(
    cd "$repository/components/flash"
    cargo install \
        --locked \
        --path crates/flash-cli \
        --bin fsh \
        --root "$work/stage"
)

runtime="$work/stage/bin/fsh"
if [[ ! -x "$runtime" ]]; then
    printf '%s\n' 'install-flash: Cargo did not produce an executable fsh' >&2
    exit 1
fi

version="$($runtime --version)"
if [[ "$version" != 'fsh 1.0.0' ]]; then
    printf 'install-flash: incompatible runtime: %s\n' "$version" >&2
    exit 1
fi

install -d "$prefix/bin"
install -m 0755 "$runtime" "$prefix/bin/fsh"
printf 'install-flash: installed fsh 1.0.0 at %s\n' "$prefix/bin/fsh"
