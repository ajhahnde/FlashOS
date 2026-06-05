// overlay: FAT32 permission-overlay parser.
//
// Pure, allocation-free, no externs. FAT32 has no native owner/mode
// concept, so /mnt files get their permission metadata from a root-level
// text file (/mnt/PERMS.TAB) instead of the 8d hard default.
// src/fat32_backend.zig reads that file once at mount time, parses it with
// these helpers into a fixed table, and open() consults the table;
// un-annotated paths keep the documented default (0666 root:root, except
// the shadow basename, which floors at 0600 — see fat32_backend.open).
// The overlay protects itself through its own entry (`PERMS.TAB 0600 0 0`).
//
// Line format: `NAME MODE UID GID`
//   * NAME — 8.3 basename as it appears in the FAT32 root; matched
//     case-insensitively (FAT32 names are caseless)
//   * MODE — octal permission word, low 9 bits only (no file-type bits;
//     the backend ORs the regular-file type back in)
//   * UID / GID — decimal
//   * `#` starts a comment; blank lines are skipped; CRLF tolerated
//     (cards get hand-edited on host machines)
//
// parse() rejects a malformed overlay WHOLESALE (returns null) instead of
// skipping bad lines: a half-applied policy is indistinguishable from a
// truncated or corrupted file, and the backend's corruption response (loud
// boot message + shadow floor) must fire for those, not silently shrink
// the table. The truth table below is the stage gate: no backend wiring
// ships until every row passes.

pub const MAX_ENTRIES: usize = 16;
// 8.3 basename: 8 name chars + '.' + 3 extension chars.
pub const MAX_NAME: usize = 12;

pub const Entry = struct {
    name_buf: [MAX_NAME]u8,
    name_len: u8,
    mode: u32,
    uid: u32,
    gid: u32,

    pub fn name(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

// Parse the overlay text into `out`. Returns the entry count (0 for an
// empty or comment-only file — valid), or null on the first malformed
// line: missing field, 5th field, non-octal mode, mode above 0o777,
// non-decimal uid/gid, empty or over-long name, or more entries than
// `out` holds.
pub fn parse(content: []const u8, out: []Entry) ?usize {
    var count: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i != content.len and content[i] != '\n') continue;
        var line = content[line_start..i];
        line_start = i + 1;
        // CRLF tolerance: strip one trailing carriage return.
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;

        // Split into exactly 4 whitespace-separated fields.
        var fields: [4][]const u8 = undefined;
        var nf: usize = 0;
        var j: usize = 0;
        while (j < trimmed.len) {
            while (j < trimmed.len and isSpace(trimmed[j])) j += 1;
            if (j >= trimmed.len) break;
            const fstart = j;
            while (j < trimmed.len and !isSpace(trimmed[j])) j += 1;
            if (nf == 4) return null; // a 5th field is malformed
            fields[nf] = trimmed[fstart..j];
            nf += 1;
        }
        if (nf != 4) return null;

        const fname = fields[0];
        if (fname.len == 0 or fname.len > MAX_NAME) return null;
        const mode = parseOctalU32(fields[1]) orelse return null;
        if (mode > 0o777) return null;
        const uid = parseDecimalU32(fields[2]) orelse return null;
        const gid = parseDecimalU32(fields[3]) orelse return null;

        if (count == out.len) return null; // over capacity
        out[count] = .{
            .name_buf = undefined,
            .name_len = @intCast(fname.len),
            .mode = mode,
            .uid = uid,
            .gid = gid,
        };
        for (fname, 0..) |c, k| out[count].name_buf[k] = c;
        count += 1;
    }
    return count;
}

// Case-insensitive lookup of `name_in` among `entries` (pass the parsed
// prefix, e.g. table[0..count]). First match wins.
pub fn lookup(entries: []const Entry, name_in: []const u8) ?Entry {
    for (entries) |e| {
        if (nameEql(e.name(), name_in)) return e;
    }
    return null;
}

// FAT32 name equality: case-insensitive byte comparison (8.3 names are
// caseless). Public so the backend can apply the same rule to names that
// are not in the table (the shadow floor check).
pub fn nameEql(a: []const u8, b: []const u8) bool {
    return eqlIgnoreCase(a, b);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isSpace(s[start])) start += 1;
    while (end > start and isSpace(s[end - 1])) end -= 1;
    return s[start..end];
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (toLower(x) != toLower(y)) return false;
    }
    return true;
}

// Octal u32 parse, exact (digits 0-7 only, no 0o prefix, no sign).
fn parseOctalU32(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '7') return null;
        v = v * 8 + (c - '0');
        if (v > 0xFFFF_FFFF) return null;
    }
    return @intCast(v);
}

// Decimal u32 parse, exact (no sign, no whitespace).
fn parseDecimalU32(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
        if (v > 0xFFFF_FFFF) return null;
    }
    return @intCast(v);
}

// ---- Host tests ----
//
// The truth table below is the gate for the FAT32 overlay: the backend
// wiring (fat32_backend.applyOverlay / open lookup) does not ship until
// every row passes. Rows pin the format the seed file
// (user_space/etc/perms.tab) and the deploy/make_test_disk seeding use.
const std = @import("std");
const testing = std.testing;

test "parse: well-formed multi-line overlay" {
    var table: [MAX_ENTRIES]Entry = undefined;
    const content =
        "PERMS.TAB 0600 0 0\n" ++
        "SHADOW 0600 0 0\n" ++
        "ROUNDTR.DAT 0666 0 0\n";
    const n = parse(content, &table).?;
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("PERMS.TAB", table[0].name());
    try testing.expectEqual(@as(u32, 0o600), table[0].mode);
    try testing.expectEqual(@as(u32, 0), table[0].uid);
    try testing.expectEqual(@as(u32, 0), table[0].gid);
    try testing.expectEqualStrings("SHADOW", table[1].name());
    try testing.expectEqual(@as(u32, 0o666), table[2].mode);
}

test "parse: comments, blank lines, and surrounding whitespace are skipped" {
    var table: [MAX_ENTRIES]Entry = undefined;
    const content =
        "# FlashOS FAT32 permission overlay\n" ++
        "\n" ++
        "   \n" ++
        "  SHADOW   0600  0   0  \n" ++
        "# trailing comment\n";
    const n = parse(content, &table).?;
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("SHADOW", table[0].name());
}

test "parse: CRLF line endings are tolerated" {
    var table: [MAX_ENTRIES]Entry = undefined;
    const content = "SHADOW 0600 0 0\r\nPERMS.TAB 0600 0 0\r\n";
    const n = parse(content, &table).?;
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("SHADOW", table[0].name());
    try testing.expectEqualStrings("PERMS.TAB", table[1].name());
}

test "parse: no trailing newline on the last line still parses" {
    var table: [MAX_ENTRIES]Entry = undefined;
    const n = parse("SHADOW 0600 0 0", &table).?;
    try testing.expectEqual(@as(usize, 1), n);
}

test "parse: empty and comment-only files are valid with zero entries" {
    var table: [MAX_ENTRIES]Entry = undefined;
    try testing.expectEqual(@as(usize, 0), parse("", &table).?);
    try testing.expectEqual(@as(usize, 0), parse("# nothing here\n", &table).?);
}

test "parse: missing field rejects the whole overlay" {
    var table: [MAX_ENTRIES]Entry = undefined;
    try testing.expectEqual(@as(?usize, null), parse("SHADOW 0600 0\n", &table));
    try testing.expectEqual(@as(?usize, null), parse("SHADOW 0600\n", &table));
    try testing.expectEqual(@as(?usize, null), parse("SHADOW\n", &table));
}

test "parse: a 5th field rejects the whole overlay" {
    var table: [MAX_ENTRIES]Entry = undefined;
    try testing.expectEqual(@as(?usize, null), parse("SHADOW 0600 0 0 extra\n", &table));
}

test "parse: one malformed line rejects the whole overlay (no partial table)" {
    var table: [MAX_ENTRIES]Entry = undefined;
    const content =
        "SHADOW 0600 0 0\n" ++
        "PERMS.TAB 9999 0 0\n"; // 9 is not an octal digit
    try testing.expectEqual(@as(?usize, null), parse(content, &table));
}

test "parse: non-octal mode and mode above 0777 reject" {
    var table: [MAX_ENTRIES]Entry = undefined;
    try testing.expectEqual(@as(?usize, null), parse("SHADOW 08 0 0\n", &table));
    try testing.expectEqual(@as(?usize, null), parse("SHADOW abc 0 0\n", &table));
    try testing.expectEqual(@as(?usize, null), parse("SHADOW 1777 0 0\n", &table));
}

test "parse: non-decimal uid / gid rejects" {
    var table: [MAX_ENTRIES]Entry = undefined;
    try testing.expectEqual(@as(?usize, null), parse("SHADOW 0600 root 0\n", &table));
    try testing.expectEqual(@as(?usize, null), parse("SHADOW 0600 0 0x0\n", &table));
}

test "parse: empty or over-long name rejects" {
    var table: [MAX_ENTRIES]Entry = undefined;
    // 13 chars: one past the 8.3 maximum.
    try testing.expectEqual(@as(?usize, null), parse("ABCDEFGHI.TXT 0600 0 0\n", &table));
}

test "parse: more entries than the table holds rejects" {
    var small: [2]Entry = undefined;
    const content =
        "A 0600 0 0\n" ++
        "B 0600 0 0\n" ++
        "C 0600 0 0\n";
    try testing.expectEqual(@as(?usize, null), parse(content, &small));
}

test "lookup: case-insensitive hit and miss" {
    var table: [MAX_ENTRIES]Entry = undefined;
    const n = parse("SHADOW 0600 0 0\nPERMS.TAB 0600 0 0\n", &table).?;
    // The backend looks paths up by their lowercase /mnt basename.
    const hit = lookup(table[0..n], "shadow").?;
    try testing.expectEqual(@as(u32, 0o600), hit.mode);
    const hit2 = lookup(table[0..n], "perms.tab").?;
    try testing.expectEqualStrings("PERMS.TAB", hit2.name());
    try testing.expectEqual(@as(?Entry, null), lookup(table[0..n], "roundtr.dat"));
}

test "lookup: empty table always misses" {
    const empty: [0]Entry = .{};
    try testing.expectEqual(@as(?Entry, null), lookup(&empty, "shadow"));
}
