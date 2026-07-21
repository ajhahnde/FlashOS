/*
 * Linker script for the Rust PID-1 payload — produces the
 * standalone pid1.elf that the kernel ELF-loads as PID 1.
 * Same single-PT_LOAD shape as
 * link/flibc_demo_linker.ld: .text / .rodata / .data / .bss all fold
 * into one R+X LOAD segment at the page-aligned base 0x100000.
 *
 * pid1.elf carries the whole native kernel-test harness, so
 * it is the largest of the staged ELFs. Folding rodata/data/bss into
 * the single LOAD keeps it to one segment, which the FlashOS ELF
 * loader (page-grain mapper, rejects non-page-aligned p_vaddr, does
 * not coalesce overlapping segments) maps without special-casing.
 *
 * Unlike the test payloads pid1.elf is loaded by kernel_process via
 * prepare_move_to_user_elf directly (not through sys_exec), so it is
 * NOT subject to sys_exec's PAGE_SIZE snapshot cap — prepare_move_to_
 * user_elf walks the PT_LOAD page by page. The harness still builds
 * ReleaseSmall + strip to keep the initramfs small.
 *
 * Layout:
 *   . = 0         — start of the only LOAD segment, page-aligned.
 *   .text         — code (entry point _start lives here).
 *   .rodata*      — the harness's [TEST]/[PASS]/[FAIL] string table.
 *   .data* / .bss* — comptime-emitted constants (expected zero-sized;
 *                    a non-zero .bss would store-fault on first write
 *                    because the LOAD is R+X — a clear runtime signal
 *                    the harness grew module-level mutable state).
 *
 * eh_frame/note/comment/dyn* sections are discarded — the harness is
 * pure syscall-wrapper inline asm with no unwind tables, and the
 * stock LLD layout would otherwise split .eh_frame_hdr / .eh_frame
 * into a leading R-only LOAD that bumps .text past the page-aligned
 * base the loader requires.
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
