/*
 * Kernel link script for QEMU's `-M virt` (AArch64).
 * Mirrors src/board/rpi4b/linker.ld; the only structural change
 * is the load base. The user-space image is identified by its
 * object file name (user_init.o) — same convention as on Pi.
 */

SECTIONS
{
    /DISCARD/ : { *(.eh_frame) *(.eh_frame_hdr) *(.note.*) *(.comment) }

    /* QEMU's `-M virt -kernel` (and UEFI/GRUB chain in Phase B)
     * follow the Linux arm64 boot protocol: kernel entry at
     * 0x40080000, the standard load offset within the virt RAM
     * window starting at 0x40000000. Linking at the same base
     * means linker-resolved global pointers point at the bytes
     * the loader placed — no relocator needed at boot. */
    . = 0x40080000;
    _image_start = .;

    /* Linux arm64 boot header (64 bytes) — placed first so UEFI/GRUB
     * (Phase B, Schritt 13) can identify the image. The branch at
     * offset 0 jumps forward to `_start_real` in `.text.boot`. */
    .text.boot.header : { KEEP(*(.text.boot.header)) }

    .text.boot : { *(.text.boot) *(.text.boot.late) *(.text.boot.literals) }
    .text : {
        *(EXCLUDE_FILE(*user_init*.o) .text)
        *(EXCLUDE_FILE(*user_init*.o) .text.*)
    }
    .rodata : {
        *(EXCLUDE_FILE(*user_init*.o) .rodata)
        *(EXCLUDE_FILE(*user_init*.o) .rodata.*)
    }
    .data : {
        *(EXCLUDE_FILE(*user_init*.o) .data)
        *(EXCLUDE_FILE(*user_init*.o) .data.*)
    }

    . = ALIGN(0x8);
    __start_patchable_functions = .;
    .patchable_function_entries : {
        KEEP(*(__patchable_function_entries))
    }
    __stop_patchable_functions = .;

    . = ALIGN(0x8);
    ksyms = .;
    symbols : {
        KEEP(*(_symbols))
    }

    . = ALIGN(0x8);
    bss_begin = .;
    .bss : {
        *(EXCLUDE_FILE(*user_init*.o) .bss)
        *(EXCLUDE_FILE(*user_init*.o) .bss.*)
        *(EXCLUDE_FILE(*user_init*.o) COMMON)
    }
    bss_end = .;

    . = ALIGN(0x1000);
    id_pg_dir = .;
    .data.id_pg_dir : { . += (3 * (1 << 12)); }
    high_pg_dir = .;
    .data.high_pg_dir : { . += (4 * (1 << 12)); }

    user_start = .;
    .text.user : { *user_init*.o(.text .text.*) }
    .rodata.user : { *user_init*.o(.rodata .rodata.*) }
    .data.user : { *user_init*.o(.data .data.*) }
    .bss.user : { *user_init*.o(.bss .bss.* COMMON) }
    . = ALIGN(0x1000);
    user_end = .;
    _end = .;

    /* Linker-resolved image_size constant for the arm64 boot header.
     * `.quad _end - _image_start` in image_header.S would force GAS
     * to emit a subtraction expression on two extern symbols, which
     * GAS rejects; assigning here turns it into a single absolute
     * symbol the linker resolves. Same trick Linux uses
     * (`_kernel_size_le` in arch/arm64/kernel/vmlinux.lds.S). */
    _image_size = _end - _image_start;
}
