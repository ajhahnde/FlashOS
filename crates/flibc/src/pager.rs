//! The pager core -- a scroll/line-index state machine over a text buffer.
//!
//! The third navigation seam, sitting beside [`crate::keys`] (input) and the console
//! sinks (output): the pure paging logic a full-screen pager (`/bin/less`) drives. It
//! indexes the line starts of a slurped byte buffer once, then answers the two
//! questions a render loop asks every frame -- "which lines are on screen?" and
//! "where does the cursor scroll to?" -- with all motion clamped so `top` never runs
//! past the last page or before the first line.
//!
//! Pure by construction: no allocator (the line index is a caller-owned `[u32]`), no
//! module state, no syscall. The driver half -- opening the file, the alternate-screen
//! takeover, and the key loop -- lives in the tool; this file holds only the logic
//! worth host-testing in isolation.

/// A pager view over an immutable text buffer. [`Pager::init`] indexes line starts
/// into the caller's `slots`; the scroll ops move `top` (the first visible line) with
/// clamping; [`Pager::line`] returns the i-th logical line. `rows` is the visible
/// content-row count the consumer paints (its page height).
pub struct Pager<'t, 'l> {
    /// The slurped text the view reads from; never mutated.
    pub text: &'t [u8],
    /// Caller-owned index; `lines[..n]` are line-start byte offsets.
    pub lines: &'l mut [u32],
    /// Number of indexed lines.
    pub n: usize,
    /// Index of the first visible line.
    pub top: usize,
    /// Visible content rows (page height).
    pub rows: usize,
}

impl<'t, 'l> Pager<'t, 'l> {
    /// Index the line starts of `text` into `slots` and return a pager homed at the
    /// top. Line 0 begins at offset 0; every byte after a `\n` begins the next line,
    /// except a single trailing `\n` (the common case -- a file that ends in a newline
    /// is N lines, not N + 1). Internal blank lines are kept. Indexing stops at
    /// `slots.len()` lines: a pathological all-newline buffer is capped rather than
    /// overrunning the caller's array (the driver caps the slurp by bytes, so this
    /// bound is not normally the binding one).
    pub fn init(text: &'t [u8], slots: &'l mut [u32], rows: usize) -> Self {
        let mut n: usize = 0;
        if !text.is_empty() && !slots.is_empty() {
            slots[0] = 0;
            n = 1;
            let mut i: usize = 0;
            while i < text.len() {
                if text[i] == b'\n' && i + 1 < text.len() {
                    if n >= slots.len() {
                        break;
                    }
                    slots[n] = (i + 1) as u32;
                    n += 1;
                }
                i += 1;
            }
        }
        Self {
            text,
            lines: slots,
            n,
            top: 0,
            rows,
        }
    }

    /// The i-th logical line: from its start offset up to (not including) its own
    /// `\n`, with a preceding `\r` (CRLF) stripped. Computing the end by scanning to
    /// the next `\n` -- rather than to the next index slot -- keeps a capped index
    /// honest: the last indexed line ends at its newline, it does not swallow the
    /// un-indexed remainder. Out-of-range `i` yields an empty slice so a render loop
    /// can ask past the last line without a bounds check.
    pub fn line(&self, i: usize) -> &'t [u8] {
        if i >= self.n {
            return b"";
        }
        let start = self.lines[i] as usize;
        let mut end: usize = start;
        while end < self.text.len() && self.text[end] != b'\n' {
            end += 1;
        }
        let mut s = &self.text[start..end];
        if !s.is_empty() && s[s.len() - 1] == b'\r' {
            s = &s[..s.len() - 1];
        }
        s
    }

    /// The largest `top` that still fills the page -- so the final screen sits at the
    /// bottom with no blank overscroll. Zero when the text fits one page.
    pub fn max_top(&self) -> usize {
        self.n.saturating_sub(self.rows)
    }

    /// Scroll down `k` lines, clamped to [`Pager::max_top`].
    pub fn down(&mut self, k: usize) {
        let mt = self.max_top();
        self.top = if self.top + k > mt { mt } else { self.top + k };
    }

    /// Scroll up `k` lines, clamped to the first line.
    pub fn up(&mut self, k: usize) {
        self.top = self.top.saturating_sub(k);
    }

    /// Forward one page (a full window of `rows`), clamped.
    pub fn page_down(&mut self) {
        self.down(self.rows);
    }

    /// Back one page, clamped.
    pub fn page_up(&mut self) {
        self.up(self.rows);
    }

    /// Jump to the first line.
    pub fn to_top(&mut self) {
        self.top = 0;
    }

    /// Jump so the last line sits on the final row.
    pub fn to_bottom(&mut self) {
        self.top = self.max_top();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn init_indexes_line_starts_and_swallows_only_the_final_newline() {
        let mut slots = [0u32; 8];
        // "a\n\nb\n" -> lines "a", "" (internal blank kept), "b"; trailing \n dropped.
        let p = Pager::init(b"a\n\nb\n", &mut slots, 10);
        assert_eq!(p.n, 3);
        assert_eq!(p.line(0), b"a");
        assert_eq!(p.line(1), b"");
        assert_eq!(p.line(2), b"b");
    }

    #[test]
    fn no_trailing_newline_still_indexes_the_last_line() {
        let mut slots = [0u32; 8];
        let p = Pager::init(b"ab\ncd", &mut slots, 10);
        assert_eq!(p.n, 2);
        assert_eq!(p.line(0), b"ab");
        assert_eq!(p.line(1), b"cd");
    }

    #[test]
    fn line_strips_a_crlf_terminator() {
        let mut slots = [0u32; 8];
        let p = Pager::init(b"x\r\ny", &mut slots, 10);
        assert_eq!(p.n, 2);
        assert_eq!(p.line(0), b"x");
        assert_eq!(p.line(1), b"y");
    }

    #[test]
    fn empty_text_has_no_lines_and_out_of_range_yields_empty() {
        let mut slots = [0u32; 8];
        let p = Pager::init(b"", &mut slots, 10);
        assert_eq!(p.n, 0);
        assert_eq!(p.line(0), b"");
    }

    #[test]
    fn init_caps_at_the_slot_count() {
        let mut slots = [0u32; 3];
        // Five lines of input, only three slots.
        let p = Pager::init(b"a\nb\nc\nd\ne", &mut slots, 10);
        assert_eq!(p.n, 3);
        assert_eq!(p.line(2), b"c");
    }

    #[test]
    fn max_top_is_zero_when_the_text_fits_one_page() {
        let mut slots = [0u32; 8];
        let mut p = Pager::init(b"a\nb\nc", &mut slots, 10);
        assert_eq!(p.max_top(), 0);
        p.to_bottom();
        assert_eq!(p.top, 0);
    }

    #[test]
    fn max_top_leaves_the_last_line_on_the_final_row() {
        let mut slots = [0u32; 16];
        // Ten lines, page of 3 -> max_top 7 (lines 7, 8, 9 on screen).
        let p = Pager::init(b"0\n1\n2\n3\n4\n5\n6\n7\n8\n9", &mut slots, 3);
        assert_eq!(p.n, 10);
        assert_eq!(p.max_top(), 7);
    }

    #[test]
    fn down_and_up_clamp_at_the_ends() {
        let mut slots = [0u32; 16];
        // max_top 7.
        let mut p = Pager::init(b"0\n1\n2\n3\n4\n5\n6\n7\n8\n9", &mut slots, 3);
        p.up(1);
        assert_eq!(p.top, 0); // already at top
        p.down(2);
        assert_eq!(p.top, 2);
        p.down(100);
        assert_eq!(p.top, 7); // clamped to max_top
        p.up(3);
        assert_eq!(p.top, 4);
    }

    #[test]
    fn page_motion_moves_by_a_full_window_and_clamps() {
        let mut slots = [0u32; 16];
        // max_top 7.
        let mut p = Pager::init(b"0\n1\n2\n3\n4\n5\n6\n7\n8\n9", &mut slots, 3);
        p.page_down();
        assert_eq!(p.top, 3);
        p.page_down();
        assert_eq!(p.top, 6);
        p.page_down();
        assert_eq!(p.top, 7); // clamped
        p.page_up();
        assert_eq!(p.top, 4);
    }

    #[test]
    fn to_top_and_to_bottom_jump_to_the_ends() {
        let mut slots = [0u32; 16];
        // max_top 7.
        let mut p = Pager::init(b"0\n1\n2\n3\n4\n5\n6\n7\n8\n9", &mut slots, 3);
        p.to_bottom();
        assert_eq!(p.top, 7);
        p.to_top();
        assert_eq!(p.top, 0);
    }
}
