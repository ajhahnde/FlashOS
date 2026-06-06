// console_ui screen layer — full-screen panels for TUI navigation.
//
// The output half of FlashOS's shell-first navigation: the shell is the
// primary interface and only specific tools take over the whole screen. A
// full-screen tool — the coming /bin/mon hardware monitor, a pager, a
// log viewer — takes over the console with enter(), paints panels
// (panelTop/panelRow/panelBottom) and metric rows (kv), reads keys via
// flibc.readKey, and restores the shell view with leave() when the user quits.
//
// Pure + freestanding, exactly like palette.zig / tags.zig: every renderer
// takes a caller-supplied Sink and emits bytes — no allocator, no module-level
// state, no dependency on the kernel or flibc. All control bytes are plain
// ANSI/VT100 over the serial console; there is no framebuffer (the project goal
// is a text workstation "ohne grafischen Overhead"). Box glyphs follow the
// shared palette.unicode charset knob (ASCII by default — the UART console
// passes raw bytes and only UTF-8 terminals render the Unicode forms).
//
// Zero footprint until referenced: like every console_ui decl, these are
// analyzed only when a call site names them, so staging the file leaves the
// kernel + fsh images byte-identical until the first consumer (/bin/mon) lands.

const palette = @import("palette.zig");

/// Byte sink — structurally identical to console_ui.Sink (Zig fn-pointer types
/// are structural), so a consumer threads one sink through the line renderers
/// and these screen renderers alike.
pub const Sink = *const fn (bytes: []const u8) void;

// ---- alternate-screen lifecycle --------------------------------------------

/// Enter full-screen: switch to the alternate screen buffer, hide the cursor,
/// home it, and clear. Pairs with leave(); the \e[?1049h alt buffer leaves the
/// shell's scrollback untouched so it reappears verbatim on leave().
pub fn enter(sink: Sink) void {
    sink("\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J");
}

/// Leave full-screen: restore the cursor and the main screen buffer. A
/// full-screen tool MUST call this on every exit path; fsh also resets the
/// console after each wait() as a backstop.
pub fn leave(sink: Sink) void {
    sink("\x1b[?25h\x1b[?1049l");
}

/// Clear the screen and home the cursor without touching the buffer stack.
pub fn clear(sink: Sink) void {
    sink("\x1b[H\x1b[2J");
}

/// Move the cursor to (row, col), 1-based — \e[<row>;<col>H.
pub fn moveTo(sink: Sink, row: u16, col: u16) void {
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    buf[i] = 0x1b;
    i += 1;
    buf[i] = '[';
    i += 1;
    i += writeDec(buf[i..], row);
    buf[i] = ';';
    i += 1;
    i += writeDec(buf[i..], col);
    buf[i] = 'H';
    i += 1;
    sink(buf[0..i]);
}

// ---- panels ----------------------------------------------------------------

// Box-drawing charset, chosen at comptime from palette.unicode. ASCII default
// keeps a dumb-terminal capture legible; the Unicode forms render on UTF-8.
const glyph = if (palette.unicode) struct {
    const tl = "\u{250c}";
    const tr = "\u{2510}";
    const bl = "\u{2514}";
    const br = "\u{2518}";
    const h = "\u{2500}";
    const v = "\u{2502}";
} else struct {
    const tl = "+";
    const tr = "+";
    const bl = "+";
    const br = "+";
    const h = "-";
    const v = "|";
};

/// A bordered panel. `width` is the total column count including both borders;
/// the inner content width is `width - 2`. The caller positions the cursor
/// (moveTo) before each row for a full-screen layout, or just emits the rows
/// inline.
pub const Panel = struct {
    title: []const u8,
    width: u16,

    fn inner(self: Panel) usize {
        return if (self.width >= 2) self.width - 2 else 0;
    }
};

/// Top border carrying the title: `+- title -----------+` — rendered only when
/// the inner width has room for "- <title> "; otherwise a plain filled border.
pub fn panelTop(sink: Sink, p: Panel) void {
    const in = p.inner();
    sink(glyph.tl);
    var used: usize = 0;
    if (in >= p.title.len + 3) {
        sink(glyph.h);
        sink(" ");
        sink(p.title);
        sink(" ");
        used = p.title.len + 3;
    }
    repeat(sink, glyph.h, in - used);
    sink(glyph.tr);
    sink("\n");
}

/// A content row: `| text<pad> |`, text clipped / space-padded to the inner
/// width minus the one-space gutter on each side.
pub fn panelRow(sink: Sink, p: Panel, text: []const u8) void {
    const in = p.inner();
    sink(glyph.v);
    if (in >= 2) {
        sink(" ");
        const room = in - 2;
        const t = if (text.len <= room) text else text[0..room];
        sink(t);
        repeat(sink, " ", room - t.len);
        sink(" ");
    } else {
        repeat(sink, " ", in);
    }
    sink(glyph.v);
    sink("\n");
}

/// Bottom border: `+-------------------+`.
pub fn panelBottom(sink: Sink, p: Panel) void {
    sink(glyph.bl);
    repeat(sink, glyph.h, p.inner());
    sink(glyph.br);
    sink("\n");
}

// ---- key/value rows --------------------------------------------------------

/// Column the value starts at in a kv() row. Eight fits "CPU"/"MEM"/"UP"/"USER"
/// with a margin; a longer key gets a single trailing space instead.
pub const kv_col: usize = 8;

/// A "key      value" metric row + newline — the renderer sysinfo and /bin/mon
/// use for each line. The key is padded to kv_col; an over-long key falls back
/// to a single space so the value never collides.
pub fn kv(sink: Sink, key: []const u8, value: []const u8) void {
    sink(key);
    const pad = if (key.len < kv_col) kv_col - key.len else 1;
    repeat(sink, " ", pad);
    sink(value);
    sink("\n");
}

// ---- helpers ---------------------------------------------------------------

/// Emit `s` `n` times.
fn repeat(sink: Sink, s: []const u8, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) sink(s);
}

/// Write `v` as decimal ASCII into `out` (>= 5 bytes), returning the count.
fn writeDec(out: []u8, v: u16) usize {
    if (v == 0) {
        out[0] = '0';
        return 1;
    }
    var tmp: [5]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x != 0) : (x /= 10) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = tmp[n - 1 - i];
    return n;
}

// ---- host tests ------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

// Capturing sink for tests: appends to a fixed buffer. Host tests run
// single-threaded, so a module-global is fine here.
var cap_buf: [512]u8 = undefined;
var cap_len: usize = 0;
fn capSink(bytes: []const u8) void {
    for (bytes) |b| {
        if (cap_len < cap_buf.len) {
            cap_buf[cap_len] = b;
            cap_len += 1;
        }
    }
}
fn capReset() void {
    cap_len = 0;
}
fn captured() []const u8 {
    return cap_buf[0..cap_len];
}

test "kv pads a short key to kv_col" {
    capReset();
    kv(capSink, "CPU", "1.50 GHz");
    try testing.expectEqualStrings("CPU     1.50 GHz\n", captured());
}

test "kv falls back to a single space for an over-long key" {
    capReset();
    kv(capSink, "LONGKEYNAME", "v");
    try testing.expectEqualStrings("LONGKEYNAME v\n", captured());
}

test "moveTo emits a 1-based CUP sequence" {
    capReset();
    moveTo(capSink, 3, 12);
    try testing.expectEqualStrings("\x1b[3;12H", captured());
}

test "panelBottom width math (ASCII default)" {
    capReset();
    panelBottom(capSink, .{ .title = "x", .width = 6 });
    // width 6 => 4 inner '-' between the corners
    try testing.expectEqualStrings("+----+\n", captured());
}

test "panelRow clips and pads to the inner width" {
    capReset();
    panelRow(capSink, .{ .title = "t", .width = 8 }, "ab");
    // inner 6, gutter 1 each side, room 4 => "ab" + 2 pad
    try testing.expectEqualStrings("| ab   |\n", captured());
}

test "writeDec handles zero and the u16 max" {
    var b: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), writeDec(&b, 0));
    try testing.expectEqual(@as(u8, '0'), b[0]);
    const n = writeDec(&b, 65535);
    try testing.expectEqualStrings("65535", b[0..n]);
}
