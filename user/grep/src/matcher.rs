//! The match core -- the pure substring matcher `/bin/grep` drives.
//!
//! The one piece of grep worth host-testing in isolation, kept apart from the driver
//! half (argv parsing, open/read, line assembly). Pure by construction -- no
//! allocator, no module state, no syscall, no flibc dependency -- so it runs on the
//! host exactly as it does on the device.
//!
//! The match is a plain windowed substring scan, optionally case-folded over ASCII:
//! grep needs no regex for its first cut (the product vision asks only for
//! literal-pattern line search). An empty pattern matches every line, the GNU grep
//! convention a `grep '' FILE` relies on.

/// True when `line` contains `pat` as a contiguous substring. With `ignore_case`, A-Z
/// fold to a-z on both sides before comparing (ASCII only; bytes >= 0x80 are matched
/// verbatim). An empty `pat` matches every line; a `pat` longer than `line` never
/// matches. O(line.len * pat.len) -- fine for the short lines a serial-console grep
/// sees.
pub fn line_contains(line: &[u8], pat: &[u8], ignore_case: bool) -> bool {
    if pat.is_empty() {
        return true;
    }
    if pat.len() > line.len() {
        return false;
    }
    let mut i: usize = 0;
    // Last start offset that still leaves room for the whole pattern.
    while i + pat.len() <= line.len() {
        if window_eq(&line[i..i + pat.len()], pat, ignore_case) {
            return true;
        }
        i += 1;
    }
    false
}

/// Byte-equality over two equal-length slices, folding case when asked. The caller
/// guarantees `a.len() == pat.len()`, so the scan walks `pat.len()` bytes.
fn window_eq(a: &[u8], pat: &[u8], ignore_case: bool) -> bool {
    let mut j: usize = 0;
    while j < pat.len() {
        let mut x = a[j];
        let mut y = pat[j];
        if ignore_case {
            x = lower(x);
            y = lower(y);
        }
        if x != y {
            return false;
        }
        j += 1;
    }
    true
}

/// ASCII lowercase fold: A-Z (0x41-0x5A) map to a-z by +0x20; every other byte is
/// returned unchanged. The guard keeps the add in range (max 'Z' + 32 == 'z'), so no
/// overflow even where the release build compiles its traps out.
fn lower(c: u8) -> u8 {
    if c.is_ascii_uppercase() {
        c + 32
    } else {
        c
    }
}

/// First offset >= `from` at which `needle` occurs in `hay`, or `None` if there is
/// none. The offset-returning sibling of [`line_contains`], for the editor's
/// search-from-cursor (grep itself stays on the bool form). Case-sensitive -- this
/// search does not fold case. An empty `needle` returns `None` so a blank search is an
/// inert no-op rather than a match that never advances the cursor. Same windowed scan
/// as [`line_contains`]; O((hay.len - from) * needle.len).
pub fn find(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if needle.is_empty() || from >= hay.len() {
        return None;
    }
    let mut i: usize = from;
    while i + needle.len() <= hay.len() {
        if window_eq(&hay[i..i + needle.len()], needle, false) {
            return Some(i);
        }
        i += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn substring_hit_anywhere_in_the_line() {
        assert!(line_contains(b"hello world", b"world", false));
        assert!(line_contains(b"hello world", b"hello", false));
        assert!(line_contains(b"hello world", b"lo wo", false));
    }

    #[test]
    fn no_match_returns_false() {
        assert!(!line_contains(b"hello world", b"xyz", false));
        assert!(!line_contains(b"abc", b"abcd", false)); // pat longer than line
    }

    #[test]
    fn empty_pattern_matches_every_line_even_empty() {
        assert!(line_contains(b"anything", b"", false));
        assert!(line_contains(b"", b"", false));
    }

    #[test]
    fn empty_line_matches_only_the_empty_pattern() {
        assert!(!line_contains(b"", b"a", false));
    }

    #[test]
    fn case_sensitive_by_default() {
        assert!(!line_contains(b"Hello", b"hello", false));
        assert!(line_contains(b"Hello", b"Hello", false));
    }

    #[test]
    fn ignore_case_folds_both_sides_over_ascii() {
        assert!(line_contains(b"Hello World", b"hello", true));
        assert!(line_contains(b"hello world", b"WORLD", true));
        assert!(line_contains(b"MiXeD", b"mixed", true));
    }

    #[test]
    fn ignore_case_leaves_non_letters_and_high_bytes_alone() {
        assert!(line_contains(b"a1b2c3", b"1B2", true));
        // 0x80 has no case; it must match itself, not fold.
        let hi = [b'x', 0x80, b'y'];
        assert!(line_contains(&hi, &hi, true));
    }

    #[test]
    fn match_at_the_very_start_and_very_end() {
        assert!(line_contains(b"abcdef", b"ab", false));
        assert!(line_contains(b"abcdef", b"ef", false));
        assert!(line_contains(b"abcdef", b"abcdef", false));
    }

    #[test]
    fn find_returns_the_first_offset_at_or_after_from() {
        assert_eq!(find(b"abcabc", b"abc", 0), Some(0));
        assert_eq!(find(b"abcabc", b"abc", 1), Some(3)); // skip the first hit
        assert_eq!(find(b"xxneedle", b"needle", 0), Some(2));
    }

    #[test]
    fn find_reports_no_match() {
        assert_eq!(find(b"abc", b"xyz", 0), None);
        assert_eq!(find(b"abc", b"abcd", 0), None); // needle longer than hay
        assert_eq!(find(b"abcabc", b"abc", 4), None); // no hit past offset 4
    }

    #[test]
    fn find_with_from_past_the_end_or_an_empty_needle_yields_none() {
        assert_eq!(find(b"abc", b"a", 3), None);
        assert_eq!(find(b"abc", b"a", 99), None);
        assert_eq!(find(b"abc", b"", 0), None); // blank search is inert
    }
}
