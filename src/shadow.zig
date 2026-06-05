// shadow: /etc/shadow line parser + hex decoder.
//
// Pure, allocation-free, no externs. The kernel's sys_authenticate
// (src/sys.zig) reads /etc/shadow into a stack buffer and walks it line by
// line with these helpers; the host tests below pin the format so a
// consumer never drifts from the build-time generator (tools/gen_shadow.zig).
//
// Line format: `user:iterations:salt_hex:hash_hex`
//   * user        — login name (raw bytes, compared verbatim)
//   * iterations  — PBKDF2-HMAC-SHA256 round count, decimal
//   * salt_hex    — salt bytes, hex (even length, lower/upper)
//   * hash_hex    — derived key bytes, hex (even length)
//
// salt/hash stay hex in the Entry; the caller hexDecode()s them right next
// to the PBKDF2 call, so this module owns no buffers. There is deliberately
// NO uid field — uid/gid/shell live in /etc/passwd (parsed in userland by
// /bin/login); /etc/shadow holds only the verifier, mirroring real Unix.

pub const Entry = struct {
    user: []const u8,
    iterations: u32,
    salt_hex: []const u8,
    hash_hex: []const u8,
};

// Split one shadow line (no trailing newline — the caller slices on '\n')
// into its four fields. Returns null on a missing or empty field, a 5th
// `:`-delimited field, or a non-decimal / zero / overflowing iteration
// count.
pub fn parseLine(line: []const u8) ?Entry {
    const c1 = indexOf(line, ':') orelse return null;
    const user = line[0..c1];
    const rest1 = line[c1 + 1 ..];

    const c2 = indexOf(rest1, ':') orelse return null;
    const iters_s = rest1[0..c2];
    const rest2 = rest1[c2 + 1 ..];

    const c3 = indexOf(rest2, ':') orelse return null;
    const salt_hex = rest2[0..c3];
    const hash_hex = rest2[c3 + 1 ..];

    // A 5th field (another ':') is malformed.
    if (indexOf(hash_hex, ':') != null) return null;
    if (user.len == 0 or iters_s.len == 0 or salt_hex.len == 0 or hash_hex.len == 0) return null;

    const iterations = parseDecimalU32(iters_s) orelse return null;
    if (iterations == 0) return null;

    return .{
        .user = user,
        .iterations = iterations,
        .salt_hex = salt_hex,
        .hash_hex = hash_hex,
    };
}

// Decode `in` (hex, even length) into `out`. Returns the byte count, or
// null on odd length, a non-hex digit, or `out` too small.
pub fn hexDecode(in: []const u8, out: []u8) ?usize {
    if (in.len % 2 != 0) return null;
    const n = in.len / 2;
    if (out.len < n) return null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const hi = hexNibble(in[2 * i]) orelse return null;
        const lo = hexNibble(in[2 * i + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return n;
}

// Encode `in` bytes as lowercase hex into `out`. Returns the character
// count (2 × in.len), or null when `out` is too small. Inverse of
// hexDecode; sys_passwd uses it to serialize the fresh salt + derived
// key back into a shadow line.
pub fn hexEncode(in: []const u8, out: []u8) ?usize {
    if (out.len < in.len * 2) return null;
    const digits = "0123456789abcdef";
    for (in, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 0xF];
    }
    return in.len * 2;
}

// Byte span (start inclusive, end exclusive, newline excluded) of the
// shadow line whose user field equals `user`. Lines that fail parseLine
// are skipped, mirroring the lookup loop in sys_authenticate. Returns
// null when no line matches.
pub const LineSpan = struct { start: usize, end: usize };

pub fn findUserLine(content: []const u8, user: []const u8) ?LineSpan {
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i != content.len and content[i] != '\n') continue;
        const line = content[line_start..i];
        const span_start = line_start;
        line_start = i + 1;
        if (line.len == 0) continue;
        const e = parseLine(line) orelse continue;
        if (bytesEqual(e.user, user)) return .{ .start = span_start, .end = i };
    }
    return null;
}

// Rewrite `user`'s shadow line in place with a fresh salt + hash, keeping
// the iteration count. The same-length invariant is what makes the
// follow-up FAT32 write splice-safe: the iteration count is reused
// verbatim and salt/hash arrive as fixed-width hex, so the new line is
// byte-for-byte the same length as the old one and the file size never
// changes. Returns false when the user is absent, the old line does not
// parse, or the lengths diverge (e.g. a hand-edited shadow with a
// different salt width — refuse rather than corrupt).
pub fn rewriteLineInPlace(
    content: []u8,
    user: []const u8,
    new_salt_hex: []const u8,
    new_hash_hex: []const u8,
) bool {
    const span = findUserLine(content, user) orelse return false;
    const old = parseLine(content[span.start..span.end]) orelse return false;

    const new_len = user.len + 1 + decimalLen(old.iterations) + 1 + new_salt_hex.len + 1 + new_hash_hex.len;
    if (new_len != span.end - span.start) return false;

    var w: usize = span.start;
    for (user) |c| {
        content[w] = c;
        w += 1;
    }
    content[w] = ':';
    w += 1;
    w += writeDecimal(content[w..], old.iterations);
    content[w] = ':';
    w += 1;
    for (new_salt_hex) |c| {
        content[w] = c;
        w += 1;
    }
    content[w] = ':';
    w += 1;
    for (new_hash_hex) |c| {
        content[w] = c;
        w += 1;
    }
    return w == span.end;
}

fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

// Digit count of `v` in decimal (v == 0 -> 1).
fn decimalLen(v: u32) usize {
    var n: usize = 1;
    var x = v / 10;
    while (x != 0) : (x /= 10) n += 1;
    return n;
}

// Write `v` in decimal at out[0..]; returns the digit count. The caller
// guarantees capacity (rewriteLineInPlace checked the total length).
fn writeDecimal(out: []u8, v: u32) usize {
    const n = decimalLen(v);
    var x = v;
    var i = n;
    while (i > 0) {
        i -= 1;
        out[i] = '0' + @as(u8, @intCast(x % 10));
        x /= 10;
    }
    return n;
}

fn indexOf(haystack: []const u8, needle: u8) ?usize {
    for (haystack, 0..) |c, i| {
        if (c == needle) return i;
    }
    return null;
}

// Decimal u32 parse, exact (no sign, no whitespace). A u64 accumulator
// catches overflow past u32 without depending on std.math.
fn parseDecimalU32(s: []const u8) ?u32 {
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
        if (v > 0xFFFF_FFFF) return null;
    }
    return @intCast(v);
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ---- Host tests ----
const std = @import("std");

test "parseLine: well-formed line" {
    const e = parseLine("flash:4096:0011aabb:deadbeef").?;
    try std.testing.expectEqualStrings("flash", e.user);
    try std.testing.expectEqual(@as(u32, 4096), e.iterations);
    try std.testing.expectEqualStrings("0011aabb", e.salt_hex);
    try std.testing.expectEqualStrings("deadbeef", e.hash_hex);
}

test "parseLine: rejects missing fields" {
    try std.testing.expectEqual(@as(?Entry, null), parseLine("flash:4096:0011aabb"));
    try std.testing.expectEqual(@as(?Entry, null), parseLine("flash:4096"));
    try std.testing.expectEqual(@as(?Entry, null), parseLine("flash"));
    try std.testing.expectEqual(@as(?Entry, null), parseLine(""));
}

test "parseLine: rejects a 5th field" {
    try std.testing.expectEqual(@as(?Entry, null), parseLine("a:1:bb:cc:extra"));
}

test "parseLine: rejects empty user / non-decimal / zero iters" {
    try std.testing.expectEqual(@as(?Entry, null), parseLine(":4096:bb:cc"));
    try std.testing.expectEqual(@as(?Entry, null), parseLine("flash:40x6:bb:cc"));
    try std.testing.expectEqual(@as(?Entry, null), parseLine("flash:0:bb:cc"));
}

test "parseLine: rejects iteration overflow past u32" {
    try std.testing.expectEqual(@as(?Entry, null), parseLine("flash:99999999999:bb:cc"));
}

test "hexDecode: round-trips bytes" {
    var out: [4]u8 = undefined;
    const n = hexDecode("0011aabb", &out).?;
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x11, 0xAA, 0xBB }, out[0..n]);
}

test "hexDecode: accepts uppercase" {
    var out: [2]u8 = undefined;
    const n = hexDecode("DEAD", &out).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD }, out[0..n]);
}

test "hexDecode: rejects odd length / bad digit / small out" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), hexDecode("abc", &out));
    try std.testing.expectEqual(@as(?usize, null), hexDecode("zz", &out));
    var small: [1]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), hexDecode("aabb", &small));
}

test "hexEncode: lowercase round-trip with hexDecode" {
    const bytes = [_]u8{ 0x00, 0x11, 0xAA, 0xBB, 0xDE, 0xAD };
    var hex: [12]u8 = undefined;
    const n = hexEncode(&bytes, &hex).?;
    try std.testing.expectEqual(@as(usize, 12), n);
    try std.testing.expectEqualStrings("0011aabbdead", hex[0..n]);

    var back: [6]u8 = undefined;
    const m = hexDecode(hex[0..n], &back).?;
    try std.testing.expectEqualSlices(u8, &bytes, back[0..m]);
}

test "hexEncode: rejects an undersized output buffer" {
    const bytes = [_]u8{ 0x01, 0x02 };
    var small: [3]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), hexEncode(&bytes, &small));
}

// Two-line fixture mirroring the gen_shadow output shape: 16-byte salts
// (32 hex chars) and 32-byte derived keys (64 hex chars).
const REWRITE_FIXTURE =
    "root:4096:" ++ ("aa" ** 16) ++ ":" ++ ("bb" ** 32) ++ "\n" ++
    "flash:4096:" ++ ("cc" ** 16) ++ ":" ++ ("dd" ** 32) ++ "\n";

test "findUserLine: locates first, last, and absent users" {
    const root_span = findUserLine(REWRITE_FIXTURE, "root").?;
    try std.testing.expectEqual(@as(usize, 0), root_span.start);
    const root_line = REWRITE_FIXTURE[root_span.start..root_span.end];
    try std.testing.expectEqualStrings("root", parseLine(root_line).?.user);

    const flash_span = findUserLine(REWRITE_FIXTURE, "flash").?;
    const flash_line = REWRITE_FIXTURE[flash_span.start..flash_span.end];
    try std.testing.expectEqualStrings("flash", parseLine(flash_line).?.user);
    // The span excludes the trailing newline.
    try std.testing.expectEqual(@as(u8, '\n'), REWRITE_FIXTURE[flash_span.end]);

    try std.testing.expectEqual(@as(?LineSpan, null), findUserLine(REWRITE_FIXTURE, "anton"));
    // A prefix of an existing user must not match.
    try std.testing.expectEqual(@as(?LineSpan, null), findUserLine(REWRITE_FIXTURE, "fla"));
}

test "findUserLine: works without a trailing newline on the last line" {
    const fixture = "root:4096:" ++ ("aa" ** 16) ++ ":" ++ ("bb" ** 32);
    const span = findUserLine(fixture, "root").?;
    try std.testing.expectEqual(fixture.len, span.end);
}

test "rewriteLineInPlace: same-length rewrite keeps neighbours and size intact" {
    var buf: [REWRITE_FIXTURE.len]u8 = undefined;
    @memcpy(&buf, REWRITE_FIXTURE);

    const new_salt = "0123456789abcdef0123456789abcdef"; // 32 hex chars
    const new_hash = "f0" ** 32; // 64 hex chars
    try std.testing.expect(rewriteLineInPlace(&buf, "flash", new_salt, new_hash));

    // The flash line carries the new salt + hash and still parses.
    const span = findUserLine(&buf, "flash").?;
    const e = parseLine(buf[span.start..span.end]).?;
    try std.testing.expectEqual(@as(u32, 4096), e.iterations);
    try std.testing.expectEqualStrings(new_salt, e.salt_hex);
    try std.testing.expectEqualStrings(new_hash, e.hash_hex);

    // The root line is byte-identical (no bleed across the rewrite).
    const root_span = findUserLine(&buf, "root").?;
    try std.testing.expectEqualStrings(
        REWRITE_FIXTURE[root_span.start..root_span.end],
        buf[root_span.start..root_span.end],
    );
    // Total content length is unchanged by construction (in-place).
}

test "rewriteLineInPlace: round-trips through PBKDF2-style fresh values twice" {
    // Two consecutive rewrites (the [TEST] passwd change + restore shape)
    // keep the file stable: same length, both parseable, order preserved.
    var buf: [REWRITE_FIXTURE.len]u8 = undefined;
    @memcpy(&buf, REWRITE_FIXTURE);

    try std.testing.expect(rewriteLineInPlace(&buf, "flash", "11" ** 16, "22" ** 32));
    try std.testing.expect(rewriteLineInPlace(&buf, "flash", "cc" ** 16, "dd" ** 32));
    try std.testing.expectEqualStrings(REWRITE_FIXTURE, &buf);
}

test "rewriteLineInPlace: refuses absent user and diverging lengths" {
    var buf: [REWRITE_FIXTURE.len]u8 = undefined;
    @memcpy(&buf, REWRITE_FIXTURE);

    // Absent user.
    try std.testing.expect(!rewriteLineInPlace(&buf, "anton", "aa" ** 16, "bb" ** 32));
    // Shorter salt (8 bytes hex = 16 chars) would shrink the line — refused.
    try std.testing.expect(!rewriteLineInPlace(&buf, "flash", "aa" ** 8, "bb" ** 32));
    // Longer hash would grow the line — refused.
    try std.testing.expect(!rewriteLineInPlace(&buf, "flash", "aa" ** 16, "bb" ** 33));
    // The refusals left the content untouched.
    try std.testing.expectEqualStrings(REWRITE_FIXTURE, &buf);
}
