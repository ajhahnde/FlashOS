#!/usr/bin/env bash

set -euo pipefail

usage()
{
    cat <<'EOF'
Usage: ./setup.sh [--plan | --check] [--yes]

Prepare the supported FlashOS development environment from an existing clone.

  --plan   Report every required change without making it
  --check  Verify the complete environment without making changes
  --yes    Pass non-interactive confirmation to the system package manager
  -h, --help
           Show this help
EOF
}

fail()
{
    printf 'setup: %s\n' "$*" >&2
    exit 1
}

quote_command()
{
    printf 'setup: plan:'
    printf ' %q' "$@"
    printf '\n'
}

run_change()
{
    quote_command "$@"
    if [[ "$mode" == "apply" ]]; then
        "$@"
    fi
}

has_command()
{
    command -v "$1" >/dev/null 2>&1
}

runtime_version()
{
    "$1" --version 2>/dev/null || true
}

mode=apply
assume_yes=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)
            [[ "$mode" == "apply" ]] || fail "choose only one of --plan and --check"
            mode=plan
            ;;
        --check)
            [[ "$mode" == "apply" ]] || fail "choose only one of --plan and --check"
            mode=check
            ;;
        --yes)
            assume_yes=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

[[ -n "${HOME:-}" ]] || fail "HOME is required"

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root_toolchain_file="$repository/rust-toolchain.toml"
flash_toolchain_file="$repository/components/flash/rust-toolchain.toml"
tool_manifest="$repository/ci/automation-tools.json"
for required_file in "$root_toolchain_file" "$flash_toolchain_file" "$tool_manifest"; do
    [[ -f "$required_file" ]] || fail "required repository file is missing: ${required_file#"$repository/"}"
done

root_toolchain="$(sed -n 's/^channel = "\([^"]*\)"/\1/p' "$root_toolchain_file")"
flash_toolchain="$(sed -n 's/^channel = "\([^"]*\)"/\1/p' "$flash_toolchain_file")"
[[ -n "$root_toolchain" ]] || fail "root Rust toolchain is not pinned"
[[ -n "$flash_toolchain" ]] || fail "Flash Rust toolchain is not pinned"
[[ "$root_toolchain" != "$flash_toolchain" ]] || fail "root and Flash Rust toolchains must remain distinct"

kernel="$(uname -s)"
machine="$(uname -m)"
package_manager=""
make_command="make"
tool_platform=""
packages=()
required_commands=(git python3 curl gzip tar podman qemu-system-x86_64)

case "$kernel-$machine" in
    Darwin-arm64)
        tool_platform=darwin-aarch64
        package_manager=brew
        make_command="gmake"
        packages=(git make python@3 podman qemu)
        required_commands+=(gmake shasum)
        ;;
    Linux-x86_64)
        tool_platform=linux-x86_64
        required_commands+=(make sha256sum)
        if has_command apt-get; then
            package_manager=apt-get
            packages=(
                git make python3 curl gzip tar coreutils podman qemu-system-x86 qemu-utils
                ovmf fuse3 libfuse3-dev fuse-overlayfs slirp4netns pkg-config
            )
        elif has_command dnf; then
            package_manager=dnf
            packages=(
                git make python3 curl gzip tar coreutils podman qemu-system-x86-core qemu-img
                edk2-ovmf fuse3 fuse3-devel fuse-overlayfs slirp4netns pkgconf-pkg-config
            )
        elif has_command pacman; then
            package_manager=pacman
            packages=(
                git make python curl gzip tar coreutils podman qemu-system-x86 qemu-img
                edk2-ovmf fuse3 fuse-overlayfs slirp4netns pkgconf
            )
        else
            fail "Linux x86_64 requires apt-get, dnf, or pacman"
        fi
        ;;
    *)
        fail "unsupported host $kernel-$machine; supported hosts are macOS arm64 and Linux x86_64"
        ;;
esac

printf 'setup: host %s-%s (%s)\n' "$kernel" "$machine" "$package_manager"
printf 'setup: Rust toolchains root=%s flash=%s\n' "$root_toolchain" "$flash_toolchain"

missing_commands=()
for command_name in "${required_commands[@]}"; do
    if ! has_command "$command_name"; then
        missing_commands+=("$command_name")
    fi
done

install_packages()
{
    case "$package_manager" in
        brew)
            run_change brew install "${packages[@]}"
            ;;
        apt-get)
            printf 'setup: privileged package changes will use apt-get for:'
            printf ' %s' "${packages[@]}"
            printf '\n'
            run_change sudo apt-get update
            if [[ "$assume_yes" == true ]]; then
                run_change sudo apt-get install -y "${packages[@]}"
            else
                run_change sudo apt-get install "${packages[@]}"
            fi
            ;;
        dnf)
            printf 'setup: privileged package changes will use dnf for:'
            printf ' %s' "${packages[@]}"
            printf '\n'
            if [[ "$assume_yes" == true ]]; then
                run_change sudo dnf install -y "${packages[@]}"
            else
                run_change sudo dnf install "${packages[@]}"
            fi
            ;;
        pacman)
            printf 'setup: privileged package changes will use pacman for:'
            printf ' %s' "${packages[@]}"
            printf '\n'
            if [[ "$assume_yes" == true ]]; then
                run_change sudo pacman -S --needed --noconfirm "${packages[@]}"
            else
                run_change sudo pacman -S --needed "${packages[@]}"
            fi
            ;;
        *)
            fail "unsupported package manager $package_manager"
            ;;
    esac
}

if [[ ${#missing_commands[@]} -gt 0 ]]; then
    printf 'setup: missing host commands:'
    printf ' %s' "${missing_commands[@]}"
    printf '\n'
    if [[ "$mode" == "check" ]]; then
        fail "host packages are incomplete"
    fi
    install_packages
else
    printf 'setup: host packages already satisfy the command contract\n'
fi

if [[ "$mode" == "apply" ]]; then
    for command_name in "${required_commands[@]}"; do
        has_command "$command_name" || fail "host package installation did not provide $command_name"
    done
fi

cargo_home="${CARGO_HOME:-$HOME/.cargo}"
export PATH="$cargo_home/bin:$PATH"

if ! has_command rustup; then
    if [[ "$mode" == "check" ]]; then
        fail "rustup is required"
    fi
    printf 'setup: Rustup will install under %s without editing shell startup files\n' "$cargo_home"
    if [[ "$mode" == "plan" ]]; then
        quote_command curl --fail --location --proto '=https' --tlsv1.2 https://sh.rustup.rs
        quote_command sh rustup-init -y --profile minimal --default-toolchain none --no-modify-path
    else
        rustup_work="$(mktemp -d "${TMPDIR:-/tmp}/flashos-rustup.XXXXXX")"
        trap 'rm -rf "$rustup_work"' EXIT HUP INT TERM
        run_change curl --fail --location --proto '=https' --tlsv1.2 --output "$rustup_work/rustup-init.sh" https://sh.rustup.rs
        run_change sh "$rustup_work/rustup-init.sh" -y --profile minimal --default-toolchain none --no-modify-path
    fi
fi

install_toolchain()
{
    local channel="$1"
    shift
    if [[ "$mode" == "check" ]]; then
        rustup run "$channel" rustc --version >/dev/null 2>&1 || fail "Rust toolchain $channel is not installed"
        for component in "$@"; do
            rustup component list --toolchain "$channel" --installed | grep -Eq "^${component}(-|$)" || fail "Rust toolchain $channel lacks $component"
        done
        return
    fi
    local arguments=(toolchain install "$channel" --profile minimal)
    for component in "$@"; do
        arguments+=(--component "$component")
    done
    run_change rustup "${arguments[@]}"
}

if [[ "$mode" == "plan" ]] && ! has_command rustup; then
    quote_command rustup toolchain install "$root_toolchain" --profile minimal --component rust-src --component rustfmt --component clippy --component rust-analyzer
    quote_command rustup toolchain install "$flash_toolchain" --profile minimal --component clippy --component rustfmt --component rust-analyzer
else
    has_command rustup || fail "rustup installation did not provide rustup"
    install_toolchain "$root_toolchain" rust-src rustfmt clippy rust-analyzer
    install_toolchain "$flash_toolchain" clippy rustfmt rust-analyzer
fi

if [[ "$mode" != "plan" ]]; then
    has_command cargo || fail "rustup installation did not provide cargo"
    rustup run "$root_toolchain" cargo --version >/dev/null
    rustup run "$flash_toolchain" cargo --version >/dev/null
fi

flash_prefix="${FLASH_INSTALL_PREFIX:-$HOME/.local}"
flash_runtime="$flash_prefix/bin/fsh"
if [[ -z "${FLASH_INSTALL_PREFIX:-}" ]] && has_command fsh; then
    ambient_flash="$(command -v fsh)"
    if [[ "$(runtime_version "$ambient_flash")" == "fsh 1.0.0" ]]; then
        flash_runtime="$ambient_flash"
        flash_prefix="$(cd "$(dirname "$ambient_flash")/.." && pwd -P)"
    fi
fi
if [[ "$(runtime_version "$flash_runtime")" != "fsh 1.0.0" ]]; then
    if [[ "$mode" == "check" ]]; then
        fail "compatible Flash runtime is not installed at $flash_runtime"
    fi
    if [[ "$mode" == "plan" ]]; then
        quote_command env "FLASH_INSTALL_PREFIX=$flash_prefix" "$repository/install-flash.sh"
    else
        run_change env "FLASH_INSTALL_PREFIX=$flash_prefix" "$repository/install-flash.sh"
    fi
else
    printf 'setup: Flash runtime already satisfies fsh 1.0.0 at %s\n' "$flash_runtime"
fi

tools_directory="$repository/build/flash-automation-tools/$tool_platform"
automation_tools_ready()
{
    [[ -x "$tools_directory/bin/taplo" ]] || return 1
    [[ -x "$tools_directory/bin/jq" ]] || return 1
    [[ -x "$tools_directory/bin/rg" ]] || return 1
    [[ -f "$tools_directory/manifest.json" ]] || return 1
    cmp -s "$tool_manifest" "$tools_directory/manifest.json" || return 1
    [[ "$(runtime_version "$tools_directory/bin/taplo")" == "taplo 0.10.0" ]] || return 1
    case "$(runtime_version "$tools_directory/bin/jq")" in
        jq-1.7.1|jq-1.7.1-apple) ;;
        *) return 1 ;;
    esac
    [[ "$("$tools_directory/bin/rg" --version 2>/dev/null | sed -n '1s/ (rev .*)$//;1p')" == "ripgrep 15.2.0" ]] || return 1
}

if ! automation_tools_ready; then
    if [[ "$mode" == "check" ]]; then
        fail "pinned automation tools are not installed under $tools_directory"
    fi
    run_change "$make_command" -s -C "$repository" flash-automation-tools
else
    printf 'setup: pinned automation tools already satisfy the manifest\n'
fi

if [[ "$mode" == "plan" ]]; then
    printf 'setup: plan complete; no changes made\n'
    exit 0
fi

rustup run "$root_toolchain" rustc --version >/dev/null
rustup run "$flash_toolchain" rustc --version >/dev/null
[[ "$(runtime_version "$flash_runtime")" == "fsh 1.0.0" ]] || fail "Flash runtime verification failed"
automation_tools_ready || fail "pinned automation-tool verification failed"

printf 'setup: environment verified\n'
case ":$PATH:" in
    *":$flash_prefix/bin:"*) ;;
    *) printf 'setup: add %s/bin to PATH before running ./build.fsh\n' "$flash_prefix" ;;
esac
