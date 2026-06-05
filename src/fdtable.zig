const layout = @import("task_layout");
const pipe_mod = @import("pipe");
const file_mod = @import("file");

pub const TaskStruct = layout.TaskStruct;
pub const FD_TABLE_SIZE = layout.FD_TABLE_SIZE;
pub const Kind = enum(u8) { none = 0, console = 1, pipe = 2, file = 3 };
pub const FdSlot = layout.FdSlot;

inline fn kindOf(s: FdSlot) Kind { return @enumFromInt(s.kind); }

pub fn install(t: *TaskStruct, k: Kind, ptr: ?*anyopaque) i32 {
    var i: usize = 0;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        if (kindOf(t.fds[i]) == .none) {
            t.fds[i] = .{ .ptr = ptr, .kind = @intFromEnum(k) };
            return @intCast(i);
        }
    }
    return -1;
}

pub fn get(t: *TaskStruct, fd: i32) ?FdSlot {
    if (fd < 0) return null;
    const idx: usize = @intCast(fd);
    if (idx >= FD_TABLE_SIZE) return null;
    const s = t.fds[idx];
    return if (kindOf(s) == .none) null else s;
}

pub fn getPipe(t: *TaskStruct, fd: i32) ?*pipe_mod.Pipe {
    const s = get(t, fd) orelse return null;
    if (kindOf(s) != .pipe) return null;
    return @ptrCast(@alignCast(s.ptr.?));
}

pub fn getFile(t: *TaskStruct, fd: i32) ?*file_mod.File {
    const s = get(t, fd) orelse return null;
    if (kindOf(s) != .file) return null;
    return @ptrCast(@alignCast(s.ptr.?));
}

pub fn isConsole(t: *TaskStruct, fd: i32) bool {
    const s = get(t, fd) orelse return false;
    return kindOf(s) == .console;
}

fn unrefSlot(s: FdSlot) void {
    switch (kindOf(s)) {
        .pipe => pipe_mod.unref(@ptrCast(@alignCast(s.ptr.?))),
        .file => file_mod.unref(@ptrCast(@alignCast(s.ptr.?))),
        .console, .none => {},
    }
}

fn refSlot(s: FdSlot) void {
    switch (kindOf(s)) {
        .pipe => pipe_mod.ref(@ptrCast(@alignCast(s.ptr.?))),
        .file => file_mod.ref(@ptrCast(@alignCast(s.ptr.?))),
        .console, .none => {},
    }
}

pub fn close(t: *TaskStruct, fd: i32) i32 {
    const s = get(t, fd) orelse return -1;
    t.fds[@intCast(fd)] = .{};
    unrefSlot(s);
    return 0;
}

pub fn dup2(t: *TaskStruct, oldfd: i32, newfd: i32) i32 {
    const src = get(t, oldfd) orelse return -1;
    if (newfd < 0 or @as(usize, @intCast(newfd)) >= FD_TABLE_SIZE) return -1;
    if (oldfd == newfd) return newfd;
    if (kindOf(t.fds[@intCast(newfd)]) != .none) unrefSlot(t.fds[@intCast(newfd)]);
    t.fds[@intCast(newfd)] = src;
    refSlot(src);
    return newfd;
}

pub fn dupAll(src: *TaskStruct, dst: *TaskStruct) void {
    var i: usize = 0;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        const s = src.fds[i];
        if (kindOf(s) != .none) {
            dst.fds[i] = s;
            refSlot(s);
        }
    }
}

pub fn closeAll(t: *TaskStruct) void {
    var i: usize = 0;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        const s = t.fds[i];
        if (kindOf(s) != .none) {
            t.fds[i] = .{};
            unrefSlot(s);
        }
    }
}

// ---- Host tests ----

const std = @import("std");

test "install fills first none slot; out-of-fds returns -1" {
    var t: TaskStruct = .{};
    const p = pipe_mod.alloc() orelse return error.OutOfMemory;
    p.refs = 1;
    const ptr: *anyopaque = @ptrCast(p);

    const a = install(&t, .pipe, ptr);
    try std.testing.expectEqual(@as(i32, 0), a);
    try std.testing.expectEqual(ptr, t.fds[0].ptr);
    try std.testing.expectEqual(@intFromEnum(Kind.pipe), t.fds[0].kind);

    var i: usize = 1;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        _ = install(&t, .pipe, ptr);
    }
    try std.testing.expectEqual(@as(i32, -1), install(&t, .pipe, ptr));
}

test "getPipe/getFile/isConsole dispatch by kind" {
    var t: TaskStruct = .{};
    const p = pipe_mod.alloc() orelse return error.OutOfMemory;
    p.refs = 1;
    const f = file_mod.alloc() orelse return error.OutOfMemory;
    f.refs = 1;

    _ = install(&t, .pipe, @ptrCast(p));
    _ = install(&t, .file, @ptrCast(f));
    _ = install(&t, .console, null);

    try std.testing.expectEqual(@as(?*pipe_mod.Pipe, p), getPipe(&t, 0));
    try std.testing.expectEqual(@as(?*pipe_mod.Pipe, null), getPipe(&t, 1));
    try std.testing.expectEqual(@as(?*pipe_mod.Pipe, null), getPipe(&t, 2));

    try std.testing.expectEqual(@as(?*file_mod.File, f), getFile(&t, 1));
    try std.testing.expectEqual(@as(?*file_mod.File, null), getFile(&t, 0));
    try std.testing.expectEqual(@as(?*file_mod.File, null), getFile(&t, 2));

    try std.testing.expect(isConsole(&t, 2));
    try std.testing.expect(!isConsole(&t, 0));
    try std.testing.expect(!isConsole(&t, 1));
}

test "close clears slot and unrefs by kind; double-close returns -1" {
    var t: TaskStruct = .{};
    const p = pipe_mod.alloc() orelse return error.OutOfMemory;
    p.refs = 2; // override alloc
    _ = install(&t, .pipe, @ptrCast(p));

    try std.testing.expectEqual(@as(i32, 0), close(&t, 0));
    try std.testing.expectEqual(@as(u8, 0), t.fds[0].kind);
    try std.testing.expectEqual(@as(u32, 1), p.refs);

    try std.testing.expectEqual(@as(i32, -1), close(&t, 0));
}

test "dup2 over open fd unrefs old occupant, copies slot, bumps ref" {
    var t: TaskStruct = .{};
    const p1 = pipe_mod.alloc() orelse return error.OutOfMemory;
    p1.refs = 1;
    const p2 = pipe_mod.alloc() orelse return error.OutOfMemory;
    p2.refs = 1;

    _ = install(&t, .pipe, @ptrCast(p1)); // fd 0
    _ = install(&t, .pipe, @ptrCast(p2)); // fd 1

    try std.testing.expectEqual(@as(i32, 1), dup2(&t, 0, 1));
    // p2 is unref'd to 0, p1 is ref'd to 2
    try std.testing.expectEqual(@as(u32, 0), p2.refs);
    try std.testing.expectEqual(@as(u32, 2), p1.refs);
    try std.testing.expectEqual(@as(?*pipe_mod.Pipe, p1), getPipe(&t, 1));

    // no-op
    try std.testing.expectEqual(@as(i32, 0), dup2(&t, 0, 0));
    try std.testing.expectEqual(@as(u32, 2), p1.refs);
}

test "dupAll/closeAll dispatch by kind" {
    var src: TaskStruct = .{};
    var dst: TaskStruct = .{};

    const p = pipe_mod.alloc() orelse return error.OutOfMemory;
    p.refs = 1;
    _ = install(&src, .pipe, @ptrCast(p));
    _ = install(&src, .console, null);

    dupAll(&src, &dst);
    try std.testing.expectEqual(@as(u32, 2), p.refs);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Kind.pipe)), dst.fds[0].kind);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Kind.console)), dst.fds[1].kind);

    closeAll(&dst);
    try std.testing.expectEqual(@as(u32, 1), p.refs);
    try std.testing.expectEqual(@as(u8, 0), dst.fds[0].kind);
}
