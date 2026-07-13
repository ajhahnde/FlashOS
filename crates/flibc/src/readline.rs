//! The raw line editor over fd 0.
//!
//! The kernel console is deliberately dumb -- no termios, no cooked mode -- so all
//! line editing lives here in userland. A per-byte state machine reads one byte
//! through the io seam, echoes printable bytes back through it, and submits on
//! CR/LF. The caller owns the line buffer; overflow truncates silently.
//!
//! The split is between what is pure and what traps:
//!
//!   * [`State`], [`Action`], [`step`] -- the byte-to-buffer transition for the
//!     plain, append-only editor.
//!   * [`Edit`] and the [`State`] cursor operations -- the transitions the full
//!     editor is built from.
//!   * [`History`] -- a caller-owned ring of submitted lines, for Up/Down recall.
//!   * [`Outcome`] -- what a completed call returns. A caller treats [`Outcome::Eof`]
//!     as logout and [`Outcome::Abandoned`] as "redraw the prompt, drop the input".
//!
//! Everything above is pure and host-tested. Only the drivers at the bottom trap
//! into the kernel, and they are the thin part.
//!
//! ## Editing rules for the plain editor
//!
//!   * `0x20..=0x7e` printable -- push to the buffer and echo. Overflow drops the
//!     byte with no echo.
//!   * `0x08` / `0x7f` (BS / DEL) -- pop one byte if the buffer is non-empty and
//!     emit `"\x08 \x08"` so the rubout column blanks. A no-op on an empty buffer.
//!   * `\r` / `\n` -- submit.
//!   * `0x04` (^D) on an empty line -- end of input. Mid-line it is ignored, which
//!     is what conservative shells do.
//!   * `0x03` (^C) -- abandon, with no echo (the caller draws the newline).
//!   * `0x09` (TAB) -- request completion. The completing driver acts on it; the
//!     plain one ignores it.
//!   * anything else -- ignored.
//!
//! ## A note on the byte loops
//!
//! The buffers here are copied and shifted a byte at a time. That is not a
//! stylistic choice: EL0 payloads run with `SCTLR_EL1.A` asserted, so a copy the
//! compiler widens into a 16-byte vector store takes an alignment fault against a
//! line buffer or a history slot that is only 8-aligned. The bare-metal target this
//! crate compiles for carries `+strict-align` and no NEON, which forecloses that
//! widening at code generation, so a plain loop is safe here and nothing has to
//! hold the compiler back by hand.

#[cfg(target_os = "none")]
use crate::{completion, io, keys};
#[cfg(target_os = "none")]
use flashos_abi::syscall::{Dirent, DT_DIR};
#[cfg(target_os = "none")]
use flashos_user_rt::syscall;

/// Copy `src` into `dst`, returning the number of bytes copied (the shorter of the
/// two lengths). A long source is clipped rather than rejected.
fn copy_bytes(dst: &mut [u8], src: &[u8]) -> usize {
    let n = if dst.len() < src.len() {
        dst.len()
    } else {
        src.len()
    };
    dst[..n].copy_from_slice(&src[..n]);
    n
}

/// What the driver must repaint after a cursor-aware edit. [`Edit::None`] means the
/// operation was a no-op at a boundary -- the buffer was full, or the cursor was
/// already at an edge -- and nothing is drawn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Edit {
    /// Nothing happened; draw nothing.
    None,
    /// A byte was inserted at the cursor: repaint `buf[pos - 1..len]`, then step the
    /// cursor back `len - pos` columns to sit just after the new byte.
    Insert,
    /// The byte before the cursor was removed: backspace, repaint `buf[pos..len]`,
    /// blank the vacated last column, step back `len - pos + 1` columns.
    Delete,
    /// The cursor moved one column left (a bare backspace, no erase).
    Left,
    /// The cursor moved one column right (re-emit the byte it stepped over).
    Right,
}

/// Line editor state over a caller-provided buffer. `len` is the committed byte
/// count and `pos` the cursor offset, with the invariant `pos <= len <= buf.len()`.
/// The plain [`step`] editor is append-only and ignores `pos`; the cursor operations
/// below back the full editor.
pub struct State<'a> {
    buf: &'a mut [u8],
    len: usize,
    pos: usize,
}

impl<'a> State<'a> {
    pub fn new(buf: &'a mut [u8]) -> Self {
        Self {
            buf,
            len: 0,
            pos: 0,
        }
    }

    /// The committed bytes.
    pub fn line(&self) -> &[u8] {
        &self.buf[..self.len]
    }

    /// The committed bytes, borrowed for as long as the underlying buffer lives. A
    /// driver returns through this so the submitted line outlives the editor state.
    pub fn into_line(self) -> &'a [u8] {
        let len = self.len;
        let buf: &'a [u8] = self.buf;
        &buf[..len]
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn pos(&self) -> usize {
        self.pos
    }

    /// Insert `c` at the cursor, shifting the tail right. A no-op when full.
    pub fn insert_at(&mut self, c: u8) -> Edit {
        if self.len >= self.buf.len() {
            return Edit::None;
        }
        let mut i = self.len;
        while i > self.pos {
            self.buf[i] = self.buf[i - 1];
            i -= 1;
        }
        self.buf[self.pos] = c;
        self.len += 1;
        self.pos += 1;
        Edit::Insert
    }

    /// Delete the byte before the cursor, shifting the tail left. A no-op at column
    /// 0.
    pub fn backspace(&mut self) -> Edit {
        if self.pos == 0 {
            return Edit::None;
        }
        let mut i = self.pos;
        while i < self.len {
            self.buf[i - 1] = self.buf[i];
            i += 1;
        }
        self.len -= 1;
        self.pos -= 1;
        Edit::Delete
    }

    /// Move the cursor one column left. A no-op at column 0.
    pub fn move_left(&mut self) -> Edit {
        if self.pos == 0 {
            return Edit::None;
        }
        self.pos -= 1;
        Edit::Left
    }

    /// Move the cursor one column right. A no-op at the end of the line.
    pub fn move_right(&mut self) -> Edit {
        if self.pos >= self.len {
            return Edit::None;
        }
        self.pos += 1;
        Edit::Right
    }

    /// Replace the whole line with `s`, clipped to capacity, and put the cursor at
    /// the end. This is what a history recall paints with.
    pub fn replace_line(&mut self, s: &[u8]) {
        self.len = copy_bytes(self.buf, s);
        self.pos = self.len;
    }
}

/// What the driver should do with a byte after [`step`] has run. Pure data: the
/// driver turns it into writes and returns, and the tests inspect it directly.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    /// Consumed silently -- an overflow drop, an ignored control byte, a mid-line
    /// ^D, or a backspace on an empty buffer.
    None,
    /// Accepted into the buffer; echo this byte.
    Echo(u8),
    /// One byte was popped; emit the standard rubout.
    Backspace,
    /// TAB: complete the current token. The completing driver extends the buffer in
    /// place; the plain one ignores this.
    Complete,
    /// The line is finished; return the buffered slice.
    Submit,
    /// ^D on an empty line.
    Eof,
    /// ^C. No echo -- the caller redraws.
    Abandon,
}

/// The result of a full editor call.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome<'a> {
    /// A submitted line, pointing into the caller's buffer.
    Line(&'a [u8]),
    /// End of input: ^D on an empty line, or a failed read.
    Eof,
    /// The user cancelled the line with ^C. The caller drops the buffer.
    Abandoned,
}

/// The one-byte transition for the plain, append-only editor. The full editor does
/// not use this: it routes bytes through the key decoder and the cursor operations
/// instead.
pub fn step(state: &mut State<'_>, byte: u8) -> Action {
    match byte {
        b'\r' | b'\n' => Action::Submit,
        0x03 => Action::Abandon,
        0x04 => {
            if state.len == 0 {
                Action::Eof
            } else {
                Action::None
            }
        }
        0x09 => Action::Complete,
        0x08 | 0x7f => {
            if state.len == 0 {
                return Action::None;
            }
            state.len -= 1;
            Action::Backspace
        }
        0x20..=0x7e => {
            if state.len >= state.buf.len() {
                return Action::None;
            }
            state.buf[state.len] = byte;
            state.len += 1;
            Action::Echo(byte)
        }
        _ => Action::None,
    }
}

// ---- command history -------------------------------------------------------

/// Per-entry capacity for a recorded line. A longer submitted line is clipped when
/// recorded; recall still works, the stored copy is just shorter. Lines hold only
/// printable bytes, so a slot needs no terminator -- `len` delimits it.
pub const HIST_LINE_CAP: usize = 256;

/// One history slot. The caller declares an array of these and hands a slice to
/// [`History::new`]; the history itself never allocates.
#[derive(Clone, Copy)]
pub struct HistSlot {
    bytes: [u8; HIST_LINE_CAP],
    len: usize,
}

impl Default for HistSlot {
    fn default() -> Self {
        Self {
            bytes: [0; HIST_LINE_CAP],
            len: 0,
        }
    }
}

/// A fixed-capacity ring of recently submitted lines, navigated with Up and Down.
/// The in-progress line is stashed on the first Up, so stepping Down past the newest
/// entry restores what the user was typing.
pub struct History<'a> {
    slots: &'a mut [HistSlot],
    stash: HistSlot,
    /// Ring index of the next write.
    head: usize,
    /// Filled slots, saturating at the ring's capacity.
    count: usize,
    /// 0 while editing the live line; k while recalling the k-th newest entry.
    nav: usize,
}

impl<'a> History<'a> {
    pub fn new(slots: &'a mut [HistSlot]) -> Self {
        Self {
            slots,
            stash: HistSlot::default(),
            head: 0,
            count: 0,
            nav: 0,
        }
    }

    /// The `back`-th newest entry, counting from 1. The newest sits one behind the
    /// write head.
    fn entry(&self, back: usize) -> &[u8] {
        let m = self.slots.len();
        let i = (self.head + m - back) % m;
        &self.slots[i].bytes[..self.slots[i].len]
    }

    /// Record a submitted line and leave browse mode. A blank line, and an exact
    /// repeat of the most recent entry, are not recorded.
    pub fn push(&mut self, line: &[u8]) {
        self.nav = 0;
        if self.slots.is_empty() || line.is_empty() {
            return;
        }
        if self.count > 0 && self.entry(1) == line {
            return;
        }
        let head = self.head;
        let n = copy_bytes(&mut self.slots[head].bytes, line);
        self.slots[head].len = n;
        self.head = (self.head + 1) % self.slots.len();
        if self.count < self.slots.len() {
            self.count += 1;
        }
    }

    /// Step one entry older. The first step stashes `current` -- the live,
    /// unsubmitted line -- so [`History::newer`] can restore it. Returns `None` at
    /// the oldest entry, and on an empty history, so the caller draws nothing.
    pub fn older(&mut self, current: &[u8]) -> Option<&[u8]> {
        if self.count == 0 {
            return None;
        }
        if self.nav == 0 {
            self.stash.len = copy_bytes(&mut self.stash.bytes, current);
            self.nav = 1;
            return Some(self.entry(1));
        }
        if self.nav < self.count {
            self.nav += 1;
            return Some(self.entry(self.nav));
        }
        None
    }

    /// Step one entry newer: the next entry, the stashed live line when stepping off
    /// the newest one, or `None` when not browsing.
    pub fn newer(&mut self) -> Option<&[u8]> {
        if self.nav == 0 {
            return None;
        }
        if self.nav > 1 {
            self.nav -= 1;
            return Some(self.entry(self.nav));
        }
        self.nav = 0;
        Some(&self.stash.bytes[..self.stash.len])
    }

    /// Leave browse mode without recording a line -- the ^C path.
    pub fn reset_nav(&mut self) {
        self.nav = 0;
    }
}

/// Completion policy for the completing editors.
///
/// `builtins` are extra command names offered for the first token -- a shell's
/// in-process built-ins, which are absent from the binary directory. `bin_dir` is the
/// directory searched for command completion; path completion needs no policy,
/// because it reads the directory named in the token itself. `prompt` is what the
/// caller printed before this line: the double-TAB candidate listing reprints it
/// after the list, so the cursor returns to a faithful prompt.
#[derive(Clone, Copy)]
pub struct Completion<'a> {
    pub builtins: &'a [&'a [u8]],
    /// NUL-terminated: it is handed straight to the kernel.
    pub bin_dir: &'a [u8],
    pub prompt: &'a [u8],
}

impl Default for Completion<'_> {
    fn default() -> Self {
        Self {
            builtins: &[],
            bin_dir: b"/bin\0",
            prompt: b"",
        }
    }
}

// ---- the drivers ------------------------------------------------------------
//
// The only part that traps. Everything above is pure, and everything here is a
// loop over the pure transitions plus the VT100 bytes a dumb serial console
// understands.

/// Read a line interactively from fd 0. Blocks until the editor reaches a terminal
/// action (submit, end of input, or abandon) or the read fails. The returned line
/// lives in `buf`. TAB and the arrow keys are ignored -- use [`readline_edit`] for
/// those.
#[cfg(target_os = "none")]
pub fn readline(buf: &mut [u8]) -> Outcome<'_> {
    let mut state = State::new(buf);
    loop {
        let Some(byte) = io::console_input() else {
            return Outcome::Eof;
        };
        match step(&mut state, byte) {
            Action::None => {}
            Action::Echo(b) => echo_byte(b),
            Action::Backspace => emit_rubout(),
            Action::Complete => {} // no policy, so TAB does nothing
            Action::Submit => return Outcome::Line(state.into_line()),
            Action::Eof => return Outcome::Eof,
            Action::Abandon => return Outcome::Abandoned,
        }
    }
}

/// Like [`readline`], but TAB completes the current token against `comp`. Equivalent
/// to [`readline_edit`] with no history.
#[cfg(target_os = "none")]
pub fn readline_completing<'a>(buf: &'a mut [u8], comp: Completion<'_>) -> Outcome<'a> {
    readline_edit(buf, comp, None)
}

/// The full line editor: TAB completion, Left/Right cursor motion with insert and
/// backspace at the cursor, and Up/Down recall from `hist`. Input is decoded through
/// the key decoder, so a multi-byte arrow sequence is absorbed rather than echoed as
/// a literal `[A`.
#[cfg(target_os = "none")]
pub fn readline_edit<'a>(
    buf: &'a mut [u8],
    comp: Completion<'_>,
    mut hist: Option<&mut History<'_>>,
) -> Outcome<'a> {
    let mut state = State::new(buf);
    let mut dec = keys::Decoder::new();
    // Consecutive TABs that had nothing left to insert. The second one lists the
    // candidates; any other key clears the streak.
    let mut stuck_tabs = false;
    loop {
        let Some(byte) = io::console_input() else {
            return Outcome::Eof;
        };
        let ev = dec.feed(byte);
        let was_stuck = stuck_tabs;
        stuck_tabs = false;
        match ev.key {
            keys::Key::Char => {
                let e = state.insert_at(ev.ch);
                render(&mut state, e);
            }
            keys::Key::Backspace => {
                let e = state.backspace();
                render(&mut state, e);
            }
            keys::Key::Left => {
                let e = state.move_left();
                render(&mut state, e);
            }
            keys::Key::Right => {
                let e = state.move_right();
                render(&mut state, e);
            }
            keys::Key::Up => {
                if let Some(h) = hist.as_deref_mut() {
                    // The recalled line borrows the history, so the redraw extent is
                    // captured before the swap and the paint is done through a copy.
                    if let Some(line) = h.older(state.line()) {
                        let mut recalled = [0u8; HIST_LINE_CAP];
                        let n = copy_bytes(&mut recalled, line);
                        replace_and_render(&mut state, &recalled[..n]);
                    }
                }
            }
            keys::Key::Down => {
                if let Some(h) = hist.as_deref_mut() {
                    if let Some(line) = h.newer() {
                        let mut recalled = [0u8; HIST_LINE_CAP];
                        let n = copy_bytes(&mut recalled, line);
                        replace_and_render(&mut state, &recalled[..n]);
                    }
                }
            }
            keys::Key::Tab => match do_complete(&mut state, &comp) {
                completion::TabClass::Stuck => {
                    // The first stuck TAB arms the listing; the next one prints it.
                    if was_stuck {
                        list_candidates(&mut state, &comp);
                    } else {
                        stuck_tabs = true;
                    }
                }
                completion::TabClass::Progressed | completion::TabClass::Empty => {}
            },
            keys::Key::Enter => {
                if let Some(h) = hist.as_deref_mut() {
                    h.push(state.line());
                }
                return Outcome::Line(state.into_line());
            }
            keys::Key::CtrlC => {
                if let Some(h) = hist.as_deref_mut() {
                    h.reset_nav();
                }
                return Outcome::Abandoned;
            }
            keys::Key::CtrlD => {
                if state.is_empty() {
                    return Outcome::Eof;
                }
                // Mid-line ^D is ignored.
            }
            // Everything readline does not bind: a bare escape, a mid-sequence
            // non-event, and the editor-only navigation and command keys.
            _ => {}
        }
    }
}

#[cfg(target_os = "none")]
fn echo_byte(b: u8) {
    io::console_sink(&[b]);
}

#[cfg(target_os = "none")]
fn emit_rubout() {
    io::console_sink(b"\x08 \x08");
}

/// Turn one [`Edit`] directive into VT100 bytes. The cursor arithmetic follows from
/// the post-operation `pos` and `len`. A backspace is emitted as a bare `0x08` --
/// move left, do not erase -- because that is what the dumb serial console
/// understands; the trailing blank in the delete case clears what the shrink left
/// behind.
#[cfg(target_os = "none")]
fn render(state: &mut State<'_>, e: Edit) {
    match e {
        Edit::None => {}
        Edit::Insert => {
            write_range(&state.buf[state.pos - 1..state.len]);
            emit_back(state.len - state.pos);
        }
        Edit::Delete => {
            echo_byte(0x08);
            write_range(&state.buf[state.pos..state.len]);
            echo_byte(b' ');
            emit_back(state.len - state.pos + 1);
        }
        Edit::Left => echo_byte(0x08),
        Edit::Right => echo_byte(state.buf[state.pos - 1]),
    }
}

/// Redraw for a history recall: swap the line, then repaint from column 0. The old
/// extent is captured before the swap so any surplus a shorter recalled line leaves
/// behind can be blanked.
#[cfg(target_os = "none")]
fn replace_and_render(state: &mut State<'_>, line: &[u8]) {
    let old_len = state.len;
    let old_pos = state.pos;
    state.replace_line(line);
    emit_back(old_pos); // cursor home to column 0 of the input
    write_range(&state.buf[..state.len]);
    if old_len > state.len {
        let extra = old_len - state.len;
        emit_spaces(extra); // blank the tail the shorter line vacated
        emit_back(extra);
    }
}

#[cfg(target_os = "none")]
fn write_range(s: &[u8]) {
    if !s.is_empty() {
        io::console_sink(s);
    }
}

#[cfg(target_os = "none")]
fn emit_back(n: usize) {
    for _ in 0..n {
        echo_byte(0x08);
    }
}

#[cfg(target_os = "none")]
fn emit_spaces(n: usize) {
    for _ in 0..n {
        echo_byte(b' ');
    }
}

/// Resolve the directory a completion enumerates into a NUL-terminated path: the
/// configured binary directory for a command, the token's own directory for a path.
/// Returns `None` when the name overflows the scratch buffer.
#[cfg(target_os = "none")]
fn resolve_dir<'d>(
    ctx: &completion::Context<'_>,
    comp: &Completion<'d>,
    dirbuf: &'d mut [u8; 128],
) -> Option<&'d [u8]> {
    match ctx.kind {
        completion::Kind::Command => Some(comp.bin_dir),
        completion::Kind::Path => {
            let d: &[u8] = if ctx.dir.is_empty() { b"." } else { ctx.dir };
            if d.len() >= dirbuf.len() {
                return None;
            }
            let n = copy_bytes(dirbuf, d);
            dirbuf[n] = 0;
            Some(&dirbuf[..=n])
        }
    }
}

/// The length of the NUL-terminated name in a directory entry.
#[cfg(target_os = "none")]
fn name_len(d: &Dirent) -> usize {
    let mut n = 0;
    while n < d.name.len() && d.name[n] != 0 {
        n += 1;
    }
    n
}

/// Fold one candidate into the running longest common prefix.
#[cfg(target_os = "none")]
fn fold(best: &mut [u8; 32], best_len: &mut usize, count: &mut usize, name: &[u8]) {
    if *count == 0 {
        *best_len = copy_bytes(best, name);
    } else {
        *best_len = completion::common_prefix_len(&best[..*best_len], name);
    }
    *count += 1;
}

/// On TAB: gather the candidates that extend the token ending at the cursor, then
/// insert their longest common extension and echo it. A unique match also gets a
/// trailing `' '` (a command or a file) or `'/'` (a directory). The return value
/// tells the caller how far it got, so a stuck repeat can arm the listing.
#[cfg(target_os = "none")]
fn do_complete(state: &mut State<'_>, comp: &Completion<'_>) -> completion::TabClass {
    let ctx = completion::parse(&state.buf[..state.pos]);
    let mut dirbuf = [0u8; 128];
    let Some(dir) = resolve_dir(&ctx, comp, &mut dirbuf) else {
        return completion::TabClass::Empty;
    };

    let mut best = [0u8; 32];
    let mut best_len = 0;
    let mut count = 0;
    let mut only_is_dir = false;

    // Built-ins participate in command completion only.
    if ctx.kind == completion::Kind::Command {
        for name in comp.builtins {
            if completion::has_prefix(name, ctx.prefix) {
                fold(&mut best, &mut best_len, &mut count, name);
            }
        }
    }

    let mut d = Dirent::default();
    let mut idx: u64 = 0;
    // SAFETY: `dir` is NUL-terminated (a literal from the policy, or terminated by
    // resolve_dir), and `d` is a live, correctly-typed entry the kernel fills.
    while unsafe { syscall::readdir(dir.as_ptr(), idx, &mut d) } == 0 {
        let name = &d.name[..name_len(&d)];
        if completion::has_prefix(name, ctx.prefix) {
            let before = count;
            fold(&mut best, &mut best_len, &mut count, name);
            if before == 0 && count == 1 {
                only_is_dir = d.d_type == DT_DIR;
            }
        }
        idx += 1;
    }

    let cls = completion::classify(count, best_len, ctx.prefix.len());
    if cls == completion::TabClass::Progressed {
        let extension = &best[ctx.prefix.len()..best_len];
        emit_insert(state, extension);
        if count == 1 {
            emit_insert(state, if only_is_dir { b"/" } else { b" " });
        }
    }
    cls
}

/// The double-TAB listing: print every candidate sharing the token's prefix on a
/// fresh line, then redraw the prompt and the in-progress line so editing resumes
/// where it left off. The same sources are re-walked rather than cached, because the
/// candidate set is small and a stack cache would not outlive the directory walk.
#[cfg(target_os = "none")]
fn list_candidates(state: &mut State<'_>, comp: &Completion<'_>) {
    let ctx = completion::parse(&state.buf[..state.pos]);
    let mut dirbuf = [0u8; 128];
    let Some(dir) = resolve_dir(&ctx, comp, &mut dirbuf) else {
        return;
    };

    write_range(b"\n");
    let mut any = false;
    if ctx.kind == completion::Kind::Command {
        for name in comp.builtins {
            if completion::has_prefix(name, ctx.prefix) {
                emit_candidate(name, &mut any);
            }
        }
    }
    let mut d = Dirent::default();
    let mut idx: u64 = 0;
    // SAFETY: as in do_complete -- `dir` is NUL-terminated and `d` is a live entry.
    while unsafe { syscall::readdir(dir.as_ptr(), idx, &mut d) } == 0 {
        let name = &d.name[..name_len(&d)];
        if completion::has_prefix(name, ctx.prefix) {
            emit_candidate(name, &mut any);
        }
        idx += 1;
    }
    write_range(b"\n");

    // Redraw the prompt and the line, then walk the cursor back to its column.
    write_range(comp.prompt);
    write_range(&state.buf[..state.len]);
    emit_back(state.len - state.pos);
}

/// One listed candidate, two spaces from the previous one.
#[cfg(target_os = "none")]
fn emit_candidate(name: &[u8], any: &mut bool) {
    if *any {
        write_range(b"  ");
    }
    write_range(name);
    *any = true;
}

/// Insert `ext` at the cursor, respecting capacity, echoing each byte through the
/// same redraw an interactive insert uses -- so a completion landed mid-line
/// repaints the tail correctly, and at the end of a line collapses to a plain echo.
#[cfg(target_os = "none")]
fn emit_insert(state: &mut State<'_>, ext: &[u8]) {
    for &c in ext {
        let e = state.insert_at(c);
        render(state, e);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- step ----

    #[test]
    fn a_printable_byte_echoes_and_pushes() {
        let mut buf = [0u8; 16];
        let mut s = State::new(&mut buf);
        assert_eq!(step(&mut s, b'a'), Action::Echo(b'a'));
        assert_eq!(s.len(), 1);
        assert_eq!(s.line(), b"a");
    }

    #[test]
    fn a_full_printable_run_builds_the_buffered_line() {
        let mut buf = [0u8; 16];
        let mut s = State::new(&mut buf);
        for &c in b"hello" {
            step(&mut s, c);
        }
        assert_eq!(s.line(), b"hello");
    }

    #[test]
    fn backspace_on_an_empty_buffer_is_a_no_op() {
        let mut buf = [0u8; 16];
        let mut s = State::new(&mut buf);
        assert_eq!(step(&mut s, 0x08), Action::None);
        assert_eq!(s.len(), 0);
    }

    #[test]
    fn backspace_pops_one_byte_and_requests_a_rubout() {
        let mut buf = [0u8; 16];
        let mut s = State::new(&mut buf);
        step(&mut s, b'a');
        step(&mut s, b'b');
        assert_eq!(step(&mut s, 0x08), Action::Backspace);
        assert_eq!(s.line(), b"a");
    }

    #[test]
    fn del_behaves_the_same_as_backspace() {
        let mut buf = [0u8; 16];
        let mut s = State::new(&mut buf);
        step(&mut s, b'x');
        assert_eq!(step(&mut s, 0x7f), Action::Backspace);
        assert_eq!(s.len(), 0);
    }

    #[test]
    fn carriage_return_submits_the_line() {
        let mut buf = [0u8; 16];
        let mut s = State::new(&mut buf);
        step(&mut s, b'h');
        step(&mut s, b'i');
        assert_eq!(step(&mut s, b'\r'), Action::Submit);
        assert_eq!(s.line(), b"hi");
    }

    #[test]
    fn a_line_feed_also_submits() {
        let mut buf = [0u8; 16];
        let mut s = State::new(&mut buf);
        step(&mut s, b'a');
        assert_eq!(step(&mut s, b'\n'), Action::Submit);
    }

    #[test]
    fn ctrl_d_on_an_empty_buffer_is_end_of_input() {
        let mut buf = [0u8; 16];
        let mut s = State::new(&mut buf);
        assert_eq!(step(&mut s, 0x04), Action::Eof);
    }

    #[test]
    fn ctrl_d_mid_line_is_ignored() {
        let mut buf = [0u8; 16];
        let mut s = State::new(&mut buf);
        step(&mut s, b'a');
        assert_eq!(step(&mut s, 0x04), Action::None);
        assert_eq!(s.line(), b"a");
    }

    #[test]
    fn ctrl_c_abandons_regardless_of_buffer_state() {
        let mut buf = [0u8; 16];
        let mut s = State::new(&mut buf);
        assert_eq!(step(&mut s, 0x03), Action::Abandon);
        step(&mut s, b'x');
        assert_eq!(step(&mut s, 0x03), Action::Abandon);
    }

    #[test]
    fn tab_requests_completion() {
        let mut buf = [0u8; 16];
        let mut s = State::new(&mut buf);
        step(&mut s, b'l');
        assert_eq!(step(&mut s, 0x09), Action::Complete);
    }

    #[test]
    fn overflow_drops_the_byte_and_emits_no_echo() {
        let mut buf = [0u8; 3];
        let mut s = State::new(&mut buf);
        for &c in b"abc" {
            step(&mut s, c);
        }
        assert_eq!(s.len(), 3);
        assert_eq!(step(&mut s, b'd'), Action::None);
        assert_eq!(s.len(), 3);
        assert_eq!(s.line(), b"abc");
    }

    #[test]
    fn backspace_after_an_overflow_truncate_clears_the_most_recent_kept_byte() {
        let mut buf = [0u8; 2];
        let mut s = State::new(&mut buf);
        step(&mut s, b'a');
        step(&mut s, b'b');
        step(&mut s, b'c'); // dropped
        assert_eq!(step(&mut s, 0x08), Action::Backspace);
        assert_eq!(s.line(), b"a");
    }

    #[test]
    fn other_control_bytes_are_ignored() {
        let mut buf = [0u8; 16];
        let mut s = State::new(&mut buf);
        for c in [0x00, 0x01, 0x07, 0x1b, 0x1f, 0x80, 0xff] {
            assert_eq!(step(&mut s, c), Action::None);
        }
        assert_eq!(s.len(), 0);
    }

    // ---- cursor editing ----

    #[test]
    fn insert_at_the_end_appends_and_advances_the_cursor() {
        let mut buf = [0u8; 8];
        let mut s = State::new(&mut buf);
        assert_eq!(s.insert_at(b'a'), Edit::Insert);
        assert_eq!(s.insert_at(b'b'), Edit::Insert);
        assert_eq!(s.line(), b"ab");
        assert_eq!(s.pos(), 2);
    }

    #[test]
    fn insert_in_the_middle_shifts_the_tail_right() {
        let mut buf = [0u8; 8];
        let mut s = State::new(&mut buf);
        for &c in b"ac" {
            s.insert_at(c);
        }
        s.move_left(); // cursor between 'a' and 'c'
        assert_eq!(s.pos(), 1);
        assert_eq!(s.insert_at(b'b'), Edit::Insert);
        assert_eq!(s.line(), b"abc");
        assert_eq!(s.pos(), 2);
    }

    #[test]
    fn insert_is_a_no_op_when_the_buffer_is_full() {
        let mut buf = [0u8; 2];
        let mut s = State::new(&mut buf);
        s.insert_at(b'a');
        s.insert_at(b'b');
        assert_eq!(s.insert_at(b'c'), Edit::None);
        assert_eq!(s.line(), b"ab");
    }

    #[test]
    fn backspace_deletes_the_byte_before_the_cursor() {
        let mut buf = [0u8; 8];
        let mut s = State::new(&mut buf);
        for &c in b"abc" {
            s.insert_at(c);
        }
        s.move_left(); // between 'b' and 'c'
        assert_eq!(s.backspace(), Edit::Delete); // removes 'b'
        assert_eq!(s.line(), b"ac");
        assert_eq!(s.pos(), 1);
    }

    #[test]
    fn backspace_at_column_zero_is_a_no_op() {
        let mut buf = [0u8; 8];
        let mut s = State::new(&mut buf);
        s.insert_at(b'x');
        s.move_left();
        assert_eq!(s.backspace(), Edit::None);
        assert_eq!(s.line(), b"x");
    }

    #[test]
    fn left_and_right_honour_the_line_edges() {
        let mut buf = [0u8; 8];
        let mut s = State::new(&mut buf);
        for &c in b"hi" {
            s.insert_at(c);
        }
        assert_eq!(s.move_right(), Edit::None); // already at the end
        assert_eq!(s.move_left(), Edit::Left);
        assert_eq!(s.move_left(), Edit::Left);
        assert_eq!(s.move_left(), Edit::None); // at column 0
        assert_eq!(s.move_right(), Edit::Right);
    }

    #[test]
    fn replace_line_swaps_the_content_and_puts_the_cursor_at_the_end() {
        let mut buf = [0u8; 8];
        let mut s = State::new(&mut buf);
        for &c in b"hello" {
            s.insert_at(c);
        }
        s.move_left();
        s.replace_line(b"hi");
        assert_eq!(s.line(), b"hi");
        assert_eq!(s.pos(), 2);
    }

    #[test]
    fn replace_line_clips_to_capacity() {
        let mut buf = [0u8; 3];
        let mut s = State::new(&mut buf);
        s.replace_line(b"toolong");
        assert_eq!(s.line(), b"too");
        assert_eq!(s.pos(), 3);
    }

    // ---- history ----

    #[test]
    fn older_walks_back_and_newer_returns_to_the_stashed_live_line() {
        let mut slots = [HistSlot::default(); 4];
        let mut h = History::new(&mut slots);
        h.push(b"one");
        h.push(b"two");
        assert_eq!(h.older(b"th"), Some(b"two".as_slice()));
        assert_eq!(h.older(b"th"), Some(b"one".as_slice()));
        assert_eq!(h.older(b"th"), None); // already the oldest
        assert_eq!(h.newer(), Some(b"two".as_slice()));
        assert_eq!(h.newer(), Some(b"th".as_slice())); // the stash, restored
        assert_eq!(h.newer(), None); // no longer browsing
    }

    #[test]
    fn blank_lines_and_immediate_duplicates_are_not_recorded() {
        let mut slots = [HistSlot::default(); 4];
        let mut h = History::new(&mut slots);
        h.push(b"ls");
        h.push(b""); // blank, ignored
        h.push(b"ls"); // duplicate of the last, ignored
        h.push(b"pwd");
        assert_eq!(h.older(b""), Some(b"pwd".as_slice()));
        assert_eq!(h.older(b""), Some(b"ls".as_slice()));
        assert_eq!(h.older(b""), None); // only two distinct entries
    }

    #[test]
    fn the_ring_overwrites_the_oldest_entry() {
        let mut slots = [HistSlot::default(); 2];
        let mut h = History::new(&mut slots);
        h.push(b"a");
        h.push(b"b");
        h.push(b"c"); // evicts "a"
        assert_eq!(h.older(b""), Some(b"c".as_slice()));
        assert_eq!(h.older(b""), Some(b"b".as_slice()));
        assert_eq!(h.older(b""), None); // "a" is gone
    }

    #[test]
    fn older_and_newer_on_an_empty_history_are_no_ops() {
        let mut slots = [HistSlot::default(); 2];
        let mut h = History::new(&mut slots);
        assert_eq!(h.older(b"x"), None);
        assert_eq!(h.newer(), None);
    }

    #[test]
    fn push_resets_browse_mode() {
        let mut slots = [HistSlot::default(); 4];
        let mut h = History::new(&mut slots);
        h.push(b"a");
        h.older(b""); // nav = 1
        h.push(b"b"); // resets nav
        assert_eq!(h.newer(), None); // not browsing after a submit
    }
}
