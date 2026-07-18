#!/usr/bin/env bash
# Synchronize and verify every live FlashOS release/toolchain version.
# Historical changelogs, roadmap milestones, protocol/spec revisions, and
# package-manager dependency locks are deliberately outside this live set.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

# shellcheck disable=SC1091
. ./versions.env

usage() {
  printf 'usage: %s --check|--write\n' "$0" >&2
  exit 2
}

case "${1:-}" in
  --check) mode=check ;;
  --write) mode=write ;;
  *) usage ;;
esac

case "$FLASHOS_RELEASE_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) printf 'invalid FLASHOS_RELEASE_VERSION: %s\n' "$FLASHOS_RELEASE_VERSION" >&2; exit 2 ;;
esac
case "$FLASHOS_RUST_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) printf 'invalid FLASHOS_RUST_VERSION: %s\n' "$FLASHOS_RUST_VERSION" >&2; exit 2 ;;
esac
case "$FLASHOS_QEMU_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) printf 'invalid FLASHOS_QEMU_VERSION: %s\n' "$FLASHOS_QEMU_VERSION" >&2; exit 2 ;;
esac

FLASHOS_RUST_MSRV=${FLASHOS_RUST_VERSION%.*}
export FLASHOS_RELEASE_VERSION FLASHOS_RUST_VERSION FLASHOS_RUST_MSRV

if [ "$mode" = write ]; then
  command -v perl >/dev/null 2>&1 || {
    printf 'perl is required for --write\n' >&2
    exit 2
  }

  perl -0pi -e '
    if ($ARGV eq "rust-toolchain.toml") {
      s{^channel = "[^"]+"$}{channel = "$ENV{FLASHOS_RUST_VERSION}"}m;
    } elsif ($ARGV eq "Cargo.toml") {
      s{(\[workspace\.package\][^\[]*?^version = ")[^"]+("\n)}{$1 . $ENV{FLASHOS_RELEASE_VERSION} . $2}em;
      s{(\[workspace\.package\][^\[]*?^rust-version = ")[^"]+("\n)}{$1 . $ENV{FLASHOS_RUST_MSRV} . $2}em;
    } elsif ($ARGV eq "Cargo.lock") {
      s{(\[\[package\]\]\nname = "flashos-[^"]+"\nversion = ")[^"]+("\n)}{$1 . $ENV{FLASHOS_RELEASE_VERSION} . $2}ge;
    } elsif ($ARGV eq "README.md" || $ARGV eq "docs/de/README.md") {
      s{badge/version-v[0-9]+\.[0-9]+\.[0-9]+}{badge/version-v$ENV{FLASHOS_RELEASE_VERSION}}g;
    }
  ' rust-toolchain.toml Cargo.toml Cargo.lock README.md docs/de/README.md
fi

failed=0

expect_line() {
  file=$1
  expected=$2
  if ! grep -Fqx "$expected" "$file"; then
    printf 'version drift: %s lacks exact line: %s\n' "$file" "$expected" >&2
    failed=1
  fi
}

expect_text() {
  file=$1
  expected=$2
  if ! grep -Fq "$expected" "$file"; then
    printf 'version drift: %s lacks: %s\n' "$file" "$expected" >&2
    failed=1
  fi
}

expect_line rust-toolchain.toml "channel = \"$FLASHOS_RUST_VERSION\""
expect_line Cargo.toml "version = \"$FLASHOS_RELEASE_VERSION\""
expect_line Cargo.toml "rust-version = \"$FLASHOS_RUST_MSRV\""
expect_text README.md "badge/version-v$FLASHOS_RELEASE_VERSION-"
expect_text docs/de/README.md "badge/version-v$FLASHOS_RELEASE_VERSION-"
expect_text .github/workflows/rust.yml 'branches: [main, "v*"]'
expect_text .github/workflows/rust.yml 'qemu-aarch64-${{ env.FLASHOS_QEMU_VERSION }}-${{ runner.os }}'
expect_text .github/workflows/rust.yml 'ver="$FLASHOS_QEMU_VERSION"'

if ! awk -v expected="$FLASHOS_RELEASE_VERSION" '
  function flush() {
    if (name ~ /^flashos-/ && version != expected) {
      printf "version drift: Cargo.lock package %s is %s, expected %s\n", name, version, expected > "/dev/stderr"
      bad = 1
    }
  }
  /^\[\[package\]\]$/ { flush(); name = ""; version = ""; next }
  /^name = "/ { value = $0; sub(/^name = "/, "", value); sub(/"$/, "", value); name = value; next }
  /^version = "/ { value = $0; sub(/^version = "/, "", value); sub(/"$/, "", value); version = value; next }
  END { flush(); exit bad }
' Cargo.lock; then
  failed=1
fi

live_docs="README.md DOCUMENTATION.md SETUP.md arch/aarch64/README.md docs/de tutorial/public"
copied_toolchains=$(grep -rInE \
  'Rust v?[0-9]+\.[0-9]+\.[0-9]+|rust-v[0-9]+\.[0-9]+\.[0-9]+|LLVM [0-9]+\.[0-9]+\.[0-9]+|qemu-system-aarch64[^0-9]*[0-9]+\.[0-9]+\.[0-9]+' \
  $live_docs 2>/dev/null || true)
if [ -n "$copied_toolchains" ]; then
  printf 'version drift: live docs copy a toolchain patch version instead of referring to versions.env:\n%s\n' "$copied_toolchains" >&2
  failed=1
fi

workflow_qemu=$(grep -nE 'QEMU.*[0-9]+\.[0-9]+\.[0-9]+|qemu.*[0-9]+\.[0-9]+\.[0-9]+' .github/workflows/rust.yml || true)
if [ -n "$workflow_qemu" ]; then
  printf 'version drift: workflow hardcodes QEMU instead of using versions.env:\n%s\n' "$workflow_qemu" >&2
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  printf 'version synchronization failed; run scripts/sync_versions.sh --write and fix non-generated drift\n' >&2
  exit 1
fi

printf 'versions OK: FlashOS %s, Rust %s (MSRV %s), QEMU %s\n' \
  "$FLASHOS_RELEASE_VERSION" "$FLASHOS_RUST_VERSION" "$FLASHOS_RUST_MSRV" "$FLASHOS_QEMU_VERSION"
