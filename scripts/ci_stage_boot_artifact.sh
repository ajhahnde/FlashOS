#!/usr/bin/env bash
# Stage the CI boot-test artifact into an immutable, checksummed directory.
#
# The multi-job CI pipeline builds the seeded rpi4b kernel + FAT32 test disk in
# one job and boots them under QEMU in a LATER job. The boot job must test the
# exact bytes the build job produced — never a rebuild — so this script collects
# the generated files into a clean directory, records a provenance manifest, and
# writes SHA-256 checksums the boot job verifies before powering on QEMU.
#
# Inputs are passed as arguments (not read from the build tree layout) so the
# script is testable outside CI. Provenance values come from the environment the
# workflow already exports; missing ones degrade to "unknown" rather than fail,
# because a checksum mismatch — not a blank manifest field — is the real gate.
#
# Usage:
#   scripts/ci_stage_boot_artifact.sh <dest-dir> <kernel-img> <test-sd-img>
#
# Environment (optional, injected by the workflow):
#   GITHUB_SHA, GITHUB_RUN_ID, FLASHOS_QEMU_VERSION
set -euo pipefail

dest=${1:?usage: ci_stage_boot_artifact.sh <dest-dir> <kernel-img> <test-sd-img>}
kernel=${2:?missing kernel image path}
testsd=${3:?missing test SD image path}

for f in "$kernel" "$testsd"; do
  [ -f "$f" ] || { printf 'stage: missing input %s\n' "$f" >&2; exit 1; }
done

rm -rf "$dest"
mkdir -p "$dest"
cp "$kernel" "$dest/kernel8.img"
cp "$testsd" "$dest/test_sd.img"

rustver=$(rustc --version 2>/dev/null | awk '{print $2}')

# build-info.json: the machine-readable provenance the boot job and any human
# reviewer can trace back to the exact commit, run, and toolchain.
cat > "$dest/build-info.json" <<EOF
{
  "build_type": "ci-boot-test",
  "board": "rpi4b",
  "commit": "${GITHUB_SHA:-unknown}",
  "run_id": "${GITHUB_RUN_ID:-unknown}",
  "rust_version": "${rustver:-unknown}",
  "qemu_version": "${FLASHOS_QEMU_VERSION:-unknown}",
  "test_flags": ["--ci-login-seed", "--boot-selftest"],
  "files": ["kernel8.img", "test_sd.img"]
}
EOF

# Checksums over the bootable bytes only; the manifest is provenance, not payload.
( cd "$dest" && sha256sum kernel8.img test_sd.img > SHA256SUMS )

printf 'staged CI boot artifact in %s:\n' "$dest"
ls -l "$dest"
cat "$dest/SHA256SUMS"
