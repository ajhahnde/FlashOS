//! A terminal-UI render core: a grid of styled cells, and the minimal ANSI byte
//! stream that carries a terminal from one grid to the next.
//!
//! Nothing here names a file descriptor, a syscall, or a terminal device. The
//! render core is a pure value layer -- a [`Buffer`] of styled [`Cell`]s -- plus
//! one function ([`diff`]) that turns the difference between two buffers into the
//! bytes a terminal needs to catch up. Those bytes leave through an injected
//! [`Sink`]; the backing (a real `write`, a capture buffer) is the caller's. So
//! the whole module is host-testable against a capturing sink.
//!
//! The diff is deliberately frugal -- the discipline a serial terminal rewards:
//!
//! * only cells that actually changed are repainted;
//! * a cursor move (`ESC [ row ; col H`) is emitted only when the cursor is not
//!   already where the next changed cell needs it, so a run of adjacent changes
//!   costs one move;
//! * an SGR escape is emitted only when the style differs from the last one
//!   written, so a run in one colour costs one escape;
//! * a code point is written as UTF-8;
//! * a single trailing reset (`ESC [ 0 m`) closes the stream when anything was
//!   drawn.
//!
//! On top of that sits [`run`], a TEA (The Elm Architecture) loop: an initial
//! model, a pure `update` (a model and an event yield the next model) and a pure
//! `view` (a model paints into a back buffer). `/bin/less` drives the loop whole;
//! `/bin/edit` needs a key set the loop's decoder does not carry and a cursor the
//! loop would hide, so it paints a [`Buffer`] and emits [`diff`] itself.
//!
//! There is deliberately no `print`-style formatting primitive: the payload link
//! forbids `core::fmt` (it drags the formatting engine into every binary), so a
//! consumer renders its own bytes and paints them with [`Buffer::text`].

use crate::io::{Sink, Writer};
use crate::keys::{self, Decoder};

/// The sixteen ANSI colours plus `Default` -- the terminal's own foreground or
/// background (SGR 39 / 49, no colour forced). 256-colour and truecolour are a
/// later concern; this is the portable floor every terminal honours.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum Color {
    #[default]
    Default,
    Black,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,
    White,
    BrightBlack,
    BrightRed,
    BrightGreen,
    BrightYellow,
    BrightBlue,
    BrightMagenta,
    BrightCyan,
    BrightWhite,
}

/// Text attributes, a bitset in [`Style::attrs`]. Only the three every terminal
/// agrees on; underline / blink / strike can join when a consumer needs them.
pub const ATTR_BOLD: u8 = 1;
pub const ATTR_DIM: u8 = 2;
pub const ATTR_REVERSE: u8 = 4;

/// A cell's appearance: a foreground, a background, and the attribute bitset. The
/// default is the terminal's own colours with no attributes.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Style {
    pub fg: Color,
    pub bg: Color,
    pub attrs: u8,
}

impl Style {
    /// The plain style -- both colours the terminal's own, no attributes.
    pub const fn plain() -> Self {
        Self {
            fg: Color::Default,
            bg: Color::Default,
            attrs: 0,
        }
    }

    /// The plain style with `attrs` set, the form a status bar wants.
    pub const fn attrs(attrs: u8) -> Self {
        Self {
            fg: Color::Default,
            bg: Color::Default,
            attrs,
        }
    }
}

/// One screen cell: a Unicode code point and its style. A fresh cell is a blank (a
/// space) in the default style, so a blanked buffer reads as an empty screen.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Cell {
    pub ch: char,
    pub style: Style,
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            ch: ' ',
            style: Style::plain(),
        }
    }
}

impl Cell {
    /// A cell carrying `ch` in the plain style.
    pub const fn ch(ch: char) -> Self {
        Self {
            ch,
            style: Style::plain(),
        }
    }
}

/// Set every cell to a blank. Used to clear the back buffer before each `view` and
/// to start the screen blank so the first frame paints in full.
fn blank_cells(cells: &mut [Cell]) {
    for c in cells.iter_mut() {
        *c = Cell::default();
    }
}

/// A rectangular grid of cells, `w` wide and `h` tall, stored row-major in
/// caller-owned storage (this module allocates nothing). Index `(x, y)` lives at
/// `y * w + x`; the slice must hold at least `w * h` cells, and two buffers passed
/// to [`diff`] must share `w` and `h`.
///
/// The paint primitives are the model-facing drawing surface. Every write is
/// bounds-clipped, so painting past an edge silently drops the off-grid cells
/// instead of faulting -- a `view` need not know the exact size to be safe.
pub struct Buffer<'a> {
    pub cells: &'a mut [Cell],
    pub w: u16,
    pub h: u16,
}

impl<'a> Buffer<'a> {
    /// Wrap caller-owned storage as a `w` x `h` grid.
    pub fn new(cells: &'a mut [Cell], w: u16, h: u16) -> Self {
        Self { cells, w, h }
    }

    /// Row-major index of `(x, y)`, or `None` when the coordinate is outside the
    /// grid. The coordinates are `usize` so an offset a primitive computed by
    /// adding a run length cannot wrap a far-off-grid cell back into the grid; an
    /// out-of-range coordinate clips.
    fn index(&self, x: usize, y: usize) -> Option<usize> {
        if x >= self.w as usize || y >= self.h as usize {
            return None;
        }
        Some(y * self.w as usize + x)
    }

    /// Write one cell at `(x, y)`. Off-grid coordinates are dropped, so every other
    /// primitive can paint without re-checking bounds at each cell.
    pub fn set(&mut self, x: u16, y: u16, c: Cell) {
        self.set_at(x as usize, y as usize, c);
    }

    fn set_at(&mut self, x: usize, y: usize, c: Cell) {
        if let Some(i) = self.index(x, y) {
            self.cells[i] = c;
        }
    }

    /// The cell at `(x, y)`, or `None` when off-grid.
    pub fn get(&self, x: u16, y: u16) -> Option<Cell> {
        self.index(x as usize, y as usize).map(|i| self.cells[i])
    }

    /// Reset every cell to a blank -- a whole-grid erase.
    pub fn clear(&mut self) {
        blank_cells(self.cells);
    }

    /// Fill the `w` x `h` rectangle whose top-left is `(x, y)` with `c`, clipped to
    /// the grid.
    pub fn fill(&mut self, x: u16, y: u16, w: u16, h: u16, c: Cell) {
        for row in 0..h as usize {
            for col in 0..w as usize {
                self.set_at(x as usize + col, y as usize + row, c);
            }
        }
    }

    /// Paint `len` cells of `ch` rightward from `(x, y)` -- a horizontal run in one
    /// style.
    pub fn hline(&mut self, x: u16, y: u16, len: u16, ch: char, style: Style) {
        for i in 0..len as usize {
            self.set_at(x as usize + i, y as usize, Cell { ch, style });
        }
    }

    /// Paint `len` cells of `ch` downward from `(x, y)` -- a vertical run in one
    /// style.
    pub fn vline(&mut self, x: u16, y: u16, len: u16, ch: char, style: Style) {
        for i in 0..len as usize {
            self.set_at(x as usize, y as usize + i, Cell { ch, style });
        }
    }

    /// Write the bytes of `s` left-to-right from `(x, y)`, one cell per byte, in
    /// `style`. Byte-wise / ASCII: each byte becomes one cell's code point, so a
    /// multi-byte glyph must go through [`Buffer::set`] with its `char`. The right
    /// edge clips the run.
    pub fn text(&mut self, x: u16, y: u16, s: &[u8], style: Style) {
        for (i, &b) in s.iter().enumerate() {
            self.set_at(
                x as usize + i,
                y as usize,
                Cell {
                    ch: b as char,
                    style,
                },
            );
        }
    }

    /// Copy `src` into this buffer with its top-left at `(x, y)`. Cells that fall
    /// off this grid are dropped (clipped, never wrapped).
    pub fn blit(&mut self, x: u16, y: u16, src: &Buffer<'_>) {
        for row in 0..src.h as usize {
            for col in 0..src.w as usize {
                let c = src.cells[row * src.w as usize + col];
                self.set_at(x as usize + col, y as usize + row, c);
            }
        }
    }

    /// Draw a single-line box border of width `w` and height `h` with its top-left
    /// at `(x, y)`, in the Unicode light box-drawing set; the interior is
    /// untouched. A zero-size box paints nothing; a 1-wide or 1-tall box
    /// degenerates to the overlapping corners.
    pub fn box_(&mut self, x: u16, y: u16, w: u16, h: u16, style: Style) {
        if w == 0 || h == 0 {
            return;
        }
        let (x0, y0) = (x as usize, y as usize);
        let x1 = x0 + w as usize - 1;
        let y1 = y0 + h as usize - 1;
        self.set_at(x0, y0, Cell { ch: '┌', style });
        self.set_at(x1, y0, Cell { ch: '┐', style });
        self.set_at(x0, y1, Cell { ch: '└', style });
        self.set_at(x1, y1, Cell { ch: '┘', style });
        for col in (x0 + 1)..x1 {
            self.set_at(col, y0, Cell { ch: '─', style });
            self.set_at(col, y1, Cell { ch: '─', style });
        }
        for row in (y0 + 1)..y1 {
            self.set_at(x0, row, Cell { ch: '│', style });
            self.set_at(x1, row, Cell { ch: '│', style });
        }
    }
}

// ---- the ANSI diff ---------------------------------------------------------

/// The SGR foreground code for a colour. The background code is exactly ten more
/// (30..37 -> 40..47, 90..97 -> 100..107, 39 -> 49), so [`bg_sgr`] is a uniform
/// offset. A match rather than a discriminant cast, so the table is explicit and
/// does not depend on the enum's declaration order.
fn fg_sgr(c: Color) -> u16 {
    match c {
        Color::Default => 39,
        Color::Black => 30,
        Color::Red => 31,
        Color::Green => 32,
        Color::Yellow => 33,
        Color::Blue => 34,
        Color::Magenta => 35,
        Color::Cyan => 36,
        Color::White => 37,
        Color::BrightBlack => 90,
        Color::BrightRed => 91,
        Color::BrightGreen => 92,
        Color::BrightYellow => 93,
        Color::BrightBlue => 94,
        Color::BrightMagenta => 95,
        Color::BrightCyan => 96,
        Color::BrightWhite => 97,
    }
}

fn bg_sgr(c: Color) -> u16 {
    fg_sgr(c) + 10
}

/// Write `n` as decimal through the writer. At most five digits; collected
/// least-significant first, then written in reading order.
fn write_dec(w: &mut Writer<'_>, n: u16) {
    if n == 0 {
        w.write_all(b"0");
        return;
    }
    let mut tmp = [0u8; 5];
    let mut i = 5;
    let mut v = n;
    while v != 0 {
        i -= 1;
        tmp[i] = b'0' + (v % 10) as u8;
        v /= 10;
    }
    w.write_all(&tmp[i..]);
}

/// `ESC [ row ; col H` -- move the cursor, 1-based, from the 0-based cell `(x, y)`.
fn emit_move_to(w: &mut Writer<'_>, x: u16, y: u16) {
    w.write_all(b"\x1b[");
    write_dec(w, y + 1);
    w.write_all(b";");
    write_dec(w, x + 1);
    w.write_all(b"H");
}

/// `ESC [ 0 ; ... m` -- a full SGR for `s`, always led by the reset so it is
/// self-contained (no need to track which attributes were on before). Attributes
/// first, then a colour code only when the colour is not the terminal default.
fn emit_style(w: &mut Writer<'_>, s: Style) {
    w.write_all(b"\x1b[0");
    if s.attrs & ATTR_BOLD != 0 {
        w.write_all(b";1");
    }
    if s.attrs & ATTR_DIM != 0 {
        w.write_all(b";2");
    }
    if s.attrs & ATTR_REVERSE != 0 {
        w.write_all(b";7");
    }
    if s.fg != Color::Default {
        w.write_all(b";");
        write_dec(w, fg_sgr(s.fg));
    }
    if s.bg != Color::Default {
        w.write_all(b";");
        write_dec(w, bg_sgr(s.bg));
    }
    w.write_all(b"m");
}

/// A code point as UTF-8, built into a fixed buffer and written in one go.
fn emit_utf8(w: &mut Writer<'_>, ch: char) {
    let mut b = [0u8; 4];
    w.write_all(ch.encode_utf8(&mut b).as_bytes());
}

/// Emit the minimal ANSI byte stream that carries a terminal showing `front` to
/// showing `back`. Both buffers must share `w` and `h`. Pure but for the sink: it
/// reads the two grids and writes to `out`, touching nothing else. When the grids
/// are identical it writes nothing at all.
pub fn diff(front: &Buffer<'_>, back: &Buffer<'_>, out: Sink) {
    let mut scratch = [0u8; 128];
    let mut w = Writer::new(out, &mut scratch);

    // The cursor and last-emitted style, tracked so a move / SGR is emitted only
    // when it actually changes. The `have_*` flags force the first of each.
    let mut have_cursor = false;
    let (mut cx, mut cy) = (0u16, 0u16);
    let mut have_style = false;
    let mut last = Style::plain();

    for y in 0..back.h {
        for x in 0..back.w {
            let idx = y as usize * back.w as usize + x as usize;
            let bc = back.cells[idx];
            if bc == front.cells[idx] {
                continue;
            }
            if !have_cursor || cx != x || cy != y {
                emit_move_to(&mut w, x, y);
                have_cursor = true;
            }
            if !have_style || last != bc.style {
                emit_style(&mut w, bc.style);
                last = bc.style;
                have_style = true;
            }
            emit_utf8(&mut w, bc.ch);
            // The terminal advances the cursor one column after a cell.
            cx = x + 1;
            cy = y;
        }
    }
    if have_style {
        w.write_all(b"\x1b[0m");
    }
    w.flush();
}

// ---- the TEA run loop ------------------------------------------------------

/// One byte from the terminal, or `None` when there is nothing to read. FlashOS's
/// `read(0)` blocks with no timeout, so on the device `None` only means
/// end-of-input; the tick it produces is what a host test scripts against.
pub type Input = fn() -> Option<u8>;

/// What the run loop feeds the model on each turn: a decoded keypress, or a tick
/// when the input yielded nothing.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Event {
    Key(keys::Event),
    Tick,
}

/// The model a [`run`] loop folds events into: pure `update`, pure `view`, and the
/// `quit` flag the loop reads to end after a final frame.
///
/// `update` consumes the model and yields the next one, so the fold stays pure in
/// the TEA sense without requiring the model to be `Copy` -- a model may own a
/// borrowed scratch slice (a pager's line index does).
pub trait Model: Sized {
    /// Fold one event into the next model.
    fn update(self, ev: Event) -> Self;
    /// Paint this model into the back buffer.
    fn view(&self, buf: &mut Buffer<'_>);
    /// End the loop after this model's frame is drawn.
    fn quit(&self) -> bool;
}

/// The two cell grids and the two IO seams a [`run`] drives. This module allocates
/// nothing, so the screen and the scratch buffer come from the caller -- `w * h`
/// cells each -- the same injection model as the [`Sink`].
pub struct Config<'a> {
    pub w: u16,
    pub h: u16,
    pub sink: Sink,
    pub input: Input,
    pub front: &'a mut [Cell],
    pub back: &'a mut [Cell],
}

/// Read one whole key from the input through a fresh decoder, draining a multi-byte
/// escape sequence (the arrows, `ESC [` ...) that the first byte opened. Returns the
/// resolved key event, or `None` when the burst produced no key:
///
/// * a sequence that opened but never completed (a lone `ESC` the user pressed, or
///   a truncated CSI) surfaces as `Escape`, the usual terminal convention;
/// * a complete-but-unmapped ground byte yields nothing (the caller ticks).
///
/// A whole sequence arrives in one input burst, so a fresh decoder per key is
/// correct.
fn decode_key(input: Input, first: u8) -> Option<keys::Event> {
    let mut dec = Decoder::new();
    let mut ev = dec.feed(first);
    while ev.key == keys::Key::None && dec.pending() {
        match input() {
            Some(b) => ev = dec.feed(b),
            None => break,
        }
    }
    if ev.key != keys::Key::None {
        return Some(ev);
    }
    if dec.pending() {
        return Some(keys::Event {
            key: keys::Key::Escape,
            ch: 0,
        });
    }
    None
}

/// Enter the alternate screen, hide the cursor, and clear -- the standard
/// full-screen setup, emitted straight through the sink.
fn enter(sink: Sink) {
    sink(b"\x1b[?1049h\x1b[?25l\x1b[2J");
}

/// Show the cursor and leave the alternate screen, restoring what was on the
/// terminal before [`run`].
fn leave(sink: Sink) {
    sink(b"\x1b[?25h\x1b[?1049l");
}

/// Run a TEA loop to completion and return the final model.
///
/// Each turn: blank the scratch buffer, `view` paints the current model into it,
/// [`diff`] emits the minimal ANSI to the sink, and the scratch becomes the screen
/// (a slice swap, no copy). A model whose `quit` is set ends the loop after its
/// frame is drawn. Otherwise the loop reads one byte; that byte and the rest of any
/// escape sequence it opens decode to one key event (so the arrows arrive whole), a
/// dry read is a [`Event::Tick`], and `update` folds the event into the next model.
pub fn run<M: Model>(init: M, cfg: Config<'_>) -> M {
    let mut model = init;
    let (mut screen_cells, mut scratch_cells) = (cfg.front, cfg.back);
    blank_cells(screen_cells);

    enter(cfg.sink);
    loop {
        blank_cells(scratch_cells);
        {
            let screen = Buffer::new(screen_cells, cfg.w, cfg.h);
            let mut scratch = Buffer::new(scratch_cells, cfg.w, cfg.h);
            model.view(&mut scratch);
            diff(&screen, &scratch, cfg.sink);
            screen_cells = screen.cells;
            scratch_cells = scratch.cells;
        }
        // The scratch just drawn is now what is on screen; swap the slices so the
        // old screen becomes next turn's scratch.
        core::mem::swap(&mut screen_cells, &mut scratch_cells);

        if model.quit() {
            break;
        }

        let ev = match (cfg.input)() {
            Some(b) => match decode_key(cfg.input, b) {
                Some(kev) => Event::Key(kev),
                None => Event::Tick,
            },
            None => Event::Tick,
        };
        model = model.update(ev);
    }
    leave(cfg.sink);
    model
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keys::Key;

    // ---- test backing: a capturing sink and a scripted input -----------------
    //
    // `Sink` and `Input` are bare function pointers (no context), so the backing
    // keeps its state in statics the pointer reaches. That makes the statics SHARED,
    // and cargo runs tests in parallel — so every test that captures must hold
    // `BENCH` for its whole body, or two of them interleave into one buffer and both
    // read garbage. (They did: the suite passed alone and failed under the full
    // workspace run, which is the signature of exactly this race.)
    extern crate std;
    use std::sync::{Mutex, MutexGuard};

    static BENCH: Mutex<()> = Mutex::new(());

    /// Take the capture bench. A failing test poisons the lock; the poison carries no
    /// information here (the next test resets the buffer anyway), so it is recovered
    /// rather than cascading one real failure into a dozen spurious ones.
    fn bench() -> MutexGuard<'static, ()> {
        BENCH.lock().unwrap_or_else(|e| e.into_inner())
    }

    static mut CAP: [u8; 256] = [0; 256];
    static mut CAP_LEN: usize = 0;

    fn cap_reset() {
        unsafe { CAP_LEN = 0 };
    }

    fn cap_sink(bytes: &[u8]) {
        unsafe {
            for &b in bytes {
                CAP[CAP_LEN] = b;
                CAP_LEN += 1;
            }
        }
    }

    fn captured() -> &'static [u8] {
        unsafe { &*core::ptr::addr_of!(CAP[..CAP_LEN]) }
    }

    static mut SCRIPT: &[u8] = &[];
    static mut SCRIPT_POS: usize = 0;

    fn script_reset(s: &'static [u8]) {
        unsafe {
            SCRIPT = s;
            SCRIPT_POS = 0;
        }
    }

    fn script_input() -> Option<u8> {
        unsafe {
            let script: &[u8] = *core::ptr::addr_of!(SCRIPT);
            if SCRIPT_POS >= script.len() {
                return None;
            }
            let c = script[SCRIPT_POS];
            SCRIPT_POS += 1;
            Some(c)
        }
    }

    fn null_input() -> Option<u8> {
        None
    }

    /// A counter model: a char or a Right arrow advances it, a tick adds ten, `q`
    /// quits. The `view` paints the count's low digit at (0, 0).
    #[derive(Clone, Copy, Default)]
    struct Counter {
        n: i32,
        quit: bool,
    }

    impl Model for Counter {
        fn update(mut self, ev: Event) -> Self {
            match ev {
                Event::Key(k) => match k.key {
                    Key::Char if k.ch == b'q' => self.quit = true,
                    Key::Char | Key::Right => self.n += 1,
                    _ => {}
                },
                Event::Tick => self.n += 10,
            }
            self
        }

        fn view(&self, buf: &mut Buffer<'_>) {
            let d = if self.n >= 0 { (self.n % 10) as u32 } else { 0 };
            buf.cells[0] = Cell::ch(char::from_digit(d, 10).unwrap());
        }

        fn quit(&self) -> bool {
            self.quit
        }
    }

    fn blank_buf(cells: &mut [Cell], w: u16, h: u16) -> Buffer<'_> {
        blank_cells(cells);
        Buffer::new(cells, w, h)
    }

    // ---- diff ---------------------------------------------------------------

    #[test]
    fn diff_of_identical_buffers_writes_nothing() {
        let _bench = bench();
        cap_reset();
        let (mut fc, mut bc) = ([Cell::default(); 6], [Cell::default(); 6]);
        let front = blank_buf(&mut fc, 3, 2);
        let back = blank_buf(&mut bc, 3, 2);
        diff(&front, &back, cap_sink);
        assert_eq!(captured(), b"");
    }

    #[test]
    fn a_single_changed_cell_moves_sets_the_default_style_and_resets() {
        let _bench = bench();
        cap_reset();
        let (mut fc, mut bc) = ([Cell::default(); 6], [Cell::default(); 6]);
        let front = blank_buf(&mut fc, 3, 2);
        let mut back = blank_buf(&mut bc, 3, 2);
        // Cell (x=2, y=1) -> 'X'. The move is 1-based: row 2, col 3.
        back.set(2, 1, Cell::ch('X'));
        diff(&front, &back, cap_sink);
        assert_eq!(captured(), b"\x1b[2;3H\x1b[0mX\x1b[0m");
    }

    #[test]
    fn a_run_of_adjacent_changes_in_one_style_costs_one_move_and_one_sgr() {
        let _bench = bench();
        cap_reset();
        let (mut fc, mut bc) = ([Cell::default(); 4], [Cell::default(); 4]);
        let front = blank_buf(&mut fc, 4, 1);
        let mut back = blank_buf(&mut bc, 4, 1);
        back.text(0, 0, b"Hi", Style::plain());
        diff(&front, &back, cap_sink);
        assert_eq!(captured(), b"\x1b[1;1H\x1b[0mHi\x1b[0m");
    }

    #[test]
    fn a_non_adjacent_change_re_emits_the_cursor_move() {
        let _bench = bench();
        cap_reset();
        let (mut fc, mut bc) = ([Cell::default(); 4], [Cell::default(); 4]);
        let front = blank_buf(&mut fc, 4, 1);
        let mut back = blank_buf(&mut bc, 4, 1);
        // Change (0,0) and (2,0), leave (1,0) blank: two moves, but the style is
        // unchanged across the gap, so the SGR coalesces.
        back.set(0, 0, Cell::ch('A'));
        back.set(2, 0, Cell::ch('B'));
        diff(&front, &back, cap_sink);
        assert_eq!(captured(), b"\x1b[1;1H\x1b[0mA\x1b[1;3HB\x1b[0m");
    }

    #[test]
    fn an_sgr_is_re_emitted_only_when_the_style_changes() {
        let _bench = bench();
        cap_reset();
        let (mut fc, mut bc) = ([Cell::default(); 4], [Cell::default(); 4]);
        let front = blank_buf(&mut fc, 4, 1);
        let mut back = blank_buf(&mut bc, 4, 1);
        let red = Style {
            fg: Color::Red,
            ..Style::plain()
        };
        let blue = Style {
            fg: Color::Blue,
            ..Style::plain()
        };
        back.set(
            0,
            0,
            Cell {
                ch: 'A',
                style: red,
            },
        );
        back.set(
            1,
            0,
            Cell {
                ch: 'B',
                style: blue,
            },
        );
        diff(&front, &back, cap_sink);
        // One move, red SGR, 'A', blue SGR (no move -- the cursor is already
        // there), 'B', reset.
        assert_eq!(captured(), b"\x1b[1;1H\x1b[0;31mA\x1b[0;34mB\x1b[0m");
    }

    #[test]
    fn attributes_and_a_background_fold_into_one_sgr() {
        let _bench = bench();
        cap_reset();
        let (mut fc, mut bc) = ([Cell::default(); 2], [Cell::default(); 2]);
        let front = blank_buf(&mut fc, 2, 1);
        let mut back = blank_buf(&mut bc, 2, 1);
        back.set(
            0,
            0,
            Cell {
                ch: '!',
                style: Style {
                    fg: Color::BrightWhite,
                    bg: Color::Blue,
                    attrs: ATTR_BOLD | ATTR_REVERSE,
                },
            },
        );
        diff(&front, &back, cap_sink);
        // reset, bold, reverse, fg 97, bg 44, then '!'.
        assert_eq!(captured(), b"\x1b[1;1H\x1b[0;1;7;97;44m!\x1b[0m");
    }

    #[test]
    fn a_non_ascii_code_point_is_written_as_utf8() {
        let _bench = bench();
        cap_reset();
        let (mut fc, mut bc) = ([Cell::default(); 1], [Cell::default(); 1]);
        let front = blank_buf(&mut fc, 1, 1);
        let mut back = blank_buf(&mut bc, 1, 1);
        // U+2502 BOX DRAWINGS LIGHT VERTICAL -> E2 94 82.
        back.set(0, 0, Cell::ch('│'));
        diff(&front, &back, cap_sink);
        assert_eq!(captured(), b"\x1b[1;1H\x1b[0m\xe2\x94\x82\x1b[0m");
    }

    // ---- the run loop -------------------------------------------------------

    #[test]
    fn run_drives_the_model_to_quit_and_emits_an_incremental_frame_stream() {
        let _bench = bench();
        cap_reset();
        script_reset(b"aq");
        let (mut fc, mut bc) = ([Cell::default(); 1], [Cell::default(); 1]);
        let final_model = run(
            Counter::default(),
            Config {
                w: 1,
                h: 1,
                sink: cap_sink,
                input: script_input,
                front: &mut fc,
                back: &mut bc,
            },
        );
        // 'a' advances 0 -> 1, then 'q' quits; the quit frame redraws the same '1'.
        assert_eq!(final_model.n, 1);
        assert!(final_model.quit);
        // enter (alt-screen, hide cursor, clear), the frame for n=0, the frame for
        // n=1, the quit frame (no change -> nothing), then leave.
        assert_eq!(
            captured(),
            b"\x1b[?1049h\x1b[?25l\x1b[2J\
              \x1b[1;1H\x1b[0m0\x1b[0m\
              \x1b[1;1H\x1b[0m1\x1b[0m\
              \x1b[?25h\x1b[?1049l"
        );
    }

    #[test]
    fn run_decodes_a_multi_byte_arrow_sequence_into_one_key_event() {
        let _bench = bench();
        cap_reset();
        // ESC [ C is a single Right arrow, then 'q' quits. The three escape bytes
        // must fold into one Right event, not leak as three raw ones.
        script_reset(b"\x1b[Cq");
        let (mut fc, mut bc) = ([Cell::default(); 1], [Cell::default(); 1]);
        let final_model = run(
            Counter::default(),
            Config {
                w: 1,
                h: 1,
                sink: cap_sink,
                input: script_input,
                front: &mut fc,
                back: &mut bc,
            },
        );
        assert_eq!(final_model.n, 1);
        assert!(final_model.quit);
    }

    #[test]
    fn run_ticks_when_the_input_is_dry() {
        let _bench = bench();
        cap_reset();
        script_reset(b"");
        let (mut fc, mut bc) = ([Cell::default(); 1], [Cell::default(); 1]);
        // A dry input ticks; the counter climbs by ten each turn and quits at 100,
        // which proves the tick reaches `update` (and that a `None` is not a key).
        #[derive(Clone, Copy, Default)]
        struct Ticker {
            n: i32,
        }
        impl Model for Ticker {
            fn update(mut self, ev: Event) -> Self {
                if ev == Event::Tick {
                    self.n += 10;
                }
                self
            }
            fn view(&self, _buf: &mut Buffer<'_>) {}
            fn quit(&self) -> bool {
                self.n >= 100
            }
        }
        let final_model = run(
            Ticker::default(),
            Config {
                w: 1,
                h: 1,
                sink: cap_sink,
                input: null_input,
                front: &mut fc,
                back: &mut bc,
            },
        );
        assert_eq!(final_model.n, 100);
    }

    // ---- the paint primitives -----------------------------------------------

    #[test]
    fn set_writes_one_cell_and_drops_off_grid_writes() {
        let mut cells = [Cell::default(); 6];
        let mut buf = blank_buf(&mut cells, 3, 2);
        buf.set(1, 1, Cell::ch('X'));
        assert_eq!(buf.get(1, 1).unwrap().ch, 'X');
        // Off-grid in x and in y: both silently dropped, no panic.
        buf.set(3, 0, Cell::ch('Y'));
        buf.set(0, 2, Cell::ch('Z'));
        assert!(buf.get(3, 0).is_none());
        assert!(buf.get(0, 2).is_none());
    }

    #[test]
    fn text_writes_a_byte_run_and_clips_at_the_right_edge() {
        let mut cells = [Cell::default(); 4];
        let mut buf = blank_buf(&mut cells, 4, 1);
        let green = Style {
            fg: Color::Green,
            ..Style::plain()
        };
        buf.text(2, 0, b"Hi!", green);
        assert_eq!(buf.get(2, 0).unwrap().ch, 'H');
        assert_eq!(buf.get(3, 0).unwrap().ch, 'i');
        assert_eq!(buf.get(3, 0).unwrap().style.fg, Color::Green);
        // The '!' would land at x=4 -- off-grid, dropped; the row's start is
        // untouched.
        assert_eq!(buf.get(0, 0).unwrap().ch, ' ');
    }

    #[test]
    fn fill_paints_a_clipped_rectangle() {
        let mut cells = [Cell::default(); 9];
        let mut buf = blank_buf(&mut cells, 3, 3);
        buf.fill(1, 1, 5, 5, Cell::ch('#')); // 5x5 runs off both edges
        assert_eq!(buf.get(1, 1).unwrap().ch, '#');
        assert_eq!(buf.get(2, 2).unwrap().ch, '#');
        assert_eq!(buf.get(0, 0).unwrap().ch, ' ');
    }

    #[test]
    fn hline_and_vline_paint_runs_in_one_style() {
        let mut cells = [Cell::default(); 16];
        let mut buf = blank_buf(&mut cells, 4, 4);
        let red = Style {
            fg: Color::Red,
            ..Style::plain()
        };
        buf.hline(0, 0, 4, '-', red);
        buf.vline(0, 0, 4, '|', Style::plain());
        assert_eq!(buf.get(3, 0).unwrap().ch, '-');
        assert_eq!(buf.get(3, 0).unwrap().style.fg, Color::Red);
        assert_eq!(buf.get(0, 3).unwrap().ch, '|');
    }

    #[test]
    fn box_draws_a_bordered_frame_and_leaves_the_interior_blank() {
        let mut cells = [Cell::default(); 12]; // a 4x3 grid
        let mut buf = blank_buf(&mut cells, 4, 3);
        buf.box_(0, 0, 4, 3, Style::plain());
        assert_eq!(buf.get(0, 0).unwrap().ch, '┌');
        assert_eq!(buf.get(3, 0).unwrap().ch, '┐');
        assert_eq!(buf.get(0, 2).unwrap().ch, '└');
        assert_eq!(buf.get(3, 2).unwrap().ch, '┘');
        assert_eq!(buf.get(1, 0).unwrap().ch, '─'); // top edge
        assert_eq!(buf.get(0, 1).unwrap().ch, '│'); // left edge
        assert_eq!(buf.get(1, 1).unwrap().ch, ' '); // interior untouched
    }

    #[test]
    fn blit_composites_one_buffer_into_another_at_an_offset() {
        let mut scells = [Cell::default(); 1];
        let mut src = blank_buf(&mut scells, 1, 1);
        src.set(0, 0, Cell::ch('*'));
        let mut dcells = [Cell::default(); 9];
        let mut dst = blank_buf(&mut dcells, 3, 3);
        dst.blit(1, 1, &src);
        assert_eq!(dst.get(1, 1).unwrap().ch, '*');
        assert_eq!(dst.get(0, 0).unwrap().ch, ' ');
    }

    #[test]
    fn clear_resets_every_cell_to_a_blank() {
        let mut cells = [Cell::default(); 4];
        let mut buf = blank_buf(&mut cells, 2, 2);
        buf.fill(0, 0, 2, 2, Cell::ch('#'));
        buf.clear();
        assert_eq!(buf.get(0, 0).unwrap().ch, ' ');
        assert_eq!(buf.get(1, 1).unwrap().ch, ' ');
    }
}
