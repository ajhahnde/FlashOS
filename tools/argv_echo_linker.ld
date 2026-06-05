/*
 * Linker script for tools/argv_echo_elf.zig — same single-PT_LOAD shape
 * as tools/flibc_demo_linker.ld. argv_echo links the flibc _start shim
 * (user_space/lib/flibc/start.zig) as its entry, walks argv, printf's
 * each arg, and exits. The forked script folds `.rodata*` / `.data*` /
 * `.bss*` into the one R+X LOAD; unlike flibc_demo this demo carries a
 * 4 KiB `.rodata` PAD on purpose, pushing the segment past one page so
 * the payload can only load through sys_execve's PT_LOAD streaming path
 * (not the legacy PAGE_SIZE snapshot cap).
 *
 * Layout:
 *   . = 0         — start of the only LOAD segment, page-aligned.
 *   .text         — code; the _start shim symbol lives here. e_entry is
 *                   set from the _start symbol via ENTRY(_start), so its
 *                   position within .text does not matter to the loader.
 *   .rodata*      — printf format literals + the 4 KiB PAD.
 *   .data*        — comptime-emitted constants (expected zero-sized).
 *   .bss*         — zero-initialized data (expected zero-sized; if
 *                   non-zero the demo would store-fault on first write
 *                   because the LOAD is R+X — clear runtime signal that
 *                   flibc's state-free invariant has been broken).
 *
 * eh_frame/note/comment/dyn* sections are discarded — the demo emits no
 * unwind tables, and the stock LLD layout would otherwise split
 * .eh_frame_hdr / .eh_frame into a leading R-only LOAD that bumps .text
 * past the page-aligned base the FlashOS loader requires.
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
