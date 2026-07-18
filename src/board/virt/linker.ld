/*
 * Kernel link script for QEMU's `-M virt` (AArch64).
 * Mirrors src/board/rpi4b/linker.ld; the only structural change
 * is the load base. PID 1 is ELF-loaded from the embedded initramfs
 * — the `user_init.o` blob and its
 * `user_start` / `user_end` wrapper are retired, same as on Pi.
 */

SECTIONS
{
    /DISCARD/ : { *(.eh_frame) *(.eh_frame_hdr) *(.note.*) *(.comment) }

    /* QEMU's `-M virt -kernel` (and a future UEFI/GRUB chain)
     * follow the Linux arm64 boot protocol: kernel entry at
     * 0x40080000, the standard load offset within the virt RAM
     * window starting at 0x40000000. Linking at the same base
     * means linker-resolved global pointers point at the bytes
     * the loader placed — no relocator needed at boot. */
    . = 0x40080000;
    _image_start = .;

    /* Linux arm64 boot header (64 bytes) — placed first so UEFI/GRUB
     * can identify the image. The branch at offset 0 jumps forward
     * to `_start_real` in `.text.boot`. */
    .text.boot.header : { KEEP(*(.text.boot.header)) }

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

    /* Embedded initramfs — mirror of src/board/rpi4b/linker.ld. See
     * that file's comment for the symbol-area convergence rationale. */
    . = ALIGN(0x4);
    .initramfs : {
        KEEP(*(.initramfs))
    }

    . = ALIGN(0x1000);
    id_pg_dir = .;
    .data.id_pg_dir : { . += (3 * (1 << 12)); }
    high_pg_dir = .;
    .data.high_pg_dir : { . += (4 * (1 << 12)); }

    . = ALIGN(0x1000);
    _end = .;

    /* Linker-resolved image_size constant for the arm64 boot header.
     * `.quad _end - _image_start` in image_header.S would force GAS
     * to emit a subtraction expression on two extern symbols, which
     * GAS rejects; assigning here turns it into a single absolute
     * symbol the linker resolves. Same trick Linux uses
     * (`_kernel_size_le` in arch/arm64/kernel/vmlinux.lds.S). */
    _image_size = _end - _image_start;

    /* virt-only 64 MiB memory-backed SD scratch. NOLOAD, and placed
     * LAST — after `_end` and
     * after `_image_size` is computed — so it shifts nothing the boot
     * path depends on: not bss_begin/bss_end (boot.S clears bss via
     * `adr x1, bss_end`, ±1 MiB PC-relative; a 64 MiB `.bss` member
     * overflows that reloc), not id_pg_dir/high_pg_dir (must stay in
     * virt's 16 MiB identity window), not `_image_size` (QEMU's DTB
     * placement). emmc2.init() @memsets the buffer itself, so it does
     * not need the boot.S bss memzero. At runtime the kernel runs at
     * the LINEAR_MAP_BASE alias whose RAM map covers 0x40000000..
     * 0x80000000, so the buffer is reachable. No rpi4b counterpart —
     * rpi4b's EMMC2 driver is real MMIO with no backing array. */
    . = ALIGN(0x1000);
    .sdscratch (NOLOAD) : {
        KEEP(*(.sdscratch))
    }

    /* End-of-reserved-PA marker for the get_free_page pool. virt loads
     * the kernel at PA 0x40080000, inside the pool's MALLOC_START
     * (0x40000000) window, so mem_map_reserve_below(_kernel_pa_end)
     * must mark every page up to and including sdscratch as allocated
     * — otherwise get_free_page hands out PAs that overlap the kernel
     * image and memzero corrupts kernel code (notably memzero itself
     * around PA 0x40081000), leading to a silent stall. Pi has the
     * mirror symbol defined as a no-op (kernel below the pool). */
    . = ALIGN(0x1000);
    _kernel_pa_end = .;
}
