<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../assets/flashos_logo_dark.png">
    <img src="../assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Development</h1>

<p>
    <a href="../README.md"><b>README</b></a> ·
    <a href="README.md"><b>Documentation</b></a> ·
    <b>Development</b> ·
    <a href="verification.md"><b>Verification</b></a> ·
    <a href="../ci/README.md"><b>CI/CD</b></a> ·
    <a href="../LICENSE"><b>License</b></a>
  </p>

</div>

---

This document outlines the repository layout, local development workflow, developer tools, checks, and generated build artifacts for FlashOS.

## Contents

1. [Source layout](#1-source-layout)
2. [Development checks](#2-development-checks)
3. [Build artefacts](#3-build-artefacts)
4. [FlashShell developer guidance](#4-flashshell-developer-guidance)

## 1. Source layout

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

## 2. Development checks

When modifying the build system or system components locally, run the appropriate check layers before assembling a full image.

Run the root build-system check:

```sh
cargo check --locked
```

Run the FlashShell host gates:

```sh
cd components/flashshell
cargo test -p flashshell-cli
cargo clippy -p flashshell-cli --all-targets -- -D warnings
```

With the Redox-compatible target toolchain on `PATH`, test target compilation:

```sh
redoxer build -p flashshell-cli --bin fsh
```

Return to the repository root before building the image:

```sh
cd ../..
make CONFIG_NAME=flashos all
```

## 3. Build artefacts

Generated output is ignored by Git. The main paths are:

```text
build/x86_64/flashos/harddrive.img     QEMU or installed-disk image
build/x86_64/flashos/redox-live.iso    self-contained USB live image
build/x86_64/flashos/filesystem/       assembled filesystem when mounted
build/x86_64/flashos/repo.tag          package-repository completion marker
prefix/x86_64-unknown-redox/           target toolchain and sysroot
components/flashshell/target/          FlashShell host build output
```

Exact intermediate names may change while inherited tooling is replaced.
Only the configured image identity and verified runtime behavior are product
contracts.

## 4. FlashShell developer guidance

FlashShell (`fsh`) is built and tested as a standalone workspace in `components/flashshell/`. For component-specific instructions on unit tests, golden fixtures, fuzzing, and end-to-end PTY testing, see the [FlashShell Development Guide](../components/flashshell/docs/development.md).

---

[← Back: Architecture](architecture.md) · [Next: Verification →](verification.md)
