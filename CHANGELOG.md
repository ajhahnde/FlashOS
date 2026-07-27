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

- Added a line editor to the console shell. `fsh` on the image read input in
  canonical mode, so a session had no in-line editing, no history recall, and no
  continuation prompt for an incomplete block. The shell now decodes keys
  itself, holds the terminal in raw mode for the duration of a single read, and
  redraws one physical row. It is selected only when standard input and standard
  output are both terminals, so a redirected session still reads plain lines
  instead of receiving cursor escapes.
- Added a release image profile that locks the root account, so a published
  image no longer carries a root password. Locking is expressed by a new
  `locked` user option in the image installer and writes an unmatchable hash;
  `sudo` is unaffected because it authenticates the invoking user before
  switching to uid 0.
- Added a security policy covering scope, supported versions, private
  vulnerability reporting, and the credential weaknesses that published images
  still carry.
- Added a second software bill of materials describing the operating-system
  image itself. Releases now publish a source document and an image document,
  each named for what it covers, with the image document bound to the SHA-256
  digests of the artifacts it describes.
- Added product-contract rules covering release credentials, parity between the
  development and release profiles, and immutable revisions for every recipe
  that reaches the image.
- Added a lint gate for the release-critical Python in `ci/`.

### Changed

- Pinned every input the image is built from: the container base image by
  digest, the Rust toolchain and its installer by version and checksum, the
  build-system Git dependencies by revision, every package recipe that reaches
  the image by revision, and the host installer that writes the image. The same
  commit previously resolved to whatever the upstream default branches happened
  to be at build time, including the kernel and the shell.
- Corrected the build-support crate license to `MIT`, matching the root license
  file and the upstream origin of every file under `src/`.

- Changed the default build configuration from the inherited `desktop` profile
  to `flashos`, so an invocation without an explicit `CONFIG_NAME` builds the
  TUI-only product image instead of a graphical desktop image. The same default
  now applies to `build.sh` and to the `changelog`, `find-recipe`, and `ventoy`
  helper scripts.
- Declared the license and repository of the build-support crate and dropped
  its inherited author field, matching the FlashShell workspace metadata.
- Corrected two build-support paths that pointed at directories the recipe
  tree no longer uses.

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
- Removed an unreferenced maintenance script that checked package coverage
  against an image configuration that no longer exists.
- Removed the inherited work-in-progress recipe collection and the packages
  that depended on it, transitively: the X11 and desktop client libraries, the
  text and font shaping stack built on them, and the development, scripting,
  and test-suite convenience groups. The recipe set is now 226 packages
  covering the kernel, core system, terminal userspace, and their libraries.
- Removed an unreferenced toolchain package manifest that no build step read
  and that listed packages without recipes.
- Removed the inherited windowing system and its clients, together with the
  graphical toolkits, font, icon, and wallpaper data packages, and the
  two-dimensional rendering libraries that only served them. The recipe set is
  now 192 packages and contains no windowing stack.
- Removed the unreferenced VirtualBox emulator target. QEMU is the supported
  emulation path.
- Removed VirtualBox installation from the native and container bootstrap
  scripts, which offered to install an emulator the build system can no longer
  target.

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
