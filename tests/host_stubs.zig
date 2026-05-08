// Stub externs for host-side unit tests.
//
// The kernel modules under test declare HW-side dependencies as
// `extern fn`. On a host build those externs are unresolved; this file
// is compiled to an object and linked into each `b.addTest` target so
// the symbols resolve at link time. No test blocks here.
//
// memzero is a no-op: the kernel passes kernel-virtual addresses
// (PA + LINEAR_MAP_BASE) which point at the linear-map alias of
// physical RAM at runtime — not a valid host pointer. Tests only
// exercise bitmap bookkeeping, not page contents.

export fn memzero(_: u64, _: u64) void {}

export fn panic(msg: [*:0]const u8) noreturn {
    @panic(@import("std").mem.span(msg));
}

export fn main_output(_: i32, _: [*:0]const u8) void {}
export fn main_output_u64(_: i32, _: u64) void {}
