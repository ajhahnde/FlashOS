// Stubs for fork host tests.
const std = @import("std");
const layout = @import("task_layout");
const TaskStruct = layout.TaskStruct;
const KeRegs = layout.KeRegs;

export var current: ?*TaskStruct = null;
export var task: [64]?*TaskStruct = [_]?*TaskStruct{null} ** 64;
export var nr_tasks: i32 = 0;
export var next_pid: i32 = 1;

var pool: [1024 * 1024]u8 align(4096) = [_]u8{0} ** (1024 * 1024);
var pool_idx: usize = 0;

export fn get_kernel_page() u64 {
    if (pool_idx + 4096 > pool.len) return 0;
    const addr = @intFromPtr(&pool[pool_idx]);
    pool_idx += 4096;
    @memset(@as([*]u8, @ptrFromInt(addr))[0..4096], 0);
    return addr;
}

export fn free_kernel_page(_: u64) void {}

// release_user_mm lives in sched.zig (not linked into the fork test
// target); the real page-freeing it does is covered by sched.zig's own
// host tests. Here it is inert — the fork tests assert the failure paths
// return -1 cleanly, not the freeing.
export fn release_user_mm(_: *TaskStruct) void {}

export fn allocate_user_page(_: *TaskStruct, _: u64, _: u64) u64 {
    return get_kernel_page();
}

// copy_virt_memory is fail-controllable so the copy_virt_memory-failure
// path in copy_process_impl can be exercised.
var fail_copy_virt: bool = false;
export fn set_fail_copy_virt(v: bool) void {
    fail_copy_virt = v;
}
export fn copy_virt_memory(_: *TaskStruct) i32 {
    return if (fail_copy_virt) -1 else 0;
}

export fn memzero(start: u64, size: u64) void {
    @memset(@as([*]u8, @ptrFromInt(start))[0..size], 0);
}

export fn memcpy(dst: *anyopaque, src: *const anyopaque, bytes: u64) *anyopaque {
    const d: [*]u8 = @ptrCast(dst);
    const s: [*]const u8 = @ptrCast(src);
    var i: usize = 0;
    while (i < bytes) : (i += 1) d[i] = s[i];
    return dst;
}

export fn copy_ke_regs(to: *KeRegs, from: *KeRegs) void {
    var i: usize = 0;
    while (i < 31) : (i += 1) to.regs[i] = from.regs[i];
    to.sp = from.sp;
    to.elr = from.elr;
    to.pstate = from.pstate;
}

export fn set_pgd(_: u64) void {}
export fn preempt_disable() void {}
export fn preempt_enable() void {}
export fn ret_from_fork() void {}
export fn main_output(_: i32, _: [*:0]const u8) void {}
export fn main_output_u64(_: i32, _: u64) void {}
export fn main_output_char(_: i32, _: u8) void {}

// fork's five host tests exercise process cloning, not the ELF loader, but the
// imported adapter still needs its production FFI symbols at link time. Parser
// behavior is covered one-for-one by flashos-kernel's host tests.
export fn fos_elf_parse_ehdr(_: [*]const u8, _: usize, _: *anyopaque) u32 {
    return 1;
}
export fn fos_elf_parse_phdr(_: [*]const u8, _: usize, _: u64, _: *anyopaque) u32 {
    return 1;
}

// Mock for pipe_mod and file_mod
pub const pipe_mod = struct {
    pub export fn dupAll(_: *TaskStruct, _: *TaskStruct) void {}
};
pub const file_mod = struct {
    pub export fn dupAll(_: *TaskStruct, _: *TaskStruct) void {}
};

export fn reset_fork_test() void {
    pool_idx = 0;
    @memset(&pool, 0);
    @memset(std.mem.asBytes(&task), 0);
    nr_tasks = 0;
    next_pid = 1;
    fail_copy_virt = false;
}
