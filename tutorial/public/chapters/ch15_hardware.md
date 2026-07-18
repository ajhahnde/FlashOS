# 15. Raspberry Pi Hardware Acceptance

QEMU gives FlashOS a fast, deterministic inner loop, but it does not model
every BCM2711 path used by the system. The Rust-port release therefore uses a
feature-enabled `rpi4b` watchdog image under QEMU and separately qualifies the
exact default and trace artefacts on a Raspberry Pi 4B.

## What the Pi firmware loads

A FAT32 boot partition contains at least:

```text
config.txt
kernel8.img
armstub8.bin
bcm2711-rpi-4-b.dtb
start4.elf
fixup4.dat
overlays/miniuart-bt.dtbo
```

The repository bundles the required firmware inputs. After the complete
two-pass build, deployment is an explicit operator action:

```bash
source flashos.zsh
SD_BOOT=/Volumes/BOOT FIRMWARE=firmware build -d
```

Without `-d`, the build does not write to the SD card.

## Serial and USB paths

Mini-UART on GPIO 14/15 carries firmware diagnostics, kernel diagnostics, and
fallback user I/O. PL011 on GPIO 8/9 carries the trace stream. The Pi USB-C
port enumerates as CDC-ACM for the preferred interactive user console while
also powering the board.

On macOS, typical device nodes are:

```bash
/dev/cu.usbserial-*   # USB-TTL adapter for Mini-UART
/dev/cu.usbmodem*     # USB-C CDC-ACM gadget
```

## Hardware-only evidence

Real-Pi acceptance covers:

- boot through login to the shell;
- EMMC2 single-block reads and writes;
- FAT32 persistence across two boots;
- create, write, read, rename, and unlink on physical media;
- USB-C enumeration, fallback, and reconnect behavior;
- optional PL011 trace capture for a trace-feature image.

QEMU's Raspberry Pi model does not provide the usable EMMC2 path required by
the driver and does not emulate the DWC2 device-mode data path. Runtime tests
skip those legs explicitly under QEMU instead of pretending they passed.

## Capturing a boot

After sourcing `flashos.zsh`, the helper surface includes:

```bash
pi capture mu       # Mini-UART diagnostics
pi capture usb      # USB user console
pi log
pi tail 100
pi quit
flashos versions check
flashos check all
```

The unattended USB capture keeps DTR/RTS asserted on one open descriptor;
`pi connect` uses `screen` for interactive work.

Use the Mini-UART path for kernel faults. USB user output can disappear during
enumeration or reconnect, while kernel diagnostics intentionally remain on the
dedicated fallback channel.

## Release identity

Hardware acceptance must use the exact `kernel8.img` and `armstub8.bin`
qualified for release. Rebuilding with different inputs and testing only that
new image does not prove the released bytes.

> [!NOTE]
> The supported release target is `rpi4b`. The preserved `virt` board is
> frozen, outside the current gate, and should not be presented as equivalent
> hardware support.

You have now followed FlashOS from the pinned Rust build through firmware,
memory, scheduling, syscalls, userland, filesystems, tests, and real hardware.
