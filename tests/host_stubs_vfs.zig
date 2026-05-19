// VFS-host-test stubs (v0.4.0).
//
// The src/vfs.zig test target's link graph is vfs.zig + the `file`
// named module (vfs.zig references file.zig's `File` type in its
// vtable signatures). file.zig declares get_free_page / free_page /
// preempt_disable / preempt_enable as externs for its alloc/unref
// page helpers; the VFS tests never exercise those paths, but the
// symbols still have to resolve at link. This stub provides them — a
// bump allocator mirroring tests/host_stubs_initramfs.zig, kept as
// its own single-purpose file: one stub file per test target.
//
// No `current` export here (unlike host_stubs_initramfs.zig): nothing
// in the VFS link graph references it — vfs.zig dispatches over data,
// file.zig takes *TaskStruct by parameter.

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
