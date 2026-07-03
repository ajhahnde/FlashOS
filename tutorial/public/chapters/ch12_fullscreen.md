# Chapter 12: Full-screen Apps — less & edit

Every program this tour has shown so far writes a stream of lines and
exits. `/bin/less` and `/bin/edit` are FlashOS's first departure from
that shape: they take over the entire 24×80 terminal, redraw only what
changed frame to frame, and hand the console back cleanly on exit. Both
build on Flash's `std` — `core.tui`, `keys`, `io` — the same standard
library surface a Flash program targeting any host would use; FlashOS's
userland is simply one more consumer of it, wired to a `Sink`/`Input`
pair that happen to be raw syscalls instead of a terminal library.

## less: the TEA loop

`less` is the first consumer of `core.tui.run`, a small implementation
of The Elm Architecture (TEA): a program supplies an initial model, a
pure `update(model, event) -> model`, and a pure `view(model, *Buffer)`
that paints a frame; `run` owns everything else — entering the
alternate screen, decoding raw bytes into key events, double-buffering
each frame, diffing it against the last one, and emitting only the
minimal ANSI to update the terminal.

```flash
const cfg core.tui.Config(Model) = .{
    .init = .{ .pg = pg, .name = baseName(path), .truncated = truncated, .quit = false },
    .update = update,
    .view = view,
    .tick_ms = 0, // read(0) blocks; a tick never arrives, so the interval is moot
    .w = #intCast(COLS),
    .h = #intCast(ROWS),
    .sink = flibc.consoleSink,
    .input = flibc.consoleInput,
    .front = front[0..],
    .back = back[0..],
}
_ = core.tui.run(Model, cfg)
```

*(excerpt from `tools/less.flash` — not standalone-compilable)*

The two injected seams — `sink` (write) and `input` (blocking
single-byte read) — are the only place `less` touches a syscall
directly; everything else about "how does a keypress become a redrawn
screen" lives inside `run`, reused verbatim by any future TEA-shaped
tool. The actual scrolling logic is *not* part of `run` at all — `std`'s
`tui` module is render-plus-loop-plus-input only, with no paging
concept of its own — so `less` supplies its own pure, host-tested
`flibc.Pager` as the model's domain state, and `update` just folds each
key event into the Pager's clamp-safe scroll operations.

## edit: a layer down, for the keys a pager doesn't need

`/bin/edit` needs `Home`, `End`, `PageUp`/`PageDown`, `Delete`, and the
`ctrl-O`/`ctrl-W`/`ctrl-X` chords — eight keys `core.tui.run`'s fixed
decoder does not know, because a pager never binds them. Rather than
extend the shared decoder for one caller, `edit` drops down one layer:
it paints a `core.tui.Buffer` and emits the same minimal `core.tui.diff`
`run` would, but drives its own `flibc.readKey()` loop with the full
extended key set, and parks the cursor itself after each frame — a
concern `run` does not expose, since a pager has no cursor to park.

```flash
_ = flibc.sys.set_console_mode(0)
flibc.altEnter()
render(&ed, &screen, &scratch)
loop(&ed, &screen, &scratch)
flibc.altLeave()
flibc.exit()
```

*(excerpt from `tools/edit.flash` — not standalone-compilable)*

`altEnter`/`altLeave` are the flibc-level wrapper for entering and
leaving the alternate screen buffer — the same VT100 mechanism a
terminal multiplexer uses to give a full-screen program its own canvas
without scrolling the shell's history away. Every exit path (`ctrl-X`,
`ctrl-C`, EOF) runs through `altLeave()` before `flibc.exit()`, so the
shell view is always restored, never left in the alternate buffer.

## The gap buffer: three pure cores, one driver

`edit`'s editing logic is deliberately factored out of the interactive
driver into three pure, host-tested cores in flibc: `gapbuf.GapBuf`
(storage), `gapbuf.LineIndex` (lines and cursor motions), and
`gapbuf.Viewport` (scroll). This split exists because the interactive
loop itself cannot run under QEMU — there is no PL011 RX path to feed
it keystrokes — so the *cores'* correctness has to be provable on the
host, leaving only the render/input wiring to be validated on real
hardware.

A gap buffer keeps a movable empty region — the "gap" — at the cursor
position; inserting or deleting at the cursor is then a cheap operation
at one end of the gap instead of shifting the whole buffer tail, and
only moving the cursor itself costs proportional-to-distance work:

```flash
pub const GapBuf = struct {
    buf []mut u8,
    gap_start usize, // first byte of the gap (== logical cursor)
    gap_end usize,   // one past the last gap byte

    pub fn insert(self *mut GapBuf, b u8) bool {
        if self.gap_start >= self.gap_end {
            return false // gap full — caller grows and retries
        }
        self.buf[self.gap_start] = b
        self.gap_start += 1
        return true
    }

    pub fn deleteBack(self *mut GapBuf) bool {
        if self.gap_start == 0 {
            return false
        }
        self.gap_start -= 1
        return true
    }

    pub fn moveGap(self *mut GapBuf, to usize) void {
        // shifts the bytes crossing the gap so gap_start lands at `to`
        // …
    }
}
```

*(excerpt from `user_space/lib/flibc/gapbuf.flash` — not
standalone-compilable)*

The cursor invariant that ties this to the rest of the editor is simple
and load-bearing: `gap_start` *is* the logical cursor offset, always.
Navigation moves the gap; an insert or delete acts at the gap and the
cursor falls out of it for free, with no separate bookkeeping to keep
in sync.

`edit` is also the first real consumer of the userland heap this tour
has met: the gap buffer's storage is `malloc`'d and doubled with
`growInto` on demand. flibc's `free` is a no-op — a grow just abandons
the old block, reclaimed only when the process exits — which is fine
for a single short-lived editor session and consistent with the
fixed-buffer, no-allocator style every other coreutil in this tour has
used instead.

## Saving: unlink, create, write — never in-place

The FAT32 backend's `write` (chapter 11) can only *grow* a file's
`file_size` — there is no truncate. Overwriting a file that got shorter
in the editor would leave a stale tail at the old, larger size. `edit`'s
save path sidesteps this entirely by not overwriting at all: it
unlinks the old file, creates a fresh one, and writes the buffer's
current `linearize()`d contents — always the correct size, at the cost
of a small crash window between the unlink and the write completing.
On a single-user hobby OS that trade is the right one; an atomic
temp-file-plus-rename save is future work.

## Handing the console back

Neither `less` nor `edit` restores kernel console mode 1 (echoed,
cooked) on exit — both leave it at mode 0, matching the shell's own
baseline, since fsh's `readline` does its own echo and a mode-1 restore
here would double-echo the next prompt. Chapter 10 already covered the
other half of this contract: after every dispatched command, fsh
unconditionally calls `sys_setConsoleMode(0)` again anyway, as a
backstop against any full-screen child — this chapter's tools or a
future one — leaving the console in a state the next prompt would
choke on.

## Lab: a toy gap buffer

This Lab reimplements the storage-only heart of `gapbuf.GapBuf` —
`insert` at the cursor and `deleteBack` — over a small fixed array, then
prints the buffer's linearized text after a few edits. It leaves out
`moveGap` (arbitrary cursor repositioning) to keep the standalone
version small; insert and delete-at-the-gap are the two operations that
make a gap buffer worth having over a plain shifting array in the first
place.

```flash
// gapbuf_toy.flash - insert/delete at a movable gap, then print the result.
use flibc

link "flibc_start"

const CAP usize = 32

const Toy = struct {
    buf [CAP]u8,
    gap_start usize,
    gap_end usize,
}

fn init() Toy {
    return .{ .buf = undefined, .gap_start = 0, .gap_end = CAP }
}

fn insert(t *mut Toy, b u8) bool {
    if t.gap_start >= t.gap_end {
        return false
    }
    t.buf[t.gap_start] = b
    t.gap_start += 1
    return true
}

fn deleteBack(t *mut Toy) bool {
    if t.gap_start == 0 {
        return false
    }
    t.gap_start -= 1
    return true
}

fn linearize(t Toy, out []mut u8) usize {
    var w usize = 0
    var k usize = 0
    while k < t.gap_start {
        out[w] = t.buf[k]
        w += 1
        k += 1
    }
    k = t.gap_end
    while k < CAP {
        out[w] = t.buf[k]
        w += 1
        k += 1
    }
    return w
}

export fn main(_ usize, _ argv) noreturn {
    var t = init()
    for c in "Flahs" {
        _ = insert(&t, c)
    }
    // fix the typo: back up over "s" and "h", drop them, retype "sh"
    _ = deleteBack(&t)
    _ = deleteBack(&t)
    _ = insert(&t, 's')
    _ = insert(&t, 'h')

    var out [CAP]u8 = undefined
    n := linearize(t, &out)
    flibc.printf("%s\n", .{out[0..n]})
    flibc.exit()
}
```

> [!NOTE]
> `for c in "Flahs"` walks the string byte by byte — each `c` is a `u8`
> — matching the same `insert(self *mut GapBuf, b u8)` shape the real
> `GapBuf` exposes.

Transpile it with the button below; it prints `Flash`.

## What's next

This tour has now climbed the full stack once, from power-on assembly
to a full-screen editor writing bytes back to a real filesystem.
Chapter 13 turns to a different question: how does a project this deep
prove, on every commit, that all of it still works?
