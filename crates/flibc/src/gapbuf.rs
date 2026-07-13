//! The pure editing state machine `/bin/edit` drives.
//!
//! The mutable-text half of the navigation seam, beside [`crate::keys`] (input)
//! and [`crate::pager`] (read-only scrolling). Three pieces, each host-tested in
//! isolation so the interactive loop -- which QEMU cannot exercise, leaving the Pi
//! as the only live witness -- rests on a correctness proof that runs under
//! `cargo test`:
//!
//! * [`GapBuf`] -- a byte buffer with a movable gap at the cursor, so insert and
//!   delete at the cursor are O(1) and allocation-free.
//! * [`LineIndex`] -- line-start offsets recomputed on change, plus the cursor
//!   motions (left/right/up/down/home/end) that are the off-by-one-prone half of
//!   an editor.
//! * [`Viewport`] -- top/left scroll state with cursor-follow clamping, including
//!   horizontal scroll (one logical line is one screen row; no soft-wrap).
//!
//! Pure by construction: no syscall, no module state, no allocator. The two
//! allocating concerns belong to the caller -- the storage array and the grow are
//! caller-owned, so this module never names `malloc` and the host build hands it
//! plain stack arrays. The grow strategy (double on a full gap) suits flibc's bump
//! heap, whose `free` is a no-op: only the rare doublings leak, and they are reaped
//! on process exit.
//!
//! Column model: each byte renders to exactly one display cell (the renderer
//! substitutes a placeholder for non-printables, including TAB), so a column is a
//! byte offset within its line. Real tab-stop expansion would make the
//! column-to-offset mapping non-trivial and is deliberately out of scope.

// ---- gap buffer ------------------------------------------------------------

/// A text buffer with a gap at the cursor. The gap is the half-open physical range
/// `[gap_start, gap_end)`; the logical text is everything else, in order. The
/// logical cursor sits at `gap_start` (the left segment is `[0, gap_start)`), so a
/// left/right cursor move is a [`GapBuf::move_gap`] and an insert is a single store
/// into the gap. Storage is caller-owned; when the gap empties, the caller hands a
/// larger array to [`GapBuf::grow_into`].
pub struct GapBuf<'a> {
    /// Caller-owned backing store.
    buf: &'a mut [u8],
    /// First byte of the gap -- and the logical cursor.
    gap_start: usize,
    /// One past the last gap byte.
    gap_end: usize,
}

impl<'a> GapBuf<'a> {
    /// An empty buffer whose gap spans the whole of `storage`.
    pub fn init(storage: &'a mut [u8]) -> Self {
        let end = storage.len();
        Self {
            buf: storage,
            gap_start: 0,
            gap_end: end,
        }
    }

    /// Bytes of free gap remaining -- the number of inserts before a grow.
    pub fn gap_len(&self) -> usize {
        self.gap_end - self.gap_start
    }

    /// Logical text length (storage minus the gap).
    pub fn len(&self) -> usize {
        self.buf.len() - self.gap_len()
    }

    /// True when the buffer holds no logical text.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Current cursor position, as a logical offset.
    pub fn cursor(&self) -> usize {
        self.gap_start
    }

    /// The `i`-th logical byte. The caller guarantees `i < len()`; bytes at or past
    /// the cursor live after the gap, so they are read past `gap_end`.
    pub fn byte_at(&self, i: usize) -> u8 {
        if i < self.gap_start {
            self.buf[i]
        } else {
            self.buf[i + self.gap_len()]
        }
    }

    /// Move the cursor to logical offset `to` (`0..=len()`) by shifting the bytes
    /// that cross the gap. Moving left slides `[to, gap_start)` up against
    /// `gap_end`; moving right slides the bytes from `gap_end` on down into
    /// `gap_start`. O(distance).
    pub fn move_gap(&mut self, to: usize) {
        if to < self.gap_start {
            let count = self.gap_start - to;
            self.buf
                .copy_within(to..self.gap_start, self.gap_end - count);
            self.gap_end -= count;
            self.gap_start = to;
        } else if to > self.gap_start {
            let count = to - self.gap_start;
            self.buf
                .copy_within(self.gap_end..self.gap_end + count, self.gap_start);
            self.gap_start += count;
            self.gap_end += count;
        }
    }

    /// Insert one byte at the cursor. Returns false -- and inserts nothing -- when
    /// the gap is full; the caller grows and retries.
    pub fn insert(&mut self, b: u8) -> bool {
        if self.gap_start >= self.gap_end {
            return false;
        }
        self.buf[self.gap_start] = b;
        self.gap_start += 1;
        true
    }

    /// Insert as many of `s` as the gap holds, returning the count inserted.
    pub fn insert_slice(&mut self, s: &[u8]) -> usize {
        let mut i = 0;
        while i < s.len() {
            if !self.insert(s[i]) {
                break;
            }
            i += 1;
        }
        i
    }

    /// Delete the byte before the cursor (Backspace). Returns false at offset 0.
    pub fn delete_back(&mut self) -> bool {
        if self.gap_start == 0 {
            return false;
        }
        self.gap_start -= 1;
        true
    }

    /// Delete the byte at the cursor (Delete). Returns false at end of buffer.
    pub fn delete_fwd(&mut self) -> bool {
        if self.gap_end >= self.buf.len() {
            return false;
        }
        self.gap_end += 1;
        true
    }

    /// Copy the logical text (both segments, in order) into `out`, returning the
    /// byte count. `out` must hold `len()` bytes -- the save path sizes it so. The
    /// gap is skipped, so the result is exactly the file content.
    pub fn linearize(&self, out: &mut [u8]) -> usize {
        let left = self.gap_start;
        let right = self.buf.len() - self.gap_end;
        out[..left].copy_from_slice(&self.buf[..left]);
        out[left..left + right].copy_from_slice(&self.buf[self.gap_end..]);
        left + right
    }

    /// Rebind to a larger caller-owned store, preserving content and cursor: the
    /// left segment keeps its offsets, the right segment moves to the tail, and the
    /// gap widens by the size difference. `bigger` must be at least as long as the
    /// current content. The old store is abandoned (flibc's `free` is a no-op, and
    /// the pages are reaped on exit).
    pub fn grow_into(&mut self, bigger: &'a mut [u8]) {
        let rlen = self.buf.len() - self.gap_end;
        let tail = bigger.len() - rlen;
        bigger[..self.gap_start].copy_from_slice(&self.buf[..self.gap_start]);
        bigger[tail..].copy_from_slice(&self.buf[self.gap_end..]);
        self.buf = bigger;
        self.gap_end = tail;
        // gap_start -- the cursor -- is unchanged.
    }
}

// ---- line index ------------------------------------------------------------

/// A `(row, col)` cursor coordinate: a logical line and a byte column within it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RowCol {
    /// Logical line, 0-based.
    pub row: usize,
    /// Byte column within the line, 0-based.
    pub col: usize,
}

/// Line-start offsets over a [`GapBuf`], plus the cursor motions. The segment model:
/// a buffer with k newlines has k+1 lines, so a trailing `'\n'` yields a final empty
/// line the cursor can navigate onto and type into -- the editor view, distinct from
/// the pager, which swallows a trailing newline for a read-only page. An empty
/// buffer is one empty line. The slot array is caller-owned; recompute via
/// [`LineIndex::rebuild`] after every edit (cheap for the small files this editor
/// targets).
pub struct LineIndex<'a> {
    /// Caller-owned; `lines[..n]` are line-start byte offsets.
    lines: &'a mut [u32],
    /// Number of lines -- at least 1 once rebuilt over a non-empty slot array.
    n: usize,
    /// Logical buffer length at the last rebuild.
    total: usize,
}

impl<'a> LineIndex<'a> {
    /// Build an index over `gb` into `slots`.
    pub fn init(slots: &'a mut [u32], gb: &GapBuf<'_>) -> Self {
        let mut li = Self {
            lines: slots,
            n: 0,
            total: 0,
        };
        li.rebuild(gb);
        li
    }

    /// Number of lines in the index.
    pub fn line_count(&self) -> usize {
        self.n
    }

    /// Logical buffer length as of the last rebuild.
    pub fn total(&self) -> usize {
        self.total
    }

    /// Recompute line starts from the current buffer. Line 0 starts at 0; every byte
    /// after a `'\n'` starts the next line. Capped at the slot count so a
    /// pathological all-newline buffer cannot overrun the caller's array.
    pub fn rebuild(&mut self, gb: &GapBuf<'_>) {
        self.total = gb.len();
        if self.lines.is_empty() {
            self.n = 0;
            return;
        }
        self.lines[0] = 0;
        let mut n = 1;
        let mut i = 0;
        while i < self.total {
            if gb.byte_at(i) == b'\n' {
                if n >= self.lines.len() {
                    break;
                }
                self.lines[n] = (i + 1) as u32;
                n += 1;
            }
            i += 1;
        }
        self.n = n;
    }

    /// Start offset of line `i` (the caller ensures `i < line_count()`).
    pub fn line_start(&self, i: usize) -> usize {
        self.lines[i] as usize
    }

    /// Byte length of line `i`, excluding its terminating `'\n'`. The last line runs
    /// to EOF; an earlier line ends just before the next line's start.
    pub fn line_len(&self, i: usize) -> usize {
        let start = self.lines[i] as usize;
        let stop = if i + 1 < self.n {
            self.lines[i + 1] as usize - 1
        } else {
            self.total
        };
        stop - start
    }

    /// The line containing logical `offset`: the last line whose start is at most
    /// `offset`. An offset sitting on a line's terminating `'\n'` belongs to that
    /// line.
    pub fn row_of(&self, offset: usize) -> usize {
        let mut row = 0;
        let mut i = 0;
        while i < self.n {
            if self.lines[i] as usize <= offset {
                row = i;
            } else {
                break;
            }
            i += 1;
        }
        row
    }

    /// Logical offset of `(row, col)`, clamping the row into range and the column to
    /// the line's length -- so a short line below a long one lands the cursor at its
    /// end rather than past it.
    pub fn offset_of(&self, row: usize, col: usize) -> usize {
        let mut r = row;
        if r >= self.n {
            r = if self.n > 0 { self.n - 1 } else { 0 };
        }
        let start = self.lines[r] as usize;
        let maxc = self.line_len(r);
        let c = if col < maxc { col } else { maxc };
        start + c
    }

    /// Cursor coordinate for a logical offset.
    pub fn locate(&self, offset: usize) -> RowCol {
        let r = self.row_of(offset);
        RowCol {
            row: r,
            col: offset - self.lines[r] as usize,
        }
    }

    /// Cursor up one line, preserving the byte column (clamped to the shorter line).
    /// A no-op on the first line.
    pub fn move_up(&self, offset: usize) -> usize {
        let r = self.row_of(offset);
        if r == 0 {
            return offset;
        }
        let col = offset - self.lines[r] as usize;
        self.offset_of(r - 1, col)
    }

    /// Cursor down one line, preserving the byte column. A no-op on the last line.
    pub fn move_down(&self, offset: usize) -> usize {
        let r = self.row_of(offset);
        if r + 1 >= self.n {
            return offset;
        }
        let col = offset - self.lines[r] as usize;
        self.offset_of(r + 1, col)
    }

    /// Start of the current line.
    pub fn home(&self, offset: usize) -> usize {
        self.lines[self.row_of(offset)] as usize
    }

    /// End of the current line: its `'\n'`, or EOF for the last line.
    pub fn end(&self, offset: usize) -> usize {
        let r = self.row_of(offset);
        self.lines[r] as usize + self.line_len(r)
    }
}

/// Cursor left one byte, clamped at the start of the buffer. Independent of the line
/// index -- a left move never changes the line-membership math beyond the offset.
pub fn move_left(offset: usize) -> usize {
    offset.saturating_sub(1)
}

/// Cursor right one byte, clamped at the end of the buffer.
pub fn move_right(offset: usize, total: usize) -> usize {
    if offset < total {
        offset + 1
    } else {
        total
    }
}

// ---- viewport --------------------------------------------------------------

/// Scroll state for the content area: `top` is the first visible line, `left` the
/// first visible column (horizontal scroll). `rows` and `cols` are the content
/// window the renderer paints. [`Viewport::scroll_to`] nudges top/left the minimum
/// needed to keep the cursor in view -- the only scrolling the editor does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Viewport {
    /// First visible logical line.
    pub top: usize,
    /// First visible byte column.
    pub left: usize,
    /// Height of the content window, in rows.
    pub rows: usize,
    /// Width of the content window, in columns.
    pub cols: usize,
}

impl Viewport {
    /// A window of `rows` by `cols`, scrolled to the buffer origin.
    pub const fn new(rows: usize, cols: usize) -> Self {
        Self {
            top: 0,
            left: 0,
            rows,
            cols,
        }
    }

    /// Bring `(row, col)` into the window with minimal movement: pull the top/left
    /// edge to the cursor when it falls off the near side, push it so the cursor sits
    /// on the far row/col when it falls off the far side.
    pub fn scroll_to(&mut self, row: usize, col: usize) {
        if row < self.top {
            self.top = row;
        } else if row >= self.top + self.rows {
            self.top = row - self.rows + 1;
        }
        if col < self.left {
            self.left = col;
        } else if col >= self.left + self.cols {
            self.left = col - self.cols + 1;
        }
    }

    /// True when `row` is inside the vertical window.
    pub fn visible_row(&self, row: usize) -> bool {
        row >= self.top && row < self.top + self.rows
    }

    /// Screen row for a logical line, 0-based. The caller ensures
    /// [`Viewport::visible_row`].
    pub fn screen_row(&self, row: usize) -> usize {
        row - self.top
    }

    /// Screen column for a byte column, 0-based. The caller ensures the column lies
    /// within `left..left + cols`.
    pub fn screen_col(&self, col: usize) -> usize {
        col - self.left
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Fill a gap buffer over `store` with `text`, returning it ready to drive.
    fn seed<'a>(store: &'a mut [u8], text: &[u8]) -> GapBuf<'a> {
        let mut gb = GapBuf::init(store);
        let _ = gb.insert_slice(text);
        gb
    }

    /// Read the whole logical buffer back into `out`, returning the slice.
    fn dump<'o>(gb: &GapBuf<'_>, out: &'o mut [u8]) -> &'o [u8] {
        let n = gb.linearize(out);
        &out[..n]
    }

    #[test]
    fn insert_builds_content_and_tracks_the_cursor() {
        let mut store = [0u8; 16];
        let mut gb = GapBuf::init(&mut store);
        let _ = gb.insert_slice(b"abc");
        assert_eq!(gb.len(), 3);
        assert_eq!(gb.cursor(), 3);
        assert_eq!(gb.byte_at(0), b'a');
        assert_eq!(gb.byte_at(2), b'c');
        let mut out = [0u8; 16];
        assert_eq!(dump(&gb, &mut out), b"abc");
    }

    #[test]
    fn move_gap_then_insert_splices_mid_buffer() {
        let mut store = [0u8; 16];
        let mut gb = seed(&mut store, b"ac");
        gb.move_gap(1); // cursor between a and c
        assert!(gb.insert(b'b'));
        let mut out = [0u8; 16];
        assert_eq!(dump(&gb, &mut out), b"abc");
        assert_eq!(gb.cursor(), 2); // after the 'b'
                                    // byte_at still reads logical order across the gap.
        assert_eq!(gb.byte_at(2), b'c');
    }

    #[test]
    fn delete_back_and_delete_fwd_at_the_cursor() {
        let mut store = [0u8; 16];
        let mut gb = seed(&mut store, b"abcd");
        gb.move_gap(2); // between b and c
        assert!(gb.delete_back()); // removes b
        let mut out = [0u8; 16];
        assert_eq!(dump(&gb, &mut out), b"acd");
        assert!(gb.delete_fwd()); // removes c
        assert_eq!(dump(&gb, &mut out), b"ad");
    }

    #[test]
    fn delete_clamps_at_the_ends() {
        let mut store = [0u8; 8];
        let mut gb = seed(&mut store, b"x");
        gb.move_gap(0);
        assert!(!gb.delete_back()); // nothing before offset 0
        gb.move_gap(1);
        assert!(!gb.delete_fwd()); // nothing after the end
    }

    #[test]
    fn insert_reports_a_full_gap() {
        let mut store = [0u8; 3];
        let mut gb = GapBuf::init(&mut store);
        assert!(gb.insert(b'a'));
        assert!(gb.insert(b'b'));
        assert!(gb.insert(b'c'));
        assert!(!gb.insert(b'd')); // gap exhausted
        assert_eq!(gb.gap_len(), 0);
    }

    #[test]
    fn grow_into_preserves_content_and_cursor_then_accepts_more() {
        let mut small = [0u8; 4];
        let mut big = [0u8; 16];
        let mut gb = seed(&mut small, b"abcd"); // gap now empty
        gb.move_gap(2); // cursor between b and c
        gb.grow_into(&mut big);
        assert_eq!(gb.len(), 4);
        assert_eq!(gb.cursor(), 2);
        assert!(gb.insert(b'Z')); // room again
        let mut out = [0u8; 16];
        assert_eq!(dump(&gb, &mut out), b"abZcd");
    }

    #[test]
    fn line_index_counts_segments_so_a_trailing_newline_yields_a_final_empty_line() {
        let mut store = [0u8; 16];
        let mut slots = [0u32; 8];
        // empty buffer -> one empty line.
        let gb0 = GapBuf::init(&mut store);
        let li0 = LineIndex::init(&mut slots, &gb0);
        assert_eq!(li0.line_count(), 1);
        assert_eq!(li0.line_len(0), 0);

        let mut store1 = [0u8; 16];
        let gb1 = seed(&mut store1, b"a\nb");
        let li1 = LineIndex::init(&mut slots, &gb1);
        assert_eq!(li1.line_count(), 2);

        let mut store2 = [0u8; 16];
        let gb2 = seed(&mut store2, b"a\nb\n");
        let li2 = LineIndex::init(&mut slots, &gb2);
        assert_eq!(li2.line_count(), 3); // trailing empty line
        assert_eq!(li2.line_len(2), 0);
    }

    #[test]
    fn line_len_and_line_start_over_a_multi_line_buffer() {
        let mut store = [0u8; 32];
        let mut slots = [0u32; 8];
        let gb = seed(&mut store, b"ab\ncde\nf");
        let li = LineIndex::init(&mut slots, &gb);
        assert_eq!(li.line_count(), 3);
        assert_eq!(li.line_start(0), 0);
        assert_eq!(li.line_len(0), 2); // "ab"
        assert_eq!(li.line_start(1), 3);
        assert_eq!(li.line_len(1), 3); // "cde"
        assert_eq!(li.line_start(2), 7);
        assert_eq!(li.line_len(2), 1); // "f"
    }

    #[test]
    fn row_of_and_locate_map_offsets_to_coordinates() {
        let mut store = [0u8; 32];
        let mut slots = [0u32; 8];
        let gb = seed(&mut store, b"ab\ncde");
        let li = LineIndex::init(&mut slots, &gb);
        assert_eq!(li.row_of(0), 0);
        assert_eq!(li.row_of(2), 0); // the '\n' belongs to line 0
        assert_eq!(li.row_of(3), 1);
        let rc = li.locate(5); // 'e' on line 1
        assert_eq!(rc.row, 1);
        assert_eq!(rc.col, 2);
    }

    #[test]
    fn move_up_and_move_down_preserve_the_column_clamped_to_the_shorter_line() {
        let mut store = [0u8; 32];
        let mut slots = [0u32; 8];
        let gb = seed(&mut store, b"long\na\nlonger");
        let li = LineIndex::init(&mut slots, &gb);
        // cursor at col 3 of line 0 ("long")
        let start = li.offset_of(0, 3);
        // down lands on line 1 ("a", len 1) clamped to col 1
        let d = li.move_down(start);
        let drc = li.locate(d);
        assert_eq!(drc.row, 1);
        assert_eq!(drc.col, 1); // clamped
                                // down again to line 2 keeps the clamped col 1: column memory is out of scope
        let d2 = li.move_down(d);
        let d2rc = li.locate(d2);
        assert_eq!(d2rc.row, 2);
        assert_eq!(d2rc.col, 1);
    }

    #[test]
    fn move_up_on_the_first_line_and_move_down_on_the_last_are_no_ops() {
        let mut store = [0u8; 32];
        let mut slots = [0u32; 8];
        let gb = seed(&mut store, b"a\nb");
        let li = LineIndex::init(&mut slots, &gb);
        assert_eq!(li.move_up(0), 0);
        let last = li.offset_of(1, 0);
        assert_eq!(li.move_down(last), last);
    }

    #[test]
    fn home_and_end_snap_to_the_line_bounds() {
        let mut store = [0u8; 32];
        let mut slots = [0u32; 8];
        let gb = seed(&mut store, b"abc\ndef");
        let li = LineIndex::init(&mut slots, &gb);
        let mid = li.offset_of(1, 1); // on "def"
        assert_eq!(li.home(mid), 4); // start of "def"
        assert_eq!(li.end(mid), 7); // EOF after "def"
    }

    #[test]
    fn move_left_and_move_right_clamp_at_the_buffer_ends() {
        assert_eq!(move_left(0), 0);
        assert_eq!(move_left(5), 4);
        assert_eq!(move_right(9, 10), 10);
        assert_eq!(move_right(10, 10), 10); // already at end
    }

    #[test]
    fn viewport_scrolls_vertically_to_follow_the_cursor() {
        let mut vp = Viewport::new(3, 80);
        vp.scroll_to(5, 0); // cursor past the window -> top so row 5 is the last row
        assert_eq!(vp.top, 3); // 5 - 3 + 1
        assert!(vp.visible_row(5));
        assert_eq!(vp.screen_row(5), 2);
        vp.scroll_to(1, 0); // cursor above the window -> top pulls up to it
        assert_eq!(vp.top, 1);
    }

    #[test]
    fn viewport_scrolls_horizontally_for_long_lines() {
        let mut vp = Viewport::new(24, 10);
        vp.scroll_to(0, 15); // col past the window
        assert_eq!(vp.left, 6); // 15 - 10 + 1
        assert_eq!(vp.screen_col(15), 9);
        vp.scroll_to(0, 2); // col before the window
        assert_eq!(vp.left, 2);
    }

    // ---- boundary cases beyond the inherited set -----------------------------

    #[test]
    fn move_gap_across_the_whole_buffer_keeps_the_logical_text() {
        let mut store = [0u8; 8];
        let mut gb = seed(&mut store, b"abcde");
        let mut out = [0u8; 8];
        for to in 0..=5 {
            gb.move_gap(to); // rightward slide, one step at a time
            assert_eq!(gb.cursor(), to);
            assert_eq!(dump(&gb, &mut out), b"abcde");
        }
        for to in (0..=5).rev() {
            gb.move_gap(to); // and back down again, exercising the leftward slide
            assert_eq!(gb.cursor(), to);
            assert_eq!(dump(&gb, &mut out), b"abcde");
        }
    }

    #[test]
    fn insert_slice_saturates_at_the_gap_and_reports_the_count() {
        let mut store = [0u8; 4];
        let mut gb = GapBuf::init(&mut store);
        assert_eq!(gb.insert_slice(b"abcdef"), 4); // only the gap's worth lands
        assert_eq!(gb.gap_len(), 0);
        let mut out = [0u8; 4];
        assert_eq!(dump(&gb, &mut out), b"abcd");
    }

    #[test]
    fn grow_into_handles_a_cursor_parked_at_either_end() {
        let mut left_store = [0u8; 4];
        let mut left_big = [0u8; 8];
        let mut gb = seed(&mut left_store, b"abcd");
        gb.move_gap(0); // the whole content sits right of the gap
        gb.grow_into(&mut left_big);
        assert_eq!(gb.cursor(), 0);
        assert_eq!(gb.gap_len(), 4);
        let mut out = [0u8; 8];
        assert_eq!(dump(&gb, &mut out), b"abcd");

        let mut right_store = [0u8; 4];
        let mut right_big = [0u8; 8];
        let mut gb2 = seed(&mut right_store, b"abcd"); // cursor already at the end
        gb2.grow_into(&mut right_big);
        assert_eq!(gb2.cursor(), 4);
        assert_eq!(gb2.gap_len(), 4);
        assert_eq!(dump(&gb2, &mut out), b"abcd");
    }

    #[test]
    fn rebuild_caps_the_line_starts_at_the_slot_count() {
        let mut store = [0u8; 16];
        let mut slots = [0u32; 3];
        let gb = seed(&mut store, b"\n\n\n\n\n");
        let li = LineIndex::init(&mut slots, &gb);
        assert_eq!(li.line_count(), 3); // capped, not overrun
        assert_eq!(li.total(), 5);
    }

    #[test]
    fn offset_of_clamps_a_row_past_the_last_line_and_a_col_past_the_line_end() {
        let mut store = [0u8; 16];
        let mut slots = [0u32; 8];
        let gb = seed(&mut store, b"ab\ncd");
        let li = LineIndex::init(&mut slots, &gb);
        assert_eq!(li.offset_of(9, 0), 3); // clamped onto the last line
        assert_eq!(li.offset_of(0, 99), 2); // clamped onto the line's end
    }
}
