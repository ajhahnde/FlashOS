//! `/bin/edit` -- the full-screen text editor.
//!
//! The second interactive consumer of the render core (after `/bin/less`) and the
//! first writer: where less proved read-only paging, edit proves mutation over the
//! pure gap-buffer core. It slurps a file into a heap-backed gap buffer, takes over
//! the console with the alternate screen, turns keys from the VT100 decoder into
//! edits and motions through the gap buffer, and writes the buffer back on ctrl-O. It
//! is the first real consumer of the heap (`sbrk` plus the bump allocator); the kernel
//! already provides everything, so this slot is pure userland.
//!
//! Why not [`tui::run`], which less uses: the loop decodes keys through its own fixed
//! decoder call, and it hides the cursor and owns the loop end-to-end, leaving no place
//! for a parked edit cursor or the modal search / confirm sub-prompts. So edit adopts
//! the render core a layer down -- it paints a [`Buffer`] and emits the minimal
//! [`tui::diff`] each frame, the same incremental repaint `run` gives less -- but keeps
//! a hand-rolled `read_key` loop (the full extended key set) and parks the cursor
//! itself after each frame.
//!
//! Architecture: the editing logic lives in three pure, host-tested cores --
//! [`GapBuf`] (storage), [`LineIndex`] (lines plus cursor motions), [`Viewport`]
//! (scroll) -- and `grep_match::find` (search). This file is the driver: argv, slurp,
//! the alt-screen dance, the render loop, and the save path. The interactive loop
//! cannot run under QEMU (no PL011-RX stdin), so the cores' host tests are the
//! correctness proof and the Pi is the only live witness.
//!
//! Cursor invariant: the gap buffer's gap start always equals the logical cursor
//! offset `cur`. Navigation moves the gap to the new cursor; an insert or delete acts
//! at the gap and then re-reads `cur` from the buffer. So `byte_at` during render and
//! `linearize` at save both see the text in logical order regardless.
//!
//! Save is unlink + create + write, not in-place: the FAT32 backend's write only
//! *grows* a file -- it has no truncate -- so overwriting a file that got shorter
//! would leave a stale tail at the wrong size. Recreating the file gives the correct
//! fresh size every time, at the cost of a small unlink-to-write crash window
//! (single-user hobby OS; atomic temp + rename is future work).
//!
//! Current limits (deferred): one logical line is one screen row (horizontal scroll,
//! no soft-wrap); no undo; tabs render as a single space and other non-printables as
//! `?` (display only -- save preserves the raw bytes); fixed 24x80 geometry; the line
//! index is capped at [`MAX_LINES`].

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_flibc::gapbuf::{self, GapBuf, LineIndex, RowCol, Viewport};
#[cfg(target_os = "none")]
use flashos_flibc::keys::{read_key, Key};
#[cfg(target_os = "none")]
use flashos_flibc::tui::{self, Buffer, Cell, Style, ATTR_REVERSE};
#[cfg(target_os = "none")]
use flashos_flibc::{alt_enter, alt_leave, console_sink, grep_match, malloc, park_cursor, sys};
#[cfg(target_os = "none")]
use flashsdk_rt::{arg, arg_ptr, entry, Argv};

// Assumed serial-terminal geometry (no window-size ioctl exists). Row 1 is the
// header, row ROWS the status/prompt line, the rest content.
#[cfg(target_os = "none")]
const ROWS: usize = 24;
#[cfg(target_os = "none")]
const HEADER: usize = 1;
#[cfg(target_os = "none")]
const STATUS: usize = 1;
/// Visible content rows (22).
#[cfg(target_os = "none")]
const CONTENT: usize = ROWS - HEADER - STATUS;
#[cfg(target_os = "none")]
const COLS: usize = 80;
/// Cell-buffer length (front and back each).
#[cfg(target_os = "none")]
const CELLS: usize = ROWS * COLS;
/// Status-line scratch (position plus legend).
#[cfg(target_os = "none")]
const STATUS_MAX: usize = 96;

/// Line-index slots (on the stack).
#[cfg(target_os = "none")]
const MAX_LINES: usize = 4096;
/// File read chunk.
#[cfg(target_os = "none")]
const SLURP: usize = 4096;
/// First gap-buffer block (there is no `fstat` to size it from).
#[cfg(target_os = "none")]
const INITIAL_CAP: usize = 64 * 1024;
/// Refuse to grow past this -- a clean stop, no OOM zombie.
#[cfg(target_os = "none")]
const MAX_CAP: usize = 4 * 1024 * 1024;

/// Editor state. The gap buffer's storage is on the heap (`malloc`, grown on a full
/// gap, never freed -- so it outlives every frame and carries the `'static` lifetime);
/// the line-index slots are caller-owned on `main`'s stack.
#[cfg(target_os = "none")]
struct Ed<'l> {
    gb: GapBuf<'static>,
    li: LineIndex<'l>,
    vp: Viewport,
    /// Logical cursor offset (equal to the gap start, by invariant).
    cur: usize,
    /// Current storage capacity in bytes.
    cap: usize,
    dirty: bool,
    /// The file did not exist at open -- skip the unlink on save.
    is_new: bool,
    /// A modal prompt (search / confirm) overlaid the status row with raw bytes the
    /// diff's front buffer never saw; this forces the next frame to repaint in full so
    /// that residue is wiped. See [`render`].
    force: bool,
    path: *const u8,
}

/// Hand the heap block back as a slice. The bump allocator never frees, so the block
/// lives for the program's life and `'static` is the honest lifetime.
///
/// # Safety
/// `n` bytes at `raw` must be a live allocation that is never handed out twice.
#[cfg(target_os = "none")]
unsafe fn heap_slice(raw: *mut u8, n: usize) -> &'static mut [u8] {
    unsafe { core::slice::from_raw_parts_mut(raw, n) }
}

// ---- mutation (keeps the gap-start == cur invariant, re-indexes lines) ----------

#[cfg(target_os = "none")]
impl Ed<'_> {
    /// Grow the storage by doubling, preserving content and cursor. False if the cap is
    /// hit or the heap rejects the allocation (a clean stop, not a crash).
    fn grow(&mut self) -> bool {
        let newcap = self.cap * 2;
        if newcap > MAX_CAP {
            return false;
        }
        let raw = malloc(newcap as u64);
        if raw.is_null() {
            return false;
        }
        self.gb.grow_into(unsafe { heap_slice(raw, newcap) });
        self.cap = newcap;
        true
    }

    fn insert_byte(&mut self, b: u8) -> bool {
        if self.gb.gap_len() == 0 && !self.grow() {
            return false;
        }
        self.gb.insert(b);
        self.cur = self.gb.cursor();
        self.dirty = true;
        self.li.rebuild(&self.gb);
        true
    }

    fn delete_back(&mut self) {
        if self.gb.delete_back() {
            self.cur = self.gb.cursor();
            self.dirty = true;
            self.li.rebuild(&self.gb);
        }
    }

    fn delete_fwd(&mut self) {
        if self.gb.delete_fwd() {
            // The cursor (the gap start) is unchanged by a forward delete.
            self.dirty = true;
            self.li.rebuild(&self.gb);
        }
    }

    // ---- navigation ------------------------------------------------------------

    fn move_to(&mut self, to: usize) {
        self.cur = to;
        self.gb.move_gap(to);
    }

    /// Page up or down by a content window of lines, one `move_up`/`move_down` step at
    /// a time so the column-clamp logic stays in the line index.
    fn page_move(&mut self, up: bool) {
        let mut pos = self.cur;
        for _ in 0..CONTENT {
            pos = if up {
                self.li.move_up(pos)
            } else {
                self.li.move_down(pos)
            };
        }
        self.move_to(pos);
    }

    // ---- save (unlink + create + write -- shrink correctness) -------------------

    /// Write the buffer back to its path. Returns false on any failure. An empty buffer
    /// creates an empty file. The old file is unlinked first so the recreated file
    /// always carries the correct, possibly smaller, size.
    fn save(&mut self) -> bool {
        let total = self.gb.len();

        if !self.is_new {
            unsafe { sys::unlink(self.path) };
        }
        let fd = unsafe { sys::create(self.path) };
        if fd < 0 {
            return false;
        }

        let mut ok = true;
        if total > 0 {
            // Linearize into a fresh heap block (page-aligned, so the copy is
            // alignment-safe) and stream it to the file. The block is abandoned (free
            // is a no-op) -- saves are infrequent and reaped on exit.
            let raw = malloc(total as u64);
            if raw.is_null() {
                ok = false;
            } else {
                let buf = unsafe { heap_slice(raw, total) };
                self.gb.linearize(buf);
                let mut off = 0;
                while off < total {
                    // The one write here is to the file fd, not to stdout, so it stays
                    // a direct syscall, outside the console seam.
                    let w = sys::write(fd, &buf[off..]);
                    if w <= 0 {
                        ok = false;
                        break;
                    }
                    off += w as usize;
                }
            }
        }

        sys::close(fd);
        if ok {
            self.is_new = false;
            self.dirty = false;
        }
        ok
    }

    /// ctrl-X: confirm a save if the buffer is dirty. True when the editor should exit
    /// (saved, or discarded), false to keep editing (cancelled).
    fn exit_confirmed(&mut self) -> bool {
        if !self.dirty {
            return true;
        }
        match self.confirm(b" save modified buffer?  y = save   n = discard   esc = cancel") {
            b'y' => self.save(),
            b'n' => true,
            _ => false,
        }
    }

    // ---- search (ctrl-W -- reuses the shared matcher over a linearized snapshot) --

    fn search(&mut self) {
        let mut pbuf = [0u8; COLS];
        let Some(plen) = self.prompt_line(b" search: ", &mut pbuf) else {
            return;
        };
        if plen == 0 {
            return;
        }
        let total = self.gb.len();
        if total == 0 {
            return;
        }
        let raw = malloc(total as u64);
        if raw.is_null() {
            return;
        }
        let snap = unsafe { heap_slice(raw, total) };
        self.gb.linearize(snap);
        let needle = &pbuf[..plen];
        // Search forward from just past the cursor; wrap to the top if the tail has no
        // hit, so a repeated ctrl-W cycles through all the matches.
        let hit = grep_match::find(snap, needle, self.cur + 1)
            .or_else(|| grep_match::find(snap, needle, 0));
        if let Some(at) = hit {
            self.move_to(at);
        }
    }

    // ---- prompts (status-line input) ---------------------------------------------
    //
    // A modal prompt overlays the status row with raw bytes that the diff's front
    // buffer never records, so it sets `force`: the next render repaints in full and
    // wipes the overlay. Output and the cursor park go straight through the console
    // seam, the same path the frame diff uses.

    /// Edit a short string on the status row. Returns its length, or `None` if the user
    /// cancelled (escape / ctrl-C). Used for the search pattern.
    fn prompt_line(&mut self, label: &[u8], buf: &mut [u8]) -> Option<usize> {
        self.force = true;
        let mut len = 0;
        loop {
            park_cursor(ROWS as u16, 1);
            console_sink(b"\x1b[2K"); // erase the status line
            console_sink(label);
            console_sink(&buf[..len]);
            let ev = read_key();
            match ev.key {
                Key::Enter => return Some(len),
                Key::Escape | Key::CtrlC | Key::Eof => return None,
                Key::Backspace => len = len.saturating_sub(1),
                Key::Char => {
                    if len < buf.len() {
                        buf[len] = ev.ch;
                        len += 1;
                    }
                }
                _ => {}
            }
        }
    }

    /// Draw a one-line prompt and read a single decision key. Returns `y`, `n`, or 0
    /// (cancel: escape / ctrl-C / anything else).
    fn confirm(&mut self, msg: &[u8]) -> u8 {
        self.force = true;
        park_cursor(ROWS as u16, 1);
        console_sink(b"\x1b[2K");
        console_sink(msg);
        let ev = read_key();
        if ev.key == Key::Char {
            match ev.ch {
                b'y' | b'Y' => return b'y',
                b'n' | b'N' => return b'n',
                _ => {}
            }
        }
        0
    }

    // ---- rendering ---------------------------------------------------------------

    /// Row 1: program, filename, and a modified / new-file marker. The blank cells
    /// already fill the row's tail, so only the text is painted.
    fn paint_header(&self, buf: &mut Buffer<'_>) {
        let mut hb = [0u8; COLS];
        let mut i = 0;
        i += put_str(&mut hb, i, b"edit: ");
        i += put_str(&mut hb, i, base_name(unsafe { cstr(self.path) }));
        if self.is_new {
            i += put_str(&mut hb, i, b"  [New File]");
        } else if self.dirty {
            i += put_str(&mut hb, i, b"  *");
        }
        buf.text(0, 0, &hb[..i], Style::plain());
    }

    /// Rows 2..ROWS-1: the visible content window, each logical line clipped to the
    /// horizontal viewport and to [`COLS`], non-printables substituted, `~` past EOF.
    /// The blanked back buffer already supplies each row's spaces, so a line that shrank
    /// between frames is erased by the diff.
    fn paint_content(&self, buf: &mut Buffer<'_>) {
        let mut rb = [0u8; COLS];
        for row in 0..CONTENT {
            let y = (HEADER + row) as u16;
            let idx = self.vp.top + row;
            if idx < self.li.line_count() {
                let n = self.build_row(idx, &mut rb);
                buf.text(0, y, &rb[..n], Style::plain());
            } else {
                buf.text(0, y, b"~", Style::plain());
            }
        }
    }

    /// Fill `buf` with line `idx`, starting at the viewport's left column, clipped to
    /// [`COLS`], each byte mapped to one display cell. Returns the count written.
    fn build_row(&self, idx: usize, buf: &mut [u8; COLS]) -> usize {
        let start = self.li.line_start(idx);
        let llen = self.li.line_len(idx);
        let mut w = 0;
        let mut c = self.vp.left;
        while c < llen && w < COLS {
            buf[w] = display_byte(self.gb.byte_at(start + c));
            w += 1;
            c += 1;
        }
        w
    }

    /// Row ROWS: the cursor position and the key legend, the whole row in reverse video
    /// so the bar spans full width (matching less's status bar). Padded with spaces so
    /// the reverse run is uniform; the buffer clips it to [`COLS`].
    fn paint_status(&self, buf: &mut Buffer<'_>, rc: RowCol) {
        let mut sb = [0u8; STATUS_MAX];
        let mut n = 0;
        n += put_byte(&mut sb, n, b' ');
        n += put_dec(&mut sb, n, (rc.row + 1) as u64);
        n += put_byte(&mut sb, n, b':');
        n += put_dec(&mut sb, n, (rc.col + 1) as u64);
        if self.dirty {
            n += put_str(&mut sb, n, b" [modified]");
        }
        n += put_str(&mut sb, n, b"   ^O write  ^W find  ^X exit");
        while n < sb.len() {
            sb[n] = b' ';
            n += 1;
        }
        buf.text(0, (ROWS - 1) as u16, &sb[..n], Style::attrs(ATTR_REVERSE));
    }

    // ---- file slurp --------------------------------------------------------------

    /// Read the whole file into the gap buffer, growing on demand. The fd is opened,
    /// drained, and closed here -- never held across the edit loop. A file that cannot
    /// be opened leaves an empty buffer flagged `[New File]`.
    fn slurp(&mut self) {
        let fd = unsafe { sys::open(self.path) };
        if fd < 0 {
            self.is_new = true;
            return;
        }
        let mut tmp = [0u8; SLURP];
        loop {
            let r = sys::read(fd, &mut tmp);
            if r <= 0 {
                break;
            }
            let got = r as usize;
            let mut fed = 0;
            while fed < got {
                fed += self.gb.insert_slice(&tmp[fed..got]);
                if fed < got && !self.grow() {
                    // MAX_CAP hit: load what fit, the rest is dropped.
                    break;
                }
            }
        }
        sys::close(fd);
    }
}

/// Paint the whole frame into the back buffer, emit the minimal diff against the front
/// buffer, then park the visible cursor at the edit position. The scroll runs first so
/// the content rows and the cursor share one viewport.
#[cfg(target_os = "none")]
fn render<'c>(ed: &mut Ed<'_>, screen: &mut Buffer<'c>, scratch: &mut Buffer<'c>) {
    let rc = ed.li.locate(ed.cur);
    ed.vp.scroll_to(rc.row, rc.col);

    // A modal prompt left raw bytes on the status row the front buffer never saw; blank
    // front so this diff repaints the whole screen and wipes them.
    if ed.force {
        screen.clear();
        ed.force = false;
    }

    scratch.clear();
    ed.paint_header(scratch);
    ed.paint_content(scratch);
    ed.paint_status(scratch, rc);
    tui::diff(screen, scratch, console_sink);

    // The scratch just drawn is now what is on screen; swap the cell slices so the next
    // frame paints into the old screen (mirroring the run loop's own swap).
    core::mem::swap(&mut screen.cells, &mut scratch.cells);

    // The diff parks the cursor at its last changed cell; move it to the edit point.
    let trow = (HEADER + ed.vp.screen_row(rc.row) + 1) as u16;
    let tcol = (ed.vp.screen_col(rc.col) + 1) as u16;
    park_cursor(trow, tcol);
}

/// The key loop. Returns when the user exits (ctrl-X, or ctrl-C / end-of-input).
#[cfg(target_os = "none")]
fn edit_loop<'c>(ed: &mut Ed<'_>, screen: &mut Buffer<'c>, scratch: &mut Buffer<'c>) {
    loop {
        let ev = read_key();
        match ev.key {
            Key::Eof | Key::CtrlC => return,
            Key::CtrlX => {
                if ed.exit_confirmed() {
                    return;
                }
            }
            Key::CtrlO => {
                ed.save();
            }
            Key::CtrlW => ed.search(),
            Key::Up => {
                let to = ed.li.move_up(ed.cur);
                ed.move_to(to);
            }
            Key::Down => {
                let to = ed.li.move_down(ed.cur);
                ed.move_to(to);
            }
            Key::Left => {
                let to = gapbuf::move_left(ed.cur);
                ed.move_to(to);
            }
            Key::Right => {
                let to = gapbuf::move_right(ed.cur, ed.gb.len());
                ed.move_to(to);
            }
            Key::Home => {
                let to = ed.li.home(ed.cur);
                ed.move_to(to);
            }
            Key::End => {
                let to = ed.li.end(ed.cur);
                ed.move_to(to);
            }
            Key::PageUp => ed.page_move(true),
            Key::PageDown => ed.page_move(false),
            Key::Enter => {
                ed.insert_byte(b'\n');
            }
            Key::Backspace => ed.delete_back(),
            Key::Delete => ed.delete_fwd(),
            Key::Char => {
                ed.insert_byte(ev.ch);
            }
            // tab / escape / none -- ignored for now.
            _ => {}
        }
        render(ed, screen, scratch);
    }
}

/// `\t` renders as a single space, other non-printables as `?`, printables verbatim.
/// Keeps every byte to one display cell, so a column is a byte offset.
#[cfg(target_os = "none")]
fn display_byte(b: u8) -> u8 {
    if b == b'\t' {
        return b' ';
    }
    if (0x20..0x7f).contains(&b) {
        return b;
    }
    b'?'
}

/// The bytes of a NUL-terminated string, without the NUL.
///
/// # Safety
/// `p` must point at a NUL-terminated string that outlives the returned slice.
#[cfg(target_os = "none")]
unsafe fn cstr<'a>(p: *const u8) -> &'a [u8] {
    let mut len = 0;
    while unsafe { *p.add(len) } != 0 {
        len += 1;
    }
    unsafe { core::slice::from_raw_parts(p, len) }
}

/// The last path component, as a slice into the argv string (no copy).
#[cfg(target_os = "none")]
fn base_name(path: &[u8]) -> &[u8] {
    let mut start = 0;
    for (i, &b) in path.iter().enumerate() {
        if b == b'/' {
            start = i + 1;
        }
    }
    &path[start..]
}

// ---- saturating byte builders (write into `out`, never past its end) ------------

#[cfg(target_os = "none")]
fn put_byte(out: &mut [u8], pos: usize, c: u8) -> usize {
    if pos < out.len() {
        out[pos] = c;
        return 1;
    }
    0
}

#[cfg(target_os = "none")]
fn put_str(out: &mut [u8], pos: usize, s: &[u8]) -> usize {
    let mut w = 0;
    while w < s.len() && pos + w < out.len() {
        out[pos + w] = s[w];
        w += 1;
    }
    w
}

/// `v` as decimal ASCII at `out[pos..]`, returning the count written.
#[cfg(target_os = "none")]
fn put_dec(out: &mut [u8], pos: usize, v: u64) -> usize {
    let mut tmp = [0u8; 20];
    let mut d = 0;
    if v == 0 {
        tmp[0] = b'0';
        d = 1;
    } else {
        let mut x = v;
        while x != 0 {
            tmp[d] = b'0' + (x % 10) as u8;
            d += 1;
            x /= 10;
        }
    }
    let mut w = 0;
    while w < d && pos + w < out.len() {
        out[pos + w] = tmp[d - 1 - w];
        w += 1;
    }
    w
}

#[cfg(target_os = "none")]
fn main(argc: usize, argv: Argv) -> i32 {
    if argc < 2 {
        console_sink(b"usage: edit <file>\n");
        return 0;
    }
    let (Some(path), Some(_)) = (unsafe { arg_ptr(argv, 1) }, unsafe { arg(argv, 1) }) else {
        console_sink(b"usage: edit <file>\n");
        return 0;
    };

    // Allocate the initial gap-buffer block on the heap (the first heap user).
    let raw = malloc(INITIAL_CAP as u64);
    if raw.is_null() {
        console_sink(b"edit: out of memory\n");
        return 0;
    }
    let store = unsafe { heap_slice(raw, INITIAL_CAP) };

    let mut slots = [0u32; MAX_LINES];
    let gb = GapBuf::init(store);
    let li = LineIndex::init(&mut slots, &gb);
    let mut ed = Ed {
        gb,
        li,
        vp: Viewport::new(CONTENT, COLS),
        cur: 0,
        cap: INITIAL_CAP,
        dirty: false,
        is_new: false,
        force: false,
        path,
    };

    // Slurp the file into the buffer (the fd is not held past the read). A file that
    // does not exist opens as an empty [New File] buffer.
    ed.slurp();

    // Cursor home at the top; index the lines.
    ed.cur = 0;
    ed.gb.move_gap(0);
    ed.li.rebuild(&ed.gb);

    // The double buffer the render loop diffs over: front is what is on screen, back is
    // where a frame is painted; render() swaps them each turn (the same shape the run
    // loop carries internally, hand-rolled here).
    let mut front_cells = [Cell::ch(' '); CELLS];
    let mut back_cells = [Cell::ch(' '); CELLS];
    let mut screen = Buffer::new(&mut front_cells, COLS as u16, ROWS as u16);
    let mut scratch = Buffer::new(&mut back_cells, COLS as u16, ROWS as u16);
    screen.clear(); // front blanked, so the first diff paints in full

    // Take over the console: raw mode (echo off) so typed keys do not leak onto the
    // alt-screen, then enter the alternate screen. alt_enter shows the cursor (an editor
    // parks a live one, unlike a pager).
    sys::set_console_mode(0);
    alt_enter();
    render(&mut ed, &mut screen, &mut scratch);

    edit_loop(&mut ed, &mut screen, &mut scratch);

    // Every exit path restores the shell view. The mode stays 0 (the shell's own
    // baseline; fsh re-asserts it after wait() as a backstop), matching less.
    alt_leave();
    0
}

#[cfg(target_os = "none")]
entry!(main);
