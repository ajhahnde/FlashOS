// flibc execvp — bare-name resolver over sys.exec_path.
//
// Linux's execvp consults $PATH; FlashOS has no environment yet, so
// a single search prefix is hard-wired: a bare name `foo` resolves to
// `/bin/foo`. A name that already contains a slash (absolute
// `/usr/bin/foo` or relative `tools/foo`) skips the prefix and is
// handed to `sys.exec_path` verbatim — the kernel joins relative paths
// against the task's `cwd` (slot 36).
//
// Layout mirrors readline.zig: the pure `resolve(name, out)` path-build
// lives at the top with host tests at the bottom of the file; the
// SVC-driving `execvp(name, argv)` driver sits behind an
// `if (has_driver)` struct-select so the host build never analyses the
// inline asm in syscalls.zig. The host fallback returns -1; only the
// aarch64-freestanding target sees the real `sys.exec_path` call.
//
// Path budget: PATH_MAX = 256 matches sys_chdir's CWD_SIZE and is the
// stack buffer fsh hands in. The resolver returns null on overflow
// (rule 1 — no realloc) so callers surface a clean -1 instead of
// truncating into a wrong binary.

const builtin = @import("builtin");

// Driver compiles only on aarch64-freestanding. Same gating idiom as
// readline.zig — the host-test build picks the empty branch so the
// SVC trampolines never reach semantic analysis.
const has_driver = builtin.cpu.arch == .aarch64 and builtin.target.os.tag == .freestanding;

/// Maximum resolved path length the driver hands to sys.exec_path. Sized
/// to match the kernel's `cwd` budget (CWD_SIZE = 256) — the kernel can
/// already handle paths up to that ceiling, so widening here would only
/// invite a later kernel-side rejection.
pub const PATH_MAX: usize = 256;

const BIN_PREFIX = "/bin/";

/// Resolve a program name into an absolute (or already-slashed) path
/// laid out in `out`. Returns a sentinel-terminated slice into `out`
/// suitable for `sys.exec_path`. Rules:
///   * empty `name`           → null
///   * `name` contains '/'    → copy verbatim + NUL into `out` (lets
///                              the kernel handle absolute / relative
///                              resolution against `cwd`)
///   * bare `name`            → `/bin/` + name + NUL
///   * `out` too small for    → null (caller gets -1 rather than a
///     prefix + name + NUL      silently truncated binary path)
///
/// Pure: no syscalls, no allocator. Exercised in isolation by the host
/// suite — see the `test` blocks at the bottom of this file.
pub fn resolve(name: []const u8, out: []u8) ?[:0]u8 {
    if (name.len == 0) return null;

    var has_slash = false;
    for (name) |c| {
        if (c == '/') {
            has_slash = true;
            break;
        }
    }

    if (has_slash) {
        if (name.len + 1 > out.len) return null;
        @memcpy(out[0..name.len], name);
        out[name.len] = 0;
        return out[0..name.len :0];
    }

    const total = BIN_PREFIX.len + name.len;
    if (total + 1 > out.len) return null;
    @memcpy(out[0..BIN_PREFIX.len], BIN_PREFIX);
    @memcpy(out[BIN_PREFIX.len..][0..name.len], name);
    out[total] = 0;
    return out[0..total :0];
}

/// Resolve `name` (bare → `/bin/<name>`; slashed → verbatim) and exec
/// the result. Returns -1 on resolve failure (empty / oversize) or
/// whatever `sys.exec_path` returns; on success the syscall does not
/// return.
pub const execvp = driver.execvp;

const driver = if (has_driver) struct {
    const sys = @import("syscalls.zig");

    pub fn execvp(name: [*:0]const u8, argv: [*]const ?[*:0]const u8) i32 {
        var path_buf: [PATH_MAX]u8 = undefined;
        var n: usize = 0;
        while (name[n] != 0) : (n += 1) {}
        const resolved = resolve(name[0..n], &path_buf) orelse return -1;
        return sys.exec_path(@ptrCast(resolved.ptr), argv);
    }
} else struct {
    // Host-test stub: never invoked from tests, present only so the
    // `pub const execvp = driver.execvp` binding type-checks on host.
    pub fn execvp(_: [*:0]const u8, _: [*]const ?[*:0]const u8) i32 {
        return -1;
    }
};

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;

test "resolve: bare name maps to /bin/<name>" {
    var buf: [64]u8 = undefined;
    const r = resolve("fsh", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/bin/fsh", r);
    try testing.expectEqual(@as(u8, 0), buf[r.len]);
}

test "resolve: single-char bare name" {
    var buf: [16]u8 = undefined;
    const r = resolve("x", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/bin/x", r);
}

test "resolve: absolute path passes through verbatim" {
    var buf: [64]u8 = undefined;
    const r = resolve("/usr/local/bin/foo", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/usr/local/bin/foo", r);
    try testing.expectEqual(@as(u8, 0), buf[r.len]);
}

test "resolve: relative path with slash passes through" {
    var buf: [64]u8 = undefined;
    const r = resolve("tools/foo", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("tools/foo", r);
}

test "resolve: leading '/' bypasses prefix even with no further slash" {
    var buf: [32]u8 = undefined;
    const r = resolve("/foo", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/foo", r);
}

test "resolve: empty name returns null" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(?[:0]u8, null), resolve("", &buf));
}

test "resolve: oversize bare name returns null" {
    var tiny: [4]u8 = undefined; // /bin/x = 6 chars + NUL = 7 > 4
    try testing.expectEqual(@as(?[:0]u8, null), resolve("foo", &tiny));
}

test "resolve: oversize passthrough returns null" {
    var tiny: [4]u8 = undefined;
    try testing.expectEqual(@as(?[:0]u8, null), resolve("/abcd", &tiny));
}

test "resolve: exact-fit bare name succeeds" {
    // "/bin/x" = 6 bytes, NUL = 7 → buffer of 7 fits
    var buf: [7]u8 = undefined;
    const r = resolve("x", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/bin/x", r);
    try testing.expectEqual(@as(u8, 0), buf[6]);
}

test "resolve: one-byte-short bare name returns null" {
    var buf: [6]u8 = undefined; // /bin/x needs 7 with NUL
    try testing.expectEqual(@as(?[:0]u8, null), resolve("x", &buf));
}

test "resolve: exact-fit passthrough succeeds" {
    var buf: [5]u8 = undefined; // "/foo" = 4 + NUL = 5
    const r = resolve("/foo", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/foo", r);
    try testing.expectEqual(@as(u8, 0), buf[4]);
}

test "resolve: bare name in PATH_MAX-sized buffer" {
    var buf: [PATH_MAX]u8 = undefined;
    const r = resolve("cat", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/bin/cat", r);
}

test "resolve: slash mid-name treated as path" {
    var buf: [32]u8 = undefined;
    const r = resolve("a/b", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("a/b", r);
}
