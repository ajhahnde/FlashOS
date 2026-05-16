// Per-process open-file handle helpers (v0.4.0).
//
// The `File` struct itself lives in src/task_layout.zig — TaskStruct's
// `open_files: [FD_TABLE_SIZE]?*File` slot is typed against the layout
// module to avoid a circular import (file.zig imports task_layout for
// TaskStruct + File). This module owns the lifetime helpers (alloc /
// unref / fdAlloc / fdGet / fdClose / dupAll / closeAll) and the FType
// tag enum that pins the `ftype` byte's meaning.
//
// One get_free_page per `File`. sizeof(File) = 40 (the
// `sb` superblock pointer fits in the same page), so the page hosts
// ~102 Files; one page per open is allocated and returned on close.
// Future work will pool these. The page is **not** tracked in
// mm.user_pages / mm.kernel_pages — File.refs owns the page
// lifetime, same posture as src/pipe.zig.
//
// open_files lives parallel to fd_table (the anonymous-pipe slots)
// until both are unified behind a single tagged-pointer fd-table.
// The split keeps pipes binary-compatible with v0.3.0, and the
// file-fd range is disjoint enough to read at a glance.

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
    // FIXME: unified pipe slot (collapse fd_table into open_files).
    _,
};

const LINEAR_MAP_BASE: u64 = 0xffff000000000000;

inline fn pageKva(pa: u64) u64 {
    return if (builtin.target.os.tag == .freestanding) pa | LINEAR_MAP_BASE else pa;
}

// Allocate + zero-initialise. Caller sets refs (typically to 1) before
// installing the File in any fd slot. Returns null on allocator failure.
pub fn alloc() ?*File {
    const pa = get_free_page();
    if (pa == 0) return null;
    const kva = pageKva(pa);
    const f: *File = @ptrFromInt(kva);
    f.* = .{};
    return f;
}

// Decrement the reference count. On the last drop, return the page to
// the allocator. No wake side: File has no wait queues (read on
// initramfs is non-blocking; FAT32 readahead is future work).
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

pub fn fdAlloc(t: *TaskStruct, f: *File) i32 {
    var i: usize = 0;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        if (t.open_files[i] == null) {
            t.open_files[i] = f;
            return @intCast(i);
        }
    }
    return -1;
}

pub fn fdGet(t: *TaskStruct, fd: i32) ?*File {
    if (fd < 0) return null;
    const idx: usize = @intCast(fd);
    if (idx >= FD_TABLE_SIZE) return null;
    return t.open_files[idx];
}

pub fn fdClose(t: *TaskStruct, fd: i32) i32 {
    const f = fdGet(t, fd) orelse return -1;
    const idx: usize = @intCast(fd);
    t.open_files[idx] = null;
    unref(f);
    return 0;
}

// Called from the fork-dup path to bump the refcount on every
// inherited slot. The sched.zig do_wait_impl plumbing wires the
// closeAll call into the reap path.
pub fn dupAll(src: *TaskStruct, dst: *TaskStruct) void {
    var i: usize = 0;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        if (src.open_files[i]) |f| {
            preempt_disable();
            f.refs += 1;
            preempt_enable();
            dst.open_files[i] = f;
        }
    }
}

pub fn closeAll(t: *TaskStruct) void {
    var i: usize = 0;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        if (t.open_files[i]) |f| {
            t.open_files[i] = null;
            unref(f);
        }
    }
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
}

test "ftype tag round-trips through extern struct" {
    const f = alloc() orelse return error.OutOfMemory;
    f.ftype = @intFromEnum(FType.INITRAMFS_FILE);
    try std.testing.expectEqual(
        FType.INITRAMFS_FILE,
        @as(FType, @enumFromInt(f.ftype)),
    );
}

test "fdAlloc fills the first null slot; out-of-fds returns -1" {
    var t: TaskStruct = .{};
    const f = alloc() orelse return error.OutOfMemory;
    f.refs = 1;

    const a = fdAlloc(&t, f);
    try std.testing.expectEqual(@as(i32, 0), a);
    try std.testing.expectEqual(@as(?*File, f), t.open_files[0]);

    var i: usize = 1;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        _ = fdAlloc(&t, f);
    }
    try std.testing.expectEqual(@as(i32, -1), fdAlloc(&t, f));
}

test "fdGet returns the installed File; bad fd returns null" {
    var t: TaskStruct = .{};
    const f = alloc() orelse return error.OutOfMemory;
    f.refs = 1;
    const fd = fdAlloc(&t, f);
    try std.testing.expectEqual(@as(?*File, f), fdGet(&t, fd));
    try std.testing.expectEqual(@as(?*File, null), fdGet(&t, -1));
    try std.testing.expectEqual(@as(?*File, null), fdGet(&t, @intCast(FD_TABLE_SIZE)));
    try std.testing.expectEqual(@as(?*File, null), fdGet(&t, 1)); // empty slot
}

test "fdClose clears the slot and decrements refs" {
    var t: TaskStruct = .{};
    const f = alloc() orelse return error.OutOfMemory;
    f.refs = 2;
    const fd = fdAlloc(&t, f);
    try std.testing.expectEqual(@as(i32, 0), fdClose(&t, fd));
    try std.testing.expectEqual(@as(?*File, null), t.open_files[0]);
    try std.testing.expectEqual(@as(u32, 1), f.refs);
    try std.testing.expectEqual(@as(i32, -1), fdClose(&t, fd));
}

test "dupAll bumps refs and copies every non-null slot" {
    var src: TaskStruct = .{};
    var dst: TaskStruct = .{};
    const f = alloc() orelse return error.OutOfMemory;
    f.refs = 2;
    _ = fdAlloc(&src, f);
    _ = fdAlloc(&src, f);

    dupAll(&src, &dst);
    try std.testing.expectEqual(src.open_files[0], dst.open_files[0]);
    try std.testing.expectEqual(src.open_files[1], dst.open_files[1]);
    try std.testing.expectEqual(@as(u32, 4), f.refs);
}

test "closeAll clears every slot and drops refs" {
    var t: TaskStruct = .{};
    const f = alloc() orelse return error.OutOfMemory;
    f.refs = 2;
    _ = fdAlloc(&t, f);
    _ = fdAlloc(&t, f);
    f.refs = 2; // override the fdAlloc-unaware refs we set above
    closeAll(&t);
    var i: usize = 0;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        try std.testing.expectEqual(@as(?*File, null), t.open_files[i]);
    }
    try std.testing.expectEqual(@as(u32, 0), f.refs);
}
