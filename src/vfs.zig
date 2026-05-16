// Tiny VFS dispatch layer keyed off a 1-bit superblock tag.
//
// v0.4.0. The shape is deliberately small: a two-slot fixed mount
// table, prefix-based path dispatch, one vtable per backend. No
// inode cache, no dentry cache, no path normalization, no
// sys_mount. Future work revisits when it needs `..` and relative
// paths, caches, and mode bits.
//
// Mount layout (locked in DOCUMENTATION.md §3): initramfs is `/`,
// FAT32 mounts at `/mnt`. Dispatch is "starts-with `/mnt/`" ->
// FAT32 slot, anything else -> initramfs slot.
//
// The vtable carries a single `open` entry (not the plan sketch's
// open_fn/open_out pair) — the sketch's open_fn was its own "unused
// stub", and the post-mortem's "don't sprawl" rule says cut it.

const std = @import("std");
const builtin = @import("builtin");
const file_mod = @import("file");

pub const File = file_mod.File;

// 1-bit superblock tag. enum(u8) (not enum(u1)) so it drops straight
// into SuperBlock's extern-struct `fs_type: u8` byte; non-exhaustive
// so a future backend id doesn't force a parser change here.
pub const FsType = enum(u8) {
    INITRAMFS = 0,
    FAT32 = 1,
    _,
};

// Per-mount state. `private` is backend-owned (initramfs ignores it;
// FAT32 stashes its volume-descriptor pointer there).
// `ops` is the dispatch vtable — null until the backend's init()
// wires it.
pub const SuperBlock = extern struct {
    fs_type: u8,
    _pad: [7]u8 = .{0} ** 7,
    private: u64 = 0,
    ops: ?*const VfsOps = null,
};

// What a backend's open hands back: enough to populate File.private +
// File.size. For initramfs: private = KVA pointer to the entry's data
// bytes, size = entry.data.len. For FAT32: private = packed
// (first_cluster | cluster_count << 32), size = the dir-entry's size.
// extern struct because it crosses the callconv(.c) vtable boundary
// by pointer.
pub const OpenResult = extern struct {
    private: u64 = 0,
    size: u64 = 0,
};

// Backend vtable. All entries are C-ABI function pointers so the
// indirect call site has a fixed, objdump-inspectable convention —
// a future unified ?*File table will reuse the same shape.
pub const VfsOps = extern struct {
    // open: resolve `path` (already mount-prefix-stripped) against the
    // backend. Returns 0 and fills `out` on hit; -1 on miss-or-error
    // (the caller decides what a miss means — sys_openFile maps it to
    // a -1 fd, [TEST] vfs-dispatch to a failed scenario). The path
    // crosses as ptr+len, not a slice: callconv(.c) forbids slice
    // params (no guaranteed in-memory representation).
    open: *const fn (sb: *SuperBlock, path_ptr: [*]const u8, path_len: usize, out: *OpenResult) callconv(.c) c_int,
    // read: copy up to `len` bytes from `f`'s current offset into
    // `buf`. Returns bytes copied, 0 on EOF, -1 on error. Advances
    // f.offset.
    read: *const fn (sb: *SuperBlock, f: *File, buf: [*]u8, len: u64) callconv(.c) i64,
    // seek: validate the target against f.size + the backend's
    // seekability. Returns the new absolute offset, -1 on a bad
    // whence or an out-of-range target.
    seek: *const fn (sb: *SuperBlock, f: *File, off: i64, whence: i32) callconv(.c) i64,
    // close: backend cleanup hook. Most backends are no-ops — the File
    // page lifetime is owned by file.zig's refcount, not the backend.
    close: *const fn (sb: *SuperBlock, f: *File) callconv(.c) void,
    // write: copy up to `len` bytes from `buf` into `f` at f.offset.
    // Returns bytes written, -1 on error (EROFS, ENOSPC, bad fd). Read-
    // only backends (initramfs) return -1 unconditionally. Advances
    // f.offset on partial-or-full success.
    write: *const fn (sb: *SuperBlock, f: *File, buf: [*]const u8, len: u64) callconv(.c) i64,
};

// Two-slot fixed mount table. Slot 0 = root (initramfs), slot 1 =
// /mnt (FAT32). A future sys_mount generalises this to N slots with
// a registered-prefix list; until then the two prefixes are hard-
// coded so the syscall hot path stays a single startsWith branch.
pub var mount_table: [2]?*SuperBlock = .{ null, null };

// FAT32 mount prefix. The trailing slash is load-bearing: it makes
// `/mnt/foo` (FAT32) and `/mnt2/foo` (initramfs) unambiguously
// different, and `/mnt` with no slash stays an initramfs path.
//
// FIXME: when fsh grows path normalization (collapse `//`,
// strip a trailing `/`), this startsWith match becomes brittle —
// switch to a per-segment compare walking the path one `/` at a time,
// the same algorithm Linux's vfs path walk uses.
const MNT_PREFIX = "/mnt/";

// Byte-wise prefix compare against MNT_PREFIX. std.mem.startsWith
// routes through std.mem.eql, which the optimiser vectorises into
// overlapping wide loads — for a 5-byte compare it emits two 4-byte
// loads at path[0] and path[1], and the path[1] load is unaligned,
// alignment-faulting under the kernel's strict-alignment SCTLR_EL1.A.
// This is the same hazard src/initramfs.zig's bytesEql works around;
// a plain byte loop has no alignment requirement and the prefix is
// five bytes, so the scan cost is irrelevant.
fn hasMntPrefix(path: []const u8) bool {
    if (path.len < MNT_PREFIX.len) return false;
    for (MNT_PREFIX, 0..) |c, i| {
        if (path[i] != c) return false;
    }
    return true;
}

// Kernel high-mem (TTBR1) alias base — same constant as src/sys.zig's
// sys_call_table_relocate.
const LINEAR_MAP_BASE: u64 = 0xffff000000000000;

// Re-point a backend's vtable entries to their high-mem (TTBR1)
// aliases. The file syscalls run at EL1 with TTBR0 holding the *user*
// pgd; an indirect `blr` through a low link-address vtable entry
// instruction-aborts because the user pgd does not map kernel low
// memory. Mirrors sys_call_table_relocate in src/sys.zig. `| BASE` is
// idempotent, so a double call is harmless. No-op on host builds
// (no TTBR split). Each backend's init() calls this on its vtable
// before registering the mount.
pub fn relocateOps(ops: *VfsOps) void {
    if (comptime builtin.target.os.tag != .freestanding) return;
    ops.open = @ptrFromInt(@intFromPtr(ops.open) | LINEAR_MAP_BASE);
    ops.read = @ptrFromInt(@intFromPtr(ops.read) | LINEAR_MAP_BASE);
    ops.seek = @ptrFromInt(@intFromPtr(ops.seek) | LINEAR_MAP_BASE);
    ops.close = @ptrFromInt(@intFromPtr(ops.close) | LINEAR_MAP_BASE);
    ops.write = @ptrFromInt(@intFromPtr(ops.write) | LINEAR_MAP_BASE);
}

// Wire a superblock into the root (initramfs) slot. Called from the
// backend's init() at kernel bring-up.
pub fn register_initramfs(sb: *SuperBlock) void {
    sb.fs_type = @intFromEnum(FsType.INITRAMFS);
    mount_table[0] = sb;
}

// Wire a superblock into the /mnt (FAT32) slot.
pub fn register_fat32(sb: *SuperBlock) void {
    sb.fs_type = @intFromEnum(FsType.FAT32);
    mount_table[1] = sb;
}

// Path-to-superblock dispatch. Returns the matching SB plus the
// residual path the backend should see: initramfs gets the full path;
// FAT32 gets the path with `/mnt` stripped but the leading `/` kept,
// so each backend keys off its own root. Returns null when the target
// slot is unmounted.
pub fn resolve(path: []const u8) ?struct { sb: *SuperBlock, sub_path: []const u8 } {
    if (hasMntPrefix(path)) {
        const sb = mount_table[1] orelse return null;
        return .{ .sb = sb, .sub_path = path[MNT_PREFIX.len - 1 ..] }; // keep leading '/'
    }
    const sb = mount_table[0] orelse return null;
    return .{ .sb = sb, .sub_path = path };
}

// Resolve + dispatch to the backend's open. On hit returns the SB
// (the caller stashes it in File.sb for later read/seek/close
// dispatch) and fills `out`. Returns null on an unmounted slot, a
// missing vtable, or a backend miss.
pub fn vfs_open(path: []const u8, out: *OpenResult) ?*SuperBlock {
    const r = resolve(path) orelse return null;
    const ops = r.sb.ops orelse return null;
    if (ops.open(r.sb, r.sub_path.ptr, r.sub_path.len, out) < 0) return null;
    return r.sb;
}

pub fn vfs_read(sb: *SuperBlock, f: *File, buf: [*]u8, len: u64) i64 {
    const ops = sb.ops orelse return -1;
    return ops.read(sb, f, buf, len);
}

pub fn vfs_seek(sb: *SuperBlock, f: *File, off: i64, whence: i32) i64 {
    const ops = sb.ops orelse return -1;
    return ops.seek(sb, f, off, whence);
}

pub fn vfs_close(sb: *SuperBlock, f: *File) void {
    if (sb.ops) |ops| ops.close(sb, f);
}

pub fn vfs_write(sb: *SuperBlock, f: *File, buf: [*]const u8, len: u64) i64 {
    const ops = sb.ops orelse return -1;
    return ops.write(sb, f, buf, len);
}

// ---- Host tests ----
//
// The VFS tests run against in-test SuperBlock fixtures and a fake
// vtable — no real backend leaks into the link graph (see
// tests/host_stubs_vfs.zig for why the stub file deliberately excludes
// the initramfs/fat32 backends).

const testing = std.testing;

var fake_initramfs_sb: SuperBlock = .{ .fs_type = 0 };
var fake_fat32_sb: SuperBlock = .{ .fs_type = 1 };

fn resetMounts() void {
    mount_table[0] = null;
    mount_table[1] = null;
    fake_initramfs_sb = .{ .fs_type = 0 };
    fake_fat32_sb = .{ .fs_type = 1 };
}

test "resolve routes a /mnt/ prefix to slot 1, stripped to a leading slash" {
    resetMounts();
    mount_table[0] = &fake_initramfs_sb;
    mount_table[1] = &fake_fat32_sb;
    const r = resolve("/mnt/foo") orelse return error.NotResolved;
    try testing.expectEqual(@as(*SuperBlock, &fake_fat32_sb), r.sb);
    try testing.expectEqualStrings("/foo", r.sub_path);
}

test "resolve routes a non-/mnt path to slot 0 with the full path" {
    resetMounts();
    mount_table[0] = &fake_initramfs_sb;
    mount_table[1] = &fake_fat32_sb;
    const r = resolve("/sbin/init") orelse return error.NotResolved;
    try testing.expectEqual(@as(*SuperBlock, &fake_initramfs_sb), r.sb);
    try testing.expectEqualStrings("/sbin/init", r.sub_path);
}

test "resolve returns null when the target slot is empty" {
    resetMounts();
    mount_table[1] = &fake_fat32_sb; // slot 0 deliberately left null
    try testing.expectEqual(
        @as(?*SuperBlock, null),
        if (resolve("/anything")) |r| r.sb else null,
    );
}

test "resolve treats /mnt with no trailing slash as an initramfs path" {
    resetMounts();
    mount_table[0] = &fake_initramfs_sb;
    mount_table[1] = &fake_fat32_sb;
    const r = resolve("/mnt") orelse return error.NotResolved;
    try testing.expectEqual(@as(*SuperBlock, &fake_initramfs_sb), r.sb);
    try testing.expectEqualStrings("/mnt", r.sub_path);
}

test "resolve treats /mnt2/... as an initramfs path (prefix needs the slash)" {
    resetMounts();
    mount_table[0] = &fake_initramfs_sb;
    mount_table[1] = &fake_fat32_sb;
    const r = resolve("/mnt2/foo") orelse return error.NotResolved;
    try testing.expectEqual(@as(*SuperBlock, &fake_initramfs_sb), r.sb);
    try testing.expectEqualStrings("/mnt2/foo", r.sub_path);
}

// Fake backend: `open` echoes a fixed payload for "/hit", misses
// otherwise; `read` returns f.private so the test can prove the
// payload threaded through File. seek/close are inert.
fn fakeOpen(_: *SuperBlock, path_ptr: [*]const u8, path_len: usize, out: *OpenResult) callconv(.c) c_int {
    const path = path_ptr[0..path_len];
    if (std.mem.eql(u8, path, "/hit")) {
        out.private = 0xABCD;
        out.size = 7;
        return 0;
    }
    return -1;
}
fn fakeRead(_: *SuperBlock, f: *File, _: [*]u8, _: u64) callconv(.c) i64 {
    return @bitCast(f.private);
}
fn fakeSeek(_: *SuperBlock, _: *File, _: i64, _: i32) callconv(.c) i64 {
    return -1;
}
fn fakeClose(_: *SuperBlock, _: *File) callconv(.c) void {}
fn fakeWrite(_: *SuperBlock, f: *File, _: [*]const u8, _: u64) callconv(.c) i64 {
    return @bitCast(f.private);
}

const fake_ops: VfsOps = .{
    .open = fakeOpen,
    .read = fakeRead,
    .seek = fakeSeek,
    .close = fakeClose,
    .write = fakeWrite,
};

test "vfs_open dispatches through the vtable and threads OpenResult back" {
    resetMounts();
    fake_initramfs_sb.ops = &fake_ops;
    mount_table[0] = &fake_initramfs_sb;

    var out: OpenResult = .{};
    const sb = vfs_open("/hit", &out) orelse return error.NotResolved;
    try testing.expectEqual(@as(*SuperBlock, &fake_initramfs_sb), sb);
    try testing.expectEqual(@as(u64, 0xABCD), out.private);
    try testing.expectEqual(@as(u64, 7), out.size);

    // A backend miss routes to the same SB but resolves to null.
    var out_miss: OpenResult = .{};
    try testing.expectEqual(@as(?*SuperBlock, null), vfs_open("/miss", &out_miss));
}

test "vfs_open returns null when the resolved SB has no vtable" {
    resetMounts();
    fake_initramfs_sb.ops = null;
    mount_table[0] = &fake_initramfs_sb;
    var out: OpenResult = .{};
    try testing.expectEqual(@as(?*SuperBlock, null), vfs_open("/anything", &out));
}

test "vfs_read threads File.private through the backend vtable" {
    resetMounts();
    fake_initramfs_sb.ops = &fake_ops;
    var f: File = .{};
    f.private = 0x1234;
    try testing.expectEqual(@as(i64, 0x1234), vfs_read(&fake_initramfs_sb, &f, undefined, 0));
}

test "vfs_read / vfs_seek return -1 when the SB has no vtable" {
    resetMounts();
    fake_initramfs_sb.ops = null;
    var f: File = .{};
    try testing.expectEqual(@as(i64, -1), vfs_read(&fake_initramfs_sb, &f, undefined, 0));
    try testing.expectEqual(@as(i64, -1), vfs_seek(&fake_initramfs_sb, &f, 0, 0));
}

test "vfs_write threads File.private through the backend vtable" {
    resetMounts();
    fake_initramfs_sb.ops = &fake_ops;
    var f: File = .{};
    f.private = 0x5678;
    try testing.expectEqual(@as(i64, 0x5678), vfs_write(&fake_initramfs_sb, &f, undefined, 0));
}

test "vfs_write returns -1 when the SB has no vtable" {
    resetMounts();
    fake_initramfs_sb.ops = null;
    var f: File = .{};
    try testing.expectEqual(@as(i64, -1), vfs_write(&fake_initramfs_sb, &f, undefined, 0));
}
