// QEMU virt does not expose a BCM2711-style system timer; periodic
// ticks come from the ARM generic timer (driven by
// src/generic_timer.zig / src/generic_timer.S, board-independent).
// Pi's `timer_init` and `handle_sys_timer_1` exports are referenced
// by Pi's IRQ wiring; the virt build does not invoke them, but
// stubbing both keeps the symbol surface consistent so any
// inadvertent reference at link time resolves to a no-op.

export fn timer_init() void {}

export fn handle_sys_timer_1() void {}
