# Chapter 3: Power-on: Firmware to start.S

Chapter 2 ended at the first `[ OK ]` line — the Mini-UART console
coming up. Everything before that line is not "the kernel" in any
meaningful sense yet: it is fixed-function GPU firmware handing off to
a tiny, hand-written assembly stub, which in turn hands off to the
kernel image's own entry point. This chapter walks that handoff chain
from power-on down to the first line of `kernel_main`, one level below
where chapter 2 left off.

## The GPU bootloader

On a Raspberry Pi 4, the ARM cores are not what runs first. The
VideoCore GPU's firmware (`start4.elf` / `fixup4.dat` on the SD card,
per `SETUP.md` §4 "SD-card layout") boots first, reads `config.txt`,
and only then loads two files into RAM and starts the ARM cores — at
EL3, the highest ARMv8 exception level:

1. `armstub8.bin` — the secure-mode bootstrap shim.
2. `kernel8.img` — the FlashOS kernel image itself.

(DOCUMENTATION.md §2, step 1.) Nothing FlashOS built has executed a
single instruction yet at this point; this step is entirely GPU
firmware and bundled Raspberry Pi Foundation blobs.

## `armstub8.S`: preparing the EL3→EL1 drop

`armstub/src/armstub8.S` is the first FlashOS-controlled code to run,
and it runs at EL3. Its job is narrow: configure the secure-mode
registers, enable the GIC (interrupt controller) in secure mode, and
hand off toward EL1 — the exception level the kernel actually runs at.

```asm
    bl      setup_gic
    bl      setup_more_regs
```

`setup_gic` sets all interrupts to group 1 and enables the
distributor/CPU interfaces; `setup_more_regs` writes `SCTLR_EL2`,
`SCTLR_EL1`, `HCR_EL2`, `SPSR_EL3`, `CPACR_EL1`, `TCR_EL1`, and
`MAIR_EL1` — most of which the kernel's own boot code (below)
overwrites again once it is running, but `SPSR_EL3` in particular is
what the *actual* EL3→EL1 privilege drop uses once control reaches it:

```asm
    /* setup SPSR_EL3 */
    ldr x0, =SPSR_EL3_VAL
    msr SPSR_EL3, x0
```

*(excerpt — not standalone-compilable)*

With those registers prepared, armstub does not `eret` itself — it
branches straight into the kernel image it just loaded, still at EL3:

```asm
primary_cpu:
    ldr w4, kernel_entry32
    ldr w0, dtb_ptr32

boot_kernel:
    mov x1, #0
    mov x2, #0
    mov x3, #0
    br x4
```

*(excerpt — not standalone-compilable)*

`x4` holds the kernel entry address the GPU firmware wrote into
armstub's data area; `br x4` is a plain branch, not an exception
return, so execution is still at EL3 when it lands on the kernel
image's own `_start`.

> [!NOTE]
> The actual `eret` that drops from EL3 to EL1 executes moments later,
> inside the kernel's own `arch/aarch64/boot.S` — see below. Armstub's
> job is to leave `SPSR_EL3` (and the GIC, and the other secure-mode
> registers) in the state that drop needs.

## `boot.S`'s `_start`: building the address space and dropping to EL1

`arch/aarch64/boot.S` is where the kernel image itself begins. `_start`
(aliased as `_start_real` for the `virt` board's Linux-image-header
compatibility) branches to `master`, the primary core's entry point.
`master` calls `drop_to_el1`, which is where the actual privilege drop
happens — using the `SPSR_EL3` value armstub wrote:

```asm
    /* EL3 path: armstub already wrote SPSR_EL3 / HCR_EL2 / SCR_EL3
     * etc. Eret to el1_entry. */
    adr x0, el1_entry
    msr ELR_EL3, x0
    eret
```

*(excerpt — not standalone-compilable)*

From EL1 onward, `master` sets up a stack, clears `.bss`, and builds
two AArch64 page-table trees — an identity mapping (so code keeps
executing correctly right up to the moment the MMU turns on) and a
"high" mapping (the kernel's real, linked virtual addresses):

```asm
    bl memzero
    bl map_identity
    bl map_high
    bl wake_up_cores
```

*(excerpt — not standalone-compilable)*

It then programs `MAIR_EL1`, `TCR_EL1`, and `VBAR_EL1` (the exception
vector base), sets `TTBR0_EL1`/`TTBR1_EL1` to the two page-table roots
just built, enables the MMU by setting `SCTLR_EL1.M` followed by an
`ISB`, and only then jumps — through the newly-live high virtual
mapping — into `kernel_main`:

```asm
    /* turn on the mmu */
    ldr x0, .Lsctlr_mmu_enabled
    msr sctlr_el1, x0
    isb
    /* prepare jumping to high mem */
    ldr x2, =LINEAR_MAP_BASE
    add sp, sp, x2
    adr x1, kernel_main
    add x1, x1, x2
    /* core 0 */
    mov x0, #0
    /* jump to high mem */
    blr x1
```

*(excerpt — not standalone-compilable)*

The secondary cores (`app`, a few lines below `master` in the same
file) take a shorter path: drop to EL1, set up a per-core stack, and
jump straight to `kernel_main` — the page tables `master` built are
already live by the time they get there.

None of the page-table construction needs explaining line by line here
— `map_identity` and `map_high` and the block-mapping macros around
them are chapter 4's subject (Memory: MMU & Page Allocator). What
matters for this chapter is just the shape of the handoff: `boot.S` is
the place where the address space the rest of the kernel runs in gets
built, and `kernel_main` is reached only once the MMU is already on.

## Landing in `kernel_main`

`kernel_main` (`src/kernel.flash`) is the first Flash code to run.
It brings up, in order: the Mini-UART console, the PL011 trace UART,
the GIC (interrupt controller) driver, the kernel's own symbol table,
the syscall table, and the generic timer — then forks PID 1 and enters
the scheduler loop (DOCUMENTATION.md §2, step 4). This is exactly the
sequence chapter 2's boot-log walkthrough named line by line; this
chapter has just supplied everything that happens *before* the first
of those lines can print.

Each of those subsystems gets its own chapter later in the tour:
memory management (the page allocator this address space now sits on)
in chapter 4, the console drivers in chapter 5, the scheduler in
chapter 6, and syscalls in chapter 7. This chapter's job was only to
establish the handoff point — from GPU firmware, through armstub, and
through `boot.S`'s page tables and MMU bring-up, to the first line of
kernel code.

## What's next

Chapter 4 picks up exactly where `boot.S`'s `map_identity` and
`map_high` left off: the MMU and the page-table layout they build, and
the physical page allocator `kernel_main` initializes once it starts
running.
