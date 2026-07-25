<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Setup</h1>

<p>
    <a href="README.md"><b>README</b></a> ·
    <a href="DOCUMENTATION.md"><b>Documentation</b></a> ·
    <b>Setup</b> ·
    <a href="ci/README.md"><b>CI/CD</b></a> ·
    <a href="CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="LICENSE"><b>License</b></a>
  </p>

</div>

---

FlashOS currently uses the inherited Podman-based build pipeline. The primary
development configuration is x86_64 with QEMU and UEFI.

## Contents

1. [Requirements](#1-requirements)
2. [Cloning and configuring](#2-cloning-and-configuring)
3. [Building the image](#3-building-the-image)
4. [Running QEMU](#4-running-qemu)
5. [Login](#5-login)
6. [Development checks](#6-development-checks)
7. [CI-equivalent local checks](#7-ci-equivalent-local-checks)
8. [Hardware preparation](#8-hardware-preparation)
9. [Troubleshooting](#9-troubleshooting)

## 1. Requirements

The supported development path requires:

- Git;
- Rustup;
- GNU Make;
- Podman;
- QEMU with x86_64 system emulation;
- enough disk space for the target toolchain, package cache, and image.

On macOS with Homebrew:

```sh
brew install git make podman qemu
```

The bootstrap script can install the platform dependencies:

```sh
./podman_bootstrap.sh -d -e qemu
```

`-d` is important inside an existing clone: it installs dependencies without
trying to clone FlashOS again.

## 2. Cloning and configuring

Clone the independent FlashOS repository:

```sh
git clone https://github.com/ajhahnde/FlashOS.git
cd FlashOS
git remote add upstream https://github.com/redox-os/redox.git
```

The `upstream` remote is optional for building. It preserves attribution and
allows comparison or selective kernel updates; it is not a requirement that
FlashOS remain update-compatible.

Create `.config` in the repository root:

```make
PODMAN_BUILD?=1
ARCH?=x86_64
CONFIG_NAME?=flashos
PREFIX_BINARY?=1
REPO_BINARY?=1
FSTOOLS_IN_PODMAN?=1
REPO_NONSTOP?=1
```

`.config` is local and ignored by Git. `REPO_BINARY=1` speeds up the
transitional package build by using available binary packages.

Start the Podman virtual machine on macOS:

```sh
podman machine init
podman machine start
```

If a machine already exists, only the second command is needed. On Apple
Silicon, keep the terminal that started the Podman machine open while the
build runs if the VM exits when its launching shell closes.

## 3. Building the image

From the repository root:

```sh
make CONFIG_NAME=flashos all
```

The first build may download or build the compiler prefix, packages, installer,
and filesystem tools. Later builds reuse their caches.

The output image is:

```text
build/x86_64/flashos/harddrive.img
```

Inspect the selected build environment without building:

```sh
make CONFIG_NAME=flashos setenv
```

It should report `ARCH=x86_64`, `CONFIG_NAME=flashos`, and the build directory
`build/x86_64/flashos`.

## 4. Running QEMU

Start the built image:

```sh
make CONFIG_NAME=flashos qemu
```

The default x86_64 configuration uses a QEMU `q35` machine and UEFI. On an
Apple Silicon host, QEMU emulates x86_64 rather than using native
virtualization, so boot is slower than on an x86_64 host.

The Make configuration searches common Linux OVMF locations and the Homebrew
edk2 firmware path. If QEMU reports missing firmware, confirm that the QEMU
package installed its x86_64 edk2 files.

## 5. Login

The development image currently contains:

| User | Password | Shell |
| :-- | :-- | :-- |
| `user` | blank | `/usr/bin/fsh` |
| `root` | `password` | `/usr/bin/fsh` |

These credentials are intentionally convenient for local testing and are not
safe for a distributed or network-exposed image.

A successful interactive gate reaches:

```text
fsh>
```

Then verify one external-to-external pipeline, for example with commands
available in the image.

## 6. Development checks

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

With the Redox-compatible target toolchain on `PATH`, run:

```sh
redoxer build -p flashshell-cli --bin fsh
```

Return to the repository root before building the image:

```sh
cd ../..
make CONFIG_NAME=flashos all
```

## 7. CI-equivalent local checks

Validate the active TUI product boundary:

```sh
python3 ci/check_profile.py
```

After building the image, run the same runtime contract used by CI:

```sh
python3 ci/qemu_smoke.py \
  --image build/x86_64/flashos/harddrive.img \
  --log build/x86_64/flashos/qemu-smoke.log
```

The automation uses a null host audio backend but keeps an HDA controller in
the virtual machine. The guest IHDA driver must start for the test to pass.
The Docker build boundary, artefact handoff, security automation, and release
flow are described in [CI/CD](ci/README.md).

## 8. Hardware preparation

Do not write the image to a physical disk as part of initial setup.
[HARDWARE.md](HARDWARE.md) defines the qualification gate.

Before any physical write:

1. finish the repository, recipe, image, and QEMU gates;
2. identify the exact target device read-only by model, capacity, and mounts;
3. unmount the correct device without guessing its name;
4. obtain explicit approval for the exact write target;
5. write and verify the image.

The physical test starts only after the migration is final.

## 9. Troubleshooting

### Podman is not reachable

Check the machine state:

```sh
podman machine list
podman info
```

Start the machine if it is stopped. If it exits immediately on macOS, launch it
from a terminal that remains open during the build.

### The wrong image profile is selected

Run:

```sh
make CONFIG_NAME=flashos setenv
```

Check `.config` for an old `CONFIG_NAME` or `ARCH` assignment.

### QEMU cannot find UEFI firmware

Confirm that QEMU is installed and locate its edk2 x86_64 code image. Homebrew
normally installs it under:

```text
/opt/homebrew/opt/qemu/share/qemu/
```

### A package still uses a Redox name

Do not rename target triples, ABI crates, relibc interfaces, or build artefacts
only for appearance. First determine whether the name is an active
compatibility interface. Product-facing FlashOS identity and inherited
technical identifiers intentionally coexist during the transition.

---

[← Back: Documentation](DOCUMENTATION.md) · [Next: Changelog →](CHANGELOG.md)
