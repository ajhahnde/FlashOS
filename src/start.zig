// start: kernel entry root for the Zig build.
//
// The entry point is `_start` in src/boot.S, which calls `kernel_main`
// (kernel.zig). Zig's executable target needs a root module; this file
// is it: every other kernel module is pulled in here via comptime
// @import so all `export fn` decls land in the final ELF.

const board = @import("board.zig");

comptime {
    _ = @import("kernel.zig");
    _ = board.uart;
    _ = board.gpio;
    _ = board.timer;
    _ = @import("generic_timer.zig");
    _ = board.irq;
    _ = board.emmc2;
    _ = board.usb;
    _ = @import("sched");
    _ = @import("fork.zig");
    _ = @import("execve");
    _ = @import("sys.zig");
    _ = @import("page_alloc");
    _ = @import("mm_user.zig");
    _ = @import("utilc");
    _ = @import("hwrng.zig");

    _ = @import("trace/utils.zig");
    _ = @import("trace/trace_main.zig");
    _ = @import("trace/ksyms.zig");
    _ = @import("trace/pl011_uart.zig");
}
