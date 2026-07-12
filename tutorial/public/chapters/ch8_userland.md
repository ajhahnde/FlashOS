# Chapter 8: Userland — ELF, execve & flibc

Chapter 6 covered `sys_execve` from the kernel side: the path-resolved
ELF loader that replaces a task's address space in place, keeping its
`pid` across the swap. This chapter closes the loop from the other
direction — where does a `.elf` file come from in the first place, and
what does a program see the instant the kernel hands it control?

## The embedded initramfs

FlashOS's base userland ships inside the kernel image itself: no
separate partition, no filesystem mount, needed to boot to a shell.
`tools/initramfs.S` carries a `.incbin "initramfs.cpio"` between
`__initramfs_start` / `__initramfs_end` labels, and both board linker
scripts place that `.initramfs` section between `bss_end` and
`id_pg_dir`. The archive itself is built by `scripts/build_initramfs.flash`,
a hand-rolled newc-cpio encoder over a sorted file list — fixed mtime,
uid, gid, and inode numbers, so the archive is a pure function of file
contents and names, not of when the build ran.

Two things live in it: the init program, staged at `/sbin/init`
(the `pid1.elf` artifact), and a handful of `[TEST]` fixture payloads
staged at `/test/*.elf` — `hello.elf`, `stackbomb.elf`, and
`flibc_demo.elf`.

`src/initramfs.flash` walks the archive at runtime with an `Iterator`
and a `locate(path)` convenience wrapper over it:

```flash
pub const Iterator = struct {
    // …
    pub fn next(self *mut Iterator) ParseError!?Entry {
        // …
    }
}

pub fn locate(path []u8) ParseError!?Entry {
    // …
}
```

*(excerpt from `src/initramfs.flash` — not standalone-compilable)*

The whole archive is read-only and lives in the kernel's own address
space; a `File` handle allocated by `src/file.flash` carries an offset
into the section rather than a copy of the bytes. Ordinary syscalls
reach it through the VFS shim (`src/vfs.flash`) like any other path — the
one exception is PID 1 itself, which calls `initramfs.locate` directly,
because it runs before the syscall path exists yet to call through.

## From bytes to a running program

`kernel_process` — the kernel-side function that starts PID 1 — locates
`/sbin/init` in the archive and hands its bytes straight to
`prepare_move_to_user_elf`:

```flash
export fn kernel_process() void {
    const entry_opt = initramfs.locate("/sbin/init") catch null
    // …
    const entry = entry_opt.?
    // …
    const blob_kva u64 = #intFromPtr(entry.data.ptr)
    const err = prepare_move_to_user_elf(blob_kva, entry.data.len)
    // …
}
```

*(excerpt from `src/kernel.flash` — not standalone-compilable)*

This is the same ELF loader chapter 6 already walked through for
`sys_execve` — parsing `PT_LOAD` segments, mapping them at their
`p_vaddr`s, and setting up the initial user stack — so there's no need
to re-derive it here. What's new in this chapter is what happens the
instant that loader is done and hands control to `e_entry`.

## argv delivery: two registers and a typed shim

Per AAPCS64 (the AArch64 procedure call standard), the loader hands a
freshly started program its argument count and vector in the first two
integer registers on `eret`: `x0 = argc`, `x1 = argv`. That is the
entire contract — everything else about "how does a program read its
own command line" is a userland convention layered on top of two raw
registers.

`user_space/lib/flibc/start.flash` is that convention: a crt0-style
shim that turns `x0`/`x1` into a typed call to the program's own
`main`:

```flash
extern fn main(argc usize, argv argv) callconv(.c) noreturn

fn _start_shim(argc usize, argv argv) callconv(.c) noreturn {
    main(argc, argv)
}

comptime {
    #export(&_start_shim, .{ .name = "_start", .linkage = .strong })
}
```

*(excerpt from `user_space/lib/flibc/start.flash` — not
standalone-compilable)*

Declaring `argc`/`argv` as ordinary typed parameters — rather than
reading `x0`/`x1` by hand in a `callconv(.naked)` function — is enough:
the compiler treats them as live-in arguments, the standard prologue
never disturbs them before they're forwarded to `main`, and there is no
hand-written register shuffle to get wrong.

This shim is not part of flibc's always-imported graph; a program pulls
it in explicitly with `link "flibc_start"`. The reason is a linkage
collision, not a style preference: `flibc.flash` re-exports the
`process` module, so anything defined inside `flibc.flash`'s own import
graph gets compiled into *every* program that does `use flibc` —
including programs that already define their own `_start` (the legacy
`hello`/`stackbomb`/`flibc_demo` payloads). Two `_start` exports in one
compilation is an "exported symbol collision" that the compiler rejects
outright, regardless of linkage — a `weak` export doesn't defer to the
linker here. Keeping the shim in a separate, opt-in module sidesteps
the collision entirely: newer programs (the `argv_echo` fixture, and
this chapter's Lab below) import `flibc_start` and get the argc/argv
shim; programs with a bespoke entry simply don't import it and keep
running their own.

## flibc: the userland mini-libc

`user_space/lib/flibc/flibc.flash` is the re-export hub every FlashOS
userland program reaches for. It's a thin top-level module that pulls
in a handful of sub-modules one level deep — `syscalls`, `io`, `heap`,
`process`, `readline`, `execvp`, `keys`, `completion`, `pager` — and
re-exports their public surface, so a program does `use flibc` once and
then reaches `flibc.printf`, `flibc.malloc`, `flibc.fork`,
`flibc.execve`, and so on without naming each leaf module individually.
The header comment in `flibc.flash` documents the Flash-side pattern
behind this: `pub use "io" as io` lowers to `pub const io =
@import("io.zig")`, so a re-export is an ordinary `pub const` over the
imported module.

`fsh`, the interactive shell, and its coreutils all link against flibc
this way. Most of them never touch the userland heap at all — the
coreutils use fixed-size stack or static buffers, so the single R+X
`PT_LOAD` each one links into carries no writable `.bss`, and flibc's
`malloc`/`sbrk` machinery goes unexercised. flibc's heap gets its first
real workout in `/bin/edit`, the full-screen editor — that's chapter
12's territory, not this one.

fsh itself, its REPL loop, and `readline` are chapter 10's territory —
this chapter only needed flibc as the thing a program links against to
get from `argc`/`argv` to a running process.

## The Lab's model: `argv_echo.flash`

`tools/argv_echo.flash` is a real `[TEST]` fixture in the tree, staged
at `/test/argv_echo.elf`, that proves this entire path end to end: it
imports the `flibc_start` shim, walks `argv[0..argc]`, and prints each
argument.

```flash
use flibc

link "flibc_start"

// …

export fn main(argc usize, argv argv) noreturn {
    // …
    var i usize = 0
    while i < argc {
        s := argv[i] orelse break
        flibc.printf("%s\n", .{s})
        i += 1
    }
    flibc.exit()
}
```

*(excerpt from `tools/argv_echo.flash` — not standalone-compilable;
the real file also pads its `.rodata` past one page to force loading
through `sys_execve`'s streaming path rather than a single-page
snapshot — an edge case this chapter's Lab doesn't need to reproduce)*

## Lab: print your own argv

This is the first Lab in the tour whose `main` actually reads its
`argv` parameter — chapter 1's `hello.flash` and the labs since then
declared `main(_ usize, _ argv)` and discarded both. This program walks
its argument vector and prints each entry, then exits — a simplified,
standalone version of `argv_echo.flash` above, without the page-padding
trick (that exists only to force a kernel-side loader edge case, which
has nothing to do with a reader compiling this locally).

```flash
// argv_dump.flash - walk argv[0..argc] and print each one, then exit.
use flibc

link "flibc_start"

export fn main(argc usize, argv argv) noreturn {
    var i usize = 0
    while i < argc {
        s := argv[i] orelse break
        flibc.printf("%s\n", .{s})
        i += 1
    }
    flibc.exit()
}
```

> [!NOTE]
> `flibc.printf`'s `%s` verb takes a null-terminated string
> (`[*:0]const u8`) — exactly the element type `argv` walks — so no
> length has to be tracked or passed separately. `flibc.io`'s format
> spec comment documents `%s` alongside `%d`/`%u`/`%x`/`%c`/`%%`.

Copy it into the Flash Editor and choose **Check lab**. Since this Lab reads `argc`/`argv`
at all, that only proves the source compiles cleanly — running
it with real arguments only happens inside FlashOS itself, where
`sys_execve` is the one thing that ever puts values in `x0`/`x1` before
`_start_shim` runs.

## What's next

A program can now run and see its own arguments — chapter 9 turns to
the question of *who* it runs as: login, credentials, and the identity
a shell inherits before a user ever types a command.
