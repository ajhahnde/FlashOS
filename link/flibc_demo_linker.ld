/*
 * Linker script for the Rust flibc_demo payload — same single-PT_LOAD
 * shape as link/hello_linker.ld, extended to capture `.rodata*` (printf
 * format strings, the "flibc malloc ok" message) and any `.data*` /
 * `.bss*` the compiler may emit. flibc's bump allocator stores no state
 * (each malloc is a thin sbrk wrapper, returning the previous break),
 * so a writable PT_LOAD is unnecessary; folding rodata/data/bss into
 * the R+X LOAD keeps the blob at one segment, which in turn keeps it
 * inside sys_exec's PAGE_SIZE snapshot cap.
 *
 * Layout:
 *   . = 0         — start of the only LOAD segment, page-aligned.
 *   .text         — code (entry point _start lives here).
 *   .rodata*      — printf format spec literals etc.
 *   .data*        — comptime-emitted constants (expected zero-sized).
 *   .bss*         — zero-initialized data (expected zero-sized; if
 *                   non-zero the demo would store-fault on first write
 *                   because the LOAD is R+X — clear runtime signal that
 *                   the state-free bump-allocator invariant has been
 *                   broken).
 *
 * eh_frame/note/comment/dyn* sections are discarded — the demo is small
 * enough that none of its Zig codepaths emit unwind tables, and the
 * stock LLD layout would otherwise split .eh_frame_hdr / .eh_frame into
 * a leading R-only LOAD that bumps .text past the page-aligned base
 * the FlashOS loader requires.
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
