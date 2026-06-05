// Mini-UART driver for Raspberry Pi 4

const std = @import("std");
const console = @import("console");

extern fn irq_disable() void;
extern fn irq_enable() void;

const LINEAR_MAP_BASE: u64 = 0xFFFF000000000000;
const DEVICE_BASE: u64 = 0xFE000000;

// Calculate kernel virtual address from physical address
fn pa_to_kva(pa: u64) u64 {
    return pa + LINEAR_MAP_BASE;
}

// Mini-UART registers structure (volatile for MMIO)
const AuxRegs = extern struct {
    irq_status: u32,
    enables: u32,
    reserved: [14]u32,
    mu_io: u32,
    mu_ier: u32,
    mu_iir: u32,
    mu_lcr: u32,
    mu_mcr: u32,
    mu_lsr: u32,
    mu_msr: u32,
    mu_scratch: u32,
    mu_control: u32,
    mu_status: u32,
    mu_baud_rate: u32,
};

// Get AuxRegs pointer (MMIO)
fn getAuxRegs() *volatile AuxRegs {
    const aux_addr = pa_to_kva(DEVICE_BASE + 0x00215000);
    return @as(*volatile AuxRegs, @ptrFromInt(aux_addr));
}

// GPIO functions (C interface)
extern fn gpio_pin_set_func(pin: u8, func: u8) void;
extern fn gpio_pin_enable(pin: u8) void;

const GFAlt5: u8 = 2;
const TXD0: u8 = 14;
const RXD0: u8 = 15;

/// Initialize mini-UART
export fn mini_uart_init() void {
    const aux = getAuxRegs();

    // Set GPIO 14 and 15 to UART1 (mini-uart)
    gpio_pin_set_func(TXD0, GFAlt5);
    gpio_pin_set_func(RXD0, GFAlt5);

    // Clear pull-up/pull-down resistors.
    gpio_pin_enable(TXD0);
    gpio_pin_enable(RXD0);

    // Enable mini-uart
    aux.enables = 1;

    // Disable TX and RX and auto flow control
    aux.mu_control = 0;

    // Enable receive interrupts, check bcm errata
    aux.mu_ier = 0xD;

    // Set 8-bit mode
    aux.mu_lcr = 3;

    // Set RTS to always high
    aux.mu_mcr = 0;

    // 115200 @ 500 MHz
    aux.mu_baud_rate = 541;

    // Enable TX and RX
    aux.mu_control = 3;

    // Drain any garbage from the RX FIFO so the interrupt line goes low,
    // ensuring we don't miss the first edge-triggered RX interrupt.
    while ((aux.mu_lsr & 1) != 0) {
        _ = aux.mu_io;
    }

    mini_uart_send('\r');
    mini_uart_send('\n');
    mini_uart_send('\n');
}

/// Send a single character via UART
export fn mini_uart_send(c: u8) void {
    const aux = getAuxRegs();

    // Keep looping if the 5th bit is 0 (TX FIFO full)
    while ((aux.mu_lsr & 0x20) == 0) {}

    aux.mu_io = c;
}

/// Receive a character via UART
export fn mini_uart_recv() u8 {
    const aux = getAuxRegs();

    // Keep looping if the 1st bit is 0 (RX FIFO empty)
    while ((aux.mu_lsr & 1) == 0) {}

    return @as(u8, @truncate(aux.mu_io));
}

/// True iff the mini-UART RX FIFO has at least one byte ready.
/// mu_lsr bit 0 = "data ready" (BCM2837/2711 ARM-Peripherals §2.2.1).
/// Non-blocking — feeds the IRQ-side drain loop in board/rpi4b/irq.zig
/// so console_push can collect every queued byte in one IRQ slot
/// instead of relying on the level-triggered AUX line re-firing.
/// `export` (not `pub`) so irq.zig consumes it via the same
/// `extern fn` discipline as the rest of the UART helpers.
export fn mini_uart_rx_pending() bool {
    const aux = getAuxRegs();
    return (aux.mu_lsr & 1) != 0;
}

/// Drain the mini-UART RX FIFO into the console ring from a non-IRQ
/// (idle-loop) caller — a defensive backstop. The AUX RX interrupt
/// (VC_AUX_IRQ) is the primary delivery path and does reach handle_irq on
/// real hardware, draining into console_push from irq.zig; this poll only
/// matters if a byte is ever left between IRQ slots. IRQs are masked across
/// the drain: console_push assumes an IRQ-masked caller (src/console.zig),
/// so this can't race the AUX handler on the same FIFO/ring. Cheap LSR
/// poll; no-op when the FIFO is empty.
pub fn poll_rx_into_console() void {
    irq_disable();
    while (mini_uart_rx_pending()) {
        console.console_push(mini_uart_recv());
    }
    irq_enable();
}

/// Send a null-terminated string via UART
export fn mini_uart_send_string(str: [*:0]const u8) void {
    var i: usize = 0;
    while (str[i] != 0) : (i += 1) {
        const c = str[i];
        if (c == '\n') {
            // Also do CR if there's a '\n'
            mini_uart_send('\r');
        }
        mini_uart_send(c);
    }
}

/// Print function compatible with Zig's std.fmt interface
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
