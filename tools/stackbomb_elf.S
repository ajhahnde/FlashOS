/*
 * Embed tools/stackbomb.elf (built from tools/stackbomb_elf.zig) into
 * the kernel image's .rodata section between two globals so the
 * [TEST] stack-overflow harness can pass them to sys_exec via the
 * bridge u64s in user_space/kernel_tests.zig.
 *
 * Mirrors tools/hello_elf.S — see that file for the .incbin path
 * resolution rules; the build wires `stackbomb_elf_stage` as an
 * include path so the relative "stackbomb.elf" lookup succeeds
 * regardless of CWD.
 */

    .section .rodata.stackbomb_elf,"a",@progbits
    .balign 8
    .globl  stackbomb_elf_start
stackbomb_elf_start:
    .incbin "stackbomb.elf"
    .globl  stackbomb_elf_end
stackbomb_elf_end:
