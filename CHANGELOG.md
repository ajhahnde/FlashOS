<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Changelog</h1>

<p>
    <a href="README.md"><b>README</b></a> ·
    <a href="DOCUMENTATION.md"><b>Documentation</b></a> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
    <a href="ci/README.md"><b>CI/CD</b></a> ·
    <b>Changelog</b> ·
    <a href="LICENSE"><b>License</b></a>
  </p>

</div>

---

All notable changes to the current FlashOS source tree are recorded here. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The `0.9.0` and older tags inherited with the Redox OS source history are
upstream tags, not FlashOS releases. The former AArch64 FlashOS release history
remains available in the archived `FlashOS-old` repository.

## [Unreleased]

### Changed

- Changed the default build configuration from the inherited `desktop` profile
  to `flashos`, so an invocation without an explicit `CONFIG_NAME` builds the
  TUI-only product image instead of a graphical desktop image. The same default
  now applies to `build.sh` and to the `changelog`, `find-recipe`, and `ventoy`
  helper scripts.

### Removed

- Removed every inherited image configuration that the product does not build:
  the desktop, Wayland, X11, server, minimal, development, and test profiles,
  the inherited base configuration they were layered on, and the configuration
  directories for the inactive `aarch64`, `i586`, and `riscv64gc`
  architectures. `config/` now contains only the FlashOS base configuration and
  the active `x86_64` product profile.
- Removed the unreferenced upstream build-server image, packaging, and
  toolchain targets, which built configurations that no longer exist and named
  their artefacts after the upstream project.
- Removed the inherited graphical client library and every package recipe that
  depends on it, transitively: the SDL 1 and SDL 2 families, the OpenGL and
  multimedia libraries built on them, the demo, game, emulator, and web-browser
  packages, and the desktop, X11, and Xfce package groups. The remaining recipe
  set no longer offers a graphical stack, matching the TUI-only product scope.
  The corresponding entries were also dropped from the static-clean target, the
  native bootstrap package list, and the Nix development shell.

## [0.1.0] - 2026-07-26

### Added

- Added the independent x86_64 FlashOS image profile at
  `config/x86_64/flashos.toml`.
- Defined FlashOS as a TUI-only product: no Orbital, COSMIC, X11, Wayland,
  GUI applications, or graphical installer is selected by the active profile.
- Added a FlashOS-owned TUI base configuration without Orbital scheme access
  or the inherited legacy `/ui` compatibility symlinks; audio remains in
  scope.
- Made graphical XDG home directories optional in the inherited installer and
  disabled their creation for the FlashOS image.
- Added FlashShell to the active source tree and installed `fsh` as the login
  shell for both development accounts.
- Added the FlashShell target recipe and target-build verification.
- Added FlashOS hostname, release metadata, console issue, QEMU title, network
  boot filename, and image build path.
- Restored the English documentation suite with the original FlashOS
  light/dark logo presentation and top navigation.
- Added public hardware, trademark, attribution, and upstream reference
  documents.
- Restored GitHub Actions as an x86_64-native CI/CD architecture with
  independent build-system, FlashShell, and TUI product-contract gates.
- Added a FlashOS-owned Docker clean-room build, immutable checksummed image
  promotion, and a separate QEMU consumer that verifies FlashOS identity,
  TUI login, FlashShell pipelines, and the IHDA audio driver.
- Added a self-contained live image for removable USB media and qualified its
  exact promoted bytes through an emulated USB mass-storage boot.
- Added scheduled dependency policy, Dependabot, tag-driven release
  packaging, CycloneDX SBOM generation, checksums, and build provenance.

### Changed

- Renamed the standalone repository and product from Redox to FlashOS.
- Renamed the default branch from `master` to `main`.
- Detached the GitHub repository from the Redox OS fork network while keeping
  `redox-os/redox` as the local `upstream` remote.
- Removed the inherited Redox GitLab pipeline and GitLab templates; GitHub
  Actions is the single active public automation surface.
- Archived the former AArch64 project separately as `FlashOS-old`.
- Renamed the root support crate from `redox_cookbook` to `flashos_build`.
- Defined the intended long-term borrowed boundary as the Redox OS kernel.
  Current Redox userspace, relibc, toolchain, installer, bootloader, package,
  and build dependencies remain transitional.
- Made future kernel divergence explicit: FlashOS may stop consuming Redox
  kernel updates when its kernel requirements differ.
- Extended the product contract to enforce release-version lockstep across
  the root crate, FlashShell workspace, README, `os-release`, console issue,
  and release artefact names.
- Moved build-provenance attestation into release-candidate packaging so a
  non-publishing dry run exercises the same attestation used by tagged
  delivery.
- Updated artifact downloads and pull-request dependency review to their
  Node 24 action runtimes.
- Kept the installed-disk and removable-media contracts distinct:
  `harddrive.img` is qualified over NVMe, while `redox-live.iso` is qualified
  over USB and included in release checksums and provenance.

### Verified

- FlashShell host tests and clippy checks.
- FlashShell target compilation for `x86_64-unknown-redox`.
- Root Cargo metadata and locked dependency check.
- FlashOS build-environment selection for `x86_64` and the `flashos` profile.
- QEMU boot, login to `fsh> `, and an external-to-external pipeline on the
  final rebranded image.
- Automated QEMU contract including the FlashOS bootloader, kernel identity,
  login prompt, FlashShell pipeline, and retained IHDA audio driver.
- Non-publishing release workflow: clean-room rebuild of both images, separate
  NVMe and USB QEMU qualification, compression, checksum verification,
  CycloneDX SBOM generation, and build-provenance attestation.
- Physical live USB boot, display, keyboard, login, and FlashShell validation
  on a Sony VAIO VPCEB4L1E.

---

[← Back: CI/CD](ci/README.md) · [Back to README](README.md)
