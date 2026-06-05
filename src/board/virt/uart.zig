// PL011 UART driver for QEMU's `-M virt` and any UEFI/ARM host
// that already programmed the UART before kernel entry.
//
// ABI mirrors src/board/rpi4b/uart.zig — same exported symbols
// (`mini_uart_init`, `mini_uart_send`, `mini_uart_send_string`,
// `mini_uart_recv`) so the kernel-side callers in utilc.zig and
// kernel.zig don't need a board-aware switch.
//
// PL011 base on `-M virt`: 0x09000000 physical, mapped via the
// kernel linear map.  Registers we touch:
//   * DR @ +0x000 — data register (read = RX byte, write = TX byte)
//   * FR @ +0x018 — flag register; bit 4 = RXFE (RX empty),
//     bit 5 = TXFF (TX full)
// `mini_uart_init` does not configure the UART — UEFI / QEMU set
// baud, line control and FIFO state — it emits a "\r\n\n" heartbeat
// so the serial console can show the kernel reached this point.

const std = @import("std");
const Dtb = @import("dtb.zig").Dtb;

const LINEAR_MAP_BASE: u64 = 0xFFFF000000000000;

/// PL011 base — fallback to QEMU virt's well-known address
/// (`arm,pl011` in qemu-system-aarch64 -M virt). mini_uart_init
/// re-reads this from the DTB so a UEFI host that places PL011
/// elsewhere (Fusion, real arm64 firmware) is handled without a
/// rebuild. PL011_IRQ for the GIC side lives in irq.zig.
var pl011_base: u64 = 0x09000000;
const PL011_IRQ_FALLBACK: u32 = 33;

fn pa_to_kva(pa: u64) u64 {
    return pa + LINEAR_MAP_BASE;
}

const Pl011Regs = extern struct {
    dr: u32, // +0x000
    _reserved: [5]u32, // +0x004..+0x014 (RSR/ECR + reserved)
    fr: u32, // +0x018
};

fn getRegs() *volatile Pl011Regs {
    return @as(*volatile Pl011Regs, @ptrFromInt(pa_to_kva(pl011_base)));
}

/// Idle-loop RX poll — board-API parity with the rpi4b mini-UART drain
/// (src/board/rpi4b/uart.zig). virt's PL011 RX is interrupt-driven and
/// the QEMU test harness injects bytes via sys_console_inject, so the
/// idle path has nothing to poll. Inline-empty so the virt binary and
/// its byte-identical test output are unchanged (mirrors
/// board.irq.board_irq_init's inline-to-nothing discipline).
pub inline fn poll_rx_into_console() void {}

/// PL011 GIC INTID for the active platform — DTB-derived if
/// available, else the QEMU virt fallback (SPI 1 → 33). Read by
/// irq.zig at board_irq_init time.
pub fn pl011Irq() u32 {
    if (Dtb.fromHandoff()) |dtb| {
        if (dtb.findInterrupt("arm,pl011")) |i| return i;
    }
    return PL011_IRQ_FALLBACK;
}

const FR_RXFE: u32 = 1 << 4; // receive FIFO empty
const FR_TXFF: u32 = 1 << 5; // transmit FIFO full

/// Emit a heartbeat to confirm the kernel reached uart init.
/// No hardware setup — UEFI/QEMU programmed the controller. If the
/// boot loader handed off a DTB (board_quirks.S / dtb.zig), use the
/// `arm,pl011` reg base from there in case this host doesn't have
/// the controller at QEMU's standard 0x09000000.
export fn mini_uart_init() void {
    if (Dtb.fromHandoff()) |dtb| {
        if (dtb.findDeviceBase("arm,pl011")) |base| {
            pl011_base = base;
        }
    }
    mini_uart_send('\r');
    mini_uart_send('\n');
    mini_uart_send('\n');
}

/// Send a single character via PL011.
export fn mini_uart_send(c: u8) void {
    const regs = getRegs();
    while ((regs.fr & FR_TXFF) != 0) {}
    regs.dr = c;
}

/// Receive a single character via PL011.
/// `pub` (in addition to `export`) so board/virt/irq.zig can call it
/// alongside `pl011_rx_pending` via the `uart` named import — matches
/// the rest of the helpers reachable through that handle.
pub export fn mini_uart_recv() u8 {
    const regs = getRegs();
    while ((regs.fr & FR_RXFE) != 0) {}
    return @as(u8, @truncate(regs.dr));
}

/// True iff PL011 has at least one RX byte available.
/// FR bit 4 (RXFE = receive FIFO empty) clear → byte present.
/// Non-blocking; feeds the IRQ-side drain loop in board/virt/irq.zig.
pub fn pl011_rx_pending() bool {
    return (getRegs().fr & FR_RXFE) == 0;
}

/// Send a null-terminated string via PL011, expanding LF to CRLF.
export fn mini_uart_send_string(str: [*:0]const u8) void {
    var i: usize = 0;
    while (str[i] != 0) : (i += 1) {
        const c = str[i];
        if (c == '\n') {
            mini_uart_send('\r');
        }
        mini_uart_send(c);
    }
}

/// Print function compatible with Zig's std.fmt interface.
pub fn print(comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buffer, format, args) catch {
        mini_uart_send_string("format error");
        return;
    };
    for (formatted) |c| {
        if (c == '\n') mini_uart_send('\r');
        mini_uart_send(c);
    }
}
