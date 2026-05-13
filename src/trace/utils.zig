// Trace I/O helpers — output via PL011 UART for tracing.
// Layouts come from src/task_layout.zig.

const layout = @import("task_layout");
const TaskStruct = layout.TaskStruct;

pub const PL: i32 = 1;

const ID_MAP_PAGES: usize = 3;
const HIGH_MAP_PAGES: usize = 6;
const ENTRIES_PER_TABLE: usize = 512;

extern fn pl011_uart_send_string(str: [*:0]const u8) void;
extern fn pl011_uart_recv() u8;

extern var id_pg_dir: u64;
extern var high_pg_dir: u64;

export fn trace_output(interface: i32, str: [*:0]const u8) void {
    switch (interface) {
        PL => pl011_uart_send_string(str),
        else => trace_output(PL, "trace_output bad interface\n"),
    }
}

export fn trace_u64_to_char_array(in: u64, buf: [*]u8) void {
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast((15 - i) * 4);
        const tmp: u8 = @intCast((in >> shift) & 0xf);
        buf[i] = if (tmp <= 9) tmp + '0' else tmp - 10 + 'a';
    }
}

export fn trace_char_to_char_array(ch: u8, buf: [*]u8) void {
    buf[0] = ch;
}

export fn trace_output_char(interface: i32, ch: u8) void {
    var printable: [2]u8 = undefined;
    printable[0] = ch;
    printable[1] = 0;
    trace_output(interface, @ptrCast(&printable[0]));
}

export fn trace_output_u64(interface: i32, in: u64) void {
    var printable: [17]u8 = undefined;
    printable[16] = 0;
    trace_u64_to_char_array(in, @ptrCast(&printable[0]));
    trace_output(interface, @ptrCast(&printable[0]));
}

export fn trace_output_process(interface: i32, p: *TaskStruct) void {
    trace_output(interface, "task address: ");
    trace_output_u64(interface, @intFromPtr(p));
    trace_output(interface, ", state: ");
    trace_output_u64(interface, @bitCast(p.state));
    trace_output(interface, ", counter: ");
    trace_output_u64(interface, @bitCast(p.counter));
    trace_output(interface, ", priority: ");
    trace_output_u64(interface, @bitCast(p.priority));
    trace_output(interface, ", preempt_count: ");
    trace_output_u64(interface, @bitCast(p.preempt_count));
    trace_output(interface, ", pgd: ");
    trace_output_u64(interface, p.mm.pgd);
    trace_output(interface, "\n");
}

export fn trace_output_insn(interface: i32, addr_in: u64) void {
    const addr: u64 = addr_in & ~@as(u64, 0x7);
    trace_output(interface, "instruction address: ");
    trace_output_u64(interface, addr);
    trace_output(interface, ", instruction: ");
    const ptr: *const volatile u64 = @ptrFromInt(addr);
    trace_output_u64(interface, ptr.*);
    trace_output(interface, "\n");
}

export fn trace_output_pt(interface: i32, page: [*]u64) void {
    var i: usize = 0;
    while (i < ENTRIES_PER_TABLE) : (i += 1) {
        trace_output_u64(interface, @intFromPtr(&page[i]));
        trace_output(interface, ": ");
        trace_output_u64(interface, page[i]);
        if ((i % 2) != 0) {
            trace_output(interface, "\n");
        } else {
            trace_output(interface, "  ");
        }
    }
}

export fn trace_output_kernel_pts(interface: i32) void {
    _ = interface;
    var pt: [*]u64 = @ptrCast(&id_pg_dir);
    var i: usize = 0;
    while (i < ID_MAP_PAGES) : (i += 1) {
        trace_output(PL, "pt = ");
        trace_output_u64(PL, @intFromPtr(pt));
        trace_output(PL, "\n");
        trace_output_pt(PL, pt);
        pt += ENTRIES_PER_TABLE;
    }
    pt = @ptrCast(&high_pg_dir);
    i = 0;
    while (i < HIGH_MAP_PAGES) : (i += 1) {
        trace_output(PL, "pt = ");
        trace_output_u64(PL, @intFromPtr(pt));
        trace_output(PL, "\n");
        trace_output_pt(PL, pt);
        pt += ENTRIES_PER_TABLE;
    }
}

export fn trace_recv(interface: i32) u8 {
    switch (interface) {
        PL => return pl011_uart_recv(),
        else => {
            trace_output(PL, "main_recv bad interface\n");
            return 0;
        },
    }
}
