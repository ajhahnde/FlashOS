/*
 * Embed initramfs.cpio (built by cargo xtask from the
 * staged initramfs tree) into the kernel image between two globals
 * the kernel's native initramfs parser reads via TTBR1.
 *
 * .incbin's path is resolved against the assembler's include path —
 * see xtask/src/build.rs where the staged initramfs.cpio directory is added
 * to clang's include path. Without that include-path wiring
 * the relative "initramfs.cpio" lookup would fail.
 *
 * Section name `.initramfs` matches the linker.ld output section on
 * both boards (src/board/rpi4b/linker.ld, src/board/virt/linker.ld),
 * which place the section between bss_end and id_pg_dir.
 */

    .section .initramfs, "a", @progbits
    .balign 4
    .globl  __initramfs_start
__initramfs_start:
    .incbin "initramfs.cpio"
    .balign 4
    .globl  __initramfs_end
__initramfs_end:
