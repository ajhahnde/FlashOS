# 2. Build and First Boot

FlashOS uses the repository-pinned Rust toolchain and its LLVM tools, Cargo,
Clang, and `rust-lld`. The bare-metal target is
`aarch64-unknown-none-softfloat`.

`versions.env` is the single authored source for the live FlashOS, Rust, and
QEMU versions. `scripts/sync_versions.sh` updates and verifies the conventional
files consumed by Cargo, rustup, CI, and the public badges.

The release-qualified machine is a 4 GiB Raspberry Pi 4B. The 1 GiB model is
not supported because FlashOS's physical-page pool begins at 1 GiB. The current
raw kernel is about 1.2 MiB and the complete FAT32 boot bundle about 3.4 MiB;
these are current build readings, not fixed ABI limits.

On macOS, install the host dependencies and let `rustup` read the repository
pin:

```bash
brew install llvm qemu mtools
rustup show
```

## A direct production build

From the repository root:

```bash
cargo xtask build --board rpi4b
cargo xtask armstub
```

The first command builds every Rust payload, creates the deterministic
initramfs, assembles the retained `.S` inputs, links `kernel8.elf`, inspects it,
and converts it to `kernel8.img`. The second command builds the EL3-to-EL1 Pi
armstub.

The resulting files live under `rust-out/rpi4b/`:

```text
kernel8.elf    unstripped kernel for inspection
kernel8.img    raw image loaded by Pi firmware
armstub8.elf   linked bootstrap shim
armstub8.bin   raw bootstrap image
```

## The normal development helper

The shell helper adds clean-room hygiene, the two-pass symbol build, and
symbol-address convergence checking:

```bash
source flashos.zsh
build
```

It does not deploy unless you explicitly use `build -d`.

## Boot under QEMU

```bash
source flashos.zsh
run qemu
```

This starts QEMU's Raspberry Pi 4 model and routes Mini-UART to the terminal.
For the unattended release contract, use:

```bash
run watchdog rpi4b
```

The watchdog builds a selftest image, creates the FAT32 fixture, and waits up
to 720 seconds. A green run includes `30/30 passed`, 34 scenario checkpoints,
one boot-baseline checkpoint, no `[FAIL]`, no `ERROR CAUGHT`, and three shell
homescreen markers.

> [!IMPORTANT]
> `rpi4b` is the supported release path. The retained `virt` path is frozen and
> useful only for historical comparison; it is not a current compatibility
> promise.

## Why a custom target?

The target has no operating system beneath it, no host libc, and a soft-float
ABI. Kernel and user payloads therefore use `no_std` static libraries and are
linked by `xtask` with explicit linker scripts. Host tests remain ordinary
Cargo test binaries, which keeps pure logic fast to verify.

Next, we follow a byte from firmware entry to the Rust kernel.
