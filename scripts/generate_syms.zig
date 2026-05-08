const std = @import("std");

const pre_allocated_size = 65536;
const symbol_area_file = "src/symbol_area.S";
const entry_size = 64;
const max_sym_name_len = entry_size - 8 - 1;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_obj = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_obj.interface;

    try stdout.writeAll("generating symbol area\n");

    var file = try std.Io.Dir.cwd().createFile(io, symbol_area_file, .{});
    defer file.close(io);

    var file_buf: [4096]u8 = undefined;
    var writer_obj = file.writer(io, &file_buf);
    const writer = &writer_obj.interface;

    try writer.writeAll(".section \"_symbols\", \"a\"\n");
    var count: usize = 0;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_obj = std.Io.File.stdin().reader(io, &stdin_buf);
    const stdin = &stdin_obj.interface;

    var input_buf: [1024 * 1024]u8 = undefined;
    const input_len = try stdin.readSliceShort(&input_buf);

    var line_it = std.mem.splitScalar(u8, input_buf[0..input_len], '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;

        var it = std.mem.tokenizeAny(u8, trimmed, " \t");
        const addr = it.next() orelse continue;
        _ = it.next() orelse continue;
        // ignore the symbol type field
        const name = it.next() orelse continue;

        if (name.len > max_sym_name_len) {
            std.debug.panic("{s} is too long!\n", .{name});
        }

        try writer.print(".quad 0x{s}\n", .{addr});
        try writer.print(".string \"{s}\"\n", .{name});
        try writer.print(".space {d}\n", .{max_sym_name_len - name.len});

        count += 1;
    }

    // null entry sentinel that terminates the symbol table
    try writer.writeAll(".space 64\n");
    count += 1;

    const used_space = entry_size * count;
    if (used_space > pre_allocated_size) {
        std.debug.panic("too many symbols! please expand the pre allocated size!\n", .{});
    }

    try writer.print(".space {d}\n", .{pre_allocated_size - used_space});

    // flush buffered output before exiting
    try writer.flush();

    try stdout.print("symbol area: {d}\n", .{used_space});
    try stdout.writeAll("please be sure the pre_allocated_size == the .space value in the first pass!\n");
    try stdout.flush();
}
