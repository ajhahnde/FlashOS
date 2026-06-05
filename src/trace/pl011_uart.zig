// PL011 UART driver (UART4 on RPi4) — used as the dedicated trace
// interface so trace output stays out of the way of the mini-UART
// console. The hardware lives at the BCM2711 device-MMIO window
// (0xFE201800), reachable through the linear map only on Pi 4.
// On `-Dboard=virt` the BCM2711 device window is not mapped, so each
// public function is gated by a comptime board check; virt builds
// emit empty stubs (no separate trace UART, primary console takes
// the trace output too if needed).  rpi4b output is byte-identical
// because the comptime-true `if` is elided by Zig.

const is_pi = @import("build_options").board == .rpi4b;

const LINEAR_MAP_BASE: u64 = 0xFFFF000000000000;
const DEVICE_BASE: u64 = 0xFE000000;
const PBASE: u64 = DEVICE_BASE + LINEAR_MAP_BASE;
const UART4_BASE: u64 = PBASE + 0x201800;

const TXD4: u8 = 8;
const RXD4: u8 = 9;
const GFAlt4: u8 = 3;

const Pl011Regs = extern struct {
    data: u32,
    rsrecr: u32,
    reserved: [4]u32,
    flag: u32,
    reserved_1: u32,
    ilpr: u32,
    ibrd: u32,
    fbrd: u32,
    lcrh: u32,
    cr: u32,
    ifls: u32,
    imsc: u32,
    ris: u32,
    mis: u32,
    icr: u32,
    dmacr: u32,
    reserved_2: [13]u32,
    itcr: u32,
    itip: u32,
    itop: u32,
    tdr: u32,
};

fn regs() *volatile Pl011Regs {
    return @as(*volatile Pl011Regs, @ptrFromInt(UART4_BASE));
}

extern fn gpio_pin_set_func(pin: u8, func: u8) void;
extern fn gpio_pin_enable(pin: u8) void;

export fn pl011_uart_init() void {
    if (comptime is_pi) {
        gpio_pin_set_func(TXD4, GFAlt4);
        gpio_pin_set_func(RXD4, GFAlt4);
        gpio_pin_enable(TXD4);
        gpio_pin_enable(RXD4);

        const r = regs();
        // 8-bit word size, no parity, FIFO enabled, no break
        r.lcrh = 0x70;
        // immediate interrupts
        r.ifls = 0;
        // baud rate divisors
        r.ibrd = 26;
        r.fbrd = 3;
        // mask all interrupts for now
        r.imsc = 0x7FF;
        // flow control + enable TX/RX + enable UART
        r.cr = 0xC301;
    }
}

export fn pl011_uart_send(c: u8) void {
    if (comptime is_pi) {
        const r = regs();
        while ((r.flag & 0x20) != 0) {}
        r.data = c;
    }
}

export fn pl011_uart_recv() u8 {
    if (comptime is_pi) {
        const r = regs();
        while ((r.flag & 0x10) != 0) {}
        return @truncate(r.data & 0xFF);
    }
    return 0;
}

export fn pl011_uart_send_string(str: [*:0]const u8) void {
    if (comptime is_pi) {
        var i: usize = 0;
        while (str[i] != 0) : (i += 1) {
            const c = str[i];
            if (c == '\n') {
                pl011_uart_send('\r');
            }
            pl011_uart_send(c);
        }
    }
}
