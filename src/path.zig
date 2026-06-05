// path: pure path-resolution helpers.
//
// The kernel keeps its VFS resolver absolute-only (vfs.resolve in
// src/vfs.zig). Per-task `cwd` (task_layout.TaskStruct.cwd) lives one
// abstraction layer above — sys_chdir stores into it, and sys_openFile
// / execveKernel join relative paths against it at the syscall
// boundary before handing the absolute result to vfs.resolve.
//
// joinResolve is the single non-recursive `.` / `..` collapse used
// for both store (sys_chdir) and resolve (open/execve). Pure: no
// allocator, no externs, no kernel imports — exercised in isolation
// by the host suite (see the tests at the bottom of this file).
//
// Sibling-import only — no named module needed for path.zig itself.
// build.zig wires the comptime-pure source for both the kernel and
// host builds; consumers that name this file as a named import
// (`sys.zig`, `execve.zig`) reach it through the `path` module wired
// in build.zig.

const std = @import("std");

// Maximum nesting depth the component stack can hold. 64 components is
// well above the working set (paths like `/bin/fsh` or
// `/etc/fshrc` have one or two components); a pathological caller
// gets a clean null instead of writing past the stack.
const MAX_DEPTH: usize = 64;

// Working buffer for the (cwd + "/" + rel) composition before the
// single-pass collapse. 512 bytes covers a 256-byte cwd plus a
// 255-byte relative tail with room for the joiner slash, which is the
// ceiling sys_chdir's user-side copy enforces.
const WORK_MAX: usize = 512;

// joinResolve: normalise `rel` against `cwd` into `out`. Returns a
// slice of `out` containing the absolute path with `.` / `..` /
// duplicate-slash segments collapsed. `out` must be large enough to
// hold the final result; returns null on:
//   * `rel` already absolute (leading '/') AND longer than WORK_MAX
//   * cwd + '/' + rel longer than WORK_MAX
//   * resolved length wouldn't fit in `out`
//   * deeper than MAX_DEPTH components after collapse
//
// `cwd` is treated as an absolute base; an empty `cwd` resolves to
// "/" (defensive — callers should pass at least "/"). A leading '/'
// in `rel` bypasses cwd entirely (still gets collapsed). Trailing
// slashes are dropped. The empty resolved path is normalised to "/"
// so callers can blindly hand the result to vfs.resolve.
pub fn joinResolve(cwd: []const u8, rel: []const u8, out: []u8) ?[]const u8 {
    var work: [WORK_MAX]u8 = undefined;
    var work_len: usize = 0;

    if (rel.len > 0 and rel[0] == '/') {
        if (rel.len > WORK_MAX) return null;
        @memcpy(work[0..rel.len], rel);
        work_len = rel.len;
    } else {
        // Anchor on cwd; "" → "/" (defensive). Always emit a slash
        // separator before splicing in `rel` — the collapse below
        // treats repeated slashes as a single boundary.
        if (cwd.len == 0) {
            if (work_len + 1 > WORK_MAX) return null;
            work[work_len] = '/';
            work_len += 1;
        } else {
            if (cwd.len > WORK_MAX) return null;
            @memcpy(work[0..cwd.len], cwd);
            work_len = cwd.len;
        }
        if (work_len == 0 or work[work_len - 1] != '/') {
            if (work_len + 1 > WORK_MAX) return null;
            work[work_len] = '/';
            work_len += 1;
        }
        if (work_len + rel.len > WORK_MAX) return null;
        @memcpy(work[work_len..][0..rel.len], rel);
        work_len += rel.len;
    }

    // Component stack: each entry is the byte offset in `out` where
    // the leading '/' of that component begins. Popping `..` restores
    // out_len to the stored offset, which discards the just-pushed
    // path segment in a single assignment.
    var stack: [MAX_DEPTH]usize = undefined;
    var depth: usize = 0;
    var out_len: usize = 0;

    var i: usize = 0;
    while (i < work_len) {
        // Skip any run of slashes (folds "//" + leading "/").
        while (i < work_len and work[i] == '/') i += 1;
        if (i >= work_len) break;
        var j = i;
        while (j < work_len and work[j] != '/') j += 1;
        const comp = work[i..j];
        i = j;

        if (comp.len == 1 and comp[0] == '.') {
            // Skip a "." segment.
        } else if (comp.len == 2 and comp[0] == '.' and comp[1] == '.') {
            if (depth > 0) {
                depth -= 1;
                out_len = stack[depth];
            }
            // ".." past root is a no-op (stays at "/").
        } else {
            if (depth >= MAX_DEPTH) return null;
            if (out_len + 1 + comp.len > out.len) return null;
            stack[depth] = out_len;
            depth += 1;
            out[out_len] = '/';
            out_len += 1;
            @memcpy(out[out_len..][0..comp.len], comp);
            out_len += comp.len;
        }
    }

    if (out_len == 0) {
        if (out.len < 1) return null;
        out[0] = '/';
        out_len = 1;
    }
    return out[0..out_len];
}

// ---- Host tests ----

const testing = std.testing;

test "joinResolve: relative against root" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("/", "bin/fsh", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/bin/fsh", r);
}

test "joinResolve: relative against non-root cwd" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("/etc", "fshrc", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/etc/fshrc", r);
}

test "joinResolve: absolute rel bypasses cwd" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("/etc", "/bin/fsh", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/bin/fsh", r);
}

test "joinResolve: dot segments are dropped" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("/usr", "./local/./bin", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/usr/local/bin", r);
}

test "joinResolve: parent collapses one component" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("/usr/local/bin", "../lib", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/usr/local/lib", r);
}

test "joinResolve: mid-path .. collapses correctly" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("/", "a/./b/../c", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/a/c", r);
}

test "joinResolve: .. past root stays at root" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("/", "../../foo", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/foo", r);
}

test "joinResolve: bare .. from root is root" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("/", "..", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/", r);
}

test "joinResolve: double slashes fold" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("/foo", "//bar//baz", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/bar/baz", r);
}

test "joinResolve: empty rel resolves to cwd" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("/etc", "", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/etc", r);
}

test "joinResolve: trailing slash dropped" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("/", "etc/", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/etc", r);
}

test "joinResolve: dot-only rel resolves to cwd" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("/var/log", ".", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/var/log", r);
}

test "joinResolve: collapse to root when popping everything" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("/a/b", "../..", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/", r);
}

test "joinResolve: out-buffer overflow returns null" {
    var tiny: [4]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), joinResolve("/", "abcdefg", &tiny));
}

test "joinResolve: oversize composition returns null" {
    var buf: [4096]u8 = undefined;
    const long_rel: [WORK_MAX + 1]u8 = .{'x'} ** (WORK_MAX + 1);
    try testing.expectEqual(@as(?[]const u8, null), joinResolve("/", long_rel[0..], &buf));
}

test "joinResolve: empty cwd resolves under root" {
    var buf: [128]u8 = undefined;
    const r = joinResolve("", "foo", &buf) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/foo", r);
}
