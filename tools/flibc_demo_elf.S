/*
 * Embed tools/flibc_demo.elf (built from tools/flibc_demo_elf.zig +
 * the user_space/lib/flibc/ module) into the kernel image's .rodata
 * section between two globals so the [TEST] flibc harness can pass
 * them to sys_exec via the bridge u64s in user_space/kernel_tests.zig.
 *
 * Mirrors tools/hello_elf.S — the build wires `flibc_demo_elf_stage`
 * as an include path so the relative "flibc_demo.elf" lookup succeeds
 * regardless of CWD.
 */

    .section .rodata.flibc_demo_elf,"a",@progbits
    .balign 8
    .globl  flibc_demo_elf_start
flibc_demo_elf_start:
    .incbin "flibc_demo.elf"
    .globl  flibc_demo_elf_end
flibc_demo_elf_end:
