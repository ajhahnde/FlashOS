//! FlashOS shared terminal look.
//!
//! One crate, compiled into every binary that draws to the console: the boot log
//! and the userspace tools (fsh, login, dmesg, ...). Editing it restyles the whole
//! system on the next build -- there is no second copy of a bracket tag or an ANSI
//! code anywhere else on the Rust side.
//!
//! Layout: the look is split by concern so it scales as the UI grows, but it stays
//! a single import -- consumers reach the whole surface through this crate.
//!
//!   * [`palette`] -- the color knob + the ANSI palette
//!   * [`tags`]    -- the [`Level`] severity taxonomy + each level's [`Tag`]
//!   * [`screen`]  -- the non-full-screen line layer (clear, key/value rows)
//!   * this file   -- the [`Sink`], the renderers, the [`Logger`], the homescreen
//!
//! Freestanding by construction: no allocator, no formatting engine, no dependency
//! on kernel internals or flibc. Output is routed through a caller-supplied
//! [`Sink`], so the same renderers serve the kernel and userland with neither side
//! leaking in.
//!
//! This crate is the single source of truth for the console look across the
//! kernel and userland.

#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(test)]
extern crate std;

pub mod palette;
pub mod screen;
pub mod tags;

pub use tags::{Level, Tag, FAIL, INFO, LOAD, OK, SKIP, WARN};

/// Whether the palette is emitting escapes, lifted so call sites read
/// `console_ui::COLOR`.
pub const COLOR: bool = palette::COLOR;

/// Box-drawing charset for the screen-layer panels. `false` = ASCII, `true` =
/// Unicode.
pub const UNICODE: bool = palette::UNICODE;

/// A byte sink. Each consumer binds it to its own console writer: the kernel to a
/// byte loop over its main output, userland to `write(1, ...)`. Context-free by
/// design -- a plain function pointer carries no environment, so a renderer needs
/// neither an allocator nor a generic parameter to reach the console.
pub type Sink = fn(&[u8]);

/// Boot-success marker -- the homescreen tail. Frozen: `scripts/run_qemu_test.sh`
/// greps this literal (x3 per boot) as the boot pass signal. Do not reword without
/// updating the contract header in that script.
pub const MARKER_READY: &[u8] = b" - type 'help' for commands";

// ---- renderers -------------------------------------------------------------

/// Write a tag as `<pre><word><post>` with the brackets + padding in the default
/// color and only `word` tinted by `t.ansi`. Color off => both ANSI strings are
/// empty and the bytes are the plain six-wide `[ OK ]` form.
fn write_tag(sink: Sink, t: Tag) {
    sink(t.pre);
    sink(t.ansi);
    sink(t.word);
    sink(palette::RESET);
    sink(t.post);
}

/// Write a tag followed by a single space, with no message and no newline -- the
/// seam for a line whose tail is assembled by the caller.
pub fn tagged(sink: Sink, t: Tag) {
    write_tag(sink, t);
    sink(b" ");
}

/// Write one finished tagged line: `<tag> <msg>\n`, the tag colored when enabled.
pub fn line(sink: Sink, t: Tag, msg: &[u8]) {
    tagged(sink, t);
    sink(msg);
    sink(b"\n");
}

/// A plain banner / homescreen line (text + newline).
pub fn banner(sink: Sink, text: &[u8]) {
    sink(text);
    sink(b"\n");
}

/// A pending stage that resolves in place. [`stage`] prints `[LOAD] <msg>` with no
/// newline; a later [`Stage::done`] / [`Stage::failed`] carriage-returns to column
/// 0 and overwrites the tag, then ends the line. Same width + same message text
/// means the overwrite is exact even with color on (the escapes are zero-width).
#[derive(Clone, Copy)]
pub struct Stage<'a> {
    sink: Sink,
    msg: &'a [u8],
}

impl Stage<'_> {
    /// Flip the pending tag to green `[ OK ]` and finish the line.
    pub fn done(self) {
        self.resolve(OK);
    }

    /// Flip the pending tag to red `[FAIL]` and finish the line.
    pub fn failed(self) {
        self.resolve(FAIL);
    }

    fn resolve(self, t: Tag) {
        (self.sink)(b"\r");
        line(self.sink, t, self.msg);
    }
}

/// Begin a pending stage: prints `[LOAD] <msg>` (no newline yet). Resolve it with
/// [`Stage::done`] or [`Stage::failed`].
pub fn stage(sink: Sink, msg: &[u8]) -> Stage<'_> {
    tagged(sink, LOAD);
    sink(msg);
    Stage { sink, msg }
}

/// A [`Sink`] bound once, so a consumer logs `log.ok(...)` instead of repeating the
/// sink at every call. Pure sugar over the free [`line`] renderer -- the look is
/// unchanged.
#[derive(Clone, Copy)]
pub struct Logger {
    sink: Sink,
}

impl Logger {
    pub fn ok(self, msg: &[u8]) {
        line(self.sink, OK, msg);
    }
    pub fn info(self, msg: &[u8]) {
        line(self.sink, INFO, msg);
    }
    pub fn warn(self, msg: &[u8]) {
        line(self.sink, WARN, msg);
    }
    pub fn fail(self, msg: &[u8]) {
        line(self.sink, FAIL, msg);
    }
    pub fn skip(self, msg: &[u8]) {
        line(self.sink, SKIP, msg);
    }
    /// Log at a runtime-chosen level.
    pub fn status(self, level: Level, msg: &[u8]) {
        line(self.sink, tags::of(level), msg);
    }
}

/// Bind a [`Sink`] into a [`Logger`].
pub fn logger(sink: Sink) -> Logger {
    Logger { sink }
}

// ---- assembled lines -------------------------------------------------------

/// Copy `s` into `buf` at `at`, clamped to `buf.len()`; returns the new offset.
fn append(buf: &mut [u8], at: usize, s: &[u8]) -> usize {
    let mut i = 0;
    while i < s.len() && at + i < buf.len() {
        buf[at + i] = s[i];
        i += 1;
    }
    at + i
}

/// Assemble the shell prompt `<user> @ <cwd> <sigil> ` into `buf`, returning the
/// filled slice. The ANSI escapes are spelled only here, never in fsh: amber user
/// (bold when root), dim `@`, white cwd, amber sigil (`# ` for root, `$ ` otherwise).
/// With color off every escape collapses to nothing and the bytes are the bare
/// `<user> @ <cwd> # ` / `$ ` form. A short buffer truncates rather than overruns.
pub fn render_prompt<'a>(buf: &'a mut [u8], user: &[u8], cwd: &[u8], root: bool) -> &'a [u8] {
    let mut n = 0;
    // user: bold amber (the Flash-brand accent).
    n = append(buf, n, palette::BOLD);
    n = append(buf, n, palette::YELLOW);
    n = append(buf, n, user);
    n = append(buf, n, palette::RESET);
    // separator: dim so the two identity halves read as one unit.
    n = append(buf, n, palette::DIM);
    n = append(buf, n, b" @ ");
    n = append(buf, n, palette::RESET);
    // cwd: white -- bright neutral, stands apart from the amber identity + sigil.
    n = append(buf, n, palette::WHITE);
    n = append(buf, n, cwd);
    n = append(buf, n, palette::RESET);
    n = append(buf, n, b" ");
    // sigil: amber like the user; root also bold to flag elevated privilege.
    if root {
        n = append(buf, n, palette::BOLD);
    }
    n = append(buf, n, palette::YELLOW);
    n = append(buf, n, if root { b"# " } else { b"$ " });
    n = append(buf, n, palette::RESET);
    &buf[..n]
}

/// FlashOS shell homescreen: `FlashOS [v<version>] by <author> - type 'help' for
/// commands`, followed by a blank line. `version` and `author` are passed in (this
/// crate is freestanding), so the release version lives in exactly one place.
///
/// Every escape is closed with `RESET` *before* [`MARKER_READY`] so the
/// boot-watchdog substring grep still matches bare bytes -- an unclosed color here
/// would splice an escape into the marker and break the contract.
pub fn homescreen(sink: Sink, version: &[u8], author: &[u8]) {
    sink(b"Flash");
    sink(palette::YELLOW);
    sink(b"OS");
    sink(palette::RESET);
    sink(b" [v");
    sink(palette::GREY);
    sink(version);
    sink(palette::RESET);
    sink(b"] by ");
    sink(palette::GREY);
    sink(author);
    sink(palette::RESET);
    sink(MARKER_READY);
    sink(b"\n\n");
}

/// A capturing sink, so the renderers can be asserted byte-for-byte on the host.
/// Thread-local because `cargo test` runs tests in parallel and a [`Sink`] carries
/// no context to key on.
#[cfg(test)]
pub(crate) mod testing {
    use std::cell::RefCell;
    use std::vec::Vec;

    std::thread_local! {
        static BUF: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    }

    pub fn cap_sink(bytes: &[u8]) {
        BUF.with(|b| b.borrow_mut().extend_from_slice(bytes));
    }

    pub fn cap_reset() {
        BUF.with(|b| b.borrow_mut().clear());
    }

    pub fn captured() -> Vec<u8> {
        BUF.with(|b| b.borrow().clone())
    }
}

#[cfg(test)]
mod tests {
    use super::testing::{cap_reset, cap_sink, captured};
    use super::*;
    use std::format;
    use std::vec::Vec;

    /// Strip SGR escapes, so a test can assert the column geometry the
    /// carriage-return overwrite depends on regardless of the color knob.
    fn uncolored(bytes: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == 0x1b {
                while i < bytes.len() && bytes[i] != b'm' {
                    i += 1;
                }
                i += 1;
            } else {
                out.push(bytes[i]);
                i += 1;
            }
        }
        out
    }

    #[test]
    fn a_tagged_line_is_the_six_column_label_then_the_message() {
        cap_reset();
        line(cap_sink, OK, b"Reached target Shell");
        assert_eq!(
            uncolored(&captured()),
            b"[ OK ] Reached target Shell\n".to_vec()
        );
    }

    #[test]
    fn only_the_word_is_tinted_and_the_brackets_stay_default() {
        cap_reset();
        line(cap_sink, FAIL, b"rng");
        // The escape opens *after* the bracket and closes before it.
        assert_eq!(
            captured(),
            b"[\x1b[31mFAIL\x1b[0m] rng\n".to_vec(),
            "the brackets must not be swallowed by the tint"
        );
    }

    #[test]
    fn a_resolved_stage_overwrites_the_pending_tag_in_the_same_columns() {
        cap_reset();
        stage(cap_sink, b"Mounting /mnt").done();
        // [LOAD] <msg>, then \r, then [ OK ] <msg>\n -- both labels are six wide,
        // so the second write lands exactly on top of the first.
        assert_eq!(
            uncolored(&captured()),
            b"[LOAD] Mounting /mnt\r[ OK ] Mounting /mnt\n".to_vec()
        );
    }

    #[test]
    fn the_homescreen_marker_survives_the_color_escapes_unspliced() {
        cap_reset();
        homescreen(cap_sink, env!("CARGO_PKG_VERSION").as_bytes(), b"ajhahn");
        let out = captured();
        // The boot watchdog greps the raw marker with grep -F: it must appear in
        // the byte stream with no escape spliced into it, color on or off.
        assert!(
            out.windows(MARKER_READY.len()).any(|w| w == MARKER_READY),
            "boot-success marker was broken by an ANSI escape"
        );
        let expected = format!(
            "FlashOS [v{}] by ajhahn - type 'help' for commands\n\n",
            env!("CARGO_PKG_VERSION")
        );
        assert_eq!(uncolored(&out), expected.as_bytes());
    }

    #[test]
    fn the_prompt_ends_in_a_hash_for_root_and_a_dollar_otherwise() {
        let mut buf = [0u8; 128];
        assert_eq!(
            uncolored(render_prompt(&mut buf, b"root", b"/", true)),
            b"root @ / # ".to_vec()
        );

        let mut buf = [0u8; 128];
        assert_eq!(
            uncolored(render_prompt(&mut buf, b"flash", b"/mnt", false)),
            b"flash @ /mnt $ ".to_vec()
        );
    }

    #[test]
    fn a_short_prompt_buffer_truncates_instead_of_overrunning() {
        let mut buf = [0u8; 4];
        let out = render_prompt(&mut buf, b"averyverylongusername", b"/deep/path", false);
        assert!(out.len() <= 4);
    }
}
