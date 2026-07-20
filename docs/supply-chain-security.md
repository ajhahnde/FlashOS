# Supply-chain security

FlashOS's automation is built to make the build inputs and outputs auditable and
hard to tamper with. This document summarizes the controls and where they live.

## Pinned toolchains

The Rust toolchain is pinned in `rust-toolchain.toml` (channel, target,
components) and single-sourced from `versions.env` through
`scripts/sync_versions.sh`. Every CI job activates that exact toolchain via the
`setup-flashos` composite action. The FlashShell consumer workspace pins its own
toolchain in `components/flashshell/rust-toolchain.toml`.

## Pinned QEMU

The boot contract is validated against one QEMU release (`FLASHOS_QEMU_VERSION`).
The `setup-qemu` composite action builds exactly that version from source and
caches it, keyed on OS, architecture, version, and a fingerprint of the configure
flags. The runner's bundled QEMU is never used for qualification.

## Clean-room build guard

The production build runs under `cargo xtask guard --board rpi4b --full`, which
places rejecting shims ahead of retired compilers on `PATH` and traces the
subprocess tree. Any invocation of a retired toolchain fails the build, proving
the production image is produced only by the pinned Rust toolchain and clang.

## Action SHA pinning

Every third-party GitHub Action is pinned to a full commit SHA, with the
human-readable release retained in an inline comment. Floating tags (`@v4`) are
mutable and are not used. `.github/dependabot.yml` configures the `github-actions`
ecosystem so pinned SHAs are updated through reviewable pull requests, which then
run the full CI and security workflows.

## Minimal token permissions

Every workflow declares `permissions: contents: read` at the top level. The only
elevated grant is on the release `publish` job (`contents: write`,
`id-token: write`, `attestations: write`), scoped to the single job that creates
the release and its provenance attestation.

## Dependency review

`security.yml` runs GitHub's dependency review on pull requests, failing when a
change introduces a dependency with a known high-severity advisory.

## cargo-deny

`deny.toml` encodes a reviewed policy checked in CI (`cargo deny check`):

- **advisories** — fail on any matching RUSTSEC advisory (no ignores).
- **licenses** — allow only Apache-2.0, MIT, and BSD-3-Clause, matching the
  actual dependency set (the RustCrypto stack, `libc`, `subtle`).
- **bans** — reject wildcard version requirements on external crates; the only
  wildcards in the tree are intra-workspace path dependencies of an OS that is
  never published to crates.io. Duplicate versions warn rather than fail.
- **sources** — allow crates only from crates.io; no git or private registries.

The cargo-deny action pins its own stable Rust, isolated from the FlashOS
production compiler.

## Provenance

Release archives and their `SHA256SUMS` carry a GitHub build-provenance
attestation binding the artifact digests to the repository, workflow, commit, and
tag. See [release-process.md](release-process.md) for verification.

## Recommended repository settings

Some controls are provided by GitHub configuration rather than workflow YAML, and
should be enabled in repository settings:

- secret scanning and push protection;
- Dependabot alerts and Dependabot security updates;
- branch protection requiring the `CI / required` status;
- optionally, required signed commits, at the maintainer's discretion.

## Cloud authentication model

No optional cloud publishing is configured. If an AWS artifact-publishing phase
is later added, it must use GitHub OIDC to assume a least-privilege role scoped to
this repository and its release context — never a stored static access key.
