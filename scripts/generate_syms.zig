const std = @import("std");

// Total reserved size of the `_symbols` section. The section is
// self-contained: symbol_area.S emits its entries followed by a
// `.space` fill up to exactly this size, and the linker scripts just
// `KEEP(*(_symbols))` with no separate reservation — so this constant
// is the only knob. Bumped 65536 -> 98304 once the symbol count
// (compiler-rt + the FS modules) pushed used_space past 64 KiB; bumped
// 98304 -> 131072 when the USB gadget driver pushed past 96 KiB.
const pre_allocated_size = 131072;
const symbol_area_file = "src/symbol_area.S";
const entry_size = 64;
const max_sym_name_len = entry_size - 8 - 1;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_obj = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_obj.interface;


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
    if (input_len == input_buf.len) {
        std.debug.panic("symbol table input filled the {d} B buffer — likely truncated, grow input_buf!\n", .{input_buf.len});
    }

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
        // Print actionable numbers: the bump must be at least the
        // shortfall, rounded to a comfortable size so the next few
        // growth rounds don't re-trip this. pre_allocated_size at the
        // top of this file is the only knob — the `_symbols` section
        // is self-sized (this script's trailing `.space` fill) and the
        // linker scripts just `KEEP(*(_symbols))`, so nothing else
        // needs touching in lockstep.
        std.debug.panic(
            "too many symbols! used_space={d} > pre_allocated_size={d} " ++
                "(shortfall {d} bytes, {d} symbols at {d} bytes each). " ++
                "Bump pre_allocated_size in scripts/generate_syms.zig.\n",
            .{ used_space, pre_allocated_size, used_space - pre_allocated_size, count, entry_size },
        );
    }

    try writer.print(".space {d}\n", .{pre_allocated_size - used_space});

    // flush buffered output before exiting
    try writer.flush();

    try stdout.print("       -> symbol area: \x1b[1;36m{d}\x1b[0m\n", .{used_space});
    try stdout.flush();
}
