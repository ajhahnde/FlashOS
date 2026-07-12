# Chapter 2: Build & First Boot (QEMU)

This chapter is the practical on-ramp for the rest of the tour: build
the kernel, boot it under QEMU, and read what the boot log is telling
you. The status lines are also a map — each names a subsystem that a
later chapter explores in more detail.

## Prerequisites

The build needs the pinned Flash compiler, Zig for orchestration and
test compatibility, AArch64 binutils, and QEMU. `SETUP.md` in the repository root is
the authoritative installation guide; it records the required versions
and the exact compiler revision, so this tour does not duplicate values
that change independently of the concepts below.

## Building

The repository build entry point is `build.zig`:

```bash
zig build                   # kernel + Pi armstub -> zig-out/
```

Despite the command name, product source does not take a Flash→Zig detour:
`build.zig` asks `flashc` for native LLVM output, turns it into AArch64
objects, and links those objects with the assembly sources. The Zig
compatibility backend remains available to the host-test path, not to the
shipping kernel, userland, or tools.

For the release-style two-pass build, use the shell helper:

```bash
source flashos.zsh          # provides the `build` helper
build                       # build, populate symbols, rebuild, verify
build -d                    # same pipeline, then deploy to the SD card
```

The simple command is ideal for a quick compile. The helper additionally
proves that the embedded kernel symbol table converges across both link
passes. Chapter 14 explains why that second pass exists.

## Running under QEMU

Two machines are wired into the build graph and selected with
`-Dboard=`:

```bash
zig build -Dboard=rpi4b run        # Raspberry Pi 4 model
zig build -Dboard=virt  run-virt   # generic ARMv8 machine
```

The Raspberry Pi model is the primary validation target used throughout
this tour. Its `run` step routes the kernel's Mini-UART output to the
controlling terminal, so the boot log appears directly in the same
shell.

There is also a self-validating boot step:

```bash
zig build -Dboard=rpi4b test-rpi4b
```

This watchdog does more than wait for any prompt. It checks the live
contract in `scripts/run_qemu_test.sh`: every expected scenario must
pass, failure markers must be absent, page-allocation checkpoints must
match, and all scripted login sessions must reach the shell. The script
owns the exact counts and checkpoint values so documentation never has
to repeat them.

> [!NOTE]
> QEMU is the fast inner-loop signal. Hardware-only paths such as the
> SD controller and USB gadget console have explicit skip or fallback
> behavior under emulation and are validated separately on a Pi.

## Reading the boot log

A successful Pi boot reaches a sequence shaped like this (hardware that
is unavailable under QEMU may report `SKIP` instead of `OK`):

```text
[ OK ] Mini-UART init
[ OK ] Boot core 0 (EL1)
[ OK ] PL011 UART init
[ OK ] IRQ vectors init
[ OK ] GIC init
[SKIP] USB DWC2 init
[ OK ] KSYMS init
[ OK ] Syscall table relocate
[ OK ] Trace init
[ OK ] Kernel trace -> PL011
[ OK ] Initramfs mount (/)
[SKIP] EMMC2 init
[SKIP] FAT32 mount (no volume)
[ OK ] HWRNG init
[ OK ] Userspace init

login: flash
Password: *****

.flashOS [...] by ajhahnde - type 'help' for commands

$ help
```

The exact success/skip mix depends on the selected board and attached
hardware, but the order carries stable architectural meaning:

- **Console first.** Mini-UART comes up early because every later status
  line needs somewhere to go. Chapter 5 covers the console path.
- **CPU and exception plumbing.** Core state, exception vectors, and the
  interrupt controller make syscalls and timer interrupts possible.
- **Kernel bookkeeping.** The symbol table, relocated syscall table, and
  tracing hooks prepare diagnostics and the EL0 boundary.
- **Storage.** The embedded initramfs provides `/`; the SD controller may
  add a writable FAT32 mount at `/mnt` on real hardware.
- **Userspace hand-off.** Entropy initializes before PID 1 announces that
  userspace is alive and starts the password-gated login flow.

The final homescreen tail is printed by `fsh` after authentication. It is
also the stable boot-success marker consumed by the watchdog and hardware
capture helpers.

## What's next

This chapter has no editor lab — its artifact is a bootable image and a
validated serial log. Chapter 3 starts at the first instruction the CPU
executes, before even the Mini-UART console exists.
