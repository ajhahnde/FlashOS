const std = @import("std");
const Io = std.Io;

// Deterministic newc cpio encoder.
//
// build.zig invokes it as
//   build_initramfs <output.cpio> <stage_dir> <arc1>:<mode1> <arc2>:<mode2> ...
// where the <arcN> list is pre-sorted lexicographically by build.zig
// and <modeN> is the entry's octal newc mode (per-file modes so the
// VFS permission layer can distinguish /etc/shadow 0600 from the
// 0755 binaries). For each arc the encoder reads <stage_dir>/<arc>
// and emits one newc entry with name "./<arc>" (matches the cpio(1)
// `find . -type f` layout the initramfs.zig parser already
// canonicalises via its `./` strip). All headers fix mtime / uid /
// gid / nlink so the archive bytes are a pure function of file
// contents + name list + mode list, not host filesystem state.
//
// Replaces the addSystemCommand cpio(1) block in build.zig — bsdcpio
// stamps the host-clock mtime into c_mtime and gives every entry a
// fresh inode at byte 12, which drifted between two clean builds and
// blocked Pi-hash baseline refresh.

const MAGIC = "070701";
const HEADER_SIZE: usize = 110;
const READ_LIMIT: Io.Limit = .limited(1 << 24); // 16 MiB / file is plenty

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.panic(
            "usage: build_initramfs <output.cpio> <stage_dir> <arc>...\n",
            .{},
        );
    }
    const out_path = args[1];
    const stage_path = args[2];
    const arcs = args[3..];

    var stage = try Io.Dir.cwd().openDir(io, stage_path, .{});
    defer stage.close(io);

    var out_file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);

    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);
    const w = &out_writer.interface;

    var ino: u32 = 1;
    for (arcs) |arc_spec| {
        // Each token is "<arc>:<octal mode>" (build.zig formats it).
        // Refusing a token without a mode keeps a stale invocation from
        // silently flattening every entry back to one mode.
        const colon = std.mem.lastIndexOfScalar(u8, arc_spec, ':') orelse
            return error.MissingMode;
        const arc = arc_spec[0..colon];
        const mode = try std.fmt.parseInt(u32, arc_spec[colon + 1 ..], 8);
        const data = try stage.readFileAlloc(io, arc, gpa, READ_LIMIT);
        defer gpa.free(data);
        try emitEntry(w, ino, arc, mode, data);
        ino += 1;
    }
    try emitTrailer(w, ino);

    try w.flush();
}

fn emitEntry(w: *Io.Writer, ino: u32, arc: []const u8, mode: u32, data: []const u8) !void {
    // Name written into the archive matches cpio(1) `find . -type f`
    // output ("./<arc>") so the initramfs.zig `./`-strip canonicaliser
    // produces "/<arc>" for `locate("/sbin/init")` etc.
    var name_buf: [512]u8 = undefined;
    if (arc.len + 2 >= name_buf.len) return error.NameTooLong;
    name_buf[0] = '.';
    name_buf[1] = '/';
    @memcpy(name_buf[2 .. 2 + arc.len], arc);
    name_buf[2 + arc.len] = 0;
    const name_with_nul = name_buf[0 .. 2 + arc.len + 1];

    try writeHeader(w, .{
        .ino = ino,
        .mode = mode,
        .filesize = @intCast(data.len),
        .namesize = @intCast(name_with_nul.len),
    });
    try w.writeAll(name_with_nul);
    try padTo4(w, HEADER_SIZE + name_with_nul.len);
    try w.writeAll(data);
    try padTo4(w, data.len);
}

fn emitTrailer(w: *Io.Writer, ino: u32) !void {
    const name = "TRAILER!!!\x00";
    try writeHeader(w, .{
        .ino = ino,
        .mode = 0,
        .filesize = 0,
        .namesize = @intCast(name.len),
    });
    try w.writeAll(name);
    try padTo4(w, HEADER_SIZE + name.len);
}

const HeaderArgs = struct {
    ino: u32,
    mode: u32,
    filesize: u32,
    namesize: u32,
};

fn writeHeader(w: *Io.Writer, h: HeaderArgs) !void {
    try w.writeAll(MAGIC);
    try writeHex8(w, h.ino);
    try writeHex8(w, h.mode);
    try writeHex8(w, 0); // uid
    try writeHex8(w, 0); // gid
    try writeHex8(w, 1); // nlink — GNU cpio writes 1 on the trailer too
    try writeHex8(w, 0); // mtime
    try writeHex8(w, h.filesize);
    try writeHex8(w, 0); // devmajor
    try writeHex8(w, 0); // devminor
    try writeHex8(w, 0); // rdevmajor
    try writeHex8(w, 0); // rdevminor
    try writeHex8(w, h.namesize);
    try writeHex8(w, 0); // check
}

fn writeHex8(w: *Io.Writer, v: u32) !void {
    var buf: [8]u8 = undefined;
    const hex = "0123456789ABCDEF";
    var i: usize = 8;
    var x = v;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[x & 0xF];
        x >>= 4;
    }
    try w.writeAll(&buf);
}

fn padTo4(w: *Io.Writer, n: usize) !void {
    const pad = (4 - (n & 3)) & 3;
    if (pad == 0) return;
    try w.writeAll(("\x00\x00\x00")[0..pad]);
}

// ---- Host tests ----
//
// Pin the byte offsets the kernel parser (src/initramfs.zig) reads:
// mode at 14, uid at 22, gid at 30. A drift between this encoder and
// that parser is a silent permission bypass, so the offsets are
// asserted here against literal hex.

test "emitEntry stamps the per-file mode into the newc mode field" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try emitEntry(&w, 1, "etc/shadow", 0o100600, "x");
    const out = w.buffered();
    try std.testing.expectEqualStrings("070701", out[0..6]);
    // 0o100600 == 0x8180; newc fields are 8-digit uppercase hex.
    try std.testing.expectEqualStrings("00008180", out[14..22]);
    try std.testing.expectEqualStrings("00000000", out[22..30]); // uid root
    try std.testing.expectEqualStrings("00000000", out[30..38]); // gid root
}

test "emitEntry gives two entries distinct modes" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try emitEntry(&w, 1, "bin/fsh", 0o100755, "\x7fELF");
    const first_len = w.buffered().len;
    try emitEntry(&w, 2, "etc/shadow", 0o100600, "s");
    const out = w.buffered();
    // 0o100755 == 0x81ED on the first header; 0x8180 on the second.
    try std.testing.expectEqualStrings("000081ED", out[14..22]);
    try std.testing.expectEqualStrings("00008180", out[first_len + 14 .. first_len + 22]);
}
