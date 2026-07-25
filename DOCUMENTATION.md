<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Documentation</h1>

<p>
    <a href="README.md"><b>README</b></a> ·
    <b>Documentation</b> ·
    <a href="SETUP.md"><b>Setup</b></a> ·
    <a href="ci/README.md"><b>CI/CD</b></a> ·
    <a href="CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="LICENSE"><b>License</b></a>
  </p>

</div>

---

This document describes the current x86_64 implementation. The former
AArch64/Raspberry Pi implementation is preserved in the separately archived
`FlashOS-old` repository and is not a contract for this source tree.

## Contents

1. [Project boundary](#1-project-boundary)
2. [Source layout](#2-source-layout)
3. [Image configuration](#3-image-configuration)
4. [Build and boot path](#4-build-and-boot-path)
5. [FlashShell integration](#5-flashshell-integration)
6. [Identity and compatibility names](#6-identity-and-compatibility-names)
7. [Verification](#7-verification)
8. [CI/CD](#8-cicd)
9. [Build artefacts](#9-build-artefacts)

## 1. Project boundary

FlashOS is an independent solo project. Its repository, releases, product
identity, system configuration, roadmap, and shell are owned by FlashOS.

FlashOS is a TUI product. A framebuffer, display driver, keyboard driver, and
`fbcond` may be required to present a terminal on physical hardware; they are
not a desktop or GUI layer. Orbital, COSMIC, X11, Wayland, graphical
applications, and a graphical installer are outside the product scope.

The current source tree began as a Redox OS build-system baseline. During the
bootstrap phase it still consumes the Redox kernel, target toolchain, relibc,
bootloader, installer, userspace packages, recipes, and image tooling. This is
an implementation fact, not the intended permanent system boundary.

The long-term boundary is:

```text
Redox OS kernel lineage
        │
        ▼
FlashOS kernel boundary
        │
        ├── FlashOS system services and userspace
        ├── FlashOS packaging and image definition
        └── FlashShell product interface
```

The kernel may later be patched, forked, or vendored for FlashOS. If that work
makes later Redox kernel updates impractical, update compatibility is optional.
That future kernel split is a deliberate project step, not part of the current
repository migration.

## 2. Source layout

```text
config/
  flashos-base.toml               TUI foundation without Orbital or /ui paths
  x86_64/flashos.toml             active FlashOS image manifest

components/
  flashshell/                     nested FlashShell Cargo workspace

recipes/
  core/kernel/                    current kernel source and build recipe
  terminal/flashshell/            fsh package recipe
  ...                             transitional inherited package recipes

mk/                               Make build modules
podman/                           container build environment
scripts/                          build, boot, and maintenance helpers
ci/                              product contracts and QEMU automation
.github/workflows/               CI, security, reusable image, and release flows
src/                              root build-system support crate
versions.env                      live release version used by delivery gates
Makefile                          top-level image and emulator entry point
```

The root Cargo package is named `flashos_build`. It supports the inherited
package and image pipeline; it is not the operating-system kernel. FlashShell
has its own workspace, toolchain file, libraries, tests, and license under
`components/flashshell/`.

## 3. Image configuration

[`config/x86_64/flashos.toml`](config/x86_64/flashos.toml) is the source of
truth for the active image. It includes the inherited base profile, then
defines the FlashOS-specific package set and identity.

The active manifest includes
[`config/flashos-base.toml`](config/flashos-base.toml), a FlashOS-owned
foundation that retains console display, input, audio, networking, and normal
filesystem paths without inheriting Orbital permissions or legacy `/ui`
symlinks.

The current package set is deliberately small and contains no GUI package:

- `flashshell`
- `coreutils`
- `extrautils`

The image creates `root` and `user`, with `/usr/bin/fsh` as the shell for both
accounts. It also writes:

- a TUI-oriented scheme policy without `orbital` access;
- `/etc/hostname` as `flashos`;
- `/usr/lib/os-release` with the FlashOS 0.1.0 identity;
- `/etc/issue` with the FlashOS version;
- the console init service used to start login sessions.

The root password and blank development-user password in this manifest are
not production credentials. They exist only for the current local image.

## 4. Build and boot path

The build is driven by Make and can run through Podman:

1. `.config` or command-line variables select `ARCH=x86_64` and
   `CONFIG_NAME=flashos`.
2. The prefix stage provides the `x86_64-unknown-redox` compiler and sysroot.
3. Cookbook builds or retrieves the packages selected by the FlashOS manifest.
4. The installer assembles the filesystem and applies FlashOS users and files.
5. The disk stage creates `build/x86_64/flashos/harddrive.img`.
6. QEMU starts a `q35` machine, normally with UEFI firmware, and attaches the
   disk image.
7. The console service starts `getty`; login launches `/usr/bin/fsh`.

The current build foundation still has internal files and variables whose
names contain `redox`. They remain where they identify inherited tooling or
formats. User-visible FlashOS paths and titles use the FlashOS name.

The inherited `base` package still carries some functions that the minimal
image may not need, including a development daemon. These are tracked as
pruning candidates. Console display, input, audio, storage, and
hardware-enumeration paths must be retained until their product and physical
hardware dependencies have been verified. TUI-only does not mean audio-free.

## 5. FlashShell integration

FlashShell is developed in-tree at
[`components/flashshell/`](components/flashshell/). Its primary crates separate
syntax, runtime behavior, platform interfaces, POSIX integration, and the CLI.

The target package recipe at
[`recipes/terminal/flashshell/recipe.toml`](recipes/terminal/flashshell/recipe.toml)
builds the `fsh` binary from
`components/flashshell/crates/flashshell-cli`. The installed path is
`/usr/bin/fsh`, which matches the shell entries in the image manifest.

Host development and target integration are separate gates:

```sh
cd components/flashshell
cargo test -p flashshell-cli
cargo clippy -p flashshell-cli --all-targets -- -D warnings
redoxer build -p flashshell-cli --bin fsh
```

The first two commands validate the host implementation. The final command
validates the target ABI using the Redox-compatible sysroot.

## 6. Identity and compatibility names

FlashOS product identity is used in the image name, hostname, release files,
virtual-machine title, network boot file, documentation, and public project
surface.

Some names intentionally remain:

| Name | Why it remains |
| :-- | :-- |
| `x86_64-unknown-redox` | current compiler target and ABI |
| `redoxer` | current target build tool |
| `relibc` and `redox_*` crates | current system interfaces |
| selected `redox-*` artefact names | inherited build or disk formats |
| `upstream` remote | attribution, comparison, and optional kernel updates |

Renaming an active interface without replacing it would hide a dependency
rather than remove it. Compatibility names disappear only when FlashOS owns a
working replacement.

## 7. Verification

Changes are accepted in layers:

1. **Orientation** — the shared Codex/Claude session hook reports the active
   FlashOS repository without applying archived AArch64 contracts.
2. **Host shell** — FlashShell tests and clippy pass.
3. **Target shell** — `fsh` builds for `x86_64-unknown-redox`.
4. **Recipe** — the FlashShell package cooks from the intended source.
5. **Image** — the `flashos` image builds with the expected identity, package,
   user, and shell metadata.
6. **QEMU** — login reaches `fsh> ` and an external-to-external pipeline runs.
7. **Hardware** — a physical device is tested only after the migration and
   image gates are complete.

The physical qualification criteria and current matrix are maintained in
[HARDWARE.md](HARDWARE.md).

## 8. CI/CD

The automation preserves a strict producer/consumer boundary:

1. root build-system and FlashShell checks run independently;
2. the active package, TUI, login-shell, and audio policy is checked without
   building an image;
3. a FlashOS-owned Docker environment performs the clean-room x86_64 build;
4. the resulting disk and checksum are uploaded as one immutable workflow
   artefact;
5. a separate runner downloads those exact bytes and boots them in QEMU;
6. the smoke test verifies FlashOS branding, the TUI login, FlashShell,
   an external pipeline, and the IHDA audio driver;
7. scheduled security automation evaluates advisories, licenses, dependency
   sources, and newly introduced pull-request dependencies;
8. a semantic-version tag rebuilds and qualifies the image, emits checksums
   and a CycloneDX SBOM, records build provenance, and publishes the release.

The reusable image workflow is shared by continuous integration and release
delivery. Releases therefore cannot bypass the same runtime qualification
used on `main`. See [CI/CD](ci/README.md) for the boundary table and local
contract commands.

## 9. Build artefacts

Generated output is ignored by Git. The main paths are:

```text
build/x86_64/flashos/harddrive.img     bootable development disk image
build/x86_64/flashos/filesystem/       assembled filesystem when mounted
build/x86_64/flashos/repo.tag          package-repository completion marker
prefix/x86_64-unknown-redox/           target toolchain and sysroot
components/flashshell/target/          FlashShell host build output
```

Exact intermediate names may change while inherited tooling is replaced.
Only the configured image identity and verified runtime behavior are product
contracts.

---

[← Back: README](README.md) · [Next: Setup →](SETUP.md)
