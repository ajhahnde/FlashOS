//! Console I/O -- the sinks, the terminal-control seam, and formatted output.
//!
//! Output is built into a stack-resident 256-byte [`Buf`], then emitted to a
//! descriptor in a single length-carrying write syscall. Output longer than 255
//! bytes is silently truncated: the trailing slot stays free, and truncating beats
//! a syscall-per-flush mid-format for a userland this size.
//!
//! ## Why not `write!`
//!
//! Rust's formatting machinery (`core::fmt`) is a code-size and symbol-count
//! multiplier that would eat directly into the kernel's fixed 128 KiB symbol budget
//! and the frozen memory map, and every EL0 payload gate in `xtask` fails the build
//! if a `core::fmt` symbol appears. So the old comptime-`printf` is replaced by an
//! explicit part list: [`printf`] takes a slice of [`Part`]s and renders each with a
//! hand-rolled integer formatter. Same output bytes, same truncation bound, no
//! formatting engine.

#[cfg(target_os = "none")]
use flashsdk_rt::syscall;

/// Bytes an assembled line may occupy before it is truncated.
pub const BUF_LEN: usize = 256;

/// One renderable argument. The old `printf("%s = %d\n", ...)` becomes
/// `printf(&[Str(b"x = "), Dec(v), Str(b"\n")])` -- the specs, minus the parser.
#[derive(Clone, Copy)]
pub enum Part<'a> {
    /// A byte slice, emitted verbatim (the old `%s` over a known length).
    Str(&'a [u8]),
    /// Signed decimal (the old `%d` / `%i`).
    Dec(i64),
    /// Unsigned decimal (the old `%u`).
    Udec(u64),
    /// Lowercase hex, unpadded (the old `%x`).
    Hex(u64),
    /// A single byte (the old `%c`).
    Byte(u8),
}

/// A fixed-capacity line builder with saturating appends. Pure: it touches no
/// syscall, so the byte-exact rendering of every [`Part`] is host-testable.
pub struct Buf {
    bytes: [u8; BUF_LEN],
    len: usize,
}

impl Default for Buf {
    fn default() -> Self {
        Self::new()
    }
}

impl Buf {
    pub const fn new() -> Self {
        Self {
            bytes: [0; BUF_LEN],
            len: 0,
        }
    }

    /// The bytes written so far.
    pub fn as_slice(&self) -> &[u8] {
        &self.bytes[..self.len]
    }

    /// Append one byte, silently dropping it once the buffer is full. The last
    /// slot is deliberately left unused, matching the old builder's bound.
    pub fn byte(&mut self, b: u8) -> &mut Self {
        if self.len < BUF_LEN - 1 {
            self.bytes[self.len] = b;
            self.len += 1;
        }
        self
    }

    /// Append a byte slice, saturating at the buffer bound.
    pub fn str(&mut self, s: &[u8]) -> &mut Self {
        for &b in s {
            self.byte(b);
        }
        self
    }

    /// Append a signed decimal.
    pub fn dec(&mut self, val: i64) -> &mut Self {
        if val < 0 {
            self.byte(b'-');
            // i64::MIN would overflow a plain negation, so recover the magnitude
            // through the wrapping identity instead of branching on it.
            let magnitude = (-(val.wrapping_add(1))) as u64 + 1;
            self.udec(magnitude)
        } else {
            self.udec(val as u64)
        }
    }

    /// Append an unsigned decimal.
    pub fn udec(&mut self, val: u64) -> &mut Self {
        if val == 0 {
            return self.byte(b'0');
        }
        // u64::MAX is 20 decimal digits.
        let mut tmp = [0u8; 20];
        let mut n = 0;
        let mut v = val;
        while v > 0 {
            tmp[n] = b'0' + (v % 10) as u8;
            n += 1;
            v /= 10;
        }
        while n > 0 {
            n -= 1;
            self.byte(tmp[n]);
        }
        self
    }

    /// Append lowercase hex, unpadded.
    pub fn hex(&mut self, val: u64) -> &mut Self {
        if val == 0 {
            return self.byte(b'0');
        }
        const DIGITS: &[u8; 16] = b"0123456789abcdef";
        let mut tmp = [0u8; 16];
        let mut n = 0;
        let mut v = val;
        while v > 0 {
            tmp[n] = DIGITS[(v & 0xf) as usize];
            n += 1;
            v >>= 4;
        }
        while n > 0 {
            n -= 1;
            self.byte(tmp[n]);
        }
        self
    }

    /// Append one rendered [`Part`].
    pub fn part(&mut self, part: Part<'_>) -> &mut Self {
        match part {
            Part::Str(s) => self.str(s),
            Part::Dec(v) => self.dec(v),
            Part::Udec(v) => self.udec(v),
            Part::Hex(v) => self.hex(v),
            Part::Byte(b) => self.byte(b),
        }
    }

    /// Append every part in order.
    pub fn parts(&mut self, parts: &[Part<'_>]) -> &mut Self {
        for &p in parts {
            self.part(p);
        }
        self
    }
}

/// Render `parts` into a fixed buffer -- the pure half of [`printf`], so a call
/// site's exact bytes can be asserted on the host without a kernel.
pub fn render(parts: &[Part<'_>]) -> Buf {
    let mut buf = Buf::new();
    buf.parts(parts);
    buf
}

/// The output seam: hand it a slice, it consumes the whole slice. Infallible by
/// contract -- backpressure and write errors are the backing's concern, dealt with
/// behind the pointer the caller binds ([`console_sink`], [`err_sink`], or a test's
/// collector).
pub type Sink = fn(&[u8]);

/// A buffered writer over a [`Sink`]. Bytes accumulate in the caller's buffer and
/// drain when it fills or on [`flush`](Writer::flush) -- so a long line is written
/// in several syscalls rather than truncated, which is what separates this from the
/// fixed-capacity [`Buf`] that [`printf`] renders into. Nothing is allocated: the
/// buffer belongs to the caller's frame.
pub struct Writer<'a> {
    sink: Sink,
    buf: &'a mut [u8],
    end: usize,
}

impl<'a> Writer<'a> {
    /// Bind a writer that batches into `buf` and drains through `sink`. `buf` must
    /// be non-empty, or a write could never make progress.
    pub fn new(sink: Sink, buf: &'a mut [u8]) -> Self {
        debug_assert!(!buf.is_empty());
        Self { sink, buf, end: 0 }
    }

    /// Drain whatever is buffered. A no-op when empty, so it is always safe to call
    /// at the end of a write.
    pub fn flush(&mut self) {
        if self.end > 0 {
            (self.sink)(&self.buf[..self.end]);
            self.end = 0;
        }
    }

    /// Write every byte, draining to the sink whenever the buffer fills. The bytes
    /// are not seen by the sink until a flush or the next fill.
    pub fn write_all(&mut self, bytes: &[u8]) {
        for &b in bytes {
            if self.end == self.buf.len() {
                self.flush();
            }
            self.buf[self.end] = b;
            self.end += 1;
        }
    }
}

// ---- the syscall-facing half -----------------------------------------------

/// The OS side of the console seam: hand a finished byte slice to fd 1. This is
/// the single place userland turns bytes into a write syscall; every console write
/// routes through it, and the console renderers bind it as their `Sink`.
#[cfg(target_os = "none")]
pub fn console_sink(bytes: &[u8]) {
    let _ = syscall::write(syscall::STDOUT, bytes);
}

/// The same, for fd 2.
#[cfg(target_os = "none")]
pub fn err_sink(bytes: &[u8]) {
    let _ = syscall::write(syscall::STDERR, bytes);
}

/// The input half of the console seam: block on one byte from fd 0, or `None` at
/// end-of-input. FlashOS's console read has no timeout -- it blocks until a byte
/// arrives -- so a caller that wants to animate cannot rely on this returning.
#[cfg(target_os = "none")]
pub fn console_input() -> Option<u8> {
    let mut b = [0u8; 1];
    if syscall::read(syscall::STDIN, &mut b) <= 0 {
        return None;
    }
    Some(b[0])
}

/// Enter the alternate screen, show the cursor, and clear. The cursor is shown
/// (not hidden as a pager would want) because the editor parks a live edit cursor;
/// the matching restore is [`alt_leave`].
#[cfg(target_os = "none")]
pub fn alt_enter() {
    console_sink(b"\x1b[?1049h\x1b[?25h\x1b[2J");
}

/// Show the cursor and leave the alternate screen -- the exact inverse of
/// [`alt_enter`].
#[cfg(target_os = "none")]
pub fn alt_leave() {
    console_sink(b"\x1b[?25h\x1b[?1049l");
}

/// Park the cursor at 1-based `(row, col)`. A render core's diff leaves the cursor
/// wherever its last changed cell was, so a program that wants a visible cursor at
/// a chosen spot calls this after the frame is drawn.
#[cfg(target_os = "none")]
pub fn park_cursor(row: u16, col: u16) {
    console_sink(cursor_park_sequence(row, col).as_slice());
}

/// The `ESC [ row ; col H` bytes [`park_cursor`] emits, split out so they can be
/// asserted on the host.
pub fn cursor_park_sequence(row: u16, col: u16) -> Buf {
    let mut buf = Buf::new();
    buf.byte(0x1b)
        .byte(b'[')
        .udec(row as u64)
        .byte(b';')
        .udec(col as u64)
        .byte(b'H');
    buf
}

/// Write a byte slice followed by a newline.
#[cfg(target_os = "none")]
pub fn puts(s: &[u8]) {
    let mut buf = Buf::new();
    buf.str(s).byte(b'\n');
    console_sink(buf.as_slice());
}

/// Render `parts` and emit them to stdout in one write.
#[cfg(target_os = "none")]
pub fn printf(parts: &[Part<'_>]) {
    console_sink(render(parts).as_slice());
}

/// Render `parts` and emit them to stderr in one write.
#[cfg(target_os = "none")]
pub fn eprintf(parts: &[Part<'_>]) {
    err_sink(render(parts).as_slice());
}

#[cfg(test)]
mod tests {
    use super::Part::{Byte, Dec, Hex, Str, Udec};
    use super::*;

    #[test]
    fn parts_render_in_order() {
        let out = render(&[
            Str(b"pid "),
            Dec(42),
            Str(b" @ 0x"),
            Hex(0xbbff2),
            Byte(b'\n'),
        ]);
        assert_eq!(out.as_slice(), b"pid 42 @ 0xbbff2\n");
    }

    #[test]
    fn zero_renders_as_a_single_digit_in_every_base() {
        assert_eq!(render(&[Dec(0)]).as_slice(), b"0");
        assert_eq!(render(&[Udec(0)]).as_slice(), b"0");
        assert_eq!(render(&[Hex(0)]).as_slice(), b"0");
    }

    #[test]
    fn the_most_negative_integer_renders_without_overflowing_its_negation() {
        // -i64::MIN is not representable: a naive `-val` traps or wraps to itself
        // and prints the wrong magnitude.
        assert_eq!(render(&[Dec(i64::MIN)]).as_slice(), b"-9223372036854775808");
        assert_eq!(render(&[Dec(-1)]).as_slice(), b"-1");
    }

    #[test]
    fn the_widest_unsigned_value_renders_every_digit() {
        assert_eq!(
            render(&[Udec(u64::MAX)]).as_slice(),
            b"18446744073709551615"
        );
        assert_eq!(render(&[Hex(u64::MAX)]).as_slice(), b"ffffffffffffffff");
    }

    #[test]
    fn output_past_the_buffer_bound_truncates_rather_than_overruns() {
        let long = [b'x'; 512];
        let out = render(&[Str(&long)]);
        assert_eq!(out.as_slice().len(), BUF_LEN - 1);
        assert!(out.as_slice().iter().all(|&b| b == b'x'));
    }

    #[test]
    fn a_truncated_line_drops_the_tail_and_keeps_the_head() {
        let head = [b'a'; BUF_LEN - 1];
        let out = render(&[Str(&head), Str(b"TAIL")]);
        assert_eq!(out.as_slice().len(), BUF_LEN - 1);
        assert!(!out.as_slice().ends_with(b"TAIL"));
    }

    // The writer's sink is a bare `fn` pointer (no captured environment, so no
    // allocation), which leaves a static as the only place a test can collect what
    // was written. Both writer tests share it, so each resets it first.
    static mut WRITTEN: [u8; 64] = [0; 64];
    static mut WRITTEN_LEN: usize = 0;
    static mut DRAINS: usize = 0;

    fn collect(bytes: &[u8]) {
        unsafe {
            let len = WRITTEN_LEN;
            WRITTEN[len..len + bytes.len()].copy_from_slice(bytes);
            WRITTEN_LEN = len + bytes.len();
            DRAINS += 1;
        }
    }

    fn reset_collector() {
        unsafe {
            WRITTEN_LEN = 0;
            DRAINS = 0;
        }
    }

    #[test]
    fn a_writer_holds_its_bytes_back_until_it_is_flushed() {
        reset_collector();
        let mut buf = [0u8; 16];
        let mut w = Writer::new(collect, &mut buf);
        w.write_all(b"hi");
        assert_eq!(unsafe { DRAINS }, 0, "an unflushed writer must not emit");
        w.flush();
        assert_eq!(unsafe { &WRITTEN[..WRITTEN_LEN] }, b"hi");
        assert_eq!(unsafe { DRAINS }, 1);
        w.flush();
        assert_eq!(
            unsafe { DRAINS },
            1,
            "flushing an empty writer must be a no-op"
        );
    }

    #[test]
    fn output_past_the_writer_buffer_drains_rather_than_truncating() {
        // The distinction from `Buf`, which drops the tail: a line longer than the
        // buffer must still reach the sink whole, split across drains.
        reset_collector();
        let mut buf = [0u8; 4];
        let mut w = Writer::new(collect, &mut buf);
        w.write_all(b"abcdefghij");
        w.flush();
        assert_eq!(unsafe { &WRITTEN[..WRITTEN_LEN] }, b"abcdefghij");
        assert_eq!(
            unsafe { DRAINS },
            3,
            "10 bytes through a 4-byte buffer: 4 + 4 + 2"
        );
    }

    #[test]
    fn the_cursor_park_sequence_is_one_based_and_semicolon_separated() {
        assert_eq!(cursor_park_sequence(1, 1).as_slice(), b"\x1b[1;1H");
        assert_eq!(cursor_park_sequence(24, 80).as_slice(), b"\x1b[24;80H");
    }
}
