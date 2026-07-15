// Transitional adapter for the Rust-owned file-descriptor table.
//
// The per-task slot array, kind dispatch, and ref-count discipline live in
// crates/kernel/src/fdtable.rs. This shim preserves the `Kind` tag and the
// install/get/dup2/close/dupAll/closeAll API the remaining Flash callers
// (sys, fork, sched, kernel) still use. Removed once the last one ports.

const layout = @import("task_layout");

pub const TaskStruct = layout.TaskStruct;
pub const FdSlot = layout.FdSlot;
pub const File = layout.File;
pub const FD_TABLE_SIZE = layout.FD_TABLE_SIZE;

pub const Kind = enum(u8) { none = 0, console = 1, pipe = 2, file = 3 };

extern fn fos_fdtable_install(t: *TaskStruct, kind: u8, ptr: ?*anyopaque) i32;
extern fn fos_fdtable_get(t: *TaskStruct, fd: i32, out: *FdSlot) i32;
extern fn fos_fdtable_get_file(t: *TaskStruct, fd: i32) ?*File;
extern fn fos_fdtable_dup2(t: *TaskStruct, oldfd: i32, newfd: i32) i32;
extern fn fos_fdtable_close(t: *TaskStruct, fd: i32) i32;
extern fn fos_fdtable_close_all(t: *TaskStruct) void;
extern fn fos_fdtable_dup_all(src: *TaskStruct, dst: *TaskStruct) void;

pub fn install(t: *TaskStruct, k: Kind, ptr: ?*anyopaque) i32 {
    return fos_fdtable_install(t, @intFromEnum(k), ptr);
}

pub fn get(t: *TaskStruct, fd: i32) ?FdSlot {
    var s: FdSlot = undefined;
    if (fos_fdtable_get(t, fd, &s) == 0) return null;
    return s;
}

pub fn getFile(t: *TaskStruct, fd: i32) ?*File {
    return fos_fdtable_get_file(t, fd);
}

pub fn dup2(t: *TaskStruct, oldfd: i32, newfd: i32) i32 {
    return fos_fdtable_dup2(t, oldfd, newfd);
}

pub fn close(t: *TaskStruct, fd: i32) i32 {
    return fos_fdtable_close(t, fd);
}

pub fn closeAll(t: *TaskStruct) void {
    fos_fdtable_close_all(t);
}

pub fn dupAll(src: *TaskStruct, dst: *TaskStruct) void {
    fos_fdtable_dup_all(src, dst);
}
