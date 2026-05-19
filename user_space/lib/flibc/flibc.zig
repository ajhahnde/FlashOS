// flibc — FlashOS userland mini-libc.
//
// Layered:
//   * sys      — raw SVC wrappers around the kernel ABI
//                (lib/syscall_defs.zig). One Zig fn per syscall ID.
//   * io       — printf / puts / write on top of sys.write. printf is a
//                comptime-format %d/%u/%x/%s/%c subset; output flushes
//                via sys.write in a single syscall per call.
//   * heap     — bump allocator over sys.brk/sbrk. State-free; each
//                malloc(n) is a sys.sbrk(+n) returning the previous
//                break. No free.
//   * process  — fork / wait / exit / execve. fork/wait/exit are direct
//                passthroughs; execve adds an ELF-magic guard before
//                forwarding to sys.exec.
//
// Re-exports below are the userland-facing surface; demo programs can
// `@import("flibc")` and stay one module deep. The sub-modules are
// public too for callers that need raw `flibc.sys.dump_free`
// directly.

pub const sys = @import("syscalls.zig");
pub const io = @import("io.zig");
pub const heap = @import("heap.zig");
pub const process = @import("process.zig");

pub const printf = io.printf;
pub const puts = io.puts;
pub const write = io.write;

pub const malloc = heap.malloc;
pub const free = heap.free;

pub const fork = process.fork;
pub const wait = process.wait;
pub const exit = process.exit;
pub const execve = process.execve;
