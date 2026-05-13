// PID 1 entry point. Runs in EL0 after the kernel hands off via
// prepare_move_to_user. The body of the in-kernel test suite (fork-
// stress / kill / exec scenarios + tally) lives in kernel_tests.zig;
// this file keeps only the hardcoded entry symbol.
//
// Every decl is placed into .text.user / .rodata.user via linksection
// so the linker script can wrap the user image in `user_start` /
// `user_end` for the kernel to copy into a user page.

const tests = @import("kernel_tests.zig");

const PID1_MSG: [*:0]const u8 linksection(".rodata.user") = "pid 1 in user space\n";

export fn user_process() linksection(".text.user") noreturn {
    tests.sys_writeConsole(PID1_MSG);
    const result = tests.run_all();
    tests.print_tally(result.passed, result.total);
    tests.sys_exit();
}
