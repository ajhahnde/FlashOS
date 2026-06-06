// console_ui — FlashOS shared terminal look.
//
// One module, compiled into every binary that draws to the console: the kernel
// boot log and the userspace tools (fsh, login, dmesg, …). Editing this module
// restyles the whole system on the next build — there is no second copy of a
// bracket tag or an ANSI code anywhere else in the tree.
//
// Layout: the look is split by concern so it scales as the UI grows, but it
// stays a single import — consumers only ever `@import("console_ui")`.
//   * palette.zig — the `color` knob + the ANSI palette
//   * tags.zig    — the `Level` severity taxonomy + each level's `Tag`
//   * this file   — the `Sink`, the renderers, the `Logger`, and the
//                   homescreen; it re-exports the two above so a consumer
//                   reaches the whole surface through one name.
//
// Freestanding by construction: no allocator, no std, no dependency on kernel
// internals or flibc. Output is routed through a caller-supplied `Sink`, so the
// same renderers serve the kernel (main_output) and userspace (write(2)) with
// neither side leaking in. Because it is pure and target-agnostic, each
// consumer recompiles it with its own settings.

pub const palette = @import("palette.zig");
pub const tags = @import("tags.zig");
pub const screen = @import("screen.zig");

// ---- public surface (flat re-exports) --------------------------------------
// The hot names a consumer reaches for, lifted to the top level so call sites
// read `console_ui.ok` / `console_ui.color` rather than digging through a
// sub-namespace. The full palette + taxonomy stay reachable as `console_ui.
// palette.*` / `console_ui.tags.*`.
pub const color = palette.color;
pub const Level = tags.Level;
pub const Tag = tags.Tag;
pub const ok = tags.ok;
pub const info = tags.info;
pub const load = tags.load;
pub const warn = tags.warn;
pub const fail = tags.fail;
pub const skip = tags.skip;

/// A byte sink. Each consumer binds it to its own console writer:
///   kernel -> a byte loop over main_output_char(MU, b)
///   user   -> write(1, bytes.ptr, bytes.len)
pub const Sink = *const fn (bytes: []const u8) void;

/// Box-drawing charset for the screen-layer panels — single-sourced in
/// palette.zig and re-exported here so call sites keep reading
/// `console_ui.unicode`. false = ASCII (+-|), true = Unicode.
pub const unicode: bool = palette.unicode;

/// Boot-success marker — the homescreen tail. Frozen: scripts/run_qemu_test.sh
/// greps this literal (x3 per boot) as the boot pass signal. Single source of
/// truth — do not reword without updating the contract header in
/// scripts/run_qemu_test.sh.
pub const marker_ready = " - type 'help' for commands";

// ---- renderers -------------------------------------------------------------

/// Write a tag as `<pre><word><post>` with the brackets + padding in the
/// default color and only `word` tinted by `t.ansi`. Color off => both ANSI
/// strings are empty and the bytes are the plain six-wide `[ OK ]` form.
fn writeTag(sink: Sink, t: Tag) void {
    sink(t.pre);
    sink(t.ansi);
    sink(t.word);
    sink(palette.reset);
    sink(t.post);
}

/// Write a tag followed by a single space, with no message and no newline — the
/// seam for a line whose tail is assembled by the caller (e.g. a boot line that
/// interleaves dynamic digits).
pub fn tagged(sink: Sink, t: Tag) void {
    writeTag(sink, t);
    sink(" ");
}

/// Write one finished tagged line: `<tag> <msg>\n`, the tag colored when
/// enabled.
pub fn line(sink: Sink, t: Tag, msg: []const u8) void {
    tagged(sink, t);
    sink(msg);
    sink("\n");
}

/// A pending stage that resolves in place. `stage()` prints `[LOAD] <msg>` with
/// no newline; a later `.done()` / `.failed()` carriage-returns to column 0 and
/// overwrites the tag, then ends the line. Same width + same message text means
/// the overwrite is exact even with color on (the escapes are zero-width).
pub const Stage = struct {
    sink: Sink,
    msg: []const u8,

    /// Flip the pending tag to green [ OK ] and finish the line.
    pub fn done(self: Stage) void {
        self.resolve(ok);
    }

    /// Flip the pending tag to red [FAIL] and finish the line.
    pub fn failed(self: Stage) void {
        self.resolve(fail);
    }

    fn resolve(self: Stage, t: Tag) void {
        self.sink("\r");
        line(self.sink, t, self.msg);
    }
};

/// Begin a pending stage: prints `[LOAD] <msg>` (no newline yet). Resolve it
/// with `.done()` or `.failed()`.
pub fn stage(sink: Sink, msg: []const u8) Stage {
    tagged(sink, load);
    sink(msg);
    return .{ .sink = sink, .msg = msg };
}

/// A plain banner / homescreen line (text + newline). Placeholder seam for the
/// richer panel + key/value renderers, which land when a screen needs them.
pub fn banner(sink: Sink, text: []const u8) void {
    sink(text);
    sink("\n");
}

/// A `Sink` bound once, so a consumer logs `log.ok("…")` instead of repeating
/// the sink at every call. Pure sugar over the free `line` renderer — the look
/// is unchanged. The free renderers stay available for one-off and assembled
/// lines.
pub const Logger = struct {
    sink: Sink,

    pub fn ok(self: Logger, msg: []const u8) void {
        line(self.sink, tags.ok, msg);
    }
    pub fn info(self: Logger, msg: []const u8) void {
        line(self.sink, tags.info, msg);
    }
    pub fn warn(self: Logger, msg: []const u8) void {
        line(self.sink, tags.warn, msg);
    }
    pub fn fail(self: Logger, msg: []const u8) void {
        line(self.sink, tags.fail, msg);
    }
    pub fn skip(self: Logger, msg: []const u8) void {
        line(self.sink, tags.skip, msg);
    }
    /// Log at a runtime-chosen level.
    pub fn status(self: Logger, level: Level, msg: []const u8) void {
        line(self.sink, tags.of(level), msg);
    }
};

/// Bind a `Sink` into a `Logger`.
pub fn logger(sink: Sink) Logger {
    return .{ .sink = sink };
}

/// FlashOS shell homescreen: `FlashOS [v<version>] by <author> - type 'help'
/// for commands`, followed by a blank line. `version` and `author` are passed
/// in (this module is freestanding) — fsh feeds `build_options.version`, itself
/// sourced from build.zig.zon, so the release version lives in exactly one
/// place. The `type 'help' for commands` tail is the frozen boot-success marker
/// (run_qemu_test.sh greps it x3) — keep it byte-for-byte.
pub fn homescreen(sink: Sink, version: []const u8, author: []const u8) void {
    sink("FlashOS [v");
    sink(version);
    sink("] by ");
    sink(author);
    sink(marker_ready);
    sink("\n\n");
}
