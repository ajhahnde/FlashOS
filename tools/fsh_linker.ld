/*
 * Linker script for the native FlashOS shell. Same
 * single-PT_LOAD shape as tools/argv_echo_linker.ld, minus the 4 KiB
 * .rodata PAD: fsh does not need to cross a page (it is not proving the
 * sys_execve streaming path), so it folds straight into one R+X LOAD.
 * Entry is the flibc _start argc/argv shim, selected via ENTRY(_start).
 *
 * Layout:
 *   . = 0         — start of the only LOAD segment, page-aligned.
 *   .text         — code; the _start shim symbol lives here. e_entry is
 *                   set from _start via ENTRY(_start), so its position
 *                   within .text does not matter to the loader.
 *   .rodata*      — printf / prompt / help string literals.
 *   .data*        — comptime-emitted constants (expected zero-sized).
 *   .bss*         — zero-initialized data (expected zero-sized; fsh keeps
 *                   every mutable buffer on the user stack precisely so
 *                   this stays empty — a non-zero .bss would store-fault
 *                   on first write because the LOAD is R+X).
 *
 * eh_frame/note/comment/dyn* are discarded — fsh emits no unwind tables,
 * and the stock LLD layout would otherwise split .eh_frame_hdr /
 * .eh_frame into a leading R-only LOAD that bumps .text past the
 * page-aligned base the FlashOS loader requires.
 */

ENTRY(_start)

PHDRS {
    text PT_LOAD FLAGS(5); /* PF_R | PF_X */
}

SECTIONS {
    . = 0;

    .text : {
        *(.text._start)
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.data .data.*)
        *(.bss .bss.*)
        *(COMMON)
    } :text

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note*)
        *(.comment*)
        *(.dynamic)
        *(.dynsym)
        *(.dynstr)
        *(.gnu.hash)
        *(.hash)
        *(.gnu.version*)
        *(.interp)
        *(.rela*)
        *(.rel*)
    }
}
