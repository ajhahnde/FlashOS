// Minimal named-module stand-in for utilc's host tests. The kernel log ring's
// implementation and tests are Rust-owned; utilc only needs its tee call to
// link while exercising UART output on the Zig host.

const StubRing = struct {
    pub fn pushStr(_: *@This(), _: [*:0]const u8) void {}
};

pub var klog: StubRing = .{};
