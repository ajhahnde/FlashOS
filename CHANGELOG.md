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
- Added shared private Codex and Claude orientation, rules, hooks, handovers,
  and project-state integration for the new repository.
- Restored GitHub Actions as an x86_64-native CI/CD architecture with
  independent build-system, FlashShell, and TUI product-contract gates.
- Added a FlashOS-owned Docker clean-room build, immutable checksummed image
  promotion, and a separate QEMU consumer that verifies FlashOS identity,
  TUI login, FlashShell pipelines, and the IHDA audio driver.
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

### Verified

- FlashShell host tests and clippy checks.
- FlashShell target compilation for `x86_64-unknown-redox`.
- Root Cargo metadata and locked dependency check.
- FlashOS build-environment selection for `x86_64` and the `flashos` profile.
- QEMU boot, login to `fsh> `, and an external-to-external pipeline on the
  final rebranded image.
- Automated QEMU contract including the FlashOS bootloader, kernel identity,
  login prompt, FlashShell pipeline, and retained IHDA audio driver.

### Pending

- Run the new GitHub-hosted Docker build and security policies after the
  migration changes are committed.
- Begin physical hardware qualification only after all software-migration
  gates pass.

---

[← Back: CI/CD](ci/README.md) · [Back to README](README.md)
