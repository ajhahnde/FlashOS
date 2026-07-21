# 1. Welcome to FlashOS

FlashOS is a small UNIX-like operating system for AArch64. Its maintained
implementation is Rust, with a deliberately small set of AArch64 assembly and
linker scripts where the processor or firmware contract requires them.

This tour follows the real production path used by the Rust-port release:

```text
Pi firmware
    ↓
EL3 armstub
    ↓
EL1 Rust kernel
    ↓
EL0 PID 1 → login → /bin/fsh
```

The Raspberry Pi 4B is the supported release target. QEMU's `raspi4b` machine
is the fast inner-loop boot environment and boots a feature-enabled selftest
image from the production graph. The exact default and trace artefacts are
qualified separately on real Pi hardware. The retained `virt` input is frozen
and is not part of the current release gate.

## What is in the system?

- a four-level MMU and physical-page allocator;
- preemptive, priority-weighted task scheduling;
- `fork`, `execve`, `wait`, `exit`, and `kill`;
- a VFS with read-only initramfs and a mutable FAT32 mount;
- unified console, pipe, and file descriptors;
- users, login, permissions, and password authentication;
- a shell, pager, editor, and core utilities in EL0;
- kernel tracing, host tests, and a 30-scenario runtime harness.

The repository mirrors those boundaries. `crates/kernel/` owns the Rust kernel,
`crates/kernel-abi/` owns layouts shared with userland and assembly, `userland/` contains
EL0 executables, and `rootfs/` contains checked-in filesystem seeds. The root
`src/` directory now contains only retained assembly, linker, trace, and symbol
glue—not the kernel implementation.

## How to use this tour

Each chapter connects one concept to the current source tree. Code fragments
are teaching-sized excerpts or close simplifications; follow the linked path
for the authoritative implementation. The right-hand editor is a Rust
scratchpad for loading and modifying examples. It does not replace the native
bare-metal build or its target-specific checks.

> [!NOTE]
> FlashOS is pre-1.0. Internal layouts and syscall details may change between
> releases. The current `crates/kernel-abi/` crate is an internal contract, not yet a
> stable public SDK.

## What comes after the Rust-port release?

The planned order is explicit: first FlashSDK establishes a narrow public
syscall/userspace ABI and runtime; FlashShell becomes its first product
consumer; then FlashUI becomes the second consumer and embeds FlashShell as a
native TUI. Only after those steps is the default post-login session intended
to change. `/bin/fsh` remains a tested recovery shell.

Next, we build the current system and watch its boot contract complete.
