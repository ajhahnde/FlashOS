// board: comptime indirection to the active board's driver modules.
//
// The four hardware-specific modules (uart, gpio, timer, irq) are
// selected by build.zig via `-Dboard=` and exposed through the
// generated `build_options` module. Each pub const below resolves at
// comptime to the chosen board's driver source. Side-effect importing
// these aliases from start.zig registers the driver `export fn` decls
// with the linker.

const build_options = @import("build_options");

pub const uart = switch (build_options.board) {
    .rpi4b => @import("board/rpi4b/uart.zig"),
    .virt => @import("board/virt/uart.zig"),
};

pub const gpio = switch (build_options.board) {
    .rpi4b => @import("board/rpi4b/gpio.zig"),
    .virt => @import("board/virt/gpio.zig"),
};

pub const timer = switch (build_options.board) {
    .rpi4b => @import("board/rpi4b/timer.zig"),
    .virt => @import("board/virt/timer.zig"),
};

pub const irq = switch (build_options.board) {
    .rpi4b => @import("board/rpi4b/irq.zig"),
    .virt => @import("board/virt/irq.zig"),
};

// emmc2: BCM2711 SDHCI driver on rpi4b, memory-backed fake on virt
// (QEMU `-M virt` exposes no SDHCI peripheral; see
// src/board/virt/emmc2.zig).
pub const emmc2 = switch (build_options.board) {
    .rpi4b => @import("board/rpi4b/emmc2.zig"),
    .virt => @import("board/virt/emmc2.zig"),
};

// usb: BCM2711 DWC2 USB-OTG gadget (CDC-ACM console) on rpi4b; no-op
// stub on virt (QEMU emulates no DWC2 device path; see
// src/board/virt/usb.zig).
pub const usb = switch (build_options.board) {
    .rpi4b => @import("board/rpi4b/usb.zig"),
    .virt => @import("board/virt/usb.zig"),
};

// power: machine reset. BCM2711 watchdog full-reset on rpi4b; PSCI
// SYSTEM_RESET (SMC) on QEMU virt. Called directly by sys_reboot
// (SYS_REBOOT) — power.zig exports no driver `export fn`, so the call
// site pulls it in, not a start.zig side-effect import.
pub const power = switch (build_options.board) {
    .rpi4b => @import("board/rpi4b/power.zig"),
    .virt => @import("board/virt/power.zig"),
};
