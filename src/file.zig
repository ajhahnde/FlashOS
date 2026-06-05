// file: per-process open-file (`File`) lifetime helpers.
//
// The `File` struct itself lives in src/task_layout.zig so TaskStruct
// can carry it without a circular import (file.zig imports task_layout
// for TaskStruct + File). This module owns the lifetime helpers (alloc
// / unref / ref) and the FType tag enum that pins the `ftype` byte's
// meaning. The fd-table proper — installing a `File` into a task's
// `fds` slots, dup/close on fork/reap — lives in src/fdtable.zig.
//
// One get_free_page per `File`. sizeof(File) = 64 (the
// `sb` superblock pointer + the permission metadata + the dir-entry
// location, padded to the u64 alignment), so the page hosts
// ~64 Files; one page per open is allocated and returned on close.
// Future work will pool these. The page is **not** tracked in
// mm.user_pages / mm.kernel_pages — File.refs owns the page
// lifetime, same posture as src/pipe.zig.

const builtin = @import("builtin");
const layout = @import("task_layout");

pub const TaskStruct = layout.TaskStruct;
pub const File = layout.File;
pub const FD_TABLE_SIZE = layout.FD_TABLE_SIZE;

extern fn get_free_page() u64;
extern fn free_page(p: u64) void;
extern fn preempt_disable() void;
extern fn preempt_enable() void;

// FType tag namespace for `File.ftype`. Only INITRAMFS_FILE is
// populated today; the reserved slots are documented here so the
// enum acts as the manifest for future backends.
pub const FType = enum(u8) {
    INITRAMFS_FILE = 0,
    // Reserved for future File backends (e.g. FAT32-backed files); the
    // tagged-pointer fd-table itself lives in src/fdtable.zig.
    _,
};

const LINEAR_MAP_BASE: u64 = 0xFFFF000000000000;

inline fn pageKva(pa: u64) u64 {
    return if (builtin.target.os.tag == .freestanding) pa | LINEAR_MAP_BASE else pa;
}

// Allocate and zero a File. Returns null on allocator failure.
// refs starts at 0; the installer sets it (typically to 1).
pub fn alloc() ?*File {
    const pa = get_free_page();
    if (pa == 0) return null;
    const kva = pageKva(pa);
    const f: *File = @ptrFromInt(kva);
    f.* = .{};
    return f;
}

// Drop one ref. On the last drop, free the page. No wake side: File
// has no wait queues (initramfs read is non-blocking; FAT32 readahead
// is future work).
pub fn unref(f: *File) void {
    preempt_disable();
    f.refs -= 1;
    const last = f.refs == 0;
    preempt_enable();
    if (!last) return;
    const kva: u64 = @intFromPtr(f);
    const pa: u64 = if (builtin.target.os.tag == .freestanding)
        kva & ~LINEAR_MAP_BASE
    else
        kva;
    free_page(pa);
}

pub fn ref(f: *File) void {
    preempt_disable();
    f.refs += 1;
    preempt_enable();
}

// ---- Host tests ----

const std = @import("std");

test "alloc returns a zero-initialised File" {
    const f = alloc() orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(u8, 0), f.ftype);
    try std.testing.expectEqual(@as(u32, 0), f.refs);
    try std.testing.expectEqual(@as(u64, 0), f.offset);
    try std.testing.expectEqual(@as(u64, 0), f.private);
    try std.testing.expectEqual(@as(u64, 0), f.size);
    // Permission metadata starts at the safe-deny default.
    try std.testing.expectEqual(@as(u32, 0), f.mode);
    try std.testing.expectEqual(@as(u32, 0), f.uid);
    try std.testing.expectEqual(@as(u32, 0), f.gid);
    // Dir-entry location starts unset.
    try std.testing.expectEqual(@as(u32, 0), f.dirent_lba);
    try std.testing.expectEqual(@as(u32, 0), f.dirent_off);
}

test "ftype tag round-trips through extern struct" {
    const f = alloc() orelse return error.OutOfMemory;
    f.ftype = @intFromEnum(FType.INITRAMFS_FILE);
    try std.testing.expectEqual(
        FType.INITRAMFS_FILE,
        @as(FType, @enumFromInt(f.ftype)),
    );
}
