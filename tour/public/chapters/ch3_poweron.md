# 3. From Power-On to `kernel_main`

The Raspberry Pi does not jump straight into Rust. Firmware, a tiny armstub,
and the architecture boot code establish the execution environment first.

## Stage 1: firmware and armstub

The GPU firmware reads `config.txt`, loads `armstub8.bin` and `kernel8.img`,
then enters `armstub/src/armstub8.S` at EL3. The armstub configures the secure
state needed by the Pi and performs the EL3-to-EL1 hand-off.

## Stage 2: architectural boot

`arch/aarch64/boot.S` owns `_start`. It:

1. establishes the early stack;
2. parks secondary cores;
3. clears BSS;
4. constructs the early identity and high mappings;
5. programs `TCR_EL1`, `MAIR_EL1`, `TTBR0_EL1`, and `TTBR1_EL1`;
6. installs the exception-vector base;
7. enables the MMU;
8. branches through the high mapping to `kernel_main`.

The boundary is an ordinary C-ABI symbol exported by the Rust static library.
`crates/klib/` is the narrow static-link/export seam between assembly and the
kernel crate.

## Stage 3: Rust bring-up

`kernel_main_impl` in `crates/kernel/src/kmain.rs` initializes subsystems in an
order that respects their dependencies:

```text
page allocator
  → UARTs and console rendering
  → vectors, GIC, timer
  → USB gadget and trace symbols
  → syscall table and initramfs
  → EMMC2 and optional FAT32 mount
  → entropy source
  → scheduler and PID 1
```

FlashOS is currently uniprocessor. Other Pi cores remain parked, so the
scheduler does not yet need an SMP locking model.

## PID 0 and PID 1

PID 0 keeps the boot stack and acts as the idle/scheduler context. The kernel
creates PID 1 as a kernel thread, installs console descriptors 0, 1, and 2,
finds `/sbin/init` in the initramfs, and maps its ELF image into a fresh EL0
address space.

At the final exception return, the CPU changes privilege level as well as
program counter: Rust kernel code continues only when EL0 later invokes a
syscall, takes an interrupt, or faults.

> [!TIP]
> `arch/aarch64/README.md` documents the provided/required symbol boundary
> between retained assembly and Rust. `cargo xtask asm-defs --check` verifies
> the generated constants on that boundary.

Next, we look at the virtual-memory contract that makes this transition safe.
