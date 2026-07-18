//! `/bin/less` -- the full-screen text pager.
//!
//! The first consumer of the TUI run loop: where the one-shot tools proved the io
//! seam (a writer draining through a sink), less proves the interactive half. The
//! whole frame goes through [`tui::run`], the TEA loop -- less hands it an initial
//! model, a pure `update` (a model and an event yield the next model), a pure `view`
//! (a model paints into a back buffer), and the two injected IO seams. `run` enters
//! the alternate screen, reads keys through its own decoder, double-buffers each
//! `view` and emits only the minimal ANSI diff, then restores the shell view on quit.
//!
//! The scroll logic stays the pure [`Pager`] core -- the TUI layer is render + loop +
//! input, it has no paging of its own, so the pager is the model's domain state.
//!
//! Input is the raw byte seam: `console_input` blocks on `read(0)` and yields one
//! byte; the loop's decoder folds the multi-byte `ESC [` arrow bursts into whole key
//! events. `read(0)` has no timeout, so a tick never fires (nothing here animates).
//! Output is `console_sink` over fd 1. The keys less acts on -- the arrows, Enter,
//! Escape/Ctrl-C/Ctrl-D, and the `q j k space f b g G` chords -- are all in the
//! shared key set, so no local extension is needed (that is the editor's concern).
//!
//! Scope is a proof, like the pager core: it pages a single named file, slurps up to
//! [`BUF_MAX`] bytes onto its own stack (no heap, no `.bss`), indexes the first
//! [`MAX_LINES`] lines, and assumes a 24x80 serial terminal (no window-size ioctl
//! exists yet). A file larger than the slurp shows a `(more)` marker. Reading a pipe
//! is out of scope: fd 0 is the key source, so `cmd | less` would have nowhere to
//! read keys from (a `/dev/tty` concern for later).

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_flibc::pager::Pager;
#[cfg(target_os = "none")]
use flashos_flibc::tui::{self, Buffer, Cell, Event, Style, ATTR_REVERSE};
#[cfg(target_os = "none")]
use flashos_flibc::{console_input, console_sink, keys::Key, sys};
#[cfg(target_os = "none")]
use flashsdk_rt::{arg, arg_ptr, entry, Argv};

// Assumed serial-terminal geometry. One header row (the title bar), one status row,
// the rest content. No window-size query exists, so these are fixed.
#[cfg(target_os = "none")]
const ROWS: usize = 24;
#[cfg(target_os = "none")]
const HEADER: usize = 1;
#[cfg(target_os = "none")]
const STATUS: usize = 1;
/// Visible content rows -- also the pager core's page height.
#[cfg(target_os = "none")]
const PAGE: usize = ROWS - HEADER - STATUS;
/// Clip width -- keep each rendered row to one line.
#[cfg(target_os = "none")]
const COLS: usize = 80;
/// Cell-buffer length (front and back each).
#[cfg(target_os = "none")]
const CELLS: usize = ROWS * COLS;

/// File slurp cap (on this frame).
#[cfg(target_os = "none")]
const BUF_MAX: usize = 16384;
/// Line-index slots.
#[cfg(target_os = "none")]
const MAX_LINES: usize = 2048;
/// Status-line scratch ("first-last/n ..." plus the legend).
#[cfg(target_os = "none")]
const STATUS_MAX: usize = 96;

/// The pager model: the pure scroll state, the title's filename (a slice into argv --
/// stable for the program's life), the truncation marker, and the `quit` flag the run
/// loop reads to end after a final frame.
#[cfg(target_os = "none")]
struct Less<'a> {
    pg: Pager<'a, 'a>,
    name: &'a [u8],
    truncated: bool,
    quit: bool,
}

#[cfg(target_os = "none")]
impl tui::Model for Less<'_> {
    /// Fold one event into the next model: the scroll ops each clamp inside the pager
    /// core, and the quit keys set the flag the loop reads. A tick cannot arrive (the
    /// blocking input never times out) but is handled for the enum's sake. The keys
    /// here are exactly the shared set; the editor's home/end/page/ctrl chords are
    /// absent because a pager does not bind them.
    fn update(mut self, ev: Event) -> Self {
        let Event::Key(k) = ev else {
            return self;
        };
        match k.key {
            Key::Escape | Key::CtrlC | Key::CtrlD => self.quit = true,
            Key::Up => self.pg.up(1),
            Key::Down | Key::Enter => self.pg.down(1),
            Key::Char => match k.ch {
                b'q' => self.quit = true,
                b'j' => self.pg.down(1),
                b'k' => self.pg.up(1),
                b' ' | b'f' => self.pg.page_down(),
                b'b' => self.pg.page_up(),
                b'g' => self.pg.to_top(),
                b'G' => self.pg.to_bottom(),
                _ => {}
            },
            // left/right/tab/backspace/none -- ignored.
            _ => {}
        }
        self
    }

    /// Paint the whole frame into the back buffer: a plain title bar, [`PAGE`] content
    /// rows (`~` past EOF), then a full-width reverse-video status bar. The buffer
    /// arrives blanked each turn, so a row's untouched tail is already spaces -- only
    /// the painted cells are written, and the loop's diff repaints only what changed.
    fn view(&self, buf: &mut Buffer<'_>) {
        // Title bar -- plain, the "+- less: <name> -----+" panel look.
        let mut trow = [0u8; COLS];
        let n = title_row(&mut trow, self.name);
        buf.text(0, 0, &trow[..n], Style::plain());

        // Content rows. The blank cells already fill each row's tail and any short
        // line, so the diff erases a line that shrank between frames.
        for row in 0..self.pg.rows {
            let y = (HEADER + row) as u16;
            let idx = self.pg.top + row;
            if idx < self.pg.n {
                let l = self.pg.line(idx);
                let clipped = if l.len() <= COLS { l } else { &l[..COLS] };
                buf.text(0, y, clipped, Style::plain());
            } else {
                buf.text(0, y, b"~", Style::plain());
            }
        }

        // Status bar -- the whole row in reverse video so the bar spans full width.
        let mut srow = [0u8; STATUS_MAX];
        let sn = status_row(&mut srow, &self.pg, self.truncated);
        buf.text(
            0,
            (ROWS - 1) as u16,
            &srow[..sn],
            Style::attrs(ATTR_REVERSE),
        );
    }

    fn quit(&self) -> bool {
        self.quit
    }
}

/// Build the title row `+- less: <name> ` plus a `-` fill plus `+`, padded to
/// [`COLS`], and return [`COLS`]. Every put is saturating, so a pathological long
/// name clips rather than overrunning the row.
#[cfg(target_os = "none")]
fn title_row(out: &mut [u8; COLS], name: &[u8]) -> usize {
    let mut n = 0;
    n += put_str(out, n, b"+- less: ");
    n += put_str(out, n, name);
    n += put_byte(out, n, b' ');
    while n < COLS - 1 {
        out[n] = b'-';
        n += 1;
    }
    out[COLS - 1] = b'+';
    COLS
}

/// Build the status text ` first-last/n [(more)]   <legend>` into `out`, padded with
/// spaces to its full width so the reverse-video bar is uniform, and return the padded
/// length. Saturating puts keep it inside `out`.
#[cfg(target_os = "none")]
fn status_row(out: &mut [u8; STATUS_MAX], pg: &Pager<'_, '_>, truncated: bool) -> usize {
    let mut n = 0;
    let shown = if pg.n > pg.top {
        core::cmp::min(pg.rows, pg.n - pg.top)
    } else {
        0
    };
    let first = if pg.n == 0 { 0 } else { pg.top + 1 };
    let last = pg.top + shown;
    n += put_byte(out, n, b' ');
    n += put_dec(out, n, first as u64);
    n += put_byte(out, n, b'-');
    n += put_dec(out, n, last as u64);
    n += put_byte(out, n, b'/');
    n += put_dec(out, n, pg.n as u64);
    if truncated {
        n += put_str(out, n, b" (more)");
    }
    n += put_str(out, n, b"   q=quit  space=page  b=back  g/G=ends");
    while n < out.len() {
        out[n] = b' ';
        n += 1;
    }
    n
}

/// The last path component, as a slice into the argv string (no copy). `/a/b` -> `b`,
/// `x` -> `x`.
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

/// `v` as decimal ASCII at `out[pos..]`, returning the count written. The digits fall
/// out least-significant first into a scratch, then copy in reading order.
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
        console_sink(b"usage: less <file>\n");
        return 0;
    }
    let (Some(path_ptr), Some(path)) = (unsafe { arg_ptr(argv, 1) }, unsafe { arg(argv, 1) })
    else {
        console_sink(b"usage: less <file>\n");
        return 0;
    };

    let fd = unsafe { sys::open(path_ptr) };
    if fd < 0 {
        console_sink(b"less: cannot open file\n");
        return 0;
    }

    // Slurp up to BUF_MAX bytes; `truncated` if the file filled the buffer (it may
    // hold more -- best-effort, this is a proof pager).
    let mut buf = [0u8; BUF_MAX];
    let mut n = 0;
    while n < buf.len() {
        let r = sys::read(fd, &mut buf[n..]);
        if r <= 0 {
            break;
        }
        n += r as usize;
    }
    sys::close(fd);
    let truncated = n == buf.len();

    let mut slots = [0u32; MAX_LINES];
    let pg = Pager::init(&buf[..n], &mut slots, PAGE);

    // The double buffer the TEA loop diffs over: front is what is on screen, back is
    // where `view` paints; `run` swaps them each turn.
    let mut front = [Cell::ch(' '); CELLS];
    let mut back = [Cell::ch(' '); CELLS];

    // Take over the console: echo off (mode 0) so typed keys do not leak onto the
    // alt-screen. `run` itself enters the alternate buffer, hides the cursor, and
    // restores both on return.
    sys::set_console_mode(0);

    tui::run(
        Less {
            pg,
            name: base_name(path),
            truncated,
            quit: false,
        },
        tui::Config {
            w: COLS as u16,
            h: ROWS as u16,
            sink: console_sink,
            input: console_input,
            front: &mut front,
            back: &mut back,
        },
    );

    // The console is left in mode 0 (echo off) -- the shell's own baseline, where
    // readline does its own echo -- so there is deliberately no mode restore here
    // (mode 1 would double-echo the next prompt); fsh also re-asserts mode 0 after
    // wait() as a backstop.
    0
}

#[cfg(target_os = "none")]
entry!(main);
