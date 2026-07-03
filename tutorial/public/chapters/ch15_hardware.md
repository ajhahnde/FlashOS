# Chapter 15: On Real Hardware (Pi 4)

Every chapter so far has been agnostic about whether the kernel this
tour describes is running under QEMU or on a physical Raspberry Pi 4 —
deliberately, since the same image, the same boot contract, and the
same `[TEST]` harness apply to both. This closing chapter is about the
places that genuinely differ: how the image gets onto a real SD card,
how a real serial console differs from QEMU's virtual one, and the
USB-C console that makes Pi hardware need no extra adapter at all.

## The SD card layout

The Pi's firmware boots from a FAT32-formatted card whose root must
hold, at minimum:

```text
config.txt              # ships in this repo
kernel8.img             # built by `zig build`
armstub8.bin             # built by `zig build`
bcm2711-rpi-4-b.dtb      # bundled in this repo
start4.elf               # bundled in this repo
fixup4.dat                # bundled in this repo
overlays/miniuart-bt.dtbo
```

The firmware blobs — the device tree, `start4.elf`, `fixup4.dat`, and
the mini-UART overlay — are vendored under `firmware/` in this
repository, taken directly from the official Raspberry Pi firmware
project, so a checkout has everything it needs without a separate
download step. `zig build deploy` writes the two files this repo
actually builds (`kernel8.img`, `armstub8.bin`) onto a mounted card,
reading its target mount point and firmware directory from environment
variables (`SD_BOOT`, defaulting to `/Volumes/BOOT`; `FIRMWARE`,
defaulting to `firmware`) rather than a hardcoded path.

## Three console channels, one purpose split

A running Pi actually exposes three separate serial-ish channels, each
with a distinct job:

- **Mini-UART (UART1)**, on GPIO 14/15 — the main console, and the
  fallback whenever USB is not enumerated.
- **PL011 (UART4)**, on GPIO 8/9 — a channel dedicated to the tracing
  subsystem chapter 5 mentioned only in passing, kept separate so trace
  output never interleaves with interactive console bytes.
- **The USB-C gadget console** — described below.

GPIO 14/15 carries an interesting sequential hand-off before the kernel
even starts: the firmware's own boot messages route over PL011_0 on
those same pins (`config.txt`'s `dtoverlay=miniuart-bt` arranges this),
so the earliest `MESS:…` lines are visible on the same physical cable a
developer will use for the kernel's own console. Once `mini_uart_init`
runs, it reconfigures those pins to the mini-UART function — last write
to the GPIO function selector wins — silently taking over from the
firmware. Nothing conflicts; it's a clean relay race with no shared
state between the two owners.

## The USB-C console: one cable, no adapter

The more distinctive path is the Pi's own USB-C port doubling as a full
interactive console. `src/board/rpi4b/usb.flash` brings the BCM2711's
DWC2 USB-OTG controller up as a Full-Speed USB *device*, enumerating as
a standard CDC-ACM serial function — the same class of device a USB
modem or Arduino-style board presents. macOS binds its built-in
`AppleUSBCDCACM` driver automatically; nothing to install, and a single
USB-C-to-USB-C cable carries both power and the console simultaneously.

```text
ls /dev/cu.usbmodem*            # node appears once the gadget enumerates
screen /dev/cu.usbmodem00011 115200
```

Getting from "controller powered up" to "host sees a serial device" is
not instantaneous, and the driver is deliberately careful about the
timing. A USB bus reset electrically disarms the endpoint, and the host
doesn't send its first `SETUP` packet until roughly 20 ms after the
reset ends — which only works if something is polling the controller
at microsecond granularity the whole time. There's no IRQ line wired
for this controller; instead, the idle loop that already runs on core 0
between other work calls `board.usb.poll()` on every pass, right next
to the UART RX backstop. To avoid macOS's habit of permanently
disabling a port after a few failed enumeration attempts, the gadget
stays electrically detached — pull-up held low — until the poll loop
has run gap-free for a full two seconds of sustained idle, measured off
the hardware cycle counter, and only then asserts the pull-up that
makes it visible to the host. If enumeration ever stalls for ten
seconds without completing `SET_CONFIGURATION`, the driver self-heals
with a one-second detach pulse — electrically indistinguishable from
unplugging and replugging the cable, which resets the host's port state
too.

Once enumerated, the switch is transparent to everything above it:
`fsh`'s prompt and command output redirect from the Mini-UART to the
USB console automatically, because the write path is a **mux, not a
tee** — `board.usb.cdc_tx` when enumerated, the Mini-UART otherwise,
never both at once. Kernel `[Debug]` prints and the USB driver's own
bring-up trace stay on the Mini-UART unconditionally regardless of
enumeration state, so a developer watching the mini-UART adapter always
sees boot diagnostics even while a second person is typing commands
over the USB-C cable. Under QEMU, which does not emulate DWC2's
device-mode data path, `usb_init()` simply fails soft and the console
falls back to the Mini-UART — the same fallback behavior a real board
shows with no cable attached, which is exactly why the CI boot
watchdog stays green without ever touching USB.

## QEMU vs. hardware: what actually differs

Across this whole tour, the QEMU-versus-hardware gap has been narrow
and explicit rather than pervasive:

- **FAT32 writes** (chapter 11) — QEMU's `raspi4b` machine cannot
  complete the SD card's `CMD8` initialization sequence, so `/mnt`
  never mounts under either QEMU board; every write-path scenario is
  Pi-only, taking the explicit SKIP branch under emulation.
- **The USB-C console** (this chapter) — falls back to the Mini-UART
  under QEMU rather than failing the boot.
- **Everything else** — the scheduler, the syscall boundary, the
  memory manager, the login flow, fsh itself — runs identically on
  both, which is precisely what lets a green QEMU boot stand in as
  meaningful evidence before a change ever reaches real silicon.

## The tour, end to end

Fifteen chapters ago this tour started at the moment a Raspberry Pi's
firmware hands control to `start.S`. It has now walked every layer
between that instant and a `$` prompt running real commands against a
real filesystem: the MMU, the console, the scheduler, the syscall
boundary, ELF loading, login and identity, the shell, the filesystem,
full-screen tools, the test harness that proves all of it, the build
pipeline that produces it, and finally the hardware it actually runs
on. That is the whole path — power-on to prompt.
