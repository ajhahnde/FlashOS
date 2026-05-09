/*
 * Embed tools/hello.elf (built from tools/hello_elf.zig) into the
 * kernel image's .rodata section between two globals so the
 * [TEST] exec-elf harness can pass them to sys_exec via the bridge
 * u64s in user_space/kernel_tests.zig.
 *
 * .incbin's path is resolved against the assembler's include path —
 * see build.zig where the staged hello.elf directory is added via
 * kernel_mod.addIncludePath(...). Without that include-path wiring the
 * relative "hello.elf" lookup would fail.
 */

    .section .rodata.hello_elf,"a",@progbits
    .balign 8
    .globl  hello_elf_start
hello_elf_start:
    .incbin "hello.elf"
    .globl  hello_elf_end
hello_elf_end:
