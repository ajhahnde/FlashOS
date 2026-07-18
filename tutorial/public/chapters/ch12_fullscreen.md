# 12. Full-Screen User Programs

`/bin/less` and `/bin/edit` are Rust EL0 programs under `user/`. They do not
draw through a framebuffer driver. They use terminal control sequences, raw
key decoding, and the alternate screen over the same console descriptors as
the shell.

## Shared userland building blocks

`crates/flibc/` contains the reusable cores:

| Module | Responsibility |
| :----- | :------------- |
| `keys.rs` | decode escape sequences, arrows, control keys, and Tab |
| `tui.rs` | terminal screen entry/exit and rendering helpers |
| `pager.rs` | line indexing, viewport position, and scroll clamping |
| `gapbuf.rs` | editable text storage with a movable gap |
| `heap.rs` | userland bump allocation over `brk`/`sbrk` |

These pure state machines are host-testable without booting the kernel. The
program crates connect them to file descriptors and syscalls.

## Pager flow

`user/less/` reads a file into bounded user memory, indexes line starts, enters
the alternate screen, renders the visible range, and changes the viewport in
response to decoded keys. On exit it restores the normal screen.

## Editor flow

`user/edit/` is the main heap consumer. It loads text into a gap buffer, moves
the gap to make insertion and deletion local, renders the viewport, and saves
through the current FAT32 mutation surface.

```text
file bytes → gap buffer → edit operations → rendered viewport
                                      ↓
                              unlink/create/write
```

The save sequence works around the absence of general file truncation. It is
appropriate for the current filesystem, but not yet an atomic save protocol.

## Terminal ownership

Full-screen tools temporarily own the interactive terminal. They must restore
screen state even on ordinary exit. Kernel diagnostics remain on Mini-UART, so
they do not depend on the user program's alternate-screen lifecycle.

## Relationship to future FlashUI

These programs are current, shipped tools. FlashUI is a later native TUI
initiative that will embed FlashShell and eventually become the default
post-login session. Its MVP is planned to hand the terminal to foreground
programs like `edit` and restore its own screen afterward, rather than emulate
an entire terminal or duplicate those programs.

`/bin/fsh`, `/bin/less`, and `/bin/edit` remain real standalone recovery and
foreground paths through that future integration.

> [!TIP]
> The right design boundary is state versus transport: buffer, pager, and
> renderer logic can be host-tested; raw console I/O and real FAT32 persistence
> need runtime or hardware evidence.

Next, we examine the layers of evidence that qualify those boundaries.
