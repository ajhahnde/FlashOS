// initramfs_backend: src/initramfs.zig newc cpio parser as a
// VfsOps vtable (v0.4.0).
//
// Lives separately from src/initramfs.zig on purpose: the parser stays
// VFS-agnostic and host-testable in isolation (it imports neither
// `vfs` nor `file`). The split mirrors a fsh -> flibc -> syscalls
// layering — the bottom layer never imports the top layer's types.
//
// The read / seek bodies live here next to their private state; the
// sys.zig handlers dispatch through the vtable rather than inlining
// the per-backend arithmetic.

const initramfs = @import("initramfs");
const vfs = @import("vfs");
const file_mod = @import("file");

const File = file_mod.File;

// Single static superblock — initramfs is a singleton mount (slot 0).
// fs_type is re-stamped by vfs.register_initramfs; the initialiser
// here just keeps the field non-garbage before init() runs.
pub var sb: vfs.SuperBlock = .{ .fs_type = @intFromEnum(vfs.FsType.INITRAMFS) };

// `var`, not `const`: init() relocates these entries to their
// high-mem aliases in place via vfs.relocateOps (see there).
var ops_vtable: vfs.VfsOps = .{
    .open = open,
    .read = read,
    .seek = seek,
    .close = close,
    .write = writeEROFS,
};

// Kernel bring-up hook — relocates the vtable to its high-mem alias,
// wires it onto the superblock, and registers the mount. Called from
// kernel_main_impl before the free-page baseline emit; allocates
// nothing (just sets pointers), so the baseline holds.
pub fn init() void {
    vfs.relocateOps(&ops_vtable);
    sb.ops = &ops_vtable;
    vfs.register_initramfs(&sb);
}

fn open(_: *vfs.SuperBlock, path_ptr: [*]const u8, path_len: usize, out: *vfs.OpenResult) callconv(.c) c_int {
    const path = path_ptr[0..path_len];
    const entry = (initramfs.locate(path) catch return -1) orelse return -1;
    out.private = @intFromPtr(entry.data.ptr);
    out.size = entry.data.len;
    return 0;
}

fn read(_: *vfs.SuperBlock, f: *File, buf: [*]u8, len: u64) callconv(.c) i64 {
    if (f.offset >= f.size) return 0;
    const remaining = f.size - f.offset;
    const n: u64 = if (len > remaining) remaining else len;
    const src: [*]const u8 = @ptrFromInt(f.private);
    var i: u64 = 0;
    while (i < n) : (i += 1) buf[i] = src[f.offset + i];
    f.offset += n;
    return @bitCast(n);
}

fn seek(_: *vfs.SuperBlock, f: *File, off: i64, whence: i32) callconv(.c) i64 {
    const cur_signed: i64 = @bitCast(f.offset);
    const sz_signed: i64 = @bitCast(f.size);
    const target: i64 = switch (whence) {
        0 => off, // SEEK_SET
        1 => cur_signed + off, // SEEK_CUR
        2 => sz_signed + off, // SEEK_END
        else => return -1,
    };
    if (target < 0 or target > sz_signed) return -1;
    f.offset = @bitCast(target);
    return target;
}

fn close(_: *vfs.SuperBlock, _: *File) callconv(.c) void {
    // Initramfs has no per-handle state beyond what file.zig owns —
    // the File page lifetime is the refcount's job.
}

// Initramfs is read-only by design (it's the CPIO image baked into
// the kernel). Every write returns -1 — caller treats as EROFS.
fn writeEROFS(_: *vfs.SuperBlock, _: *File, _: [*]const u8, _: u64) callconv(.c) i64 {
    return -1;
}
