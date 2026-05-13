// Kernel utility functions
// Layouts come from src/task_layout.zig.

const layout = @import("task_layout");
const TaskStruct = layout.TaskStruct;
const KeRegs = layout.KeRegs;

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
        const tmp: u8 = @intCast((in >> shift) & 0xf);
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

/// 8-byte aligned copy. `bytes` is rounded down to nearest 8.
export fn memcpy(dst: [*]u64, src: [*]const u64, bytes: u64) void {
    const num: u64 = bytes >> 3;
    var i: u64 = 0;
    while (i < num) : (i += 1) {
        dst[i] = src[i];
    }
}

export fn panic(msg: [*:0]const u8) noreturn {
    main_output(MU, "KERNEL PANIC: ");
    main_output(MU, msg);
    main_output(MU, "\n");
    err_hang();
}
