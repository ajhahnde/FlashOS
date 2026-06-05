// QEMU's `-M virt` exposes no GPIO controller — the BCM2711 GPIO
// matrix is a Pi specialty.  The kernel still imports
// `src/trace/pl011_uart.zig`, which carries Pi-specific
// GPIO-pin-mux calls (extern fn gpio_pin_set_func / gpio_pin_enable)
// for the secondary tracing UART; these no-op exports satisfy those
// symbols. No virt code path invokes them at runtime.

export fn gpio_pin_set_func(pin: u8, func: u8) void {
    _ = pin;
    _ = func;
}

export fn gpio_pin_enable(pin: u8) void {
    _ = pin;
}
