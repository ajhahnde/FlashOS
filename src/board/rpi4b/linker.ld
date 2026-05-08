/*
 * Kernel link script (RPi4, AArch64).
 * The user-space image is identified by its object file name
 * (user_init.o). Everything from that object lands in the
 * .text.user / .rodata.user / .data.user / .bss.user wrapper sections
 * between `user_start` and `user_end`, which the kernel copies into a
 * user page when dropping PID 1 to EL0.
 */

SECTIONS
{
    /DISCARD/ : { *(.eh_frame) *(.eh_frame_hdr) *(.note.*) *(.comment) }

    /* RPi4 firmware loads kernel8.img at PA 0x80000 (the standard AArch64
     * load address; see "Kernel relocated to 0x80000" in start4.elf log).
     * Linking at the same base means linker-resolved global pointers
     * actually point at the bytes the firmware placed — no relocator
     * needed at boot. Previously the implicit base was 0x01000000, which
     * sat above the 16 MB id-map and caused L2 translation faults the
     * moment any global was dereferenced (e.g. ksyms in cal_ksyms_count). */
    . = 0x80000;

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
    .data.high_pg_dir : { . += (6 * (1 << 12)); }

    user_start = .;
    .text.user : { *user_init*.o(.text .text.*) }
    .rodata.user : { *user_init*.o(.rodata .rodata.*) }
    .data.user : { *user_init*.o(.data .data.*) }
    .bss.user : { *user_init*.o(.bss .bss.* COMMON) }
    . = ALIGN(0x1000);
    user_end = .;
}
