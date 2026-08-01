# Getting Started

[FlashOS](../README.md) › [Documentation](README.md) › Getting Started

This guide explains how to configure, build, and boot FlashOS for the first time. It is intended for users and developers who want to establish a clean toolchain and reach a working interactive QEMU session before diving deeper into system architecture. Development internals and automated verification scripts are documented separately.

## On this page

- [Before you begin](#before-you-begin)
- [Requirements](#requirements)
- [Clone the repository](#clone-the-repository)
- [Configure the build](#configure-the-build)
- [Build the development image](#build-the-development-image)
- [Build the live image](#build-the-live-image)
- [Run FlashOS in QEMU](#run-flashos-in-qemu)
- [Log in and verify the session](#log-in-and-verify-the-session)
- [Prepare physical media](#prepare-physical-media)
- [Common problems](#common-problems)
- [Next steps](#next-steps)

## Before you begin

FlashOS currently leverages an inherited Podman-based build system to compile cross-target packages in a clean container environment. The supported and primary evaluation environment is an x86_64 target architecture running inside QEMU (`q35` machine model) using UEFI firmware (`edk2`). Building a full disk image requires compiling or retrieving binary target packages, assembling a bootable disk filesystem, and invoking local virtual machine execution.

## Requirements

The supported local build path requires:
- Git
- Rustup (to automatically provision toolchains)
- GNU Make
- Podman (for containerized package cooking)
- QEMU with x86_64 system emulation and UEFI firmware (`edk2` / OVMF)
- Sufficient available storage for cross-toolchain caches, target sysroots, and compiled images.

On macOS using Homebrew, install the host dependencies:

```sh
brew install git make podman qemu
```

Alternatively, use the included Podman bootstrap helper script from inside your repository clone to install required platform tools without attempting a redundant Git re-clone:

```sh
./podman_bootstrap.sh -d -e qemu
```

On macOS, initialize and start your virtual machine for Podman before attempting a build:

```sh
podman machine init
podman machine start
```

## Clone the repository

Clone the standalone FlashOS repository directly:

```sh
git clone https://github.com/ajhahnde/FlashOS.git
cd FlashOS
git remote add upstream https://github.com/redox-os/redox.git
```

Adding the optional `upstream` remote preserves historical attribution to Redox OS and facilitates technical reference comparisons or selective kernel updates; update compatibility is not mandatory.

## Configure the build

Before launching Make, establish your local build parameters by creating a `.config` file in the repository root:

```make
PODMAN_BUILD?=1
ARCH?=x86_64
CONFIG_NAME?=flashos
PREFIX_BINARY?=1
REPO_BINARY?=1
FSTOOLS_IN_PODMAN?=1
REPO_NONSTOP?=1
```

The `.config` file is local and ignored by Git. Setting `REPO_BINARY=1` substantially accelerates initial building by utilizing cached transitional binary packages where available.

You can inspect the resulting build environment variables without triggering compilation:

```sh
make CONFIG_NAME=flashos setenv
```

This command should report `ARCH=x86_64`, `CONFIG_NAME=flashos`, and an output build directory of `build/x86_64/flashos`.

### Optional shell helpers

The repository includes optional sourceable Bash and Zsh wrapper functions for streamlining frequent development commands. To integrate them in Bash, append to `~/.bashrc`:

```sh
[[ -f /path/to/FlashOS/flashos.sh ]] && source /path/to/FlashOS/flashos.sh
```

For Zsh, source the dedicated Zsh entrypoint from `~/.zshrc` (which includes native tab completion and directory hook compatibility):

```zsh
[[ -f /path/to/FlashOS/flashos.zsh ]] && source /path/to/FlashOS/flashos.zsh
```

Key helper operations include:
- `flashos doctor` — Diagnose local toolchain and Podman health.
- `flashos status` — Summarize active profile state.
- `flashos build disk` — Assemble the default development disk image.
- `flashos run disk` — Launch interactive QEMU execution.
- `flashos qualify disk` — Run local verification gates and exact-artifact smoke tests.

These helpers are thin abstractions over documented Make, Cargo, and Python verification contracts; they never execute Git commits, tags, pushes, or physical disk writes.

## Build the development image

To build the standard development disk image, execute from the repository root:

```sh
make CONFIG_NAME=flashos all
```

During the initial build, the container pipeline compiles or fetches the target toolchain prefix, cookbook packages, installer utilities, and filesystem creation tools. Subsequent iterations reuse these persistent local caches.

Once complete, the bootable development hard drive image artifact is generated at:

```text
build/x86_64/flashos/harddrive.img
```

## Build the live image

When testing removable USB media or evaluating ephemeral systems, compile the self-contained live ISO image:

```sh
make CONFIG_NAME=flashos build/x86_64/flashos/redox-live.iso
```

This command generates `build/x86_64/flashos/redox-live.iso`. Never substitute `harddrive.img` for USB removable booting; standard hard drive images require a persistent early-root block device after kernel startup, whereas `redox-live.iso` incorporates a specialized live bootloader that clones the complete root filesystem directly into RAM before initiating system startup.

## Run FlashOS in QEMU

Start your built hard drive disk image inside an interactive QEMU session:

```sh
make CONFIG_NAME=flashos qemu
```

The default x86_64 configuration launches a QEMU `q35` virtual machine using UEFI firmware. On Apple Silicon (M1/M2/M3) hosts, QEMU performs architecture emulation for x86_64 rather than native hardware virtualization, resulting in longer initial boot durations than on native x86_64 hardware.

## Log in and verify the session

When the startup sequence reaches the console login prompt, authenticate using one of the evaluation accounts compiled into the development profile:

| User Account | Password | Login Shell |
| :-- | :-- | :-- |
| `user` | *(blank / no password)* | `/usr/bin/fsh` |
| `root` | `password` | `/usr/bin/fsh` |

> **Note:** These credentials and passwordless accounts are intentional evaluations shortcuts for local development only and are unsafe for untrusted networks or production deployments.

A successful login drops directly into FlashShell, indicated by the primary prompt:

```text
>>
```

To verify basic shell and operational integrity, test an external pipeline using tools installed on the image:

```fsh
^ls -l | ^grep flash
```

## Prepare physical media

Do not write compiled images to physical media as part of an initial setup routine. Physical hardware testing is an advanced qualification gate governed by [Hardware Compatibility](hardware.md).

> **Warning:** Writing raw disk images to block devices is destructive and will irreversibly obliterate existing data if directed to the wrong drive.

When you are ready to evaluate FlashOS on physical machines, enforce the following safety mandates:
1. Complete all local repository, recipe, and QEMU runtime qualification tests first.
2. Verify device names before every write operation. Never assume or guess device node paths (such as `/dev/sdb` or `/dev/disk2`), as operating systems reassign device identifiers dynamically between reboots and insertions.
3. Identify the destination media read-only by verifying its exact hardware model, storage capacity, and mount status using reliable system diagnostics.
4. Ensure the correct target disk is unmounted cleanly before writing.
5. Obtain explicit authorization before committing bytes to physical media.
6. Write only `redox-live.iso` for USB thumb drives; never write `harddrive.img` to removable media.

## Common problems

### Podman is unreachable or stops immediately

Inspect your Podman virtual machine status:

```sh
podman machine list
podman info
```

If stopped, restart it with `podman machine start`. On Apple Silicon hosts where background VMs close alongside their terminal parent, leave the launching terminal window open during compilation.

### The wrong image profile is selected

Verify your active Make target parameters:

```sh
make CONFIG_NAME=flashos setenv
```

If an unwanted configuration appears, inspect root `.config` and remove any obsolete or conflicting assignments for `CONFIG_NAME` or `ARCH`.

### QEMU cannot resolve UEFI firmware (`edk2`)

Ensure QEMU architecture emulation binaries are installed. The Make build orchestration scans standard Linux OVMF directories and Homebrew's default macOS edk2 repository:

```text
/opt/homebrew/opt/qemu/share/qemu/
```

Confirm that files such as `edk2-x86_64-code.fd` exist inside your QEMU share path.

### Build outputs or packages reference Redox identifiers

Do not rename internal target triples (`x86_64-unknown-redox`), compiler sysroots, `relibc` library interfaces, or intermediate build artifacts solely for branding aesthetics. Technical compatibility names explicitly remain in the source tree where they represent live build contracts during the bootstrap phase.

## Next steps

With a functioning QEMU image compiled and verified, explore deeper system topics:
- Review [Architecture](architecture.md) to study layer separations and build-to-boot sequencing.
- Consult [Development](development.md) for modifying package recipes and iterating on system crates.
- Visit [Verification and Testing](verification.md) to execute automated product profile assertions and serial smoke tests locally.

---

[← Previous: Documentation Index](README.md) · [Documentation index](README.md) · [Next: Architecture →](architecture.md)
