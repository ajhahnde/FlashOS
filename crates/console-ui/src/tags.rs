//! The severity taxonomy and its look.
//!
//! A status line is a six-column bracket label (`[ OK ]`, `[FAIL]`, ...) followed
//! by a message. This module owns the taxonomy: the [`Level`] an event carries and
//! the [`Tag`] each level renders as. The renderer tints only the inner word and
//! leaves the brackets + padding in the default color, the way systemd's boot log
//! does.

use crate::palette;

/// Severity of a status line. New levels slot in here and gain a tag below; every
/// renderer that takes a `Level` then handles them through [`of`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    /// green -- a step completed
    Ok,
    /// cyan -- neutral notice
    Info,
    /// yellow -- a step in progress (resolves to ok / fail)
    Load,
    /// yellow -- degraded but continuing
    Warn,
    /// red -- a step failed
    Fail,
    /// grey -- a step was not applicable
    Skip,
}

/// A six-column status tag, split into the three spans the renderer needs: the
/// bracket-plus-padding on each side stays in the default color and only `word` is
/// tinted by `ansi`. Splitting it this way (rather than coloring a fixed inner
/// slice) lets `[ OK ]` tint just `OK` while `[FAIL]` tints all four inner columns.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Tag {
    /// Left bracket + leading padding, e.g. `"[ "` or `"["`.
    pub pre: &'static [u8],
    /// The tinted word, e.g. `"OK"` / `"FAIL"`.
    pub word: &'static [u8],
    /// Trailing padding + right bracket, e.g. `" ]"` or `"]"`.
    pub post: &'static [u8],
    /// SGR prefix wrapped around `word` when color is on (empty when off).
    pub ansi: &'static [u8],
}

/// Build a tag, asserting the six-column total width that the carriage-return
/// overwrite (`[LOAD]` -> `[ OK ]`) depends on -- a wrong-width tag becomes a
/// compile error instead of a runtime column jump.
const fn tag(
    pre: &'static [u8],
    word: &'static [u8],
    post: &'static [u8],
    ansi: &'static [u8],
) -> Tag {
    assert!(
        pre.len() + word.len() + post.len() == 6,
        "console-ui tag must be exactly 6 columns wide"
    );
    Tag {
        pre,
        word,
        post,
        ansi,
    }
}

pub const OK: Tag = tag(b"[ ", b"OK", b" ]", palette::GREEN);
pub const INFO: Tag = tag(b"[", b"INFO", b"]", palette::CYAN);
pub const LOAD: Tag = tag(b"[", b"LOAD", b"]", palette::YELLOW);
pub const WARN: Tag = tag(b"[", b"WARN", b"]", palette::YELLOW);
pub const FAIL: Tag = tag(b"[", b"FAIL", b"]", palette::RED);
pub const SKIP: Tag = tag(b"[", b"SKIP", b"]", palette::GREY);

// ---- raw marker bytes ------------------------------------------------------
// Prefixes for writers that cannot render through a `Sink` -- the in-kernel test
// harness and PID 1 emit whole NUL-terminated lines through a single console
// write, and the boot watchdog greps some of these markers as bare bytes
// (grep -F). The test markers therefore stay uncolored on purpose: an SGR escape
// inside the brackets would break the byte-exact contract match.

/// `[TEST] ` / `[PASS] ` / `[FAIL] ` -- the self-test scenario markers.
pub const TEST_MARK: &[u8] = b"[TEST] ";
pub const PASS_MARK: &[u8] = b"[PASS] ";
pub const FAIL_MARK: &[u8] = b"[FAIL] ";

/// `[Debug] ` -- kernel diagnostic traces. These deliberately bypass the tag
/// taxonomy and the console mux (they must stay on the UART regardless of USB
/// state), but their prefix is still spelled only here.
pub const DEBUG_MARK: &[u8] = b"[Debug] ";

/// Map a [`Level`] to its [`Tag`]. The exhaustive match makes a new `Level`
/// variant a compile error here until it is given a tag.
pub const fn of(level: Level) -> Tag {
    match level {
        Level::Ok => OK,
        Level::Info => INFO,
        Level::Load => LOAD,
        Level::Warn => WARN,
        Level::Fail => FAIL,
        Level::Skip => SKIP,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_tag_is_exactly_six_columns_wide() {
        // The carriage-return overwrite ([LOAD] -> [ OK ]) is only exact if the
        // uncolored widths agree; `tag` asserts this at compile time, and this
        // pins it against a future tag added by hand.
        for t in [OK, INFO, LOAD, WARN, FAIL, SKIP] {
            assert_eq!(t.pre.len() + t.word.len() + t.post.len(), 6);
        }
    }

    #[test]
    fn of_maps_each_level_to_its_tag() {
        assert_eq!(of(Level::Ok), OK);
        assert_eq!(of(Level::Info), INFO);
        assert_eq!(of(Level::Load), LOAD);
        assert_eq!(of(Level::Warn), WARN);
        assert_eq!(of(Level::Fail), FAIL);
        assert_eq!(of(Level::Skip), SKIP);
    }

    #[test]
    fn the_test_harness_markers_carry_no_escape() {
        // run_qemu_test.sh greps these with grep -F; an SGR escape spliced into
        // the brackets would silently break the boot contract.
        for mark in [TEST_MARK, PASS_MARK, FAIL_MARK, DEBUG_MARK] {
            assert!(!mark.contains(&0x1b));
        }
    }
}
