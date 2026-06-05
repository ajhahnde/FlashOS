// Payload for [TEST] flibc — exercises three flibc layers:
// printf (comptime format + sys_writeConsole flush),
// malloc (bump-over-sbrk), and exit (sys_exit). fork/wait/execve are
// covered indirectly by the existing fork-stress / exec-elf scenarios
// running through their flibc-equivalent SVC wrappers, so the demo
// stays single-PT_LOAD by avoiding a self-fork.
//
// Build: aarch64-freestanding ET_EXEC via build.zig (pie=false, strip,
// ReleaseSmall, hello-style page caps). Embedded in the kernel image
// via .incbin in tools/flibc_demo_elf.S so the harness can hand its
// bytes to sys_exec without an initramfs.
//
// Trace contract verified by the test scenario in
// user_space/kernel_tests.zig:
//   "flibc hello 42\n"      — printf %d round-trip
//   "flibc malloc ok\n"     — bump-allocate 32 B, write+verify pattern

const flibc = @import("flibc");

const ALLOC_BYTES: u64 = 32;

// Naked entry: kernel sets sp = STACK_TOP, regs zeroed. _start runs as
// a normal Zig function (no `callconv(.naked)`) because flibc_main below
// uses Zig features (loops with locals, malloc fallthrough) that require
// a real frame; the AAPCS64 prologue Zig emits is fine on the eagerly-
// mapped top stack page.
export fn _start() noreturn {
    flibc.printf("flibc hello %d\n", .{@as(u32, 42)});

    const buf = flibc.malloc(ALLOC_BYTES) orelse {
        flibc.puts("flibc malloc fail");
        flibc.exit();
    };

    // Demand-allocate the heap page on first write — do_data_abort
    // classifies the fault as in-range heap and stamps a fresh RW+UXN
    // page before retrying. The pattern is round-trip-verified below
    // so a stale TLB / wrong-PA bug surfaces as a "flibc malloc bad"
    // line in the trace instead of a silent pass.
    var i: u64 = 0;
    while (i < ALLOC_BYTES) : (i += 1) {
        buf[i] = @as(u8, @intCast(i)) +% 0x55;
    }

    var ok = true;
    i = 0;
    while (i < ALLOC_BYTES) : (i += 1) {
        const expected: u8 = @as(u8, @intCast(i)) +% 0x55;
        if (buf[i] != expected) ok = false;
    }

    flibc.puts(if (ok) "flibc malloc ok" else "flibc malloc bad");
    flibc.exit();
}
