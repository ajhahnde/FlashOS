// Recursive stack-blower for the [TEST] stack-overflow scenario.
// Built as a separate aarch64-freestanding ET_EXEC alongside hello.elf
// (build.zig) and embedded into the kernel image via .incbin
// (tools/stackbomb_elf.S) so the in-kernel harness can hand its bytes
// to sys_exec without an initramfs.
//
// _start jumps into a trivial recursion that pushes 1 KiB per frame
// (sub sp, #1024 + str x30, [sp]) so each `bl 1b` deepens the stack
// by exactly that amount. After ~64 frames SP crosses STACK_LOW and
// the next store enters the guard page; the kernel's do_data_abort
// detects the guard fault, prints `[KERN] stack overflow at 0x<hex>`,
// and zombies the task. The parent's sys_wait then reaps as usual.

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\.balign 8
        \\1:
        \\    sub sp, sp, #1024
        \\    str x30, [sp]
        \\    bl 1b
    );
}
