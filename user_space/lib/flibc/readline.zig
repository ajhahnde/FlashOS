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
//   * `State` + `Action` + `step` — the pure byte → buffer transition for the
//     plain editor. Host-tested (see the `test` blocks at the bottom).
//   * `Edit` + the State cursor ops (insertAt / backspace / moveLeft /
//     moveRight / replaceLine) — the pure transitions for the full editor
//     (`readlineEdit`). Also host-tested.
//   * `History` — a caller-owned ring of submitted lines (Up/Down recall).
//     Pure + host-tested; storage is the caller's (rule 1 — no .bss).
//   * `Outcome` — the public driver return type (`line` / `eof` /
//     `abandoned`). Callers (fsh) treat `eof` as logout and `abandoned`
//     as "redraw prompt, drop input".
//   * `readline(buf)` / `readlineCompleting` / `readlineEdit` — the
//     SVC-driven drivers. Gated through an `if (has_driver)`-selected
//     anonymous struct so the host-test build never analyses the inline-asm
//     body. The host fallback returns `.eof`; only the aarch64-freestanding
//     target sees the real loop.
//
// Editing rules for plain step/readline (single-line, append-only — no cursor
// motion or history; readlineEdit adds those over the same buffer by routing
// bytes through keys.Decoder):
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

/// Forward byte copy through a *volatile* destination (non-overlapping); returns
/// the number of bytes copied (min of the two lengths). flibc payloads run with
/// SCTLR_EL1.A strict alignment asserted, and the ReleaseSmall loop-idiom
/// vectorizer will happily widen a plain `while (i<n) dst[i]=src[i]` copy into a
/// `str q` (16-byte NEON) store — which takes an alignment data abort when the
/// destination is only 8-aligned, as a history slot or the line buffer routinely
/// is. Volatile accesses are never widened or merged, so this is alignment-safe
/// by construction; the buffers are at most one line, so the byte-wise cost is
/// irrelevant. Mirrors the hand-rolled providers in src/utilc.zig and
/// flibc/mem.zig that dodge the same hazard. The cursor shift loops below cast
/// the line buffer the same way for the same reason.
fn copyBytes(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    const d: [*]volatile u8 = @ptrCast(dst.ptr);
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = src[i];
    return n;
}

/// A cursor-aware edit directive returned by the State cursor ops. A plain
/// enum on purpose: a payload-carrying union is a >16-byte by-value return that
/// LLVM materialises with a `str q` (16-byte NEON) store through the AArch64
/// indirect-result register x8 — and that store takes an alignment data abort
/// under SCTLR_EL1.A when the caller's result slot is only 8-aligned (the
/// struct's natural alignment). A bare enum returns in a register: no store, no
/// fault. The whole-line replace carries no payload here; replaceLine is void
/// and the driver captures the pre-swap extent itself. `.none` means the op was
/// a no-op at a boundary (buffer full, cursor at an edge) and nothing is drawn.
pub const Edit = enum {
    none,
    /// A byte was inserted at the cursor: repaint buf[pos-1..len], then step
    /// the cursor back (len-pos) columns to sit just after the new byte.
    insert,
    /// The byte before the cursor was removed: backspace, repaint buf[pos..len],
    /// blank the vacated last column, step back (len-pos+1) columns.
    delete,
    /// Cursor moved one column left (a bare backspace, no erase).
    left,
    /// Cursor moved one column right (re-emit the byte it stepped over).
    right,
};

/// Line editor state. `buf` is the caller-provided fixed-size buffer
/// (rule 1 — no realloc); `len` is the committed-byte count and `pos` the
/// cursor offset, with the invariant `pos <= len <= buf.len`. Submission
/// yields `buf[0..len]`. Plain `step`/`readline` are append-only and ignore
/// `pos`; the cursor ops below back `readlineEdit`.
pub const State = struct {
    buf: []u8,
    len: usize = 0,
    pos: usize = 0,

    pub fn init(buf: []u8) State {
        return .{ .buf = buf };
    }

    pub fn slice(self: *const State) []const u8 {
        return self.buf[0..self.len];
    }

    /// Insert `c` at the cursor, shifting the tail right. No-op when full.
    pub fn insertAt(self: *State, c: u8) Edit {
        if (self.len >= self.buf.len) return .none;
        const v: [*]volatile u8 = @ptrCast(self.buf.ptr); // alignment-safe, see copyBytes
        var i = self.len;
        while (i > self.pos) : (i -= 1) v[i] = v[i - 1];
        v[self.pos] = c;
        self.len += 1;
        self.pos += 1;
        return .insert;
    }

    /// Delete the byte before the cursor, shifting the tail left. No-op at col 0.
    pub fn backspace(self: *State) Edit {
        if (self.pos == 0) return .none;
        const v: [*]volatile u8 = @ptrCast(self.buf.ptr); // alignment-safe, see copyBytes
        var i = self.pos;
        while (i < self.len) : (i += 1) v[i - 1] = v[i];
        self.len -= 1;
        self.pos -= 1;
        return .delete;
    }

    /// Move the cursor one column left. No-op at col 0.
    pub fn moveLeft(self: *State) Edit {
        if (self.pos == 0) return .none;
        self.pos -= 1;
        return .left;
    }

    /// Move the cursor one column right. No-op at end of line.
    pub fn moveRight(self: *State) Edit {
        if (self.pos >= self.len) return .none;
        self.pos += 1;
        return .right;
    }

    /// Replace the whole line with `s` (clipped to capacity), cursor to end.
    /// Backs history recall. Void (not Edit-returning): the driver captures the
    /// pre-swap extent before calling, so the redraw needs nothing back.
    pub fn replaceLine(self: *State, s: []const u8) void {
        self.len = copyBytes(self.buf, s);
        self.pos = self.len;
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

/// One-byte state transition for the plain (append-only) editor. Pure: no
/// syscalls, no allocator. `readlineEdit` does not use this — it routes bytes
/// through keys.Decoder and the State cursor ops instead.
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

// ---- command history (caller-owned ring; rule 1 — no allocator / no .bss) ---

/// Per-entry capacity for a recorded history line. Matches fsh's LINE_MAX; a
/// longer submitted line is clipped when recorded (recall still works, the
/// stored copy is just shorter). Lines hold only printable bytes, so a slot
/// needs no NUL terminator — `len` delimits it.
pub const HIST_LINE_CAP: usize = 256;

/// One history slot. The caller declares an array of these on its stack and
/// hands a slice to History.init; History itself never allocates. Slot bytes
/// are written by `push` before they are ever read back, so an `undefined`
/// array is a valid backing store (History.count gates every read).
pub const HistSlot = struct {
    bytes: [HIST_LINE_CAP]u8 = undefined,
    len: usize = 0,
};

/// A fixed-capacity ring of recently submitted lines, navigated with Up/Down.
/// Pure (host-tested): `older`/`newer` walk the ring and hand back the recalled
/// line; the driver paints it with State.replaceLine. The in-progress line is
/// stashed on the first Up so Down past the newest entry restores it.
pub const History = struct {
    slots: []HistSlot,
    stash: HistSlot = .{},
    head: usize = 0, // ring index of the next write (mod slots.len)
    count: usize = 0, // filled slots, saturating at slots.len
    nav: usize = 0, // 0 = editing the live line; k = the k-th newest recalled

    pub fn init(slots: []HistSlot) History {
        return .{ .slots = slots };
    }

    // The k-th newest entry (k in 1..count): the newest sits one behind head.
    fn entry(self: *const History, back: usize) []const u8 {
        const m = self.slots.len;
        const i = (self.head + m - back) % m;
        return self.slots[i].bytes[0..self.slots[i].len];
    }

    /// Record a submitted line and leave browse mode. A blank line and an exact
    /// repeat of the most-recent entry are not recorded (ignoredups).
    pub fn push(self: *History, line: []const u8) void {
        self.nav = 0;
        if (self.slots.len == 0 or line.len == 0) return;
        if (self.count > 0 and eql(self.entry(1), line)) return;
        const slot = &self.slots[self.head];
        slot.len = copyBytes(&slot.bytes, line);
        self.head = (self.head + 1) % self.slots.len;
        if (self.count < self.slots.len) self.count += 1;
    }

    /// Step one entry older. The first step stashes `current` (the live,
    /// unsubmitted line) so `newer` can restore it. Returns the recalled line,
    /// or null at the oldest entry / on empty history (caller draws nothing).
    pub fn older(self: *History, current: []const u8) ?[]const u8 {
        if (self.count == 0) return null;
        if (self.nav == 0) {
            self.stash.len = copyBytes(&self.stash.bytes, current);
            self.nav = 1;
            return self.entry(1);
        }
        if (self.nav < self.count) {
            self.nav += 1;
            return self.entry(self.nav);
        }
        return null;
    }

    /// Step one entry newer. Returns the recalled line, the stashed live line
    /// when stepping off the newest entry, or null when not browsing.
    pub fn newer(self: *History) ?[]const u8 {
        if (self.nav == 0) return null;
        if (self.nav > 1) {
            self.nav -= 1;
            return self.entry(self.nav);
        }
        self.nav = 0;
        return self.stash.bytes[0..self.stash.len];
    }

    /// Leave browse mode without recording a line (^C path).
    pub fn resetNav(self: *History) void {
        self.nav = 0;
    }

    fn eql(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        var i: usize = 0;
        while (i < a.len) : (i += 1) if (a[i] != b[i]) return false;
        return true;
    }
};

/// Read a line interactively from fd 0. Blocks until the editor returns
/// a terminal action (submit / eof / abandon) or sys_read fails. The
/// returned `Outcome.line` slice lives in `buf` and is valid until the
/// next call that reuses `buf`. Plain readline ignores TAB and arrow keys.
pub const readline = driver.readline;

/// Like `readline`, but TAB completes the current token against `comp`: the
/// first token against `comp.bin_dir` + `comp.builtins`, a later token as a
/// filesystem path. The buffer is extended in place + echoed; a unique match
/// also appends a trailing ' ' (command / file) or '/' (directory). Equivalent
/// to `readlineEdit` with no history.
pub fn readlineCompleting(buf: []u8, comp: Completion) Outcome {
    return driver.readlineEdit(buf, comp, null);
}

/// The full line editor: TAB completion (as `readlineCompleting`), plus
/// Left/Right cursor motion with insert/backspace at the cursor, plus Up/Down
/// recall from `hist`. Pass `hist = null` for the completion-only editor.
/// Input is decoded through keys.Decoder, so the multi-byte arrow sequences are
/// absorbed rather than echoed as literal `[A` etc.
pub fn readlineEdit(buf: []u8, comp: Completion, hist: ?*History) Outcome {
    return driver.readlineEdit(buf, comp, hist);
}

/// Completion policy for `readlineCompleting` / `readlineEdit`. `builtins` are
/// extra command names offered for the first token (a shell's in-process
/// built-ins, which are absent from /bin); `bin_dir` is the directory searched
/// for command completion. Path completion needs no policy — it reads the dir
/// named in the token itself. `prompt` is the string the caller printed before
/// this line: the double-TAB candidate listing reprints `prompt` + the line
/// after the list so the cursor returns to a faithful prompt (empty = caller
/// has no prompt, so only the line is redrawn).
pub const Completion = struct {
    builtins: []const []const u8 = &.{},
    bin_dir: [*:0]const u8 = "/bin",
    prompt: []const u8 = "",
};

const driver = if (has_driver) struct {
    const sys = @import("syscalls.zig");
    const completion = @import("completion.zig");
    const keys = @import("keys.zig");
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

    // The full editor. Bytes are fed through keys.Decoder so the arrow
    // sequences decode into cursor / history motion; every other key maps to a
    // pure State op whose Edit directive `render` turns into VT100 output.
    pub fn readlineEdit(buf: []u8, comp: Completion, hist: ?*History) Outcome {
        // 16-byte aligned: LLVM SLP-vectorises the adjacent `len`/`pos` updates
        // into a single `str q` (16-byte NEON) store to state+0x10. Under
        // SCTLR_EL1.A strict alignment that store faults unless the slot is
        // 16-aligned, and State's natural alignment is only 8.
        var state align(16) = State.init(buf);
        var dec = keys.Decoder{};
        // Consecutive "stuck" TABs (completion with nothing left to insert). The
        // second one lists the candidates; any other key clears the streak.
        var stuck_tabs: u8 = 0;
        var byte: u8 = 0;
        while (true) {
            const n = sys.read(0, @ptrCast(&byte), 1);
            if (n <= 0) return .eof;
            const ev = dec.feed(byte);
            const was_stuck = stuck_tabs;
            stuck_tabs = 0;
            switch (ev.key) {
                .char => render(&state, state.insertAt(ev.ch)),
                .backspace => render(&state, state.backspace()),
                .left => render(&state, state.moveLeft()),
                .right => render(&state, state.moveRight()),
                .up => if (hist) |h| {
                    if (h.older(state.slice())) |line| replaceAndRender(&state, line);
                },
                .down => if (hist) |h| {
                    if (h.newer()) |line| replaceAndRender(&state, line);
                },
                .tab => switch (doComplete(&state, comp)) {
                    .stuck => {
                        // First stuck TAB arms; the next one lists.
                        if (was_stuck != 0) listCandidates(&state, comp) else {
                            stuck_tabs = 1;
                        }
                    },
                    .progressed, .empty => {},
                },
                .enter => {
                    if (hist) |h| h.push(state.slice());
                    return .{ .line = state.slice() };
                },
                .ctrl_c => {
                    if (hist) |h| h.resetNav();
                    return .abandoned;
                },
                .ctrl_d => if (state.len == 0) return .eof, // mid-line ^D ignored
                // .none while mid-sequence, a bare ESC, or the never-fed .eof:
                .escape, .none, .eof => {},
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

    // Turn one Edit directive into VT100 bytes. The cursor arithmetic is
    // derived from the post-op state.{pos,len} plus, for a line replace, the
    // captured old extent. Backspace as 0x08 (move-left, no erase) is what the
    // dumb serial console understands; the trailing-column blank in `.delete`
    // and the surplus blank in `.replace` clear what a shrink leaves behind.
    fn render(state: *State, e: Edit) void {
        switch (e) {
            .none => {},
            .insert => {
                writeRange(state.buf[state.pos - 1 .. state.len]);
                emitBack(state.len - state.pos);
            },
            .delete => {
                echoByte(0x08);
                writeRange(state.buf[state.pos..state.len]);
                echoByte(' ');
                emitBack(state.len - state.pos + 1);
            },
            .left => echoByte(0x08),
            .right => echoByte(state.buf[state.pos - 1]),
        }
    }

    // History recall redraw: swap the line, then erase-and-repaint from column
    // 0. Captures the old extent before replaceLine mutates so it can blank any
    // surplus a shorter recalled line leaves behind. Kept off the Edit return
    // path (see Edit) so no >16-byte struct is materialised through x8.
    fn replaceAndRender(state: *State, line: []const u8) void {
        const old_len = state.len;
        const old_pos = state.pos;
        state.replaceLine(line);
        emitBack(old_pos); // cursor home to column 0 of the input
        writeRange(state.buf[0..state.len]);
        if (old_len > state.len) {
            const extra = old_len - state.len;
            emitSpaces(extra); // blank the tail the shorter line vacated
            emitBack(extra);
        }
    }

    fn writeRange(s: []const u8) void {
        if (s.len != 0) _ = sys.write_fd(1, s.ptr, s.len);
    }

    fn emitBack(n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) echoByte(0x08);
    }

    fn emitSpaces(n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) echoByte(' ');
    }

    // Resolve the directory a completion enumerates into a NUL-terminated path
    // for sys.readdir: comp.bin_dir for a command, the token's own dir for a
    // path. Returns null when the dir name overflows the scratch buffer.
    fn resolveDir(ctx: completion.Context, comp: Completion, dirbuf: *[128]u8) ?[*:0]const u8 {
        switch (ctx.kind) {
            .command => return comp.bin_dir,
            .path => {
                const d = if (ctx.dir.len == 0) "." else ctx.dir;
                if (d.len >= dirbuf.len) return null;
                _ = copyBytes(dirbuf, d);
                dirbuf[d.len] = 0;
                return @ptrCast(dirbuf);
            },
        }
    }

    // On TAB: gather candidates that extend the token ending at the cursor,
    // insert the longest common extension at the cursor + echo it. A unique
    // match also gets a trailing ' ' (command / file) or '/' (directory).
    // Returns how far it got (progressed / stuck / empty) so readlineEdit can
    // arm the double-TAB listing on a stuck repeat. All buffers are stack-local
    // (rule 1); the running common prefix is copied out of the reused Dirent so
    // it stays valid across the readdir walk.
    fn doComplete(state: *State, comp: Completion) completion.TabClass {
        const ctx = completion.parse(state.buf[0..state.pos]);
        var dirbuf: [128]u8 = undefined;
        const dirz = resolveDir(ctx, comp, &dirbuf) orelse return .empty;

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

        const cls = completion.classify(count, best_len, ctx.prefix.len);
        if (cls == .progressed) {
            emitInsert(state, best[ctx.prefix.len..best_len]);
            if (count == 1) emitInsert(state, if (only_is_dir) "/" else " ");
        }
        return cls;
    }

    // Double-TAB: print every candidate sharing the token's prefix on a fresh
    // line, then redraw the prompt + the in-progress line so editing resumes
    // where it left off. Re-walks the same sources doComplete enumerated (the
    // candidate set is small and a stack cache would not outlive the readdir
    // walk); names are listed bare, two spaces apart, and the terminal wraps a
    // long row.
    fn listCandidates(state: *State, comp: Completion) void {
        const ctx = completion.parse(state.buf[0..state.pos]);
        var dirbuf: [128]u8 = undefined;
        const dirz = resolveDir(ctx, comp, &dirbuf) orelse return;

        writeRange("\n");
        var any = false;
        if (ctx.kind == .command) {
            for (comp.builtins) |name| {
                if (!completion.hasPrefix(name, ctx.prefix)) continue;
                emitCandidate(name, &any);
            }
        }
        var d: defs.Dirent = .{};
        var idx: u64 = 0;
        while (sys.readdir(dirz, idx, &d) == 0) : (idx += 1) {
            var nl: usize = 0;
            while (nl < d.name.len and d.name[nl] != 0) : (nl += 1) {}
            const name = d.name[0..nl];
            if (!completion.hasPrefix(name, ctx.prefix)) continue;
            emitCandidate(name, &any);
        }
        writeRange("\n");

        // Redraw the prompt + line, then walk the cursor back to its column.
        writeRange(comp.prompt);
        writeRange(state.buf[0..state.len]);
        emitBack(state.len - state.pos);
    }

    // One listed candidate, two-space separated from the previous.
    fn emitCandidate(name: []const u8, any: *bool) void {
        if (any.*) writeRange("  ");
        writeRange(name);
        any.* = true;
    }

    // Fold one candidate into the running longest-common-prefix `best`.
    fn fold(best: *[32]u8, best_len: *usize, count: *usize, name: []const u8) void {
        if (count.* == 0) {
            best_len.* = copyBytes(best, name);
        } else {
            best_len.* = completion.commonPrefixLen(best[0..best_len.*], name);
        }
        count.* += 1;
    }

    // Insert `ext` at the cursor (respecting capacity), echoing each byte
    // through the same redraw the interactive insert uses — so a completion
    // landed mid-line repaints the tail correctly, and at end-of-line collapses
    // to a plain echo.
    fn emitInsert(state: *State, ext: []const u8) void {
        for (ext) |c| render(state, state.insertAt(c));
    }
} else struct {
    // Host-test stubs: never invoked from tests, present only so the public
    // bindings resolve on host (the pure step / cursor / History / completion
    // cores are what the host suite exercises).
    pub fn readline(_: []u8) Outcome {
        return .eof;
    }
    pub fn readlineEdit(_: []u8, _: Completion, _: ?*History) Outcome {
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

// ---- cursor-editing (Edit / State) tests ----

test "edit: insert at end appends and advances the cursor" {
    var buf: [8]u8 = undefined;
    var s = State.init(&buf);
    try testing.expectEqual(Edit.insert, s.insertAt('a'));
    try testing.expectEqual(Edit.insert, s.insertAt('b'));
    try testing.expectEqualStrings("ab", s.slice());
    try testing.expectEqual(@as(usize, 2), s.pos);
}

test "edit: insert in the middle shifts the tail right" {
    var buf: [8]u8 = undefined;
    var s = State.init(&buf);
    for ("ac") |c| _ = s.insertAt(c);
    _ = s.moveLeft(); // cursor between 'a' and 'c'
    try testing.expectEqual(@as(usize, 1), s.pos);
    try testing.expectEqual(Edit.insert, s.insertAt('b'));
    try testing.expectEqualStrings("abc", s.slice());
    try testing.expectEqual(@as(usize, 2), s.pos);
}

test "edit: insert is a no-op when the buffer is full" {
    var buf: [2]u8 = undefined;
    var s = State.init(&buf);
    _ = s.insertAt('a');
    _ = s.insertAt('b');
    try testing.expectEqual(Edit.none, s.insertAt('c'));
    try testing.expectEqualStrings("ab", s.slice());
}

test "edit: backspace deletes the byte before the cursor" {
    var buf: [8]u8 = undefined;
    var s = State.init(&buf);
    for ("abc") |c| _ = s.insertAt(c);
    _ = s.moveLeft(); // between 'b' and 'c'
    try testing.expectEqual(Edit.delete, s.backspace()); // removes 'b'
    try testing.expectEqualStrings("ac", s.slice());
    try testing.expectEqual(@as(usize, 1), s.pos);
}

test "edit: backspace at column 0 is a no-op" {
    var buf: [8]u8 = undefined;
    var s = State.init(&buf);
    _ = s.insertAt('x');
    _ = s.moveLeft();
    try testing.expectEqual(Edit.none, s.backspace());
    try testing.expectEqualStrings("x", s.slice());
}

test "edit: left/right honour the line edges" {
    var buf: [8]u8 = undefined;
    var s = State.init(&buf);
    for ("hi") |c| _ = s.insertAt(c);
    try testing.expectEqual(Edit.none, s.moveRight()); // already at end
    try testing.expectEqual(Edit.left, s.moveLeft());
    try testing.expectEqual(Edit.left, s.moveLeft());
    try testing.expectEqual(Edit.none, s.moveLeft()); // at col 0
    try testing.expectEqual(Edit.right, s.moveRight());
}

test "edit: replaceLine swaps content and puts the cursor at the end" {
    var buf: [8]u8 = undefined;
    var s = State.init(&buf);
    for ("hello") |c| _ = s.insertAt(c);
    _ = s.moveLeft();
    s.replaceLine("hi");
    try testing.expectEqualStrings("hi", s.slice());
    try testing.expectEqual(@as(usize, 2), s.pos);
}

test "edit: replaceLine clips to capacity" {
    var buf: [3]u8 = undefined;
    var s = State.init(&buf);
    s.replaceLine("toolong");
    try testing.expectEqualStrings("too", s.slice());
    try testing.expectEqual(@as(usize, 3), s.pos);
}

// ---- History tests ----

test "history: older walks back, newer returns to the stashed live line" {
    var slots: [4]HistSlot = undefined;
    var h = History.init(&slots);
    h.push("one");
    h.push("two");
    try testing.expectEqualStrings("two", h.older("th").?);
    try testing.expectEqualStrings("one", h.older("th").?);
    try testing.expect(h.older("th") == null); // already oldest
    try testing.expectEqualStrings("two", h.newer().?);
    try testing.expectEqualStrings("th", h.newer().?); // stash restored
    try testing.expect(h.newer() == null); // no longer browsing
}

test "history: blank lines and immediate dups are not recorded" {
    var slots: [4]HistSlot = undefined;
    var h = History.init(&slots);
    h.push("ls");
    h.push(""); // blank ignored
    h.push("ls"); // dup of last ignored
    h.push("pwd");
    try testing.expectEqualStrings("pwd", h.older("").?);
    try testing.expectEqualStrings("ls", h.older("").?);
    try testing.expect(h.older("") == null); // only two distinct entries
}

test "history: the ring overwrites the oldest entry" {
    var slots: [2]HistSlot = undefined;
    var h = History.init(&slots);
    h.push("a");
    h.push("b");
    h.push("c"); // evicts "a"
    try testing.expectEqualStrings("c", h.older("").?);
    try testing.expectEqualStrings("b", h.older("").?);
    try testing.expect(h.older("") == null); // "a" is gone
}

test "history: older/newer on empty history are no-ops" {
    var slots: [2]HistSlot = undefined;
    var h = History.init(&slots);
    try testing.expect(h.older("x") == null);
    try testing.expect(h.newer() == null);
}

test "history: push resets browse mode" {
    var slots: [4]HistSlot = undefined;
    var h = History.init(&slots);
    h.push("a");
    _ = h.older(""); // nav = 1
    h.push("b"); // resets nav
    try testing.expect(h.newer() == null); // not browsing after a submit
}
