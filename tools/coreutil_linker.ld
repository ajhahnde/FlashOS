/*
 * Shared linker script for the minimal coreutils (tools/echo_elf.zig,
 * tools/cat_elf.zig). Identical single-PT_LOAD shape to
 * tools/fsh_linker.ld: one R+X LOAD at base 0, _start shim entry, no
 * page-crossing PAD. echo and cat have the same link needs, so one
 * script serves both rather than two byte-identical forks.
 *
 * Layout:
 *   . = 0         — start of the only LOAD segment, page-aligned.
 *   .text         — code; the _start shim symbol lives here. e_entry is
 *                   set from _start via ENTRY(_start).
 *   .rodata*      — string literals (diagnostics, separators).
 *   .data*        — comptime-emitted constants (expected zero-sized).
 *   .bss*         — zero-initialized data (expected zero-sized; the
 *                   coreutils keep their buffers on the user stack so
 *                   this stays empty — a non-zero .bss would store-fault
 *                   on first write because the LOAD is R+X).
 *
 * eh_frame/note/comment/dyn* are discarded — these payloads emit no
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
