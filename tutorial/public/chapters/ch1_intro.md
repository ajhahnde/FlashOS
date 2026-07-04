# Chapter 1: What is FlashOS

FlashOS is a hobby AArch64 operating system. It boots on real Raspberry
Pi 4 Model B hardware and under QEMU's `-M raspi4b` and `-M virt`
machines, running everything from the boot trampoline to an interactive
login shell without a Linux host underneath it — FlashOS *is* the
kernel and the userland.

The kernel core, the board drivers, and the userland (including the
`fsh` shell and its coreutils) are written in
[Flash](https://github.com/ajhahnde/Flash), a systems language whose
compiler, `flashc`, is a native LLVM compiler. (Transitional note: FlashOS's
build still consumes flashc's bootstrap Zig backend while the native-object
port completes — this tour says so once, here and in Chapter 14, and
otherwise talks about the compiler as it is.) As
`PORT.md` (in the repository root) documents, FlashOS did not start
this way — it began as a C kernel, was rewritten in pure Zig and
AArch64 assembly, and later had its OS-image modules ported from Zig
to Flash module by module, with the boot assembly, linker scripts, and
host build tooling staying Zig throughout.

## What this tour shows

This guided tour follows FlashOS's real boot order — power-on to
prompt — one layer at a time. It starts at the earliest boot code the
CPU executes, then walks up through memory management, the console
drivers, the scheduler, the syscall boundary, and the userland C
library, before turning to how a session actually starts: login,
identity, the interactive shell, and the filesystem it operates on. From
there the tour looks at the coreutils and demo programs that ride on
top, the in-kernel self-test harness that keeps the kernel honest across
changes, and the build pipeline that turns `.flash` source into a
bootable image. The tour closes on real Raspberry Pi 4 hardware, where
everything covered along the way is running outside of QEMU.

Each chapter pairs a short read with a hands-on lab: a real, runnable
piece of Flash source you compile and inspect yourself, the same way
the actual kernel and userland are built.

## Lab: Hello, World!

Every Flash program that talks to the outside world does it through
`flibc`, FlashOS's userland mini-libc — the same library the shipped
`/bin` coreutils link against. This is the smallest complete FlashOS
userland program: it writes one line to standard output through the
`write_fd` syscall wrapper, then exits.

```flash
// hello.flash - the smallest Flash program: write a line, then exit.
use flibc

link "flibc_start"
link "flibc_mem"

export fn main(_ usize, _ argv) noreturn {
    msg := "Hello from FlashOS!\n"
    _ = flibc.sys.write_fd(1, msg.ptr, msg.len)
    flibc.exit()
}
```

> [!NOTE]
> The two `_` parameters on `main` stand in for the argument count and
> vector; this program ignores both. `flibc.sys.write_fd` is a thin
> wrapper over the `write` syscall, and `flibc.exit()` wraps `exit` —
> the same syscalls a shell like `fsh` or a coreutil like `cat` uses.

Compile it with the button below and read the output: a
`main` with C calling convention, wired to the same `flibc` module the
rest of FlashOS's userland imports.
