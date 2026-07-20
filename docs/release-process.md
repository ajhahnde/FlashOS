# Release process

Production releases are produced by `.github/workflows/release.yml`. A release is
rebuilt from the tagged commit — never copied from a CI run — and ships a
flashable Raspberry Pi 4B bundle with checksums, an SBOM, and a provenance
attestation.

## Version source of truth

`versions.env` holds `FLASHOS_RELEASE_VERSION`. `scripts/sync_versions.sh`
propagates it to `rust-toolchain.toml`, `Cargo.toml`, `Cargo.lock`, and the README
version badge, and `--check` fails on any drift. The release workflow binds the
git tag to this manifest: a tag whose name is not `v${FLASHOS_RELEASE_VERSION}`
fails the run before anything is built.

## Tag naming

Releases are triggered by pushing a tag matching `v*` (for example `v0.8.0`). The
tag must equal `v` + the version in `versions.env`.

## Manual dry run

`workflow_dispatch` runs the `package` job only. It validates, rebuilds, packages,
checksums, and generates the SBOM, then uploads everything as a workflow
artifact — but it does **not** create a GitHub Release. Publishing is reached only
when the workflow runs on a **tag** ref (a `v*` push, or a manual dispatch
selected against a tag with `publish=true`). A dispatch on a branch can never
publish.

## Production environment approval

The `publish` job targets the protected `production` GitHub Environment. Configure
required reviewers on that environment to gate publication behind a manual
approval. The `package` job needs no approval, so dry runs stay frictionless.

## What a release contains

The bundle (`FlashOS-<version>-rpi4b/`) is the flashable set for the FAT boot
partition:

- `kernel8.img` — the production kernel (no CI flags)
- `armstub8.bin` — the EL3→EL1 bootstrap shim
- `config.txt`, `start4.elf`, `fixup4.dat`, `bcm2711-rpi-4-b.dtb`,
  `overlays/miniuart-bt.dtbo` — Raspberry Pi 4B firmware and configuration
- `LICENSE.md`
- `build-info.json` — provenance manifest (version, tag, commit, Rust target and
  version, QEMU qualification version, reproducible build timestamp, file list)
- `INSTALL.md` — installation instructions

The production kernel omits `--ci-login-seed` and `--boot-selftest`; it boots to
the real `login:` prompt. The CI boot-test image (which carries both flags) is a
separate artifact and is never released.

Packaged as `FlashOS-<version>-rpi4b.tar.gz` and `.zip`. Archives are
deterministic: sorted entries, zeroed ownership, and an `mtime` pinned to the
commit time (`SOURCE_DATE_EPOCH`).

## Checksum verification

`SHA256SUMS` covers both archives. It is generated and verified during packaging,
verified again in the `publish` job before the release is created, and published
as a release asset. To verify a download:

```bash
sha256sum -c SHA256SUMS
```

## SBOM scope

A CycloneDX SBOM (`FlashOS-<version>.cdx.json`) is generated from the Cargo
dependency graph and covers every Cargo workspace dependency. It does **not**
describe the Raspberry Pi firmware blobs (`start4.elf`, `fixup4.dat`, the DTB) or
the clang/LLVM toolchain inputs, which are not Cargo components. Treat the SBOM as
the source-dependency inventory, not a complete bill of the firmware image.

## Attestation verification

The `publish` job records a GitHub build-provenance attestation binding the
archive and checksum digests to the repository, workflow, commit, and tag. Verify
a downloaded archive with the GitHub CLI:

```bash
gh attestation verify FlashOS-<version>-rpi4b.tar.gz --repo <owner>/FlashOS
```

Attestation requires a repository plan that supports it; where unsupported, the
step is the only part that will not run, and the checksummed release still stands.

## Rollback or replacement policy

Releases are immutable once published. To correct a bad release, publish a new
patch version rather than rewriting an existing tag. Re-running the workflow on an
existing tag re-uploads assets with `--clobber` but does not change the tag's
commit.
