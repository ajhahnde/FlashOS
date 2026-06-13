// start: kernel entry root for the Zig build.
//
// The entry point is `_start` in src/boot.S, which calls `kernel_main`
// (kernel.flash). Zig's executable target needs a root module; this file
// is it: every other kernel module is pulled in here via comptime
// @import so all `export fn` decls land in the final ELF.

const board = @import("board.zig");

// Board-driver trampolines for the Flash-sourced kernel + syscall modules.
// src/kernel.flash and src/sys.flash are named modules whose generated .zig
// lives in the build cache, so they can no longer @import the relatively
// imported board bag. This root module still imports board.zig directly, so
// these thin C-ABI wrappers bridge the boundary — kernel.flash / sys.flash
// reach each board entry point through a matching `extern fn`. (Same role
// fork.zig's move_to_user_elf_argv plays for execve.)
export fn board_irq_init() void {
    board.irq.board_irq_init();
}
export fn board_usb_init() i32 {
    return board.usb.usb_init();
}
export fn board_usb_poll() void {
    board.usb.poll();
}
export fn board_usb_enumerated() bool {
    return board.usb.enumerated();
}
export fn board_usb_cdc_tx(ptr: [*]const u8, len: u64) void {
    board.usb.cdc_tx(ptr[0..len]);
}
export fn board_emmc2_init() i32 {
    return board.emmc2.init();
}
export fn board_emmc2_write_block(lba: u32, buf: *const [512]u8) i32 {
    return board.emmc2.write_block(lba, buf);
}
export fn board_emmc2_read_block(lba: u32, buf: *[512]u8) i32 {
    return board.emmc2.read_block(lba, buf);
}
export fn board_uart_poll_rx_into_console() void {
    board.uart.poll_rx_into_console();
}
export fn board_power_reboot() noreturn {
    board.power.reboot();
}

comptime {
    _ = @import("kernel");
    _ = board.uart;
    _ = board.gpio;
    _ = board.timer;
    _ = @import("generic_timer");
    _ = board.irq;
    _ = board.emmc2;
    _ = board.usb;
    _ = @import("sched");
    _ = @import("fork");
    _ = @import("execve");
    _ = @import("sys");
    _ = @import("page_alloc");
    _ = @import("mm_user");
    _ = @import("utilc");
    _ = @import("hwrng");

    _ = @import("trace/utils.zig");
    _ = @import("trace/trace_main.zig");
    // ksyms is a named module (see build.zig) so the -Dtrace sampler can
    // reach it without ksyms.zig ending up a member of two modules.
    _ = @import("ksyms");
    _ = @import("trace/pl011_uart.zig");
}
