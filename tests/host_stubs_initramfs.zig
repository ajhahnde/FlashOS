// File/initramfs-test-only stubs (v0.4.0).
//
// src/file.zig calls get_free_page / free_page / preempt_disable /
// preempt_enable. The page_alloc test target links the real allocator,
// so adding the same symbols to tests/host_stubs.zig would duplicate
// them at link time. tests/host_stubs_pipe.zig solves the same problem
// for pipe.zig — this stub mirrors that pattern for the file/initramfs
// test target.
//
// `current` is typed against layout.TaskStruct here (instead of
// `?*anyopaque` as in tests/host_stubs.zig) because future
// initramfs/file host tests reach into `current.open_files` directly,
// and the per-target stub keeps task_layout out of the shared stub TU
// — see post_mortem_v0.3.0.md for the advance-risks rationale. The
// link-time symbol is a single 8-byte pointer slot either way;
// file.zig only declares the externs it actually consumes (no
// `current` decl), so the typed shape stays a host-test-only concern.

const layout = @import("task_layout");

pub var current_storage: layout.TaskStruct = .{};
export var current: ?*layout.TaskStruct = &current_storage;

var host_page_buf: [1 << 20]u8 align(4096) = undefined;
var host_page_bump: usize = 0;

export fn get_free_page() u64 {
    const PAGE: usize = 4096;
    if (host_page_bump + PAGE > host_page_buf.len) return 0;
    const off = host_page_bump;
    host_page_bump += PAGE;
    return @intFromPtr(&host_page_buf[off]);
}

export fn free_page(_: u64) void {}

export fn preempt_disable() void {}
export fn preempt_enable() void {}
