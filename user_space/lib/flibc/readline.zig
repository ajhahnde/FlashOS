// flibc readline — raw line editor over fd 0.
//
// The kernel console stays "dumb" — no termios, no cooked mode,
// sys_setConsoleMode is inert (a future PTY concern). All line editing
// lives here in userland: a per-byte state machine reads via
// sys_read(0, &b, 1), echoes printable bytes through sys_write(1, …),
// and submits on CR/LF. The caller owns the line buffer (rule 1 — no
// allocator); overflow truncates silently.
//
// Layout:
//   * `State` + `Action` + `step` — the pure byte → buffer transition.
//     Host-tested (see the `test` blocks at the bottom of this file).
//   * `Outcome` — the public driver return type (`line` / `eof` /
//     `abandoned`). Callers (fsh) treat `eof` as logout and `abandoned`
//     as "redraw prompt, drop input".
//   * `readline(buf)` — the SVC-driven driver. Gated through an
//     `if (has_driver)`-selected anonymous struct so the host-test
//     build never analyses the inline-asm body. The host fallback
//     returns `.eof`; only the aarch64-freestanding target sees the
//     real loop.
//
// Editing rules (single-line; no history / no escape sequences):
//   * 0x20..0x7e (printable)  — push to buffer + echo back. Overflow
//     truncates: byte dropped, no echo.
//   * 0x08 / 0x7f (BS / DEL)  — pop one byte if non-empty and emit
//     "\x08 \x08" so the rubout column blanks; no-op on empty buffer.
//   * '\r' or '\n'            — submit; returns the slice as Outcome.line.
//   * 0x04 (^D) on empty line — EOF (caller exits the REPL).
//   * 0x04 (^D) mid-line      — ignored (matches conservative shells).
//   * 0x03 (^C)               — abandon; caller drops the buffer and
//     prints a fresh prompt. No echo (fsh draws the newline).
//   * 0x09 (TAB)              — request completion. readlineCompleting acts on
//     it (extend the token against /bin + builtins, or a path dir); plain
//     readline ignores it.
//   * Anything else           — ignored.

const builtin = @import("builtin");

// Driver compiles only on aarch64-freestanding (the actual flibc target).
// The host-test build flips this off so the SVC trampolines never enter
// semantic analysis; only the pure state machine is exercised there.
const has_driver = builtin.cpu.arch == .aarch64 and builtin.target.os.tag == .freestanding;

/// Line editor state. `buf` is the caller-provided fixed-size buffer
/// (rule 1 — no realloc); `len` is the live cursor / committed-byte
/// count. Submission yields `buf[0..len]`.
pub const State = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) State {
        return .{ .buf = buf };
    }

    pub fn slice(self: *const State) []const u8 {
        return self.buf[0..self.len];
    }
};

/// What the driver should do with a byte after `step` runs. Pure data —
/// the driver translates this into sys_write_fd / return calls; tests
/// inspect it directly.
pub const Action = union(enum) {
    /// Byte consumed silently (overflow drop, ignored control char,
    /// ^D mid-line, or BS on empty buffer).
    none,
    /// Byte accepted into the buffer; echo this byte to fd 1.
    echo: u8,
    /// One byte was popped; emit the standard "\x08 \x08" rubout.
    backspace,
    /// TAB — request completion of the current token. The completing driver
    /// extends the buffer in place; plain readline ignores it.
    complete,
    /// Line is complete; driver should return the buffered slice.
    submit,
    /// ^D on an empty line — driver returns Outcome.eof.
    eof,
    /// ^C — driver returns Outcome.abandoned; no echo (caller redraws).
    abandon,
};

/// Driver outcome for a full `readline` call.
pub const Outcome = union(enum) {
    /// Submitted line; slice points into the caller-provided buffer.
    line: []const u8,
    /// Stream EOF — ^D on an empty line, or sys_read returned <= 0.
    eof,
    /// User cancelled the line (^C). Caller drops the buffer.
    abandoned,
};

/// One-byte state transition. Pure: no syscalls, no allocator.
pub fn step(state: *State, byte: u8) Action {
    return switch (byte) {
        '\r', '\n' => .submit,
        0x03 => .abandon,
        0x04 => if (state.len == 0) Action.eof else Action.none,
        0x09 => .complete,
        0x08, 0x7f => blk: {
            if (state.len == 0) break :blk Action.none;
            state.len -= 1;
            break :blk Action.backspace;
        },
        0x20...0x7e => blk: {
            if (state.len >= state.buf.len) break :blk Action.none;
            state.buf[state.len] = byte;
            state.len += 1;
            break :blk Action{ .echo = byte };
        },
        else => .none,
    };
}

/// Read a line interactively from fd 0. Blocks until the editor returns
/// a terminal action (submit / eof / abandon) or sys_read fails. The
/// returned `Outcome.line` slice lives in `buf` and is valid until the
/// next call that reuses `buf`. Plain readline ignores TAB.
pub const readline = driver.readline;

/// Like `readline`, but TAB completes the current token against `comp`: the
/// first token against `comp.bin_dir` + `comp.builtins`, a later token as a
/// filesystem path. The buffer is extended in place + echoed; a unique match
/// also appends a trailing ' ' (command / file) or '/' (directory).
pub fn readlineCompleting(buf: []u8, comp: Completion) Outcome {
    return driver.readlineCompleting(buf, comp);
}

/// Completion policy for `readlineCompleting`. `builtins` are extra command
/// names offered for the first token (a shell's in-process built-ins, which are
/// absent from /bin); `bin_dir` is the directory searched for command
/// completion. Path completion needs no policy — it reads the dir named in the
/// token itself.
pub const Completion = struct {
    builtins: []const []const u8 = &.{},
    bin_dir: [*:0]const u8 = "/bin",
};

const driver = if (has_driver) struct {
    const sys = @import("syscalls.zig");
    const completion = @import("completion.zig");
    const defs = @import("syscall_defs");

    pub fn readline(buf: []u8) Outcome {
        var state = State.init(buf);
        var byte: u8 = 0;
        while (true) {
            const n = sys.read(0, @ptrCast(&byte), 1);
            if (n <= 0) return .eof;
            switch (step(&state, byte)) {
                .none => {},
                .echo => |b| echoByte(b),
                .backspace => emitRubout(),
                .complete => {}, // no policy → TAB ignored
                .submit => return .{ .line = state.slice() },
                .eof => return .eof,
                .abandon => return .abandoned,
            }
        }
    }

    pub fn readlineCompleting(buf: []u8, comp: Completion) Outcome {
        var state = State.init(buf);
        var byte: u8 = 0;
        while (true) {
            const n = sys.read(0, @ptrCast(&byte), 1);
            if (n <= 0) return .eof;
            switch (step(&state, byte)) {
                .none => {},
                .echo => |b| echoByte(b),
                .backspace => emitRubout(),
                .complete => doComplete(&state, comp),
                .submit => return .{ .line = state.slice() },
                .eof => return .eof,
                .abandon => return .abandoned,
            }
        }
    }

    fn echoByte(b: u8) void {
        var out = b;
        _ = sys.write_fd(1, @ptrCast(&out), 1);
    }

    fn emitRubout() void {
        const seq = "\x08 \x08";
        _ = sys.write_fd(1, seq.ptr, seq.len);
    }

    // On TAB: gather candidates that extend the current token, append the
    // longest common extension to the buffer + echo it. A unique match also
    // gets a trailing ' ' (command / file) or '/' (directory). Ambiguous or
    // empty matches do nothing (classic single-tab behaviour). All buffers are
    // stack-local (rule 1); the running common prefix is copied out of the
    // reused Dirent so it stays valid across the readdir walk.
    fn doComplete(state: *State, comp: Completion) void {
        const ctx = completion.parse(state.slice());

        // Directory to enumerate, NUL-terminated for sys.readdir.
        var dirbuf: [128]u8 = undefined;
        const dirz: [*:0]const u8 = switch (ctx.kind) {
            .command => comp.bin_dir,
            .path => blk: {
                const d = if (ctx.dir.len == 0) "." else ctx.dir;
                if (d.len >= dirbuf.len) return;
                var i: usize = 0;
                while (i < d.len) : (i += 1) dirbuf[i] = d[i];
                dirbuf[d.len] = 0;
                break :blk @ptrCast(&dirbuf);
            },
        };

        var best: [32]u8 = undefined;
        var best_len: usize = 0;
        var count: usize = 0;
        var only_is_dir = false;

        // Built-ins participate in command completion only.
        if (ctx.kind == .command) {
            for (comp.builtins) |name| {
                if (!completion.hasPrefix(name, ctx.prefix)) continue;
                fold(&best, &best_len, &count, name);
            }
        }

        var d: defs.Dirent = .{};
        var idx: u64 = 0;
        while (sys.readdir(dirz, idx, &d) == 0) : (idx += 1) {
            var nl: usize = 0;
            while (nl < d.name.len and d.name[nl] != 0) : (nl += 1) {}
            const name = d.name[0..nl];
            if (!completion.hasPrefix(name, ctx.prefix)) continue;
            const before = count;
            fold(&best, &best_len, &count, name);
            if (before == 0 and count == 1) only_is_dir = (d.d_type == defs.DT_DIR);
        }

        if (count == 0 or best_len <= ctx.prefix.len) return;

        emitAppend(state, best[ctx.prefix.len..best_len]);
        if (count == 1) emitAppend(state, if (only_is_dir) "/" else " ");
    }

    // Fold one candidate into the running longest-common-prefix `best`.
    fn fold(best: *[32]u8, best_len: *usize, count: *usize, name: []const u8) void {
        if (count.* == 0) {
            const n = @min(name.len, best.len);
            var i: usize = 0;
            while (i < n) : (i += 1) best[i] = name[i];
            best_len.* = n;
        } else {
            best_len.* = completion.commonPrefixLen(best[0..best_len.*], name);
        }
        count.* += 1;
    }

    // Append `ext` to the live buffer (respecting capacity) and echo each byte.
    fn emitAppend(state: *State, ext: []const u8) void {
        for (ext) |c| {
            if (state.len >= state.buf.len) return;
            state.buf[state.len] = c;
            state.len += 1;
            echoByte(c);
        }
    }
} else struct {
    // Host-test stubs: never invoked from tests, present only so the public
    // bindings resolve on host (the pure step / completion cores are what the
    // host suite exercises).
    pub fn readline(_: []u8) Outcome {
        return .eof;
    }
    pub fn readlineCompleting(_: []u8, _: Completion) Outcome {
        return .eof;
    }
};

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;

test "step: printable byte echoes and pushes" {
    var buf: [16]u8 = undefined;
    var s = State.init(&buf);
    const a = step(&s, 'a');
    try testing.expectEqual(Action{ .echo = 'a' }, a);
    try testing.expectEqual(@as(usize, 1), s.len);
    try testing.expectEqualStrings("a", s.slice());
}

test "step: full printable run builds buffered line" {
    var buf: [16]u8 = undefined;
    var s = State.init(&buf);
    for ("hello") |c| _ = step(&s, c);
    try testing.expectEqualStrings("hello", s.slice());
}

test "step: BS on empty buffer is a no-op" {
    var buf: [16]u8 = undefined;
    var s = State.init(&buf);
    try testing.expectEqual(Action.none, step(&s, 0x08));
    try testing.expectEqual(@as(usize, 0), s.len);
}

test "step: BS pops one byte and requests rubout" {
    var buf: [16]u8 = undefined;
    var s = State.init(&buf);
    _ = step(&s, 'a');
    _ = step(&s, 'b');
    const a = step(&s, 0x08);
    try testing.expectEqual(Action.backspace, a);
    try testing.expectEqualStrings("a", s.slice());
}

test "step: DEL (0x7f) behaves the same as BS" {
    var buf: [16]u8 = undefined;
    var s = State.init(&buf);
    _ = step(&s, 'x');
    const a = step(&s, 0x7f);
    try testing.expectEqual(Action.backspace, a);
    try testing.expectEqual(@as(usize, 0), s.len);
}

test "step: CR submits the line" {
    var buf: [16]u8 = undefined;
    var s = State.init(&buf);
    _ = step(&s, 'h');
    _ = step(&s, 'i');
    try testing.expectEqual(Action.submit, step(&s, '\r'));
    try testing.expectEqualStrings("hi", s.slice());
}

test "step: LF also submits" {
    var buf: [16]u8 = undefined;
    var s = State.init(&buf);
    _ = step(&s, 'a');
    try testing.expectEqual(Action.submit, step(&s, '\n'));
}

test "step: ^D on empty buffer is EOF" {
    var buf: [16]u8 = undefined;
    var s = State.init(&buf);
    try testing.expectEqual(Action.eof, step(&s, 0x04));
}

test "step: ^D mid-line is ignored" {
    var buf: [16]u8 = undefined;
    var s = State.init(&buf);
    _ = step(&s, 'a');
    try testing.expectEqual(Action.none, step(&s, 0x04));
    try testing.expectEqualStrings("a", s.slice());
}

test "step: ^C abandons regardless of buffer state" {
    var buf: [16]u8 = undefined;
    var s = State.init(&buf);
    try testing.expectEqual(Action.abandon, step(&s, 0x03));
    _ = step(&s, 'x');
    try testing.expectEqual(Action.abandon, step(&s, 0x03));
}

test "step: TAB requests completion" {
    var buf: [16]u8 = undefined;
    var s = State.init(&buf);
    _ = step(&s, 'l');
    try testing.expectEqual(Action.complete, step(&s, 0x09));
}

test "step: overflow drops the byte and emits no echo" {
    var buf: [3]u8 = undefined;
    var s = State.init(&buf);
    _ = step(&s, 'a');
    _ = step(&s, 'b');
    _ = step(&s, 'c');
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqual(Action.none, step(&s, 'd'));
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqualStrings("abc", s.slice());
}

test "step: BS after overflow truncate clears the most recent kept byte" {
    var buf: [2]u8 = undefined;
    var s = State.init(&buf);
    _ = step(&s, 'a');
    _ = step(&s, 'b');
    _ = step(&s, 'c'); // dropped
    try testing.expectEqual(Action.backspace, step(&s, 0x08));
    try testing.expectEqualStrings("a", s.slice());
}

test "step: other control bytes are ignored" {
    var buf: [16]u8 = undefined;
    var s = State.init(&buf);
    for ([_]u8{ 0x00, 0x01, 0x07, 0x1b, 0x1f, 0x80, 0xff }) |c| {
        try testing.expectEqual(Action.none, step(&s, c));
    }
    try testing.expectEqual(@as(usize, 0), s.len);
}
