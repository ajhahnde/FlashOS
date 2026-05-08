// Comptime indirection from "the active board" to the four
// hardware-specific driver modules (uart, gpio, timer, irq). The
// board is selected by build.zig via the `-Dboard=` option and
// exposed through the generated `build_options` module.
//
// Each pub const below resolves at comptime to the chosen board's
// driver source. Side-effect importing these aliases from start.zig
// is what registers the driver `export fn` decls with the linker.

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
