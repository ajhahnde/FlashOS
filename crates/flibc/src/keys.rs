//! The key decoder -- raw console bytes turned into semantic key events.
//!
//! This is the input half of the shell-first navigation seam. A full-screen tool
//! puts the console in raw mode (kernel echo off, byte at a time -- the same mode
//! the login password loop relies on) and pulls key events until the stream closes.
//!
//! The decode itself is a pure state machine over single bytes, because an arrow
//! key is not a byte: it arrives as the three-byte `ESC [ A` sequence, and a naive
//! reader would surface it as an Escape followed by two printable characters. The
//! machine is therefore fed byte by byte and answers [`Key::None`] while it is still
//! inside a sequence. Keeping it pure -- and keeping the syscall-bound [`read_key`]
//! a thin loop on top -- is what lets every sequence be host-tested without a kernel
//! underneath.

#[cfg(target_os = "none")]
use crate::io;

/// A decoded key. [`Key::Char`] carries its byte in [`Event::ch`]; [`Key::None`]
/// means the byte was consumed mid-sequence and the caller should feed more;
/// [`Key::Eof`] means the stream closed.
///
/// The navigation set (delete / home / end / page up / page down) and the editor
/// command chords are decoded whether or not a given caller uses them -- a pager or
/// a readline that does not lets them fall through its match arm.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Up,
    Down,
    Left,
    Right,
    Enter,
    Backspace,
    Delete,
    Tab,
    Escape,
    Home,
    End,
    PageUp,
    PageDown,
    CtrlC,
    CtrlD,
    CtrlO,
    CtrlW,
    CtrlX,
    Char,
    None,
    Eof,
}

/// A key event. `ch` is meaningful only for [`Key::Char`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Event {
    pub key: Key,
    pub ch: u8,
}

impl Event {
    /// An event that carries no byte.
    const fn plain(key: Key) -> Self {
        Self { key, ch: 0 }
    }
}

/// Where the decoder stands inside an escape sequence.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
enum State {
    #[default]
    Ground,
    Esc,
    Csi,
}

/// An incremental VT100 input decoder. Feed it one byte at a time; it answers
/// [`Key::None`] while inside an escape sequence and a real key when one completes.
/// A fresh decoder per [`read_key`] call is correct, because a whole sequence is
/// consumed within one call.
#[derive(Clone, Copy, Debug, Default)]
pub struct Decoder {
    state: State,
    /// Accumulates the numeric parameter of a CSI sequence (`ESC [ <n> ~`).
    param: u16,
}

impl Decoder {
    pub const fn new() -> Self {
        Self {
            state: State::Ground,
            param: 0,
        }
    }

    /// Consume one byte and report the key it completed, if any.
    pub fn feed(&mut self, b: u8) -> Event {
        match self.state {
            State::Ground => self.at_ground(b),
            State::Esc => self.at_esc(b),
            State::Csi => self.at_csi(b),
        }
    }

    fn at_ground(&mut self, b: u8) -> Event {
        match b {
            0x1b => {
                self.state = State::Esc;
                Event::plain(Key::None)
            }
            b'\r' | b'\n' => Event::plain(Key::Enter),
            b'\t' => Event::plain(Key::Tab),
            0x08 | 0x7f => Event::plain(Key::Backspace),
            0x03 => Event::plain(Key::CtrlC),
            0x04 => Event::plain(Key::CtrlD),
            0x0f => Event::plain(Key::CtrlO),
            0x17 => Event::plain(Key::CtrlW),
            0x18 => Event::plain(Key::CtrlX),
            0x20..=0x7e => Event {
                key: Key::Char,
                ch: b,
            },
            _ => Event::plain(Key::None),
        }
    }

    fn at_esc(&mut self, b: u8) -> Event {
        if b == b'[' {
            self.state = State::Csi;
            self.param = 0;
            return Event::plain(Key::None);
        }
        if b == 0x1b {
            // A second ESC: stay pending on the newer one.
            return Event::plain(Key::None);
        }
        // ESC followed by anything else is a bare Escape, and the trailing byte is
        // dropped -- Alt-<key> chords are out of scope.
        self.state = State::Ground;
        Event::plain(Key::Escape)
    }

    fn at_csi(&mut self, b: u8) -> Event {
        // Digits accumulate the parameter so that ESC[3~ (delete) and ESC[5~ (page
        // up) stay distinguishable rather than collapsing into one key. A ';' opens a
        // sub-parameter (a modified arrow such as ESC[1;5C), so the parameter is
        // reset and the final group wins: the arrow and tilde keys ignore modifiers
        // here.
        if b.is_ascii_digit() {
            // A digit run wider than the parameter wraps rather than trapping. The
            // value is only matched against the small table below, so a wrapped
            // parameter decodes as an unknown sequence -- which is how an absurd
            // parameter deserves to be treated anyway.
            self.param = self.param.wrapping_mul(10).wrapping_add((b - b'0') as u16);
            return Event::plain(Key::None);
        }
        if b == b';' {
            self.param = 0;
            return Event::plain(Key::None);
        }
        self.state = State::Ground;
        match b {
            b'A' => Event::plain(Key::Up),
            b'B' => Event::plain(Key::Down),
            b'C' => Event::plain(Key::Right),
            b'D' => Event::plain(Key::Left),
            // The parameterless forms of Home and End.
            b'H' => Event::plain(Key::Home),
            b'F' => Event::plain(Key::End),
            b'~' => match self.param {
                1 | 7 => Event::plain(Key::Home),
                3 => Event::plain(Key::Delete),
                4 | 8 => Event::plain(Key::End),
                5 => Event::plain(Key::PageUp),
                6 => Event::plain(Key::PageDown),
                _ => Event::plain(Key::None),
            },
            _ => Event::plain(Key::None),
        }
    }
}

/// Drive a fresh [`Decoder`] from a byte source until one whole key completes. `next`
/// returns `None` when the stream closes, which surfaces as [`Key::Eof`].
///
/// This is the pure half of [`read_key`]: the loop that turns a byte source into a
/// single key event is worth testing, and it must not drag a syscall in to be so.
pub fn read_key_from(mut next: impl FnMut() -> Option<u8>) -> Event {
    let mut dec = Decoder::new();
    loop {
        let Some(b) = next() else {
            return Event::plain(Key::Eof);
        };
        let ev = dec.feed(b);
        if ev.key != Key::None {
            return ev;
        }
    }
}

/// Block until one whole key is read from the console. Returns [`Key::Eof`] when the
/// stream closes. Use it inside a full-screen loop, paired with the alternate-screen
/// seam and raw console mode.
#[cfg(target_os = "none")]
pub fn read_key() -> Event {
    read_key_from(io::console_input)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Feed a whole byte sequence and stop at the first completed key, the way
    /// [`read_key_from`] does over a live stream.
    fn decode_one(seq: &[u8]) -> Event {
        let mut d = Decoder::new();
        let mut last = Event::plain(Key::None);
        for &b in seq {
            last = d.feed(b);
            if last.key != Key::None {
                return last;
            }
        }
        last
    }

    #[test]
    fn printable_byte_decodes_to_char() {
        let e = decode_one(b"a");
        assert_eq!(Key::Char, e.key);
        assert_eq!(b'a', e.ch);
    }

    #[test]
    fn cr_and_lf_decode_to_enter() {
        assert_eq!(Key::Enter, decode_one(b"\r").key);
        assert_eq!(Key::Enter, decode_one(b"\n").key);
    }

    #[test]
    fn tab_decodes_to_tab() {
        assert_eq!(Key::Tab, decode_one(b"\t").key);
    }

    #[test]
    fn ctrl_c_and_ctrl_d() {
        assert_eq!(Key::CtrlC, decode_one(&[0x03]).key);
        assert_eq!(Key::CtrlD, decode_one(&[0x04]).key);
    }

    #[test]
    fn arrow_sequences_decode_through_esc_bracket_a_to_d() {
        assert_eq!(Key::Up, decode_one(b"\x1b[A").key);
        assert_eq!(Key::Down, decode_one(b"\x1b[B").key);
        assert_eq!(Key::Right, decode_one(b"\x1b[C").key);
        assert_eq!(Key::Left, decode_one(b"\x1b[D").key);
    }

    #[test]
    fn parametrized_csi_decodes_on_the_terminator_not_before() {
        let mut d = Decoder::new();
        assert_eq!(Key::None, d.feed(0x1b).key);
        assert_eq!(Key::None, d.feed(b'[').key);
        // The parameter byte is buffered, not surfaced.
        assert_eq!(Key::None, d.feed(b'5').key);
        // Only the terminator yields the key.
        assert_eq!(Key::PageUp, d.feed(b'~').key);
    }

    #[test]
    fn bare_esc_then_a_letter_yields_escape() {
        let mut d = Decoder::new();
        assert_eq!(Key::None, d.feed(0x1b).key);
        assert_eq!(Key::Escape, d.feed(b'x').key);
    }

    #[test]
    fn editor_command_chords_decode_at_ground() {
        assert_eq!(Key::CtrlO, decode_one(&[0x0f]).key);
        assert_eq!(Key::CtrlW, decode_one(&[0x17]).key);
        assert_eq!(Key::CtrlX, decode_one(&[0x18]).key);
    }

    #[test]
    fn tilde_navigation_sequences_decode_by_parameter() {
        assert_eq!(Key::Home, decode_one(b"\x1b[1~").key);
        assert_eq!(Key::Delete, decode_one(b"\x1b[3~").key);
        assert_eq!(Key::End, decode_one(b"\x1b[4~").key);
        assert_eq!(Key::PageUp, decode_one(b"\x1b[5~").key);
        assert_eq!(Key::PageDown, decode_one(b"\x1b[6~").key);
        assert_eq!(Key::Home, decode_one(b"\x1b[7~").key);
        assert_eq!(Key::End, decode_one(b"\x1b[8~").key);
    }

    #[test]
    fn letter_home_and_end_decode() {
        assert_eq!(Key::Home, decode_one(b"\x1b[H").key);
        assert_eq!(Key::End, decode_one(b"\x1b[F").key);
    }

    #[test]
    fn a_modified_arrow_still_decodes_to_a_plain_arrow() {
        assert_eq!(Key::Right, decode_one(b"\x1b[1;5C").key);
    }

    #[test]
    fn an_unknown_tilde_parameter_is_absorbed_not_leaked() {
        assert_eq!(Key::None, decode_one(b"\x1b[99~").key);
    }

    #[test]
    fn a_spent_byte_source_reports_eof() {
        // The pure half of read_key: a closed stream ends the loop instead of
        // spinning on it.
        let mut seq = b"\x1b[A".iter().copied();
        assert_eq!(Key::Up, read_key_from(|| seq.next()).key);
        let mut empty = core::iter::empty();
        assert_eq!(Key::Eof, read_key_from(|| empty.next()).key);
    }
}
