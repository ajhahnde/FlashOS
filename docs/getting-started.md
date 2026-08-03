# Getting Started

[FlashOS](../README.md) › [Documentation](README.md) › Getting Started

This guide takes you from a fresh repository clone to an interactive FlashOS session in QEMU. It covers the default x86_64 development profile, its local build configuration, the generated image artifacts, and first-login checks; repository development and verification workflows are documented separately.

> **Project status:** FlashOS is pre-alpha software. Build requirements, image formats, interfaces, and supported workflows may change without compatibility guarantees.

## On this page

- [What this guide builds](#what-this-guide-builds)
- [Host requirements](#host-requirements)
- [Clone the repository](#clone-the-repository)
- [Install the build dependencies](#install-the-build-dependencies)
- [Configure the local build](#configure-the-local-build)
- [Check the environment](#check-the-environment)
- [Build the development image](#build-the-development-image)
- [Boot FlashOS in QEMU](#boot-flashos-in-qemu)
- [Log in and verify FlashShell](#log-in-and-verify-flashshell)
- [Build and run the live image](#build-and-run-the-live-image)
- [Optional shell helpers](#optional-shell-helpers)
- [Physical media](#physical-media)
- [Troubleshooting](#troubleshooting)
- [Next steps](#next-steps)

## What this guide builds

The default configuration used here is:

| Setting                 | Value                                 |
| ----------------------- | ------------------------------------- |
| Target architecture     | `x86_64`                              |
| Target ABI              | `x86_64-unknown-redox`                |
| Image profile           | `flashos`                             |
| Primary interface       | FlashShell at `/usr/bin/fsh`          |
| Primary virtual machine | QEMU `q35`                            |
| Firmware path           | x86_64 UEFI through OVMF or edk2      |
| Development disk        | `build/x86_64/flashos/harddrive.img`  |
| Live image              | `build/x86_64/flashos/redox-live.iso` |

The `flashos` profile is a development image. It contains convenience credentials intended only for local evaluation and must not be treated as a secure deployment configuration.

## Host requirements

The documented build path uses Podman to run the cross-compilation and package-building environment.

Install or provide the following host tools:

- Git
- GNU Make
- Python 3
- Rust and Cargo, preferably managed through Rustup
- Podman
- QEMU with `qemu-system-x86_64`
- x86_64 OVMF or edk2 firmware
- sufficient storage for downloaded sources, toolchains, package caches, and generated images

The exact package names vary between host operating systems and distributions. The repository provides a bootstrap script for several Unix-like host environments.

On macOS, Podman normally runs through a Podman-managed virtual machine. On Linux, Podman commonly runs directly through the host container runtime.

## Clone the repository

Clone FlashOS and enter the repository root:

```bash
git clone https://github.com/ajhahnde/FlashOS.git
cd FlashOS
```

All commands in this guide are run from the repository root unless stated otherwise.

## Install the build dependencies

The repository bootstrap script can install the detected platform dependencies without cloning another copy of the repository:

```bash
./podman_bootstrap.sh -d -e qemu
```

Review the script before running it. Depending on the host, it may:

- invoke the system package manager;
- request elevated privileges;
- install Rustup when Rust is unavailable;
- install Podman, QEMU, FUSE-related tools, and build utilities.

You may instead install the requirements manually through your operating system's package manager.

### Start Podman on macOS

Create a Podman machine if one does not already exist:

```bash
podman machine init
```

Start it before building:

```bash
podman machine start
```

Check that Podman can reach its runtime:

```bash
podman info
```

Do not run `podman machine init` repeatedly after a machine has already been created. Use the following command to inspect existing machines:

```bash
podman machine list
```

## Configure the local build

Create a `.config` file in the repository root:

```bash
cat > .config <<'EOF'
PODMAN_BUILD?=1
ARCH?=x86_64
CONFIG_NAME?=flashos
EOF
```

This file is local build state and is ignored by Git.

The settings select:

- the Podman build path;
- the supported FlashOS architecture;
- the standard development image profile.

### Optional binary packages

To allow the build system to use transitional binary packages where available, add:

```bash
printf '%s\n' 'REPO_BINARY?=1' >> .config
```

This can reduce the amount of source compilation required for an initial image. Omit it when you specifically need locally cooked packages instead of available binary packages.

Avoid adding unrelated build variables until the default configuration works. Development-specific overrides and package workflows belong in [Development](development.md).

## Check the environment

Inspect the selected Make environment:

```bash
make CONFIG_NAME=flashos setenv
```

The output should include values equivalent to:

```text
ARCH=x86_64
CONFIG_NAME=flashos
BUILD=build/x86_64/flashos
```

The optional repository shell helpers provide a broader environment check. Load the Bash-compatible helper temporarily:

```bash
source ./flashos.sh
flashos doctor
```

The check reports whether the principal host tools, local `.config`, Podman runtime, QEMU executable, and UEFI firmware are available.

A missing optional `redoxer` installation does not prevent the normal image build. It is required for specific target-side FlashShell compilation workflows documented elsewhere.

## Build the development image

Build the standard development disk:

```bash
make CONFIG_NAME=flashos all
```

The first build may download source repositories, create the Podman build environment, obtain or compile the cross toolchain, prepare packages, and build the filesystem tools before assembling the image.

A successful build produces:

```text
build/x86_64/flashos/harddrive.img
```

The image contains the filesystem and boot components selected by `config/x86_64/flashos.toml`.

Build outputs are generated locally and must not be committed to the repository.

## Boot FlashOS in QEMU

Start the development image:

```bash
make CONFIG_NAME=flashos qemu
```

For the x86_64 profile, the Make configuration selects a QEMU `q35` machine with UEFI firmware. The default virtual machine configuration includes a display, keyboard input, emulated storage, networking, and serial diagnostic output.

On an x86_64 Linux host, QEMU may use hardware acceleration when it is available. When the host and target architectures differ, QEMU uses architecture emulation and startup can be slower.

The first boot may pause at the FlashOS bootloader. Follow the on-screen instructions to start the selected entry.

To stop a terminal-attached QEMU process, use QEMU's exit sequence:

```text
Ctrl+A, then X
```

Closing the QEMU display window also ends an ordinary interactive run.

## Log in and verify FlashShell

The development profile provides two local evaluation accounts:

| Username | Password | Login shell    |
| -------- | -------- | -------------- |
| `user`   | `user`   | `/usr/bin/fsh` |
| `root`   | `root`   | `/usr/bin/fsh` |

Use the unprivileged account for the first session:

```text
username: user
password: user
```

> **Security warning:** These credentials are compiled into the development profile for local testing. Do not expose this image to an untrusted environment or distribute it as a secure release image.

A successful login starts FlashShell and displays its primary prompt:

```text
>>
```

Run the following pipeline to verify external command execution and byte-stream piping:

```fsh
printf 'hello\nworld\n' | head -n 1
```

The expected output is:

```text
hello
```

You can also verify status-based branching:

```fsh
^false || echo fallback
```

The expected output is:

```text
fallback
```

FlashShell is not a POSIX shell. Do not assume that Bash or POSIX syntax has the same meaning. The component documentation describes the supported language and execution model:

- [FlashShell Overview](../components/flashshell/README.md)
- [FlashShell Documentation](../components/flashshell/docs/README.md)

## Build and run the live image

The development disk and live image serve different workflows:

| Artifact         | Intended use                                                                        |
| ---------------- | ----------------------------------------------------------------------------------- |
| `harddrive.img`  | Persistent development disk used by the normal QEMU workflow                        |
| `redox-live.iso` | Self-contained live image used for live boot evaluation and removable-media testing |

Build the live image:

```bash
make CONFIG_NAME=flashos live
```

The resulting artifact is:

```text
build/x86_64/flashos/redox-live.iso
```

To expose the live image to QEMU as USB mass storage, run:

```bash
make CONFIG_NAME=flashos qemu live=yes disk=usb
```

The live image is assembled with the live bootloader path and loads its root filesystem for an ephemeral session. Changes made during that session should not be treated as persistent development state.

## Optional shell helpers

The repository includes sourceable Bash and Zsh helpers. They wrap the underlying Make, Cargo, Python, and Git inspection commands without replacing those interfaces.

### Bash

Add the following line to your shell configuration, replacing the path with the location of your clone:

```bash
source /path/to/FlashOS/flashos.sh
```

Reload the shell and inspect the available commands:

```bash
flashos help
```

Common first-use commands include:

```bash
flashos status
flashos doctor
flashos env
flashos build disk
flashos run disk
flashos build live
flashos run live
```

The shorter alias `fos` invokes the same dispatcher:

```bash
fos status
```

### Zsh

Source the Zsh entry point:

```zsh
source /path/to/FlashOS/flashos.zsh
```

The Zsh entry point loads the shared helper implementation and provides Zsh command completion.

The helpers maintain their own selected profile variables for the current shell session. The default values are:

```text
FLASHOS_ARCH=x86_64
FLASHOS_CONFIG_NAME=flashos
```

For the basic workflow, the direct Make commands remain the canonical commands documented by this guide.

## Physical media

Physical boot testing is not required for the initial setup. Establish a working QEMU session first.

The documented removable-media artifact is:

```text
build/x86_64/flashos/redox-live.iso
```

> **Warning:** Writing a raw image to a block device destroys the existing contents of the selected destination. An incorrect device path can erase an unrelated disk.

Before writing an image to physical media:

1. complete the QEMU build and boot workflow;
2. identify the destination by model, capacity, and connection type;
3. verify that no required filesystem on the destination remains mounted;
4. use a trusted imaging tool appropriate for the host operating system;
5. verify the destination again immediately before approving the write;
6. retain any important data on separate media.

This guide deliberately does not provide a generic raw-device command because destination naming and safe unmount procedures differ between hosts.

A booting image on one device is not evidence of general hardware compatibility. Consult [Hardware Compatibility](hardware.md) for qualification criteria and published device-specific results.

## Troubleshooting

### Podman is unavailable

Check whether the executable is installed:

```bash
podman --version
```

Check runtime connectivity:

```bash
podman info
```

On hosts that use a Podman machine:

```bash
podman machine list
podman machine start
```

If `podman info` fails, resolve the container runtime problem before retrying the FlashOS build.

### The build selected the wrong architecture

Inspect the effective environment:

```bash
make CONFIG_NAME=flashos setenv
```

For this guide, it must report:

```text
ARCH=x86_64
CONFIG_NAME=flashos
```

Check `.config` for conflicting assignments. Command-line Make variables override values from `.config`.

### QEMU cannot find UEFI firmware

Confirm that QEMU and x86_64 firmware are installed:

```bash
qemu-system-x86_64 --version
```

Then use the helper check:

```bash
source ./flashos.sh
flashos doctor
```

FlashOS expects an OVMF or edk2 x86_64 firmware file in one of the host paths recognized by the QEMU or smoke-test configuration. Package layouts differ between Linux distributions and macOS package managers.

### The expected image does not exist

Check the selected output directory:

```bash
make CONFIG_NAME=flashos setenv
```

Build the development disk again:

```bash
make CONFIG_NAME=flashos all
```

Build the live image again:

```bash
make CONFIG_NAME=flashos live
```

The expected files are:

```text
build/x86_64/flashos/harddrive.img
build/x86_64/flashos/redox-live.iso
```

### A partial or stale image causes problems

Rebuild the development image and its generated repository state:

```bash
make CONFIG_NAME=flashos rebuild
```

This is broader than a normal incremental build. Use the narrower `all` or `live` target for routine iteration.

### The image contains Redox identifiers

Identifiers such as the following remain active technical interfaces in the current build:

```text
x86_64-unknown-redox
relibc
redox-live.iso
redox_installer
redoxfs
```

Do not rename them locally merely to change project branding. They identify target ABI, inherited tools, filesystem formats, or build contracts.

FlashOS project identity and upstream boundaries are explained in [Architecture](architecture.md) and [Upstream References](upstream/README.md).

### Login fails

Confirm that you built the development profile:

```text
CONFIG_NAME=flashos
```

Its credentials are:

```text
user / user
root / root
```

The separate `flashos-release` profile intentionally uses a different credential model and is not the profile used by this first-build guide.

## Next steps

After reaching a working FlashShell prompt:

- read [Architecture](architecture.md) for system layers, image configuration, and component boundaries;
- use [Development](development.md) for repository modification and package iteration;
- follow [Verification and Testing](verification.md) before treating a build as qualified;
- consult [Hardware Compatibility](hardware.md) before drawing conclusions about physical-device support;
- open the [FlashShell Documentation](../components/flashshell/docs/README.md) for language and scripting details.

---

[← Previous: Documentation Index](README.md) · [Documentation index](README.md) · [Next: Architecture →](architecture.md)
