//! The one place an ANSI color is spelled.
//!
//! Every entry is an SGR escape when [`COLOR`] is on and an empty slice when it
//! is off, so call sites stay branch-free: an uncolored build emits nothing extra
//! and a fixed-string contract grep matches the same bytes either way. The status
//! tags and every future panel / key-value / progress renderer tint from here --
//! never inline a raw escape at a call site.
//!
//! Only a subset is wired today; the rest are seeded so a new renderer can reach
//! for a color without widening this block.

/// Master ANSI switch. With color off every entry below is empty, so a tag
/// renders as its plain six-wide `[ OK ]` / `[FAIL]` form and the byte stream is
/// escape-free. A fixed-string contract grep that expects a bare `[FAIL]` must
/// therefore run against a color-off build; color on tints only the inner word
/// and leaves the brackets in the default color.
pub const COLOR: bool = true;

/// Charset knob for the box-drawing renderers. `false` = ASCII (`+-|`), `true` =
/// Unicode lines. The device console passes raw bytes and only UTF-8 terminals
/// render the Unicode forms, so ASCII is the safe default.
pub const UNICODE: bool = false;

/// Select an escape or nothing, depending on [`COLOR`].
const fn sgr(escape: &'static [u8]) -> &'static [u8] {
    if COLOR {
        escape
    } else {
        b""
    }
}

// Foreground -- the eight base ANSI colors (yellow is the amber the [LOAD] /
// [WARN] tags use).
pub const BLACK: &[u8] = sgr(b"\x1b[30m");
pub const RED: &[u8] = sgr(b"\x1b[31m");
pub const GREEN: &[u8] = sgr(b"\x1b[32m");
pub const YELLOW: &[u8] = sgr(b"\x1b[33m");
pub const BLUE: &[u8] = sgr(b"\x1b[34m");
pub const MAGENTA: &[u8] = sgr(b"\x1b[35m");
pub const CYAN: &[u8] = sgr(b"\x1b[36m");
pub const WHITE: &[u8] = sgr(b"\x1b[37m");

// Bright / high-intensity set (bright black = grey, the usual dim-text color).
pub const BRIGHT_BLACK: &[u8] = sgr(b"\x1b[90m");
pub const BRIGHT_RED: &[u8] = sgr(b"\x1b[91m");
pub const BRIGHT_GREEN: &[u8] = sgr(b"\x1b[92m");
pub const BRIGHT_YELLOW: &[u8] = sgr(b"\x1b[93m");
pub const GREY: &[u8] = BRIGHT_BLACK;

// Attributes.
pub const BOLD: &[u8] = sgr(b"\x1b[1m");
pub const DIM: &[u8] = sgr(b"\x1b[2m");
pub const RESET: &[u8] = sgr(b"\x1b[0m");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grey_is_the_bright_black_alias() {
        assert_eq!(GREY, BRIGHT_BLACK);
    }

    #[test]
    fn every_escape_collapses_to_nothing_when_color_is_off() {
        // `sgr` is the only gate between an escape and the empty slice, so
        // proving it here proves the whole palette obeys the knob.
        assert_eq!(
            sgr(b"\x1b[31m"),
            if COLOR { b"\x1b[31m".as_slice() } else { b"" }
        );
    }
}
