# Chapter 2: Build & First Boot (QEMU)

This chapter is the practical on-ramp for the rest of the tour: build
the kernel, boot it under QEMU, and read what the boot log is actually
telling you. The `[ OK ]` lines below are also a map — each one names a
subsystem that a later chapter (3 through 8) digs into on its own.

## Prerequisites

| Tool                  | Minimum version | Purpose                                   |
| :-------------------- | :-------------- | :----------------------------------------- |
| Zig                   | 0.16.0          | Compile Zig + assembly, run `build.zig`   |
| `flashc`              | pinned          | Compile Flash (`.flash`) sources          |
| `aarch64-elf-binutils`| 2.40+           | ELF → raw binary, symbol extraction       |
| `qemu-system-aarch64` | 11.0.0+         | Run the kernel under QEMU                 |

Installing and pinning these — including building the self-hosted
`flashc` compiler from source — is covered in full in `SETUP.md` (in
the repository root), §1 "Host toolchain". This chapter assumes that
step is already done.

## Building

Every build compiles the `.flash` source modules with `flashc` first,
so `flashc` has to be on the resolved path (or passed via `-Dflashc=`)
before either of these commands works:

```bash
zig build                 # default: kernel8.img + armstub8.bin → zig-out/
```

```bash
./build.sh                # full two-pass build with optional deploy
```

`build.sh` invokes `zig build`, `zig build populate-syms`, then `zig
build` again, diff-checks that the symbol layout converged, and
optionally runs `zig build deploy`. Either command is enough to produce
a bootable `zig-out/kernel8.img`; `build.sh` is the one the project's
own release process uses.

## Running under QEMU

Two QEMU machines are wired up, selected with `-Dboard=`:

```bash
zig build -Dboard=rpi4b run        # Pi 4 model (raspi4b)
zig build -Dboard=virt  run-virt   # generic ARMv8 (virt)
```

`-Dboard=rpi4b` is the validated board — the one this tour boots. `run`
launches `qemu-system-aarch64 -M raspi4b -serial null -serial stdio
-kernel zig-out/kernel8.img`, routing the kernel's Mini-UART output
straight onto the controlling terminal, so the boot log below appears
directly in the same shell.

There is also a self-validating variant that exits `0` only once the
boot has actually reached the interactive shell, and `1` on any
failure or timeout, with no manual watching required:

```bash
zig build -Dboard=rpi4b test-rpi4b  # the CI boot gate
```

`test-rpi4b` doesn't just wait for the first sign of a shell prompt —
the boot log's homescreen marker (the `type 'help' for commands` line
seen below) appears more than once during a single self-test boot,
because the kernel's own in-tree test harness first authenticates and
drops privilege through two scripted login sessions before the real
boot login runs. The watchdog script, `scripts/run_qemu_test.sh`, counts
how many times that marker has appeared rather than reacting to the
first one, and only declares success on the count that corresponds to
the real, final login. It applies the same counting discipline to a
handful of other boot invariants — how many self-test scenarios passed,
and a couple of free-page bookkeeping checkpoints the kernel logs along
the way — so a regression that quietly changes those numbers fails the
gate instead of slipping through.

> [!NOTE]
> QEMU is the project's authoritative inner-loop signal: the boot path
> matches real Raspberry Pi 4 hardware byte-for-byte, modulo timing.
> Everything read from the log below is exactly what a real board
> prints over its serial console.

## Reading the boot log

Below is a real excerpt — the tail of a boot, from the last `[ OK ]`
lines through login and a first few shell commands. It is copied
verbatim from the transcript the project's own boot-demo recording is
built from:

```text
[ OK ] Initialized Mini-UART console
[ OK ] Booted core 0 (EL1)
[ OK ] Initialized PL011 trace UART
[ OK ] Loaded exception vectors
[ OK ] Enabled interrupt controller
[ OK ] Started USB gadget
[ OK ] Loaded kernel symbols
[ OK ] Relocated syscall table
[ OK ] Initialized trace subsystem
[ OK ] Started kernel trace output
[ OK ] Mounted initramfs root
[ OK ] Initialized EMMC2 block device
[ OK ] Mounted /mnt (FAT32)
[ OK ] Initialized hwrng
[ OK ] Reached target Userspace

login: flash
Password: *****

FlashOS [the running version] by ajhahnde - type 'help' for commands

$ help
Commands:
  cd [dir]       change working directory
  pwd            print working directory
  free           show free page count
  whoami         print the logged-in user
  reboot         restart the machine
  exit / logout  end the session
  help           show this help
...
```

Each `[ OK ] <name>` line marks one subsystem finishing initialization,
printed in the exact order the kernel brings them up — this is not a
static checklist, it is the real sequence `kernel_main` executes:

- **Console first.** The Mini-UART line comes before almost everything
  else, because every subsequent `[ OK ]` line has to go somewhere —
  chapter 5 covers the console drivers.
- **CPU and exception plumbing next.** Booting core 0 into EL1, loading
  the exception vector table, and enabling the interrupt controller are
  what let the kernel safely take syscalls and IRQs at all — chapters 3
  and 6 pick this up (the earliest boot code, and the scheduler that
  the interrupt controller eventually drives).
- **Kernel-internal bookkeeping.** Loading the kernel's own symbol table
  and relocating the syscall table are FlashOS housekeeping steps
  particular to its own runtime; the syscall table relocation matters
  because kernel code runs from a different address than it was linked
  at — chapter 7 covers the syscall boundary this sets up.
- **Storage and the root filesystem.** Mounting the initramfs root,
  bringing up the EMMC2 (SD card) block device, and mounting `/mnt` as
  FAT32 are what make `/bin`, `/etc`, and the rest of the filesystem
  tree available before anyone logs in — chapter 8 (userland) touches
  the filesystem those programs run from.
- **Entropy and the handoff.** `Initialized hwrng` brings up the
  hardware random-number generator; `Reached target Userspace` is the
  kernel's last line before it hands control to `/bin/login`.

From there, `login:` / `Password:` is `/bin/login` doing its job, and
`FlashOS [...] by ajhahnde - type 'help' for commands` is `/bin/fsh` —
the shell — announcing that it has reached its own interactive prompt.
Everything after the `$ help` line is ordinary `fsh` use: chapter 8
covers the shell and its coreutils in depth.

## What's next

This chapter has no lab of its own — the boot log above is the
artifact, and everything in it is real output from a real build. The
next chapter starts at the very first instruction the CPU executes on
power-on, well before the Mini-UART console (the first `[ OK ]` line
here) even exists yet.
