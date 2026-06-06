// flibc key decoder — raw console bytes → semantic Key events.
//
// The input half of FlashOS's shell-first navigation (the full-screen tools).
// A full-screen tool puts the console in mode 0 (raw: kernel echo off,
// byte-at-a-time — the same mode /bin/login's password loop relies on) and
// calls readKey() in a loop until it returns .eof. The pure Decoder turns a
// byte stream — including the multi-byte ESC-[ A/B/C/D arrow sequences — into
// Key values and is host-tested; the SVC-driven readKey() driver is gated
// behind has_driver exactly like readline's, so the host build never analyses
// inline asm.
//
// No allocator, no module state beyond the caller-held Decoder. Zero footprint
// until referenced — no boot binary calls readKey yet (the first consumer,
// /bin/mon, lands with the goal.md §4 hardware monitor).

const builtin = @import("builtin");

// Driver compiles only on aarch64-freestanding (the real flibc target); the
// host-test build flips this off so the SVC trampoline never enters semantic
// analysis. Only the pure Decoder is exercised on host.
const has_driver = builtin.cpu.arch == .aarch64 and builtin.target.os.tag == .freestanding;

/// A decoded key. `.char` carries its byte in Event.ch; `.none` means the byte
/// was consumed mid-escape-sequence (feed more); `.eof` means the stream closed.
pub const Key = enum {
    up,
    down,
    left,
    right,
    enter,
    backspace,
    tab,
    escape,
    ctrl_c,
    ctrl_d,
    char,
    none,
    eof,
};

/// A key event. `ch` is meaningful only for `.char`.
pub const Event = struct {
    key: Key,
    ch: u8 = 0,
};

/// Incremental VT100 input decoder. Feed it one byte at a time; it returns
/// `.none` while inside an ESC sequence and a real key when one completes. A
/// fresh Decoder per readKey() call is correct — a whole sequence is consumed
/// within one call.
pub const Decoder = struct {
    state: State = .ground,

    const State = enum { ground, esc, csi };

    pub fn feed(self: *Decoder, b: u8) Event {
        return switch (self.state) {
            .ground => self.atGround(b),
            .esc => self.atEsc(b),
            .csi => self.atCsi(b),
        };
    }

    fn atGround(self: *Decoder, b: u8) Event {
        return switch (b) {
            0x1b => blk: {
                self.state = .esc;
                break :blk .{ .key = .none };
            },
            '\r', '\n' => .{ .key = .enter },
            '\t' => .{ .key = .tab },
            0x08, 0x7f => .{ .key = .backspace },
            0x03 => .{ .key = .ctrl_c },
            0x04 => .{ .key = .ctrl_d },
            0x20...0x7e => .{ .key = .char, .ch = b },
            else => .{ .key = .none },
        };
    }

    fn atEsc(self: *Decoder, b: u8) Event {
        if (b == '[') {
            self.state = .csi;
            return .{ .key = .none };
        }
        if (b == 0x1b) {
            // A second ESC — stay pending on the newer one.
            return .{ .key = .none };
        }
        // ESC then anything else: a bare Escape; the trailing byte is dropped
        // (Alt-<key> chords are out of scope for v1).
        self.state = .ground;
        return .{ .key = .escape };
    }

    fn atCsi(self: *Decoder, b: u8) Event {
        // Parameter bytes (digits / ';') belong to the sequence — keep reading
        // so ESC[5~ (PgUp etc.) is absorbed cleanly rather than leaking bytes.
        if ((b >= '0' and b <= '9') or b == ';') return .{ .key = .none };
        self.state = .ground;
        return switch (b) {
            'A' => .{ .key = .up },
            'B' => .{ .key = .down },
            'C' => .{ .key = .right },
            'D' => .{ .key = .left },
            else => .{ .key = .none },
        };
    }
};

/// Block until one whole key is read from fd 0. Returns `.eof` when the stream
/// closes. Use inside a full-screen loop; pair with console_ui.screen.enter /
/// leave and console mode 0.
pub const readKey = driver.readKey;

const driver = if (has_driver) struct {
    const sys = @import("syscalls.zig");

    pub fn readKey() Event {
        var dec = Decoder{};
        var b: u8 = 0;
        while (true) {
            const n = sys.read(0, @ptrCast(&b), 1);
            if (n <= 0) return .{ .key = .eof };
            const ev = dec.feed(b);
            if (ev.key != .none) return ev;
        }
    }
} else struct {
    // Host-test stub: present only so the `pub const readKey` binding succeeds.
    pub fn readKey() Event {
        return .{ .key = .eof };
    }
};

// ---- host tests ------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

fn decodeOne(seq: []const u8) Event {
    var d = Decoder{};
    var last: Event = .{ .key = .none };
    for (seq) |b| {
        last = d.feed(b);
        if (last.key != .none) return last;
    }
    return last;
}

test "printable byte decodes to char" {
    const e = decodeOne("a");
    try testing.expectEqual(Key.char, e.key);
    try testing.expectEqual(@as(u8, 'a'), e.ch);
}

test "CR and LF decode to enter" {
    try testing.expectEqual(Key.enter, decodeOne("\r").key);
    try testing.expectEqual(Key.enter, decodeOne("\n").key);
}

test "tab decodes to tab" {
    try testing.expectEqual(Key.tab, decodeOne("\t").key);
}

test "ctrl-c and ctrl-d" {
    try testing.expectEqual(Key.ctrl_c, decodeOne(&.{0x03}).key);
    try testing.expectEqual(Key.ctrl_d, decodeOne(&.{0x04}).key);
}

test "arrow sequences decode through ESC [ A..D" {
    try testing.expectEqual(Key.up, decodeOne("\x1b[A").key);
    try testing.expectEqual(Key.down, decodeOne("\x1b[B").key);
    try testing.expectEqual(Key.right, decodeOne("\x1b[C").key);
    try testing.expectEqual(Key.left, decodeOne("\x1b[D").key);
}

test "parametrized CSI (ESC[5~) is absorbed, not leaked as keys" {
    var d = Decoder{};
    try testing.expectEqual(Key.none, d.feed(0x1b).key);
    try testing.expectEqual(Key.none, d.feed('[').key);
    try testing.expectEqual(Key.none, d.feed('5').key);
    try testing.expectEqual(Key.none, d.feed('~').key);
}

test "bare ESC then a letter yields escape" {
    var d = Decoder{};
    try testing.expectEqual(Key.none, d.feed(0x1b).key);
    try testing.expectEqual(Key.escape, d.feed('x').key);
}
