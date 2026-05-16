// Block-device abstraction (v0.4.0).
//
// The FAT32 backend talks to this; the board layer
// (src/board/<board>/emmc2.zig) populates the vtable post-init.
// A single global instance (`sd_dev`) covers the current "exactly one
// SD card" assumption — future work generalises if/when a second
// block device shows up (USB mass storage, virtio-blk, etc.).
//
// `extern struct` + `callconv(.c)` keep the layout reachable from
// assembly + future board ports without depending on the Zig
// compiler's internal calling convention.

pub const BlockDev = extern struct {
    read_fn:  *const fn (lba: u32, buf: *[512]u8) callconv(.c) i32,
    write_fn: *const fn (lba: u32, buf: *const [512]u8) callconv(.c) i32,
};

// Wired at boot by board.emmc2.init() — undefined before that point.
// Reading it before init is a kernel bug; the post_mortem trace-
// init smoke check (kernel_main_impl) ensures init runs first.
pub var sd_dev: BlockDev = undefined;
