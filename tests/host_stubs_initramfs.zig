// File/initramfs-test-only stubs.
//
// src/file.zig calls get_free_page / free_page / preempt_disable /
// preempt_enable. The page_alloc test target links the real allocator,
// so a target that also supplied those symbols would duplicate them at link
// time.
//
// `current` is typed against layout.TaskStruct because future initramfs/file
// host tests reach into `current.fds` directly. Keeping the stub per-target
// avoids pulling task_layout into unrelated test translation units. The
// link-time symbol is a single 8-byte pointer slot either way;
// file.zig only declares the externs it actually consumes (no
// `current` decl), so the typed shape stays a host-test-only concern.

const layout = @import("task_layout");

extern fn get_free_page() u64;
extern fn free_page(page: u64) void;

pub var current_storage: layout.TaskStruct = .{};
export var current: ?*layout.TaskStruct = &current_storage;

export fn preempt_disable() void {}
export fn preempt_enable() void {}

export fn fos_file_alloc() ?*layout.File {
    const page = get_free_page();
    if (page == 0) return null;
    const file: *layout.File = @ptrFromInt(page);
    file.* = .{};
    return file;
}

export fn fos_file_unref(file: *layout.File) void {
    file.refs -= 1;
    if (file.refs == 0) free_page(@intFromPtr(file));
}

export fn fos_file_ref(file: *layout.File) void {
    file.refs += 1;
}

export fn mem_eql_bytes(a: [*]const u8, b: [*]const u8, n: u64) bool {
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}
