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

// WaitQueue / pipe externs. wait_queue.zig and pipe.zig both link
// against `current`, `preempt_disable`, `preempt_enable`, and
// `schedule`; pipe.zig additionally needs the page allocator. The host
// tests build the queue / ring manually and assert bookkeeping, so the
// stubs are intentionally inert — no real scheduling, no real page
// allocation. Coverage of the blocking + free-page paths comes from the
// in-kernel pipe scenario.

// Typed as `?*anyopaque` so this stub TU does not need to import
// task_layout (which would cross module boundaries — disallowed in
// Zig 0.16). The link-time symbol is a single 8-byte pointer slot
// either way; consumers (wait_queue.zig, pipe.zig) keep their typed
// `extern var current: ?*TaskStruct;` declarations.
export var current: ?*anyopaque = null;
export fn preempt_disable() void {}
export fn preempt_enable() void {}
export fn schedule() void {}

// `get_free_page` / `free_page` are NOT stubbed here — page_alloc.zig
// exports them for real and the page_alloc test target links them in
// directly. The pipe test target gets a dedicated stub via
// tests/host_stubs_pipe.zig so its bump-allocator doesn't clash with
// the page_alloc tests' real allocator.
