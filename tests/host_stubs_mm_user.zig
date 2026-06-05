// Stubs for mm_user host tests.
const std = @import("std");
const layout = @import("task_layout");
const TaskStruct = layout.TaskStruct;

export var current: ?*TaskStruct = null;

var fake_phys_mem: [1024 * 1024]u8 align(4096) = [_]u8{0} ** (1024 * 1024);
var next_free_page: usize = 0;

export fn get_free_page() u64 {
    if (next_free_page + 4096 > fake_phys_mem.len) return 0;
    const addr = @intFromPtr(&fake_phys_mem[next_free_page]);
    // std.debug.print("get_free_page: 0x{x}\n", .{addr});
    // host-stricter than kernel; mirrors page_alloc's natural alignment
    // so callers that pass garbage trip in tests.
    if (addr % 4096 != 0) @panic("get_free_page: unaligned address");
    next_free_page += 4096;
    @memset(@as([*]u8, @ptrFromInt(addr))[0..4096], 0);
    return addr;
}

export fn free_page(_: u64) void {
    // No-op for now
}

export fn memcpy(dst: *anyopaque, src: *const anyopaque, bytes: u64) *anyopaque {
    const d: [*]u8 = @ptrCast(dst);
    const s: [*]const u8 = @ptrCast(src);
    var i: usize = 0;
    while (i < bytes) : (i += 1) {
        d[i] = s[i];
    }
    return dst;
}

export fn main_output(_: i32, _: [*:0]const u8) void {}
export fn main_output_u64(_: i32, _: u64) void {}
export fn exit_process() void {
    @panic("exit_process called");
}

export fn reset_phys_mem() void {
    next_free_page = 0;
    @memset(&fake_phys_mem, 0);
}
