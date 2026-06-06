// flibc tab-completion core — the discovery half of FlashOS's shell-first
// navigation.
//
// fsh's line editor calls in here when the user presses TAB. The pure pieces
// live here and are host-tested:
//   * parse(line)          — decide what is being completed: the command (the
//                            first token) or a path argument (a later token),
//                            and split a path token into dir + basename prefix.
//   * hasPrefix / commonPrefixLen — the string folds the driver uses to filter
//                            candidates and shrink them to a shared extension.
// The candidate gathering itself (a sys_readdir walk over /bin or the path's
// directory, plus fsh's injected built-in names) is the SVC-driven half and
// lives in readline.zig behind its has_driver gate, so this file stays pure,
// allocator-free, and target-agnostic.

/// What a TAB is completing.
pub const Kind = enum {
    command, // the first token — match against /bin + the shell's built-ins
    path, // a later token — match against entries of `dir`
};

/// A parsed completion request. `dir` and `prefix` are slices into the caller's
/// line buffer (or static literals). For a command, `dir` is "" (the driver
/// searches /bin). For a path, `dir` is the directory portion — "" means the
/// cwd, "/" the root, "/bin" an absolute dir — and `prefix` the partial
/// basename to extend.
pub const Context = struct {
    kind: Kind,
    dir: []const u8,
    prefix: []const u8,
};

/// Parse the completion context from the current line. The token under
/// completion is the last whitespace-delimited run; if no earlier token
/// precedes it, it is a command, otherwise a path.
pub fn parse(line: []const u8) Context {
    // Start of the last token = one past the last space/tab.
    var tok_start: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == ' ' or line[i] == '\t') tok_start = i + 1;
    }
    // Is there a non-space byte before the token? (an earlier token exists)
    var earlier = false;
    var j: usize = 0;
    while (j < tok_start) : (j += 1) {
        if (line[j] != ' ' and line[j] != '\t') {
            earlier = true;
            break;
        }
    }
    const token = line[tok_start..];

    if (!earlier) return .{ .kind = .command, .dir = "", .prefix = token };

    // Path token: split at the last '/'.
    var slash: ?usize = null;
    var k: usize = 0;
    while (k < token.len) : (k += 1) {
        if (token[k] == '/') slash = k;
    }
    if (slash) |s| {
        const dir: []const u8 = if (s == 0) "/" else token[0..s];
        return .{ .kind = .path, .dir = dir, .prefix = token[s + 1 ..] };
    }
    return .{ .kind = .path, .dir = "", .prefix = token };
}

/// True when `name` starts with `prefix`.
pub fn hasPrefix(name: []const u8, prefix: []const u8) bool {
    if (name.len < prefix.len) return false;
    var i: usize = 0;
    while (i < prefix.len) : (i += 1) {
        if (name[i] != prefix[i]) return false;
    }
    return true;
}

/// Length of the longest common prefix of `a` and `b`.
pub fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const m = @min(a.len, b.len);
    var i: usize = 0;
    while (i < m and a[i] == b[i]) : (i += 1) {}
    return i;
}

// ---- host tests ------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "parse: a first token is a command" {
    const c = parse("ls");
    try testing.expectEqual(Kind.command, c.kind);
    try testing.expectEqualStrings("ls", c.prefix);
    try testing.expectEqualStrings("", c.dir);
}

test "parse: an empty line is an empty command" {
    const c = parse("");
    try testing.expectEqual(Kind.command, c.kind);
    try testing.expectEqualStrings("", c.prefix);
}

test "parse: a token after a space is a path in the cwd" {
    const c = parse("cat fo");
    try testing.expectEqual(Kind.path, c.kind);
    try testing.expectEqualStrings("", c.dir);
    try testing.expectEqualStrings("fo", c.prefix);
}

test "parse: an absolute path token splits dir and prefix" {
    const c = parse("cat /bin/l");
    try testing.expectEqual(Kind.path, c.kind);
    try testing.expectEqualStrings("/bin", c.dir);
    try testing.expectEqualStrings("l", c.prefix);
}

test "parse: a root-level path token keeps dir as /" {
    const c = parse("ls /b");
    try testing.expectEqual(Kind.path, c.kind);
    try testing.expectEqualStrings("/", c.dir);
    try testing.expectEqualStrings("b", c.prefix);
}

test "parse: a trailing slash yields an empty prefix" {
    const c = parse("ls /bin/");
    try testing.expectEqual(Kind.path, c.kind);
    try testing.expectEqualStrings("/bin", c.dir);
    try testing.expectEqualStrings("", c.prefix);
}

test "hasPrefix" {
    try testing.expect(hasPrefix("login", "lo"));
    try testing.expect(hasPrefix("ls", "ls"));
    try testing.expect(!hasPrefix("a", "ab"));
    try testing.expect(hasPrefix("anything", ""));
}

test "commonPrefixLen" {
    try testing.expectEqual(@as(usize, 3), commonPrefixLen("login", "logout")); // "log"
    try testing.expectEqual(@as(usize, 0), commonPrefixLen("a", "b"));
    try testing.expectEqual(@as(usize, 3), commonPrefixLen("cat", "cat"));
}
