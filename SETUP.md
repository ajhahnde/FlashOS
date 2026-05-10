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
    <a href="REFERENCE.md"><b>Reference</b></a> ·
    <a href="MIGRATION.md"><b>Migration</b></a> ·
    <a href="LICENSE.md"><b>License</b></a>
  </p>
</div>

---

This page covers the host toolchain, the SD-card layout the Raspberry
Pi 4 expects, the serial console, QEMU, and the test runner.

Reference:
[BCM2711 ARM Peripherals (RPi 4)](https://pip-assets.raspberrypi.com/categories/545-raspberry-pi-4-model-b/documents/RP-008248-DS-1-bcm2711-peripherals.pdf?disposition=inline).

## Contents

1. [Host toolchain](#1-host-toolchain)
2. [Building](#2-building)
3. [Running under QEMU](#3-running-under-qemu)
4. [SD-card layout](#4-sd-card-layout)
5. [Serial console](#5-serial-console)
6. [Helper shell functions](#6-helper-shell-functions)
7. [Host-side unit tests](#7-host-side-unit-tests)

## 1. Host toolchain

| Tool                     | Minimum version | Purpose                                |
| :----------------------- | :-------------- | :------------------------------------- |
| Zig                      | 0.16.0          | Compile Zig + assembly, run `build.zig` |
| `aarch64-elf-objcopy`    | 2.40+           | ELF → raw binary                       |
| `aarch64-elf-nm`         | 2.40+           | Symbol extraction for `populate-syms`  |
| `qemu-system-aarch64`    | 11.0.0+         | Run the kernel under QEMU              |
| `screen` (or equivalent) | –               | Serial console for the Pi              |

On macOS:

```bash
brew install zig aarch64-elf-binutils qemu
```

## 2. Building

```bash
zig build                 # default: kernel8.img + armstub8.bin → zig-out/
```

```bash
./build.sh                # full two-pass build with optional deploy
```

`build.sh` invokes `zig build`, `zig build populate-syms`, then
`zig build` again, diff-checks that the symbol layout converged, and
optionally runs `zig build deploy`.

## 3. Running under QEMU

Two QEMU machines are wired up; pick by `-Dboard=`:

```bash
zig build -Dboard=rpi4b run        # Pi 4 model (raspi4b)
zig build -Dboard=virt  run-virt   # generic ARMv8 (virt)
```

For a self-validating run that exits 0 on `8/8 passed` and 1 on
`ERROR CAUGHT`, count drift, or watchdog timeout — no manual
QEMU babysitting:

```bash
zig build -Dboard=virt  test-virt   
zig build -Dboard=rpi4b test-rpi4b  # (matches `run`)
```

To verify the Pi byte-identity baseline before flashing the SD card
(stashes `src/symbol_area.S`, cleans, rebuilds, diffs against
`scripts/pi_baseline.sha256`):

```bash
scripts/verify_pi_baseline.sh
```

`run` invokes
`qemu-system-aarch64 -M raspi4b -serial null -serial stdio -kernel zig-out/kernel8.img`
— the Mini-UART (UART1) is routed onto host stdio so the kernel's
output and the test harness's `[TEST]/[PASS]/[FAIL]` lines appear
directly in your terminal. `run-virt` uses
`-M virt,gic-version=3 -cpu cortex-a72 -m 1G -nographic`, with the
PL011 routed onto host stdio.

A green run on either board lands `8/8 passed`, twelve `0xbbff9`
free-page checkpoints (one per scenario plus 1 PID-1 baseline +
3 fork-stress rounds + 1 fork-stress final), and 0 `ERROR CAUGHT`.
The free-page invariants are documented in
[Documentation §8](DOCUMENTATION.md#free-page-invariants).

QEMU is the authoritative inner-loop signal. The boot path matches
real hardware byte-for-byte, modulo timing.

## 4. SD-card layout

The Raspberry Pi 4 boots from a FAT32-formatted card whose root must
contain at least:

```text
config.txt              # ships in this repo
kernel8.img             # built by `zig build`
armstub8.bin            # built by `zig build`
bcm2711-rpi-4-b.dtb     # from official RPi firmware
start4.elf              # from official RPi firmware
fixup4.dat              # from official RPi firmware
overlays/miniuart-bt.dtbo
```

Get the firmware from
[raspberrypi/firmware](https://github.com/raspberrypi/firmware/tree/master/boot)
and point the deploy step at it:

```bash
SD_BOOT=/Volumes/FLASH FIRMWARE=$HOME/rpi_firmware zig build deploy
```

The deploy step reads two environment variables:

| Variable      | Default                  | Purpose                              |
| :------------ | :----------------------- | :----------------------------------- |
| `SD_BOOT`     | `/Volumes/FLASH`         | SD-card mount point on macOS         |
| `FIRMWARE`    | `$HOME/rpi_firmware`     | Directory holding the official RPi firmware files |

## 5. Serial console

The kernel uses two UARTs:

- **Mini-UART (UART1)** on GPIO 14 / 15 — main console.
- **PL011 (UART4)** on GPIO 8 / 9 — dedicated trace channel.

GPIO 14/15 is shared with the firmware on purpose. `config.txt`
enables `uart_2ndstage=1` and `dtoverlay=miniuart-bt`, which routes
the firmware's PL011_0 to GPIO 14/15 so the `MESS:…` lines from
`start4.elf` are visible on the same cable. Once the kernel runs,
`mini_uart_init` (`src/board/rpi4b/uart.zig`) reconfigures the pins to alt5
(mini-UART) — last-write on the GPIO function selector wins, so the
firmware-side PL011_0 routing is silently replaced. This is a
sequential handoff, not a conflict.

### UART1 pinout (RPi 4 → USB-TTL adapter)

| RPi pin | Function       | USB-TTL pin |
| :------ | :------------- | :---------- |
| Pin 6   | GND            | GND         |
| Pin 8   | TXD (GPIO 14)  | RXD         |
| Pin 10  | RXD (GPIO 15)  | TXD         |

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

## 6. Helper shell functions

The repo ships [`.zsh_project`](.zsh_project) with a handful of
helpers. Source it from `~/.zshrc`
(`source ~/FlashOS/.zsh_project`) to make them available in every
shell.

- **`picapture [seconds]`** — runs the canonical capture flow:
  clears `$PWD/screenlog.0`, opens a detached
  `screen -L -dmS pi_capture <device> 115200` session, waits up to
  60 s for `SUCCESS` or `ERROR CAUGHT` to appear in the log, then
  captures `[seconds]` more (default 10) of post-boot output before
  quitting the screen session. Power-cycle the Pi when prompted.
- **`piconnect`** — opens an interactive `screen` session on the
  detected serial device at 115200 baud.
- **`piquit`** — terminates the detached `pi_capture` screen session
  started by `picapture`. Use from a second terminal.
- **`pilist`** — lists attached `/dev/cu.usbserial-*` devices.
- **`build`** — runs the full two-pass build (mirror of
  `./build.sh`): clean, link pass 1, `populate-syms`, link pass 2,
  diff-check the symbol layout, optionally `deploy`.
- **`showfns`** — lists the shell helpers defined in
  [`.zsh_project`](.zsh_project), the `zig build` steps, and the
  top-level functions in [`build.zig`](build.zig). Useful for
  "what targets exist again?".

The serial device is auto-detected from `/dev/cu.usbserial-*`;
override with `PI_SERIAL_DEVICE=/dev/cu.usbserial-XXXX` if you have
multiple adapters plugged in.

### Auto-source on `cd` (optional)

To load `.zsh_project` automatically whenever you enter `~/FlashOS`,
append a `chpwd` hook to your `~/.zshrc`. The command below is
idempotent — running it twice does nothing:

```bash
grep -q '_FLASHOS_LOADED' ~/.zshrc || cat >> ~/.zshrc <<'EOF'

# --- FlashOS auto-source on cd ---
autoload -Uz add-zsh-hook
load_flashos_env() {
  if [[ "$PWD" == "$HOME/FlashOS"* && -z "$_FLASHOS_LOADED" ]]; then
    [[ -f "$HOME/FlashOS/.zsh_project" ]] && source "$HOME/FlashOS/.zsh_project" && typeset -g _FLASHOS_LOADED=1
  fi
}
add-zsh-hook chpwd load_flashos_env
load_flashos_env
EOF
```

Open a new shell or run `source ~/.zshrc` to activate. Assumes the
repo lives at `~/FlashOS`.

## 7. Host-side unit tests

```bash
zig build test
```

Runs the host-side unit tests against pure-logic kernel modules.
Each module that has tests is its own test root, linked against
`tests/host_stubs.zig` (stubs for assembly-only externs). The
current suite covers `src/page_alloc.zig` and `src/elf.zig`; it
finishes in well under a second and is the fastest signal that
core kernel logic still holds.

---

[← Prev: Documentation](<DOCUMENTATION.md>) · [Next: Reference →](<REFERENCE.md>)
