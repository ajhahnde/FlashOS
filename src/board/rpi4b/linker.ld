/*
 * Kernel link script (RPi4, AArch64).
 * PID 1 is ELF-loaded from the embedded initramfs (v0.4.0):
 * `/sbin/init` is the standalone `pid1.elf` artifact, and
 * the kernel's `prepare_move_to_user_elf` maps it page-grain. The
 * v0.3.0 `user_init.o` blob — wrapped here in `.text.user` /
 * `.rodata.user` / `.data.user` / `.bss.user` between `user_start`
 * and `user_end` — is retired.
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
        *(.text)
        *(.text.*)
    }
    .rodata : {
        *(.rodata)
        *(.rodata.*)
    }
    .data : {
        *(.data)
        *(.data.*)
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
        *(.bss)
        *(.bss.*)
        *(COMMON)
    }
    bss_end = .;

    /* Embedded initramfs (v0.4.0). Placed between bss_end and
     * id_pg_dir; the kernel reads it through a TTBR1 linear-map
     * alias in src/initramfs.zig. Size shifts everything past it
     * (id_pg_dir, high_pg_dir), so the cpio bytes must be a
     * deterministic function of the source tree (see
     * scripts/build_initramfs.zig for the deterministic encoder). */
    . = ALIGN(0x4);
    .initramfs : {
        KEEP(*(.initramfs))
    }

    . = ALIGN(0x1000);
    id_pg_dir = .;
    .data.id_pg_dir : { . += (3 * (1 << 12)); }
    high_pg_dir = .;
    .data.high_pg_dir : { . += (6 * (1 << 12)); }
}
