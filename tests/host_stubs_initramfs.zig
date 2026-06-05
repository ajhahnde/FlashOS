// File/initramfs-test-only stubs.
//
// src/file.zig calls get_free_page / free_page / preempt_disable /
// preempt_enable. The page_alloc test target links the real allocator,
// so adding the same symbols to tests/host_stubs.zig would duplicate
// them at link time.
//
// `current` is typed against layout.TaskStruct here (instead of
// `?*anyopaque` as in tests/host_stubs.zig) because future
// initramfs/file host tests reach into `current.fds` directly,
// and the per-target stub keeps task_layout out of the shared stub
// TU (one stub file per test target). The link-time symbol is a
// single 8-byte pointer slot either way;
// file.zig only declares the externs it actually consumes (no
// `current` decl), so the typed shape stays a host-test-only concern.

const layout = @import("task_layout");

pub var current_storage: layout.TaskStruct = .{};
export var current: ?*layout.TaskStruct = &current_storage;

export fn preempt_disable() void {}
export fn preempt_enable() void {}

export fn mem_eql_bytes(a: [*]const u8, b: [*]const u8, n: u64) bool {
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}
