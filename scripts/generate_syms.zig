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

/// Turn a Rust v0 mangled symbol into the readable path the trace symbolizer
/// wants, e.g.
///
///   _RNvMs_NtCs1VexIXjCVNi_14flashos_kernel6sha256NtB4_10HmacSha2566finish
///   -> flashos_kernel::sha256::HmacSha256::finish
///
/// Returns null for anything that is not a v0 symbol (the kernel's Flash and
/// assembly names, and every `#[no_mangle]` seam export, pass through untouched).
///
/// Only the path segments are recovered, not generics or signatures — the symbol
/// area is a 55-byte-per-name address→name table for backtraces, not a debugger.
/// v0 encodes each segment as a decimal length followed by that many bytes, so
/// the whole job is: skip the control characters, keep the length-prefixed names.
/// Two of those control forms swallow text and must be skipped explicitly, or
/// their payload would be misread as a segment:
///
///   * `Cs<base62>_`  the crate-root disambiguator (its base62 hash can start
///                    with a digit — `Cs1VexIXjCVNi_` would otherwise read as a
///                    1-byte segment "V")
///   * `B<base62>_`   a backreference to an earlier segment
///
/// If the joined path still exceeds the entry's name budget, leading segments are
/// dropped: the tail (the function) identifies a frame, the crate prefix merely
/// qualifies it.
fn demangleRustV0(sym: []const u8, buf: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, sym, "_R")) return null;

    // Collect the path segments in order.
    var segs: [16][]const u8 = undefined;
    var n_segs: usize = 0;
    var i: usize = 2;
    while (i < sym.len and n_segs < segs.len) {
        const c = sym[i];

        if (c == 'C' and i + 1 < sym.len and sym[i + 1] == 's') {
            i += 2;
            while (i < sym.len and sym[i] != '_') : (i += 1) {}
            if (i < sym.len) i += 1;
            continue;
        }
        if (c == 'B') {
            i += 1;
            while (i < sym.len and sym[i] != '_') : (i += 1) {}
            if (i < sym.len) i += 1;
            continue;
        }
        if (!std.ascii.isDigit(c)) {
            // A namespace/impl/disambiguator control byte — nothing to keep.
            i += 1;
            continue;
        }

        var len: usize = 0;
        while (i < sym.len and std.ascii.isDigit(sym[i])) : (i += 1) {
            len = len * 10 + (sym[i] - '0');
        }
        if (len == 0) continue; // an `s0_`-style disambiguator, not a segment
        if (i + len > sym.len) return null; // malformed — leave the raw name alone
        segs[n_segs] = sym[i .. i + len];
        n_segs += 1;
        i += len;
    }
    if (n_segs == 0) return null;

    // Join with "::", dropping leading segments until the result fits.
    var first: usize = 0;
    while (first < n_segs) : (first += 1) {
        var need: usize = 0;
        for (segs[first..n_segs], 0..) |s, k| need += s.len + (if (k == 0) @as(usize, 0) else 2);
        if (need <= max_sym_name_len and need <= buf.len) break;
    }
    if (first == n_segs) return null;

    var w: usize = 0;
    for (segs[first..n_segs], 0..) |s, k| {
        if (k != 0) {
            @memcpy(buf[w..][0..2], "::");
            w += 2;
        }
        @memcpy(buf[w..][0..s.len], s);
        w += s.len;
    }
    return buf[0..w];
}

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
        const raw = it.next() orelse continue;

        var demangle_buf: [512]u8 = undefined;
        const name = demangleRustV0(raw, &demangle_buf) orelse raw;

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
