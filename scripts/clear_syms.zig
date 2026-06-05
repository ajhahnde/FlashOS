const std = @import("std");

// Must match pre_allocated_size in scripts/generate_syms.zig so a
// cleared (placeholder) table links at the same size as a populated
// one and the two-pass build converges in one regen.
const pre_allocated_size = 131072;
const symbol_area_file = "src/symbol_area.S";

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var file = try std.Io.Dir.cwd().createFile(io, symbol_area_file, .{});
    defer file.close(io);

    var file_buf: [4096]u8 = undefined;
    var writer_obj = file.writer(io, &file_buf);
    const writer = &writer_obj.interface;

    try writer.writeAll(".section \"_symbols\", \"a\"\n");
    try writer.print(".space {d}\n", .{pre_allocated_size});

    try writer.flush();
}
