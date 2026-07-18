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
    <a href="CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="LICENSE.md"><b>License</b></a>
  </p>

</div>

---

Reference:
[BCM2711 ARM Peripherals (RPi 4)](https://pip-assets.raspberrypi.com/categories/545-raspberry-pi-4-model-b/documents/RP-008248-DS-1-bcm2711-peripherals.pdf?disposition=inline)

## Contents

1. [Host toolchain](#1-host-toolchain)
2. [Building](#2-building)
3. [Running under QEMU](#3-running-under-qemu)
4. [SD-card layout](#4-sd-card-layout)
5. [Serial console](#5-serial-console)
6. [Helper shell functions](#6-helper-shell-functions)
7. [Host-side unit tests](#7-host-side-unit-tests)

## 1. Host toolchain

| Tool                     | Version / source       | Purpose                                      |
| :----------------------- | :--------------------- | :------------------------------------------- |
| Rust                     | repository pin         | Kernel, userland, host tools, and tests       |
| Clang                    | host LLVM               | Assemble retained AArch64 `.S` sources        |
| Rust `llvm-tools`        | repository pin         | Link, inspect, and convert AArch64 artefacts  |
| `qemu-system-aarch64`    | repository contract pin | Run the `raspi4b` boot contract              |
| `mtools`                 | current                | Create the QEMU FAT32 test disk               |
| `screen` (or equivalent) | –                      | Serial console for the Pi                     |
| Python 3                 | current                | DTR-aware unattended Pi console capture       |

On macOS:

```bash
brew install llvm qemu mtools
rustup show
```

`versions.env` is the single authored source for the live FlashOS, Rust, and
QEMU versions; `scripts/sync_versions.sh` synchronizes the conventional files
required by Cargo, rustup, CI, and the public badges. `rust-toolchain.toml`
additionally owns the `aarch64-unknown-none-softfloat` target and the
`rustfmt`, `clippy`, `llvm-tools`, and `rust-src` component set. `flashos.zsh`
resolves that exact toolchain through `rustup`, even when a package-manager
Rust appears earlier on `PATH`. Set `FLASHOS_CLANG=/path/to/clang` to override
the assembler.

### Runtime system requirements

| Item | Current requirement |
| :--- | :------------------ |
| Board | Raspberry Pi 4 Model B (BCM2711), booting AArch64 |
| RAM | The 4 GiB model is release-qualified. The 1 GiB model is unsupported because the physical-page pool begins at 1 GiB; other capacities are not part of the v0.8.0 hardware gate. |
| Boot media | One FAT32 microSD partition. The current boot bundle uses about 3.4 MiB, so any normal card has ample capacity. |
| Kernel image | The current production `kernel8.img` is about 1.2 MiB, including an approximately 87 KiB initramfs. These sizes may change between builds. |
| Console | A data-capable USB-C connection for the user console; a 3.3 V Mini-UART adapter is optional for early diagnostics and tracing. |
| Emulation | `qemu-system-aarch64 -M raspi4b`; EMMC2 and USB-device hardware legs still require a real Pi. |

## 2. Building

For a direct production build:

```bash
cargo xtask build --board rpi4b
cargo xtask armstub
```

For the complete two-pass symbol build, source the shell helpers:

```bash
source flashos.zsh         # provides the `build` helper
build                      # clean, test hygiene, two-pass build, armstub
build -d                   # same build, then deploy to the SD card
```

The `build` helper runs `cargo xtask clean`, checks source hygiene, links a
first kernel, regenerates `src/symbol_area.S` with `populate-syms`, relinks,
and verifies that the symbol layout converged. On `rpi4b` it also builds the
armstub. There is no interactive deploy prompt; `-d` is the deploy consent.

### Build steps

| Command                                            | Result                                      |
| :------------------------------------------------- | :------------------------------------------ |
| `cargo xtask build --board rpi4b`                  | Production Pi kernel, userland, initramfs   |
| `cargo xtask armstub`                              | Pi EL3→EL1 armstub                          |
| `cargo xtask populate-syms --board rpi4b`          | Regenerate `src/symbol_area.S`              |
| `cargo xtask test`                                 | Rust host tests                             |
| `cargo xtask guard --board rpi4b --full`           | Clean-room full production build            |
| `cargo xtask build --board rpi4b --trace`          | Trace-feature kernel                        |
| `cargo xtask clean`                                | Remove `target/` and `rust-out/`             |
| `run qemu`                                         | Build and run QEMU `-M raspi4b`             |
| `run watchdog rpi4b`                               | Run the unattended production boot contract |
| `build -d`                                         | Two-pass build and deploy to `$SD_BOOT`      |

Production artefacts use Cargo's `release` profile. The bare-metal target and
soft-float ABI are fixed by the build driver rather than selected interactively.

## 3. Running under QEMU

Source `flashos.zsh`, then use the live `raspi4b` path:

```bash
run qemu
run watchdog rpi4b
```

`rpi4b` is the validated board and the release gate. The retained `virt` build
is frozen and deprioritized; it is available through `run virt` for historical
comparison but is not a current compatibility promise.

For an unattended run that validates the test tally, page checkpoints,
and final `fsh` prompt:

```bash
run watchdog rpi4b
```

To verify the Pi byte-identity baseline before flashing the SD card
(stashes `src/symbol_area.S`, cleans, rebuilds, diffs against
`scripts/pi_baseline.sha256`):

```bash
scripts/verify_pi_baseline.sh
```

`run qemu` routes the `raspi4b` Mini-UART to host stdio. The watchdog builds
with both `--boot-selftest` and `--ci-login-seed`, creates the FAT32 fixture,
and enforces the serial-output contract with a 720-second ceiling.

A green run reports `30/30 passed`, no `[FAIL]` or `ERROR CAUGHT`, the
expected page checkpoints, and three shell homescreen markers. See
[Documentation §7](DOCUMENTATION.md#qemu-watchdog-contract) for the exact
invariants. QEMU is the authoritative inner-loop signal; real hardware
uses the same image, modulo timing.

## 4. SD-card layout

The Raspberry Pi 4 boots from a FAT32-formatted card whose root must
contain at least:

```text
config.txt              # ships in this repo
kernel8.img             # built by `cargo xtask build --board rpi4b`
armstub8.bin            # built by `cargo xtask armstub`
bcm2711-rpi-4-b.dtb     # bundled in this repo
start4.elf              # bundled in this repo
fixup4.dat              # bundled in this repo
overlays/miniuart-bt.dtbo
```

The firmware blobs are bundled in this repo under `firmware/`
(`bcm2711-rpi-4-b.dtb`, `start4.elf`, `fixup4.dat`,
`overlays/miniuart-bt.dtbo`), taken from the official
[raspberrypi/firmware](https://github.com/raspberrypi/firmware/tree/master/boot)
project and kept here for convenience and license/credit clarity. The
deploy step points at that directory by default:

```bash
SD_BOOT=/Volumes/BOOT FIRMWARE=firmware build -d
```

The deploy step reads two environment variables:

| Variable   | Default         | Purpose                                          |
| :--------- | :-------------- | :----------------------------------------------- |
| `SD_BOOT`  | `/Volumes/BOOT` | SD-card mount point on macOS                     |
| `FIRMWARE` | `firmware`      | Directory holding the bundled RPi firmware files |

## 5. Serial console

The kernel has three console/debug channels on the Pi:

- **Mini-UART (UART1)** on GPIO 14 / 15 — main console (and fallback
  when USB is not enumerated).
- **PL011 (UART4)** on GPIO 8 / 9 — dedicated trace channel.
- **USB-C gadget console** — the interactive `fsh` console over the
  Pi's USB-C port; no adapter or jumper wires (see below).

`config.txt` routes firmware diagnostics to GPIO 14/15. During kernel
startup, `mini_uart_init` switches those pins to Mini-UART, providing a
seamless firmware-to-kernel hand-off on the same cable.

### UART1 pinout (RPi 4 → USB-TTL adapter)

| RPi pin | Function      | USB-TTL pin |
| :------ | :------------ | :---------- |
| Pin 6   | GND           | GND         |
| Pin 8   | TXD (GPIO 14) | RXD         |
| Pin 10  | RXD (GPIO 15) | TXD         |

Do **not** connect VCC if the Pi is powered independently.

### Connecting on macOS

The PL2303G chip is supported natively. Find the device node and
open a session at 115200 baud:

```bash
ls /dev/cu.usbserial-*
```

```bash
screen /dev/cu.usbserial-XXXX 115200
```

Exit `screen` with `Ctrl-A`, then `K`, confirmed with `y`. To stop an
unattended `picapture` from a second terminal, run `piquit` (see §6).

### USB-C console (single C-to-C cable)

The Pi's USB-C port enumerates as a CDC-ACM device, carrying both power
and the interactive `fsh` console. macOS needs no additional driver.

```bash
ls /dev/cu.usbmodem*            # node appears once the gadget enumerates
```

```bash
screen /dev/cu.usbmodemDEVICE 115200
```

Once enumerated, user output switches to USB; kernel diagnostics remain
on Mini-UART. Without USB enumeration—including under QEMU—the user
console falls back automatically. The baud rate passed to `screen` is
cosmetic. Power-cycle the Pi if the console does not recover after a
cable replug.

## 6. Helper shell functions

Source [`flashos.zsh`](flashos.zsh) from the repository or your
`~/.zshrc`:

```bash
source ~/FlashOS/flashos.zsh
```

| Helper                        | Purpose                                                 |
| :---------------------------- | :------------------------------------------------------ |
| `build [-d]`                  | Two-pass symbol build; `-d` also deploys to the SD card |
| `run qemu` / `run virt`       | Build and start the selected QEMU board                 |
| `run watchdog [rpi4b \| virt]` | Run the unattended boot validation                      |
| `run test [--NAME]`           | Run all host tests or a filtered test                   |
| `run hw [--trace]`            | Attach to the Pi console                                |
| `pi capture [usb \| mu]`       | Capture a boot into `boot.log`                          |
| `pi connect [usb \| mu]`       | Open an interactive console                             |
| `pi list` / `pi quit`         | List devices or stop a capture session                  |
| `pi log` / `pi tail [N]`      | Read or follow the latest capture                       |
| `flashos` / `flashos list`    | List helpers and native build commands                  |
| `flashos versions [show \| check \| sync]` | Inspect or propagate the central version manifest |
| `flashos check [all \| versions \| docs \| hygiene \| shell]` | Run maintained repository checks |

The legacy names `picapture`, `piconnect`, `piquit`, and `pilist`
remain aliases. USB CDC devices are detected as `/dev/cu.usbmodem*`;
Mini-UART adapters as `/dev/cu.usbserial-*`. Override detection with
`PI_USB_CONSOLE_DEVICE` or `PI_SERIAL_DEVICE`. Capture timeouts can
be changed with `PI_CAPTURE_TIMEOUT` and `PI_PROBE_TIMEOUT`.
`pi capture usb` keeps DTR/RTS asserted and probes through the same open
descriptor, which avoids detached-terminal reconnects on macOS. Interactive
`pi connect` continues to use `screen`.

Set `BOARD=virt` to make `build` target the frozen `virt` input, or set
`NM=/path/to/llvm-nm` to override the symbol tool. Kernel faults are printed only on
Mini-UART, so use `pi capture mu` for fault diagnosis.

`build`, `run qemu`, `run virt`, `run watchdog`, and `run test` reject version
drift before compiling. Change a release, Rust, or QEMU version only in
`versions.env`, then run `flashos versions sync`.

## 7. Host-side unit tests

```bash
cargo xtask test
```

Runs the workspace's host-side Rust tests against kernel, ABI, userland, and
build-tool logic, excluding only the two bare-metal static libraries that
cannot link as host test binaries. The command's output is the authoritative
test count and the fastest signal that pure logic still holds.

---

[← Prev: Documentation](DOCUMENTATION.md) · [Next: Changelog →](CHANGELOG.md)
