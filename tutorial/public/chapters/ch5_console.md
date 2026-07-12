# Chapter 5: The Console: UART & console_ui

Chapter 4 covered where physical memory goes and how the kernel hands
pages to user tasks. This chapter turns to the console — the thing
every earlier chapter's boot log has been printing through the whole
time. The console has two largely independent concerns: getting bytes
*in* from the keyboard, and rendering bytes *out* consistently across
every program that writes a line of status. FlashOS keeps them as
separate, freestanding pieces — an RX path with no notion of what a
`[ OK ]` tag looks like, and a rendering module with no notion of UART
registers or interrupts — so each can be read, tested, and changed on
its own.

## Getting bytes in: the UART RX ring

The board IRQ handler (`src/board/rpi4b/irq.flash` on Raspberry Pi,
`src/board/virt/irq.flash` under QEMU's `-M virt`) drains the UART's RX
FIFO on every IRQ slot and pushes each byte it finds into a 256-byte
ring buffer that lives in `src/console.flash`:

```flash
pub const RX_RING_SIZE u64 = 256

var rx_ring [RX_RING_SIZE]u8 = [_]u8{0} ** RX_RING_SIZE
var rx_head u64 = 0
var rx_tail u64 = 0
var rx_wq WaitQueue = .{}
```

*(excerpt — not standalone-compilable)*

The ring is single-producer / single-consumer by construction on a
single core: only the IRQ path ever calls `console_push`, and only the
syscall path ever calls `console_read`. `console_push` is the whole
write side:

```flash
pub fn console_push(byte u8) void {
    if (is_full()) { return }
    rx_ring[rx_head % RX_RING_SIZE] = byte
    rx_head +%= 1
    rx_wq.wake_one()
}
```

*(excerpt — not standalone-compilable)*

Three things are worth noticing here. First, a full ring silently
drops the incoming byte rather than blocking the IRQ handler or growing
the buffer — correct for the current human-typing-rate use case, and a
future line-buffered terminal mode is not expected to change it.
Second, `wake_one()` fires against a `src/wait_queue.flash`
`WaitQueue`: the reader that is blocked waiting for console input is
parked on this queue, and pushing a byte is what wakes it. Third —
and easy to miss — `console_push` does *not* write the byte back out
to the UART's TX side. Echo (showing the user what they just typed) is
entirely a userspace concern; the kernel only ever moves bytes one
direction, RX FIFO to ring.

On the read side, console input is not a special case of `sys_read` —
it *is* `sys_read`. A single unified syscall dispatches on the target
file descriptor's kind, so a `read(fd, ...)` against a console fd and
a `read(fd, ...)` against a pipe fd end up in different backing
functions through the same syscall number (DOCUMENTATION.md § "Console
subsystem"). There is no separate console-specific read syscall in the
current ABI.

## Getting bytes out consistently: `console_ui`

Reading bytes in is one problem; writing them out so that every part
of the system *looks* the same is another. `lib/console_ui/` is a
single module compiled into the kernel's own boot log and into every
userspace tool that prints a status line — `fsh`, `login`, `dmesg`, and
others. Because it is one module rather than one convention repeated
by hand in each consumer, editing it restyles the whole system on the
next build: there is no second copy of a bracket tag or an ANSI escape
sequence anywhere else in the tree.

The module is split across three files by concern, but a consumer
always reaches it through a single import:

- `palette.flash` — the `color` on/off switch and the raw ANSI codes.
- `tags.flash` — the `Level` severity enum and each level's `Tag`.
- `console_ui.flash` — the `Sink` type, the line renderers, the
  `Logger`, and the homescreen banner; it re-exports the two files
  above so callers only ever write `console_ui.something`.

The seam that lets the same renderer code serve both the kernel and
userland is a single function-pointer type:

```flash
/// A byte sink. Each consumer binds it to its own console writer:
///   kernel -> a byte loop over main_output_char(MU, b)
///   user   -> write(1, bytes.ptr, bytes.len)
pub const Sink = *fn([]u8) void
```

The kernel binds a `Sink` to a loop that calls `main_output_char` one
byte at a time over the Mini-UART or PL011 device; a userspace tool
binds the very same `Sink` type to a `write(2)` syscall. Every renderer
in the module — `line`, `tagged`, `stage`, `homescreen` — takes a
`Sink` as its first argument and calls through it. None of them know
or care which side of the kernel/user boundary they are running on;
that knowledge lives entirely in the one function pointer each side
supplies.

## The tag taxonomy and its six-column invariant

A status line is a bracketed word — `[ OK ]`, `[FAIL]`, `[WARN]` —
followed by a message. `tags.flash` defines the severities and the
exact bytes each one renders as:

```flash
pub const Level = enum {
    ok, // green   — a step completed
    info, // cyan    — neutral notice
    load, // yellow  — a step in progress (resolves to ok / fail)
    warn, // yellow  — degraded but continuing
    fail, // red     — a step failed
    skip, // grey    — a step was not applicable
}
```

*(excerpt — not standalone-compilable)*

Each `Tag` is built by a small helper that asserts, at compile time,
that the bracket-plus-word-plus-bracket total is exactly six columns
wide:

```flash
fn tag(comptime pre []u8, comptime word []u8, comptime post []u8, ansi []u8) Tag {
    if pre.len + word.len + post.len != 6 { #compileError("console_ui tag must be exactly 6 columns wide") }
    return .{ .pre = pre, .word = word, .post = post, .ansi = ansi }
}
```

*(excerpt — not standalone-compilable)*

This is not decoration. A `Stage` (see `console_ui.flash`) prints
`[LOAD] <msg>` with no trailing newline, then later carriage-returns
back to column 0 and overwrites it with `[ OK ]` or `[FAIL]` once the
step resolves. That overwrite is only byte-for-byte exact — no stray
trailing character from the old tag peeking out past the new one —
because every tag in the taxonomy occupies the identical six columns.
A mismatched tag would not be a runtime glitch a reader might overlook
in a terminal; the `#compileError` in the `tag()` helper turns it into
a build failure before the mistake ever ships. It is a concrete,
small-scale example of Flash's comptime checks catching a "this must
always hold" invariant at compile time rather than trusting every
future caller to get it right by hand.

`console_ui.flash` separately re-exports `marker_ready`, the literal
tail of the boot homescreen line (`" - type 'help' for commands"`).
That string is a frozen contract: `scripts/run_qemu_test.sh` greps for
it as part of deciding whether a boot succeeded. The chapter on the
in-kernel test harness covers what the watchdog actually checks; the
point worth making here is narrower — the contract string is defined
in exactly the same module that renders it, so there is no risk of the
grep pattern and the rendered bytes drifting apart across an edit.

## Why color and a byte-exact grep are not in tension

`palette.flash` holds a single boolean, `color`, and every ANSI
constant in the file is written as a conditional on it:

```flash
pub const red = if (color) esc ++ "31m" else ""
pub const green = if (color) esc ++ "32m" else ""
```

*(excerpt — not standalone-compilable)*

With `color` off, every one of these constants collapses to the empty
string, so a build made that way emits a plain `[FAIL]` — six ASCII
bytes, no escape sequence anywhere in the stream. With `color` on, the
same call site emits `\x1b[31mFAIL\x1b[0m` framed by the same
unadorned brackets. A test contract that does a fixed-string grep for
`[FAIL]` is written against the color-off byte stream, and it works
*because* the palette makes color strictly additive: turning color on
never changes the brackets, the padding, or the word itself, only
wraps additional zero-width-in-effect escape bytes around the inner
word. Color and a byte-exact contract grep read as if they should
conflict; in this design they simply don't, because the palette was
built to guarantee it structurally rather than by convention.

## What's next

Chapter 6 turns to the scheduler — how the kernel decides which task,
including the one blocked on this console's `WaitQueue`, actually gets
to run next.

## Lab: a mini tag-logger

This lab is a small, standalone cousin of `console_ui.line`: a tag
followed by a space, a message, and a newline. It hardcodes its ANSI
escapes directly rather than importing `console_ui` — the lab is
self-contained, not a description of the kernel-tree module's
internals.

```flash
// taglogger.flash - a minimal tag-based logger, ch5 lab.
//
// A teaching-sized cousin of lib/console_ui/console_ui.flash: a fixed tag
// string (built from a raw ANSI SGR escape) followed by a space, the
// message, and a newline. It hardcodes its escapes instead of importing
// console_ui — a standalone lab, not a description of the kernel-tree
// module's internals.

use flibc

link "flibc_start"
link "flibc_mem"

const OK []u8 = "\x1b[32m[ OK ]\x1b[0m"
const WARN []u8 = "\x1b[33m[WARN]\x1b[0m"

// Write "<tag> <msg>\n" to stdout: tag, then message, then newline —
// the same shape as console_ui.line, spelled out by hand.
fn logLine(tag []u8, msg []u8) void {
    _ = flibc.sys.write_fd(1, tag.ptr, tag.len)
    _ = flibc.sys.write_fd(1, " ".ptr, 1)
    _ = flibc.sys.write_fd(1, msg.ptr, msg.len)
    _ = flibc.sys.write_fd(1, "\n".ptr, 1)
}

export fn main(_ usize, _ argv) noreturn {
    logLine(OK, "console ring initialized")
    logLine(WARN, "ring above half capacity")
    flibc.exit()
}
```

> [!NOTE]
> `\x1b[32m` / `\x1b[33m` are the SGR (Select Graphic Rendition) codes
> for green and yellow foreground; `\x1b[0m` resets back to the
> terminal's default. `console_ui`'s real palette (`palette.flash`)
> spells out the same escapes once and gates all of them behind a
> single `color` switch — the point this lab is illustrating by hand.

Copy it into the Flash Editor, choose **Check lab**, and read the compiler's output: a
handful of plain `write_fd` calls per log line, in the same
tag-then-message-then-newline order `console_ui.line` uses.
