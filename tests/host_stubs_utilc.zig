// Stubs for utilc host tests.
// utilc calls board-specific UART send/recv and err_hang.
const std = @import("std");

export var last_output: [1024]u8 = [_]u8{0} ** 1024;
export var last_output_len: usize = 0;

export fn mini_uart_send_string(str: [*:0]const u8) void {
    const s = std.mem.span(str);
    const len = @min(s.len, last_output.len - last_output_len);
    @memcpy(last_output[last_output_len..][0..len], s[0..len]);
    last_output_len += len;
}
export fn mini_uart_recv() u8 {
    return 0;
}
export fn pl011_uart_send_string(str: [*:0]const u8) void {
    mini_uart_send_string(str);
}
export fn err_hang() noreturn {
    @panic("err_hang called during test");
}
