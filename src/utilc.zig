// utilc: kernel utility functions.
// Layouts come from src/task_layout.zig.

const layout = @import("task_layout");
const TaskStruct = layout.TaskStruct;
const KeRegs = layout.KeRegs;

// Kernel-log byte-ring (src/klog_ring.zig). main_output tees every line
// into it so a userland `dmesg` can read the boot log back via
// sys_klog_read — see klog_ring.zig for the overwrite-oldest + lock-free
// rationale.
const klog_ring = @import("klog_ring");

const MU: i32 = 0;
const PL: i32 = 1;

extern fn mini_uart_send_string(str: [*:0]const u8) void;
extern fn mini_uart_recv() u8;
extern fn pl011_uart_send_string(str: [*:0]const u8) void;
extern fn err_hang() noreturn;

/// Render a u64 as 16 hex chars into buf (no NUL).
export fn u64_to_char_array(in: u64, buf: [*]u8) void {
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast((15 - i) * 4);
        const tmp: u8 = @intCast((in >> shift) & 0xF);
        if (tmp <= 9) {
            buf[i] = tmp + '0';
        } else {
            buf[i] = tmp - 10 + 'a';
        }
    }
}

export fn char_to_char_array(ch: u8, buf: [*]u8) void {
    buf[0] = ch;
}

export fn main_output_char(interface: i32, ch: u8) void {
    var printable: [2]u8 = undefined;
    printable[0] = ch;
    printable[1] = 0;
    main_output(interface, @ptrCast(&printable[0]));
}

export fn main_output(interface: i32, str: [*:0]const u8) void {
    // Tee every emitted line into the kernel log ring before it goes out
    // the UART. pushStr is pure + allocation-free + never re-enters
    // main_output, so this is safe from any context (kernel / syscall /
    // IRQ / pre-`current` boot) and leaves the free-page baseline intact.
    klog_ring.klog.pushStr(str);
    switch (interface) {
        MU => mini_uart_send_string(str),
        PL => pl011_uart_send_string(str),
        else => main_output(MU, "main_output bad interface\n"),
    }
}

export fn main_output_u64(interface: i32, in: u64) void {
    var printable: [17]u8 = undefined;
    printable[16] = 0;
    u64_to_char_array(in, @ptrCast(&printable[0]));
    main_output(interface, @ptrCast(&printable[0]));
}

export fn main_output_process(interface: i32, p: *TaskStruct) void {
    main_output(interface, "task address: ");
    main_output_u64(interface, @intFromPtr(p));
    main_output(interface, ", state: ");
    main_output_u64(interface, @bitCast(p.state));
    main_output(interface, ", counter: ");
    main_output_u64(interface, @bitCast(p.counter));
    main_output(interface, ", priority: ");
    main_output_u64(interface, @bitCast(p.priority));
    main_output(interface, ", preempt_count: ");
    main_output_u64(interface, @bitCast(p.preempt_count));
    main_output(interface, ", pgd: ");
    main_output_u64(interface, p.mm.pgd);
    main_output(interface, "\n");
}

export fn main_recv(interface: i32) u8 {
    switch (interface) {
        MU => return mini_uart_recv(),
        else => {
            main_output(MU, "main_recv bad interface\n");
            return 0;
        },
    }
}

export fn copy_ke_regs(to: *KeRegs, from: *KeRegs) void {
    var i: usize = 0;
    while (i < 31) : (i += 1) {
        to.regs[i] = from.regs[i];
    }
    to.sp = from.sp;
    to.elr = from.elr;
    to.pstate = from.pstate;
}

export fn memset(dst: [*]u8, c: i32, n_in: u64) [*]u8 {
    var n = n_in;
    var p = dst;
    const byte: u8 = @truncate(@as(u32, @bitCast(c)));
    while (n != 0) : (n -= 1) {
        p[0] = byte;
        p += 1;
    }
    return dst;
}

/// Byte-granular memory copy.
export fn memcpy(dst: *anyopaque, src: *const anyopaque, bytes: u64) *anyopaque {
    var d: [*]u8 = @ptrCast(dst);
    var s: [*]const u8 = @ptrCast(src);
    var n = bytes;

    if (@intFromPtr(d) % 8 == 0 and @intFromPtr(s) % 8 == 0) {
        var d64: [*]u64 = @ptrCast(@alignCast(d));
        var s64: [*]const u64 = @ptrCast(@alignCast(s));
        while (n >= 8) : (n -= 8) {
            d64[0] = s64[0];
            d64 += 1;
            s64 += 1;
        }
        d = @ptrCast(d64);
        s = @ptrCast(s64);
    }

    while (n > 0) : (n -= 1) {
        d[0] = s[0];
        d += 1;
        s += 1;
    }
    return dst;
}

export fn panic(msg: [*:0]const u8) noreturn {
    main_output(MU, "KERNEL PANIC: ");
    main_output(MU, msg);
    main_output(MU, "\n");
    err_hang();
}

/// Byte-wise compare without alignment requirements. std.mem.eql
/// lowers to wide loads under ReleaseSmall, which trip
/// `SCTLR_EL1.A`-asserted strict alignment when the slices live at
/// odd VAs (newc cpio entry names land at `cursor + 110`; mount-prefix
/// matching starts at arbitrary path offsets). The plain byte loop has
/// no alignment requirement; cost is irrelevant on these short scans.
pub export fn mem_eql_bytes(a: [*]const u8, b: [*]const u8, n: u64) bool {
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

// --- Host Tests ---
const std = @import("std");
const testing = std.testing;

extern var last_output: [1024]u8;
extern var last_output_len: usize;

fn reset_output() void {
    last_output_len = 0;
    @memset(&last_output, 0);
}

test "utilc: u64_to_char_array renders hex correctly" {
    var buf: [16]u8 = undefined;
    u64_to_char_array(0x123456789ABCDEF0, &buf);
    try testing.expectEqualStrings("123456789abcdef0", &buf);

    u64_to_char_array(0x0, &buf);
    try testing.expectEqualStrings("0000000000000000", &buf);

    u64_to_char_array(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectEqualStrings("ffffffffffffffff", &buf);
}

test "utilc: char_to_char_array sets char" {
    var buf: [1]u8 = undefined;
    char_to_char_array('X', &buf);
    try testing.expectEqual(@as(u8, 'X'), buf[0]);
}

test "utilc: main_output sends to UART" {
    reset_output();
    main_output(MU, "test output");
    try testing.expectEqualStrings("test output", last_output[0..last_output_len]);
}

test "utilc: main_output_char sends char" {
    reset_output();
    main_output_char(MU, 'Z');
    try testing.expectEqualStrings("Z", last_output[0..last_output_len]);
}

test "utilc: main_output_u64 sends hex" {
    reset_output();
    main_output_u64(MU, 0x1234);
    try testing.expectEqualStrings("0000000000001234", last_output[0..last_output_len]);
}

test "utilc: main_output_process sends task info" {
    reset_output();
    var t: TaskStruct = undefined;
    @memset(std.mem.asBytes(&t), 0);
    t.state = 1;
    t.counter = 10;
    t.priority = 5;
    t.preempt_count = 0;
    t.mm.pgd = 0xDEADBEEF;

    main_output_process(MU, &t);
    // Just verify it doesn't crash and produces some output
    try testing.expect(last_output_len > 0);
    try testing.expect(std.mem.containsAtLeast(u8, last_output[0..last_output_len], 1, "task address: "));
    try testing.expect(std.mem.containsAtLeast(u8, last_output[0..last_output_len], 1, "pgd: "));
}

test "utilc: memset fills memory correctly" {
    var buf: [10]u8 = [_]u8{0} ** 10;
    _ = memset(&buf, 'A', 5);
    try testing.expectEqualStrings("AAAAA", buf[0..5]);
    try testing.expectEqual(@as(u8, 0), buf[5]);
}

test "utilc: memcpy copies memory correctly (aligned)" {
    const src = "Hello, World!";
    var dst: [13]u8 align(8) = undefined;
    var src_buf: [13]u8 align(8) = undefined;
    @memcpy(&src_buf, src);

    _ = memcpy(&dst, &src_buf, 13);
    try testing.expectEqualStrings(src, &dst);
}

test "utilc: memcpy copies memory correctly (unaligned)" {
    var src: [20]u8 = undefined;
    for (&src, 0..) |*p, i| p.* = @intCast(i);
    var dst: [20]u8 = [_]u8{0} ** 20;

    // Use unaligned offsets
    _ = memcpy(dst[1..10].ptr, src[5..14].ptr, 9);
    try testing.expectEqualSlices(u8, src[5..14], dst[1..10]);
}

test "utilc: memcpy copies 31 bytes (0x1F) correctly" {
    var src: [31]u8 align(8) = undefined;
    for (&src, 0..) |*p, i| p.* = @intCast(i);
    var dst: [31]u8 align(8) = [_]u8{0} ** 31;

    _ = memcpy(&dst, &src, 31);
    try testing.expectEqualSlices(u8, &src, &dst);
}

test "utilc: copy_ke_regs copies regs" {
    var from: layout.KeRegs = undefined;
    var to: layout.KeRegs = undefined;
    @memset(std.mem.asBytes(&from), 0xAA);
    @memset(std.mem.asBytes(&to), 0xBB);

    copy_ke_regs(&to, &from);
    try testing.expectEqualSlices(u64, &from.regs, &to.regs);
    try testing.expectEqual(from.sp, to.sp);
    try testing.expectEqual(from.elr, to.elr);
    try testing.expectEqual(from.pstate, to.pstate);
}
