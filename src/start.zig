// start: kernel entry root for the Zig build.
//
// The entry point is `_start` in arch/aarch64/boot.S, which calls `kernel_main`
// (kernel.flash). Zig's executable target needs a root module; this file
// is it: every other kernel module is pulled in here via comptime
// @import so all `export fn` decls land in the final ELF.

const board = @import("board");
const build_options = @import("build_options");
extern fn rpi4b_power_reboot() noreturn;
extern fn rpi4b_uart_poll_rx_into_console() void;
extern fn rpi4b_board_irq_init() void;
extern fn rpi4b_emmc2_init() i32;
extern fn rpi4b_emmc2_write_block(lba: u32, buf: *const [512]u8) i32;
extern fn rpi4b_emmc2_read_block(lba: u32, buf: *[512]u8) i32;
extern fn rpi4b_usb_init() i32;
extern fn rpi4b_usb_poll() void;
extern fn rpi4b_usb_enumerated() bool;
extern fn rpi4b_usb_cdc_tx(ptr: [*]const u8, len: u64) void;
extern fn rpi4b_mailbox_get_temperature() u32;
extern fn rpi4b_mailbox_get_cpu_clock() u32;

// Board-driver trampolines for the Flash-sourced kernel and Rust syscall
// implementation. The generated kernel module cannot safely import board.zig
// by a relative path, so both sides reach board entry points through stable C
// symbols. The same boundary keeps the mixed-language driver cutover local.
export fn board_irq_init() void {
    if (build_options.board == .rpi4b) {
        rpi4b_board_irq_init();
    } else {
        board.irq.board_irq_init();
    }
}
export fn board_usb_init() i32 {
    if (build_options.board == .rpi4b) {
        return rpi4b_usb_init();
    } else {
        return board.usb.usb_init();
    }
}
export fn board_usb_poll() void {
    if (build_options.board == .rpi4b) {
        rpi4b_usb_poll();
    } else {
        board.usb.poll();
    }
}
export fn board_usb_enumerated() bool {
    if (build_options.board == .rpi4b) {
        return rpi4b_usb_enumerated();
    } else {
        return board.usb.enumerated();
    }
}
export fn board_usb_cdc_tx(ptr: [*]const u8, len: u64) void {
    if (build_options.board == .rpi4b) {
        rpi4b_usb_cdc_tx(ptr, len);
    } else {
        board.usb.cdc_tx(ptr[0..len]);
    }
}
export fn board_emmc2_init() i32 {
    if (build_options.board == .rpi4b) {
        return rpi4b_emmc2_init();
    } else {
        return board.emmc2.init();
    }
}
export fn board_emmc2_write_block(lba: u32, buf: *const [512]u8) i32 {
    if (build_options.board == .rpi4b) {
        return rpi4b_emmc2_write_block(lba, buf);
    } else {
        return board.emmc2.write_block(lba, buf);
    }
}
export fn board_emmc2_read_block(lba: u32, buf: *[512]u8) i32 {
    if (build_options.board == .rpi4b) {
        return rpi4b_emmc2_read_block(lba, buf);
    } else {
        return board.emmc2.read_block(lba, buf);
    }
}
export fn board_uart_poll_rx_into_console() void {
    if (build_options.board == .rpi4b) {
        rpi4b_uart_poll_rx_into_console();
    } else {
        board.uart.poll_rx_into_console();
    }
}
export fn board_power_reboot() noreturn {
    if (build_options.board == .rpi4b) {
        rpi4b_power_reboot();
    } else {
        board.power.reboot();
    }
}

export fn board_mailbox_temperature() u32 {
    if (build_options.board == .rpi4b) {
        return rpi4b_mailbox_get_temperature();
    } else {
        return board.mailbox.getTemperature();
    }
}

export fn board_mailbox_cpu_clock() u32 {
    if (build_options.board == .rpi4b) {
        return rpi4b_mailbox_get_cpu_clock();
    } else {
        return board.mailbox.getCpuClock();
    }
}

comptime {
    _ = @import("kernel");
    _ = board.uart;
    _ = board.gpio;
    _ = board.timer;
    _ = board.irq;
    _ = board.emmc2;
    _ = board.usb;
    _ = @import("sched");
    // The kernel log ring's storage. utilc used to pull this in; with utilc
    // Rust-owned, the only remaining reference is a C-ABI call, so the module
    // needs a force-import of its own to reach the linker.
    _ = @import("klog_ring");
}
