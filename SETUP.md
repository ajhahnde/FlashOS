<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flashos_logo_dark.png">
    <img src="assets/flashos_logo_light.png" alt="FlashOS" width="280">
  </picture>

<h1>Setup</h1>

<p><i>Host toolchain, SD-card layout, serial console, QEMU, and the test runner.</i></p>

<p>
    <a href="README.md"><b>README</b></a> ·
    <a href="DOCUMENTATION.md"><b>Documentation</b></a> ·
    <b>Setup</b> ·
    <a href="PORT.md"><b>Port</b></a> ·
    <a href="VERSIONING.md"><b>Versioning</b></a> ·
    <a href="CHANGELOG.md"><b>Changelog</b></a> ·
    <a href="LICENSE.md"><b>License</b></a>
  </p>

<p>
    <b>English</b> ·
    <a href="docs/de/SETUP.md">Deutsch</a>
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

| Tool                       | Minimum version | Purpose                                   |
| :------------------------- | :-------------- | :---------------------------------------- |
| Zig                        | 0.16.0          | Compile Zig + assembly, run `build.zig` |
| `flashc`                   | pinned          | Transpile Flash (`.flash`) sources to Zig |
| `aarch64-elf-objcopy`    | 2.40+           | ELF → raw binary                         |
| `aarch64-elf-nm`         | 2.40+           | Symbol extraction for `populate-syms`   |
| `qemu-system-aarch64`    | 11.0.0+         | Run the kernel under QEMU                 |
| `screen` (or equivalent) | –              | Serial console for the Pi                 |

On macOS:

```bash
brew install zig aarch64-elf-binutils qemu
```

### Flash compiler (`flashc`)

FlashOS's source modules are written in
[Flash](https://github.com/ajhahnde/Flash) and transpiled to Zig at
build time. `build.zig` resolves the `flashc` binary at
`~/Flash/zig-out/bin/flashc-stage1` by default; override the path with
`-Dflashc=<path>`. Flash publishes no prebuilt binaries, so build the
pinned self-hosted compiler from source — run this from the FlashOS
checkout so the pin is read from `flash-toolchain.lock`:

```bash
git clone https://github.com/ajhahnde/Flash.git ~/Flash
git -C ~/Flash checkout "$(grep -oE '[0-9a-f]{40}' flash-toolchain.lock)"
( cd ~/Flash && zig build stage1 )   # → ~/Flash/zig-out/bin/flashc-stage1
```

`zig build stage1` — not the bare `zig build`, which emits only the
stage0 bootstrap seed `flashc` — produces `flashc-stage1`, the revision
pinned in `flash-toolchain.lock`. Rebuild it only when that pin moves.

## 2. Building

Every build transpiles the `.flash` source modules with `flashc`, so
build it first (see §1).

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

For a self-validating run that exits 0 when the boot reaches the
interactive `fsh` prompt (the third `type 'help' for commands` homescreen
marker — see below) with no `[FAIL]` / `ERROR CAUGHT` and the expected free-page
checkpoints, and 1 on a failure or watchdog timeout (no manual QEMU
supervision):

```bash
zig build -Dboard=virt  test-virt
zig build -Dboard=rpi4b test-rpi4b  # (matches run)
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
directly on the controlling terminal. `run-virt` uses
`-M virt,gic-version=3 -cpu cortex-a72 -m 1G -nographic`, with the
PL011 routed onto host stdio.

A green run on either board lands `30/30 passed`, 34 per-scenario
free-page checkpoints (`0xbbff2` on rpi4b, `0x3be46` on virt) plus the
matching boot baseline (`0xbc000` / `0x3be54`), and 0 `ERROR CAUGHT`.
The boot then hands off to `/bin/login` → `/bin/fsh`; with the login
lifecycle fsh's homescreen marker (`type 'help' for commands`) appears
three times (two scripted `[TEST] login` sessions + the real boot
login), and the CI watchdog (`scripts/run_qemu_test.sh`) counts exactly
that. The free-page invariants are documented in
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
SD_BOOT=/Volumes/BOOT FIRMWARE=firmware zig build deploy
```

The deploy step reads two environment variables:

| Variable     | Default           | Purpose                                           |
| :----------- | :---------------- | :------------------------------------------------ |
| `SD_BOOT`  | `/Volumes/BOOT` | SD-card mount point on macOS                      |
| `FIRMWARE` | `firmware`      | Directory holding the bundled RPi firmware files  |

## 5. Serial console

The kernel has three console/debug channels on the Pi:

- **Mini-UART (UART1)** on GPIO 14 / 15 — main console (and fallback
  when USB is not enumerated).
- **PL011 (UART4)** on GPIO 8 / 9 — dedicated trace channel.
- **USB-C gadget console** — the interactive `fsh` console over the
  Pi's USB-C port; no adapter or jumper wires (see below).

GPIO 14/15 is shared with the firmware on purpose. `config.txt`
enables `uart_2ndstage=1` and `dtoverlay=miniuart-bt`, which routes
the firmware's PL011_0 to GPIO 14/15 so the `MESS:…` lines from
`start4.elf` are visible on the same cable. Once the kernel runs,
`mini_uart_init` (`src/board/rpi4b/uart.flash`) reconfigures the pins to alt5
(mini-UART) — last-write on the GPIO function selector wins, so the
firmware-side PL011_0 routing is silently replaced. This is a
sequential handoff, not a conflict.

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

The Pi's own USB-C port doubles as the console. The kernel brings the
BCM2711's DWC2 OTG controller up as a **CDC-ACM USB device**
(`src/board/rpi4b/usb.flash`), so one USB-C ↔ USB-C cable to the Mac
carries both **power and the interactive `fsh` console**. macOS binds
its built-in `AppleUSBCDCACM` driver — nothing to install.

```bash
ls /dev/cu.usbmodem*            # node appears once the gadget enumerates
```

```bash
screen /dev/cu.usbmodem00011 115200
```

Once enumerated, user/`fsh` output (the `# ` / `$ ` prompt, command output)
switches from the Mini-UART to the USB console automatically; kernel
`[Debug]` prints and the USB driver's own bring-up trace stay on the
Mini-UART. If the gadget never enumerates (no host attached, or under
QEMU, which does not emulate the DWC2 device path), the console falls
back to the Mini-UART and the GPIO flow above works unchanged.

The baud rate is cosmetic — there is no physical UART behind the USB
device; any rate works. Keystrokes typed into `screen` reach `fsh`
over USB bulk-OUT; replug / re-enumeration hardening is a known work
item, so if the console wedges after replugging the cable, power-cycle
the Pi.

## 6. Helper shell functions

The repo ships [`flashos.env.zsh`](flashos.env.zsh) with a handful of
helpers, exposed as two verb dispatchers — `pi <verb>` (serial console) and
`run <mode>` (build, emulate, or attach) — plus `build` and `flashos`. Source
it from `~/.zshrc` (`source ~/FlashOS/flashos.env.zsh`) to make them available
in every shell. The legacy flat names (`picapture`, `piconnect`, `piquit`,
`pilist`) remain as thin aliases for the corresponding `pi` verbs.

- **`picapture [usb|mu]`** — runs the canonical boot-capture flow,
  logging the session to `boot.log` in the repo root (regardless of
  the current directory; covered by the repo `.gitignore`).
  - `usb` (default): waits for the CDC gadget to enumerate on
    `/dev/cu.usbmodem*` (plugging in the C-to-C cable powers the Pi,
    so the node's appearance is itself the first boot signal), then
    probes the console once per second until the boot marker
    `type 'help' for commands` appears (fsh reached its interactive REPL).
  - `mu`: captures the Mini-UART trace adapter
    (`/dev/cu.usbserial-*`) until `type 'help' for commands` (the boot
    reached the shell on the MU fallback — no USB host attached) or
    `ERROR CAUGHT` appears. Power-cycle the Pi when prompted.
  - Kernel faults only ever print on the MU adapter — use `mu` mode
    (trace adapter + external power) for fault diagnosis.
- **`piconnect [usb|mu]`** — opens an interactive `screen` session on
  the Pi console at 115200 baud. With no argument it auto-picks the
  USB CDC console (`fsh`) when present, else the MU trace adapter;
  `usb` / `mu` force a specific channel.
- **`piquit`** — terminates the detached `pi_capture` screen session
  started by `picapture`. Use from a second terminal.
- **`pilist`** — lists attached console devices: the USB CDC console
  (`/dev/cu.usbmodem*`) and any USB-serial adapters
  (`/dev/cu.usbserial-*`, MU trace).
- **`pi log`** — pages the most recent `boot.log` capture.
- **`pi tail [N]`** — live-tails `boot.log` (last `N` lines, default 40),
  following across the next capture's log rotation.
- **`build`** — runs `./build.sh` from the repo root (works from any
  directory): clean, link pass 1, `populate-syms`, link pass 2,
  diff-check the symbol layout, optionally `deploy`. `BOARD=virt
  build` selects the virt board (deploy is skipped); `NM=llvm-nm
  build` overrides the symbol-dump binary.
- **`run <mode>`** — builds and runs a board, runs the boot watchdog, or
  attaches to hardware. `run qemu` (alias `auto`) builds and launches the
  rpi4b model in QEMU; `run virt` does the same for the virt board; `run test`
  runs the host unit tests (`run test --NAME` filters by name); `run hw`
  attaches to the Pi over serial (`--trace` selects the MU adapter).
- **`run watchdog [virt|rpi4b]`** — runs the unattended boot watchdog with the
  required `-Dci-login-seed=true` and `-Dboot-selftest=true` flags applied
  automatically; defaults to the virt board (`rpi4b` is a slower TCG run).
- **`flashos`** — lists the shell helpers defined in
  [`flashos.env.zsh`](flashos.env.zsh) and the available `zig build` steps —
  a quick inventory of targets.

The MU trace adapter is auto-detected from `/dev/cu.usbserial-*` and
the USB CDC console from `/dev/cu.usbmodem*`; override with
`PI_SERIAL_DEVICE=/dev/cu.usbserial-XXXX` /
`PI_USB_CONSOLE_DEVICE=/dev/cu.usbmodemXXXX` if multiple devices are
connected. The `picapture` timeouts default to 120 s (overall) and 30 s
(prompt probe); override with `PI_CAPTURE_TIMEOUT` / `PI_PROBE_TIMEOUT`.

### Auto-source on `cd` (optional)

To load `flashos.env.zsh` automatically whenever the shell enters
`~/FlashOS`, append a `chpwd` hook to `~/.zshrc`. The command below
is idempotent:

```bash
grep -q '_FLASHOS_LOADED' ~/.zshrc || cat >> ~/.zshrc <<'EOF'

# --- FlashOS auto-source on cd ---
autoload -Uz add-zsh-hook
load_flashos_env() {
  if [[ "$PWD" == "$HOME/FlashOS"* && -z "$_FLASHOS_LOADED" ]]; then
    [[ -f "$HOME/FlashOS/flashos.env.zsh" ]] && source "$HOME/FlashOS/flashos.env.zsh" && typeset -g _FLASHOS_LOADED=1
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
current suite covers 41 modules (468 host tests); it
finishes in well under a second and is the fastest signal that
core kernel logic still holds.

---

[← Prev: Documentation](DOCUMENTATION.md) · [Next: Port →](PORT.md)
