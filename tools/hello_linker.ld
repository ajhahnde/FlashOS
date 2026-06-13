/*
 * Minimal linker script for tools/hello.flash — produces a single
 * page-aligned PT_LOAD segment so the FlashOS ELF loader (which
 * rejects non-page-aligned p_vaddrs and does not coalesce overlapping
 * segments) can map it page-grain. The kernel loader copies file-
 * backed bytes into freshly-allocated user pages keyed by p_vaddr; a
 * stock LLD layout instead splits .eh_frame_hdr / .eh_frame into a
 * leading R-only LOAD ahead of .text, leaving .text at a non-page-
 * aligned VA that the loader rejects.
 *
 * Layout:
 *   . = 0         — start of the only LOAD segment, page-aligned.
 *   .text         — code (entry point _start lives here).
 *
 * eh_frame/note/comment/dyn* sections are discarded — _start is naked
 * inline asm with no unwind tables, so nothing references them at
 * runtime; keeping them would force a second LOAD segment with
 * different permissions, defeating the layout invariant above.
 */

ENTRY(_start)

PHDRS {
    text PT_LOAD FLAGS(5); /* PF_R | PF_X */
}

SECTIONS {
    . = 0;

    /* Page-aligned via `. = 0` above — explicit ALIGN(0x1000)
     * here would force the section's natural alignment to a page,
     * which LLD propagates into the PT_LOAD's p_align, which in turn
     * forces p_offset to a page-aligned file offset and pads the file
     * past PAGE_SIZE (the loader's snapshot-page limit). The base VA
     * 0 is already 0x1000-aligned, so no extra ALIGN is needed
     * for FlashOS's page-grain mapper.
     */
    .text : {
        *(.text._start)
        *(.text .text.*)
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
