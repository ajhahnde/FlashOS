// less — the full-screen text pager for /bin/less.
//
// The first consumer of the navigation scaffold's full-screen half: where
// sysinfo proved console_ui.screen's kv() renderer print-and-exit, less proves
// the interactive loop — it takes over the console with screen.enter(), reads
// keys through flibc.readKey()'s VT100 decoder, scrolls with the pure
// flibc.Pager core, and restores the shell view with screen.leave() on every
// exit path. Output is screen.panelTop for the title bar plus raw content rows;
// input is the arrow / page / quit keys a pager needs.
//
// Scope is a proof, like sysinfo: it pages a single named file, slurps up to
// BUF_MAX bytes onto its own stack (rule 1 — no heap, no .bss), indexes the
// first MAX_LINES lines, and assumes a 24x80 serial terminal (no window-size
// ioctl exists yet). A file larger than the slurp shows a "(more)" marker.
// Reading a pipe is out of scope: fd 0 is the key source, so `cmd | less` would
// have nowhere to read keys from (a /dev/tty concern for later).
//
// Same coreutil recipe as ls / sysinfo: flibc _start shim, flibc_mem, pie=false,
// ReleaseSmall, strip, single R+X PT_LOAD (coreutil_linker.ld). Kept out of the
// CI FSH_SCRIPT — it is interactive and the free-page baseline must stay
// deterministic.
//
// Alignment note: under SCTLR_EL1.A strict-align with a generic build target,
// LLVM will vectorize byte copies and materialize >16-byte by-value struct
// returns with a 16-byte `str q`, which faults on an only-8-aligned slot. So the
// Pager (a >16-byte value) is returned into an `align(16)` slot, and the one
// string concat (the title) writes through a volatile pointer so it is never
// widened. Everything else emits source slices straight to the sink — no copies.

const flibc = @import("flibc");
const console_ui = @import("console_ui");

comptime {
    _ = @import("flibc_start");
    _ = @import("flibc_mem");
}

const screen = console_ui.screen;

// Assumed serial-terminal geometry. One header row (panelTop), one status row,
// the rest content. No window-size query exists, so these are fixed.
const ROWS: usize = 24;
const STATUS: usize = 1;
const HEADER: usize = 1;
const PAGE: usize = ROWS - HEADER - STATUS; // visible content rows
const COLS: usize = 80; // clip width — keep each rendered row to one line

const BUF_MAX: usize = 16384; // file slurp cap (on this frame)
const MAX_LINES: usize = 2048; // line-index slots
const TITLE_MAX: usize = COLS; // "less: <name>" scratch

fn sink(bytes: []const u8) void {
    _ = flibc.sys.write_fd(1, bytes.ptr, bytes.len);
}

export fn main(argc: usize, argv: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    if (argc < 2 or argv[1] == null) {
        sink("usage: less <file>\n");
        flibc.exit();
    }
    const path = argv[1].?;

    const fd = flibc.sys.open(path);
    if (fd < 0) {
        sink("less: cannot open file\n");
        flibc.exit();
    }

    // Slurp up to BUF_MAX bytes; `truncated` if the file filled the buffer (it
    // may hold more — best-effort, this is a proof pager).
    var buf: [BUF_MAX]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const r = flibc.sys.read(fd, buf[n..].ptr, buf.len - n);
        if (r <= 0) break;
        n += @intCast(r);
    }
    _ = flibc.sys.close(fd);
    const truncated = (n == buf.len);

    // Title bar text, built once (the only string copy — volatile dest so the
    // strict-align target cannot vectorize it into a faulting `str q`).
    var title_buf: [TITLE_MAX]u8 = undefined;
    const title = buildTitle(&title_buf, baseName(path));

    // Pager value is >16 bytes; land the by-value return on a 16-aligned slot so
    // its sret store is not a misaligned `str q`.
    var slots: [MAX_LINES]u32 = undefined;
    var pg align(16) = flibc.Pager.init(buf[0..n], &slots, PAGE);

    // Take over the console: echo off (mode 0) so typed keys do not leak onto
    // the alt-screen, then the alternate buffer + hidden cursor.
    _ = flibc.sys.set_console_mode(0);
    screen.enter(sink);
    render(&pg, title, truncated);

    while (true) {
        const ev = flibc.readKey();
        var quit = false;
        switch (ev.key) {
            .eof, .escape, .ctrl_c, .ctrl_d => quit = true,
            .up => pg.up(1),
            .down, .enter => pg.down(1),
            .char => switch (ev.ch) {
                'q' => quit = true,
                'j' => pg.down(1),
                'k' => pg.up(1),
                ' ', 'f' => pg.pageDown(),
                'b' => pg.pageUp(),
                'g' => pg.toTop(),
                'G' => pg.toBottom(),
                else => {},
            },
            else => {}, // left/right/tab/backspace/none — ignored
        }
        if (quit) break;
        render(&pg, title, truncated);
    }

    // Every exit path restores the shell view. The console is left in mode 0
    // (echo off) — the shell's own baseline, where readline does its own echo —
    // so there is deliberately no mode restore here (mode 1 would double-echo
    // the next prompt); fsh also re-asserts mode 0 after wait() as a backstop.
    screen.leave(sink);
    flibc.exit();
}

// Repaint the whole screen: title bar, PAGE content rows (clipped to COLS, '~'
// past EOF), then the status row. Full clear + repaint each frame keeps the
// renderer trivial — fine for a serial console.
fn render(pg: *const flibc.Pager, title: []const u8, truncated: bool) void {
    screen.clear(sink); // home + erase
    screen.panelTop(sink, .{ .title = title, .width = COLS });

    var row: usize = 0;
    while (row < pg.rows) : (row += 1) {
        const idx = pg.top + row;
        if (idx < pg.n) {
            const l = pg.line(idx);
            sink(if (l.len <= COLS) l else l[0..COLS]);
        } else {
            sink("~");
        }
        sink("\n");
    }

    statusLine(pg, truncated);
}

// Position + key legend on the final row. No trailing newline so the alt-screen
// does not scroll. The filename already rides the title bar.
fn statusLine(pg: *const flibc.Pager, truncated: bool) void {
    const shown = if (pg.n > pg.top) @min(pg.rows, pg.n - pg.top) else 0;
    const first: u64 = if (pg.n == 0) 0 else pg.top + 1;
    const last: u64 = pg.top + shown;
    sink(" ");
    emitDec(first);
    sink("-");
    emitDec(last);
    sink("/");
    emitDec(pg.n);
    if (truncated) sink(" (more)");
    sink("   q=quit  space=page  b=back  g/G=ends");
}

// Last path component, as a slice into the argv string (no copy). "/a/b" -> "b",
// "x" -> "x".
fn baseName(path: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (path[len] != 0) : (len += 1) {}
    var start: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (path[i] == '/') start = i + 1;
    }
    return path[start..len];
}

// "less: <name>" into `buf`, clipped to its length. The destination is volatile
// so the strict-align target never widens the byte stores into a `str q`.
fn buildTitle(buf: []u8, name: []const u8) []const u8 {
    const dst: [*]volatile u8 = buf.ptr;
    var i: usize = 0;
    const prefix = "less: ";
    for (prefix) |c| {
        dst[i] = c;
        i += 1;
    }
    for (name) |c| {
        if (i >= buf.len) break;
        dst[i] = c;
        i += 1;
    }
    return buf[0..i];
}

// Emit `v` as decimal ASCII (mirrors sysinfo's u64dec — a proven small reversal
// that the strict-align target does not vectorize).
fn emitDec(v: u64) void {
    var buf: [20]u8 = undefined;
    sink(buf[0..u64dec(&buf, v)]);
}

fn u64dec(out: []u8, v: u64) usize {
    if (v == 0) {
        out[0] = '0';
        return 1;
    }
    var tmp: [20]u8 = undefined;
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
