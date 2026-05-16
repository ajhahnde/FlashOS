const std = @import("std");
const Io = std.Io;

// Deterministic newc cpio encoder (v0.4.0).
//
// build.zig invokes us as
//   build_initramfs <output.cpio> <stage_dir> <arc1> <arc2> ...
// where the <arcN> list is pre-sorted lexicographically by build.zig.
// For each arc the encoder reads <stage_dir>/<arc> and emits one newc
// entry with name "./<arc>" (matches the cpio(1) `find . -type f`
// layout the initramfs.zig parser already canonicalises via its `./`
// strip). All headers fix mtime / uid / gid / nlink / mode so the
// archive bytes are a pure function of file contents + name list,
// not host filesystem state.
//
// Replaces the addSystemCommand cpio(1) block in build.zig — bsdcpio
// stamps the host-clock mtime into c_mtime and gives every entry a
// fresh inode at byte 12, which drifted between two clean builds and
// blocked Pi-hash baseline refresh.

const MAGIC = "070701";
const HEADER_SIZE: usize = 110;
const FILE_MODE: u32 = 0o100644;
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
    for (arcs) |arc| {
        const data = try stage.readFileAlloc(io, arc, gpa, READ_LIMIT);
        defer gpa.free(data);
        try emitEntry(w, ino, arc, data);
        ino += 1;
    }
    try emitTrailer(w, ino);

    try w.flush();
}

fn emitEntry(w: *Io.Writer, ino: u32, arc: []const u8, data: []const u8) !void {
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
        .mode = FILE_MODE,
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
