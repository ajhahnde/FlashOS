<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt=".flashOS" width="280">
  </picture>

<h1>Setup</h1>

<p>
    <a href="README.md"><b>README</b></a> ·
    <a href="DOCUMENTATION.md"><b>Documentation</b></a> ·
    <b>Setup</b> ·
    <a href="PORT.md"><b>Port</b></a> ·
    <a href="VERSIONING.md"><b>Versioning</b></a> ·
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

| Tool                     | Minimum version | Purpose                                 |
| :----------------------- | :-------------- | :-------------------------------------- |
| Flash                    | 1.2.0           | Transpile the Flash sources used by `build.zig` |
| Zig                      | 0.16.0          | Compile remaining Zig host tools        |
| `aarch64-elf-objcopy`    | 2.40+           | ELF → raw binary                        |
| `aarch64-elf-nm`         | 2.40+           | Symbol extraction for `populate-syms`   |
| `qemu-system-aarch64`    | 11.0.0+         | Run the kernel under QEMU               |
| `screen` (or equivalent) | –               | Serial console for the Pi               |

On macOS:

```bash
brew install zig aarch64-elf-binutils qemu
```

### Flash compiler (`flashc`)

FlashOS is built with the pinned
[Flash](https://github.com/ajhahnde/Flash) toolchain. Flash publishes no
prebuilt binaries, so build it from source at the revision recorded in
`flash-toolchain.lock`:

```bash
git clone https://github.com/ajhahnde/Flash.git ~/Flash
git -C ~/Flash checkout "$(grep -oE '[0-9a-f]{40}' flash-toolchain.lock)"
( cd ~/Flash && zig build )
```

## 2. Building

Build Flash first (see §1), then run the native Flash build:

```bash
flash build               # kernel8.img + armstub8.bin → flash-out/
```

```bash
source flashos.zsh    # provides the `build` helper
build                     # full two-pass build
build -d                  # full two-pass build + deploy to the SD card
```

The `build` helper invokes `flash build`, `flash build populate-syms`, then
`flash build` again, checks that the symbol layout converged, and—with
`-d`—runs `flash build deploy`. There is no interactive prompt;
the `-d` flag is the deploy consent.

### Build steps

| Command                                  | Result                                      |
| :--------------------------------------- | :------------------------------------------ |
| `flash build`                            | Pi kernel and armstub                       |
| `flash build -Dboard=virt`               | `virt` kernel without armstub               |
| `flash build kernel`                     | Kernel image only                           |
| `flash build armstub`                    | Pi armstub only                             |
| `flash build populate-syms`              | Regenerate `src/symbol_area.S`              |
| `flash build deploy`                     | Copy the Pi build and firmware to `$SD_BOOT`|
| `flash build -Dboard=rpi4b run`          | Run QEMU `-M raspi4b`                       |
| `flash build -Dboard=virt run-virt`      | Run QEMU `-M virt`                          |
| `flash build -Dboard=rpi4b test-rpi4b`   | Validate a `raspi4b` boot                   |
| `flash build -Dboard=virt test-virt`     | Validate a `virt` boot                      |
| `flash build -Dboard=virt iso`           | Build the `virt` GRUB-EFI rescue ISO        |
| `flash build test`                       | Run host tests                              |
| `flash build clean`                      | Remove caches and build output              |

The default optimization mode is `ReleaseSmall`; override it with
`-Doptimize=ReleaseSafe`, `Debug`, or `ReleaseFast`.

## 3. Running under QEMU

Two QEMU machines are wired up; pick by `-Dboard=`:

```bash
flash build -Dboard=rpi4b run        # Pi 4 model (raspi4b)
flash build -Dboard=virt  run-virt   # generic ARMv8 (virt)
```

`-Dboard=rpi4b` is the validated board. `-M virt` has not been CI-gated since
[v0.5.0](https://github.com/ajhahnde/FlashOS/releases/tag/v0.5.0), the last
release verified to boot it, so later releases may have regressed. For a
known-stable `-M virt` build, use v0.5.0.

For an unattended run that validates the test tally, page checkpoints,
and final `fsh` prompt:

```bash
flash build -Dboard=rpi4b test-rpi4b  # (matches run); the CI boot gate
flash build -Dboard=virt  test-virt   # deprioritized, not CI-gated
```

To verify the Pi byte-identity baseline before flashing the SD card
(stashes `src/symbol_area.S`, cleans, rebuilds, diffs against
`scripts/pi_baseline.sha256`):

```bash
scripts/verify_pi_baseline.sh
```

`run` routes the `raspi4b` Mini-UART to host stdio. `run-virt` uses
`-M virt,gic-version=3 -cpu cortex-a72 -m 1G -nographic` and routes
PL011 to stdio.

A green run reports `30/30 passed`, no `[FAIL]` or `ERROR CAUGHT`, the
expected page checkpoints, and three shell homescreen markers. See
[Documentation §8](DOCUMENTATION.md#free-page-invariants) for the exact
invariants. QEMU is the authoritative inner-loop signal; real hardware
uses the same image, modulo timing.

## 4. SD-card layout

The Raspberry Pi 4 boots from a FAT32-formatted card whose root must
contain at least:

```text
config.txt              # ships in this repo
kernel8.img             # built by `flash build`
armstub8.bin            # built by `flash build`
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
SD_BOOT=/Volumes/BOOT FIRMWARE=firmware flash build deploy
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

Exit `screen` with `Ctrl-A`, then `K`, confirmed with `y`. To kill
a detached `picapture` session from a second terminal, run `piquit`
(see §6).

### USB-C console (single C-to-C cable)

The Pi's USB-C port enumerates as a CDC-ACM device, carrying both power
and the interactive `fsh` console. macOS needs no additional driver.

```bash
ls /dev/cu.usbmodem*            # node appears once the gadget enumerates
```

```bash
screen /dev/cu.usbmodem00011 115200
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

| Helper | Purpose |
| :----- | :------ |
| `build [-d]` | Two-pass symbol build; `-d` also deploys to the SD card |
| `run qemu` / `run virt` | Build and start the selected QEMU board |
| `run watchdog [rpi4b|virt]` | Run the unattended boot validation |
| `run test [--NAME]` | Run all host tests or a filtered test |
| `run hw [--trace]` | Attach to the Pi console |
| `pi capture [usb|mu]` | Capture a boot into `boot.log` |
| `pi connect [usb|mu]` | Open an interactive console |
| `pi list` / `pi quit` | List devices or stop a capture session |
| `pi log` / `pi tail [N]` | Read or follow the latest capture |
| `flashos` | List helpers and build steps |

The legacy names `picapture`, `piconnect`, `piquit`, and `pilist`
remain aliases. USB CDC devices are detected as `/dev/cu.usbmodem*`;
Mini-UART adapters as `/dev/cu.usbserial-*`. Override detection with
`PI_USB_CONSOLE_DEVICE` or `PI_SERIAL_DEVICE`. Capture timeouts can
be changed with `PI_CAPTURE_TIMEOUT` and `PI_PROBE_TIMEOUT`.

Set `BOARD=virt` to make `build` target `virt`, or `NM=llvm-nm`
to override the symbol tool. Kernel faults are printed only on
Mini-UART, so use `pi capture mu` for fault diagnosis.
## 7. Host-side unit tests

```bash
flash build test
```

Runs the host-side unit tests against pure-logic kernel modules.
Each module that has tests is its own test root, linked against
`tests/host_stubs.zig` (stubs for assembly-only externs). The
current suite covers 38 modules (427 host tests); it
finishes in well under a second and is the fastest signal that
core kernel logic still holds.

---

[← Prev: Documentation](DOCUMENTATION.md) · [Next: Port →](PORT.md)
