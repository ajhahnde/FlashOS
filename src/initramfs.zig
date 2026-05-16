// Embedded initramfs — newc cpio parser.
//
// Pure parser + host tests. Kernel-side integration lives in
// src/sys.zig (sys_openFile / sys_readFile) and src/kernel.zig
// (PID-1 ELF flip); the `.initramfs` linker section + `.incbin`
// build glue lives in src/board/<board>/linker.ld + build.zig.
//
// newc cpio reference: `man 5 cpio` "New ASCII Format". All numeric
// header fields are 8-byte ASCII hex (uppercase, no `0x` prefix). The
// 110-byte header is followed by the name (length = namesize, including
// the NUL terminator), padded so the next file-data byte sits on a
// 4-byte boundary. File data follows, also padded to 4. The archive
// ends with an entry named `TRAILER!!!` whose filesize is 0.

const std = @import("std");
const builtin = @import("builtin");

// Linker-provided section bounds. Defined by `.initramfs : { … }` in
// src/board/<board>/linker.ld. Host builds never reference
// these — the comptime branch in baseKva()/baseSize() reads the
// per-test fixture globals below instead.
extern var __initramfs_start: u8;
extern var __initramfs_end: u8;

const LINEAR_MAP_BASE: u64 = 0xffff000000000000;

inline fn baseKva() [*]const u8 {
    if (comptime builtin.target.os.tag == .freestanding) {
        return @ptrFromInt(@intFromPtr(&__initramfs_start) | LINEAR_MAP_BASE);
    } else {
        return host_fixture_base;
    }
}

inline fn baseSize() usize {
    if (comptime builtin.target.os.tag == .freestanding) {
        return @intFromPtr(&__initramfs_end) - @intFromPtr(&__initramfs_start);
    } else {
        return host_fixture_size;
    }
}

// Host-test injection points. Tests set these before driving the public
// API. The freestanding branches above never read them; the symbols
// live in BSS for the few bytes they cost.
pub var host_fixture_base: [*]const u8 = undefined;
pub var host_fixture_size: usize = 0;

pub const Entry = struct {
    // Borrows into the archive bytes — lifetime = archive.
    name: []const u8,
    data: []const u8,
    mode: u32,
};

pub const ParseError = error{ InvalidHex, BadMagic, ShortArchive };

const HEADER_SIZE: usize = 110;
const HEADER_MAGIC = "070701";
const TRAILER = "TRAILER!!!";

// Byte offsets of the three header fields the parser reads. The other
// ten 8-byte fields (ino/uid/gid/nlink/mtime/dev*/check) are ignored.
const OFF_MAGIC: usize = 0;
const OFF_MODE: usize = 6 + 8 * 1;
const OFF_FILESIZE: usize = 6 + 8 * 6;
const OFF_NAMESIZE: usize = 6 + 8 * 11;

fn parseHex8(buf: *const [8]u8) ParseError!u32 {
    var v: u32 = 0;
    for (buf) |c| {
        v <<= 4;
        v |= switch (c) {
            '0'...'9' => @as(u32, c - '0'),
            'A'...'F' => @as(u32, c - 'A' + 10),
            'a'...'f' => @as(u32, c - 'a' + 10),
            else => return error.InvalidHex,
        };
    }
    return v;
}

inline fn align4(x: usize) usize {
    return (x + 3) & ~@as(usize, 3);
}

// Byte-wise slice compare. std.mem.eql takes a vectorised path that
// issues wide (16-byte) loads; the archive is only `.balign 4` and
// entry names start at odd VAs (name_start = cursor + 110), so a wide
// load there alignment-faults under the kernel's strict-alignment
// SCTLR_EL1.A. A plain byte loop has no alignment requirement and the
// archive is tiny, so the linear scan cost is irrelevant.
fn bytesEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

pub const Iterator = struct {
    archive: []const u8,
    cursor: usize = 0,

    pub fn next(self: *Iterator) ParseError!?Entry {
        if (self.cursor + HEADER_SIZE > self.archive.len) return error.ShortArchive;
        const hdr = self.archive[self.cursor..][0..HEADER_SIZE];

        if (!bytesEql(hdr[OFF_MAGIC..][0..6], HEADER_MAGIC)) return error.BadMagic;

        const mode = try parseHex8(hdr[OFF_MODE..][0..8]);
        const filesize = try parseHex8(hdr[OFF_FILESIZE..][0..8]);
        const namesize = try parseHex8(hdr[OFF_NAMESIZE..][0..8]);
        // namesize counts the trailing NUL, so it can never legitimately
        // be zero. Catch it explicitly so the name_end subtraction below
        // can't underflow.
        if (namesize == 0) return error.ShortArchive;

        const name_start = self.cursor + HEADER_SIZE;
        const name_end = name_start + namesize - 1;
        if (name_end > self.archive.len) return error.ShortArchive;
        const raw_name = self.archive[name_start..name_end];
        // cpio(1) reading `find . -type f` output stores entries as
        // `./sbin/init`; the kernel API and plan tests use the leading-
        // slash form `/sbin/init`. Slice off the `.` so all consumers see
        // canonical absolute paths. TRAILER!!! has no `./` prefix so the
        // check is safe before the trailer terminator below.
        const name = if (raw_name.len >= 2 and raw_name[0] == '.' and raw_name[1] == '/')
            raw_name[1..]
        else
            raw_name;

        const data_start = align4(name_start + namesize);
        const data_end = data_start + filesize;
        if (data_end > self.archive.len) return error.ShortArchive;
        const data = self.archive[data_start..data_end];

        self.cursor = align4(data_end);

        if (bytesEql(name, TRAILER)) return null;
        return Entry{ .name = name, .data = data, .mode = mode };
    }
};

pub fn iterator() Iterator {
    const base = baseKva();
    return .{ .archive = base[0..baseSize()], .cursor = 0 };
}

pub fn locate(path: []const u8) ParseError!?Entry {
    var it = iterator();
    while (try it.next()) |e| {
        if (bytesEql(e.name, path)) return e;
    }
    return null;
}

// ---- Host tests ----
//
// buildFixture() is a comptime newc encoder used solely by the tests
// below. It mirrors the runtime encoder under scripts/build_initramfs.zig
// (only used if cpio(1) is proven non-deterministic), so any
// drift between encoder and decoder shows up here first.

const FixtureEntry = struct {
    name: []const u8,
    data: []const u8,
    mode: u32,
};

fn comptimeHex8(comptime v: u32) []const u8 {
    return std.fmt.comptimePrint("{X:0>8}", .{v});
}

fn padBytes(comptime n: usize) []const u8 {
    return switch (n & 3) {
        0 => "",
        1 => "\x00\x00\x00",
        2 => "\x00\x00",
        3 => "\x00",
        else => unreachable,
    };
}

fn emitEntry(comptime e: FixtureEntry) []const u8 {
    const hdr = HEADER_MAGIC
        ++ comptimeHex8(1) // ino
        ++ comptimeHex8(e.mode) // mode
        ++ "00000000" // uid
        ++ "00000000" // gid
        ++ "00000001" // nlink
        ++ "00000000" // mtime
        ++ comptimeHex8(@intCast(e.data.len)) // filesize
        ++ "00000000" // devmajor
        ++ "00000000" // devminor
        ++ "00000000" // rdevmajor
        ++ "00000000" // rdevminor
        ++ comptimeHex8(@intCast(e.name.len + 1)) // namesize incl. NUL
        ++ "00000000"; // check
    const name = e.name ++ "\x00";
    const name_pad = padBytes(hdr.len + name.len);
    const data_pad = padBytes(e.data.len);
    return hdr ++ name ++ name_pad ++ e.data ++ data_pad;
}

fn emitTrailer() []const u8 {
    const hdr = HEADER_MAGIC
        ++ ("00000000" ** 4) // ino, mode, uid, gid
        ++ "00000001" // nlink — GNU cpio writes 1 on the trailer too
        ++ ("00000000" ** 6) // mtime, filesize, dev*4
        ++ comptimeHex8(@intCast(TRAILER.len + 1)) // namesize
        ++ "00000000"; // check
    const name = TRAILER ++ "\x00";
    const pad = padBytes(hdr.len + name.len);
    return hdr ++ name ++ pad;
}

fn buildFixture(comptime entries: []const FixtureEntry) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (entries) |e| out = out ++ emitEntry(e);
        out = out ++ emitTrailer();
        return out;
    }
}

test "locate hit returns name + data + mode" {
    const fixture = comptime buildFixture(&.{
        .{ .name = "hi", .data = "OK", .mode = 0o100644 },
    });
    host_fixture_base = fixture.ptr;
    host_fixture_size = fixture.len;

    const e = (try locate("hi")) orelse return error.NotFound;
    try std.testing.expectEqualStrings("hi", e.name);
    try std.testing.expectEqualStrings("OK", e.data);
    try std.testing.expectEqual(@as(u32, 0o100644), e.mode);
}

test "locate miss returns null" {
    const fixture = comptime buildFixture(&.{
        .{ .name = "/sbin/init", .data = "X", .mode = 0o100755 },
    });
    host_fixture_base = fixture.ptr;
    host_fixture_size = fixture.len;

    try std.testing.expectEqual(@as(?Entry, null), try locate("/nope"));
}

test "empty archive: trailer alone terminates iteration" {
    const fixture = comptime buildFixture(&.{});
    host_fixture_base = fixture.ptr;
    host_fixture_size = fixture.len;

    var it = iterator();
    try std.testing.expectEqual(@as(?Entry, null), try it.next());
}

test "multi-entry walk preserves order and pads correctly" {
    const fixture = comptime buildFixture(&.{
        .{ .name = "a", .data = "AAA", .mode = 0o100644 },
        .{ .name = "bb", .data = "BB", .mode = 0o100644 },
        .{ .name = "ccc", .data = "C", .mode = 0o100644 },
    });
    host_fixture_base = fixture.ptr;
    host_fixture_size = fixture.len;

    var it = iterator();
    const e1 = (try it.next()) orelse return error.MissingEntry;
    try std.testing.expectEqualStrings("a", e1.name);
    try std.testing.expectEqualStrings("AAA", e1.data);

    const e2 = (try it.next()) orelse return error.MissingEntry;
    try std.testing.expectEqualStrings("bb", e2.name);
    try std.testing.expectEqualStrings("BB", e2.data);

    const e3 = (try it.next()) orelse return error.MissingEntry;
    try std.testing.expectEqualStrings("ccc", e3.name);
    try std.testing.expectEqualStrings("C", e3.data);

    try std.testing.expectEqual(@as(?Entry, null), try it.next());
}

test "bad magic returns BadMagic" {
    var hdr: [HEADER_SIZE]u8 = [_]u8{0} ** HEADER_SIZE;
    @memcpy(hdr[0..6], "999999");
    host_fixture_base = &hdr;
    host_fixture_size = hdr.len;

    var it = iterator();
    try std.testing.expectError(error.BadMagic, it.next());
}

test "leading ./ in archive name canonicalises to /" {
    // Mirrors the on-disk shape `cd $stage; find . -type f | cpio -o`
    // emits: entry names carry a `./` prefix. The parser strips the
    // dot so locate("/sbin/init") matches.
    const fixture = comptime buildFixture(&.{
        .{ .name = "./sbin/init", .data = "\x7fELF", .mode = 0o100755 },
    });
    host_fixture_base = fixture.ptr;
    host_fixture_size = fixture.len;

    const e = (try locate("/sbin/init")) orelse return error.NotFound;
    try std.testing.expectEqualStrings("/sbin/init", e.name);
    try std.testing.expectEqualStrings("\x7fELF", e.data);
}

test "header truncated below 110 bytes returns ShortArchive" {
    var buf: [50]u8 = [_]u8{0} ** 50;
    @memcpy(buf[0..6], HEADER_MAGIC);
    host_fixture_base = &buf;
    host_fixture_size = buf.len;

    var it = iterator();
    try std.testing.expectError(error.ShortArchive, it.next());
}
