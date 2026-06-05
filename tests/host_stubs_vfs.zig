// VFS-host-test stubs.
//
// The src/vfs.zig test target's link graph is vfs.zig + the `file`
// named module (vfs.zig references file.zig's `File` type in its
// vtable signatures). file.zig declares get_free_page / free_page /
// preempt_disable / preempt_enable as externs for its alloc/unref
// page helpers; the VFS tests never exercise those paths, but the
// symbols still have to resolve at link. This stub provides them.
//
// No `current` export here (unlike host_stubs_initramfs.zig): nothing
// in the VFS link graph references it — vfs.zig dispatches over data,
// file.zig takes *TaskStruct by parameter.

export fn preempt_disable() void {}
export fn preempt_enable() void {}

export fn mem_eql_bytes(a: [*]const u8, b: [*]const u8, n: u64) bool {
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}
