// flibc — FlashOS userland mini-libc.
//
// Layered:
//   * sys      — raw SVC wrappers around the kernel ABI
//                (lib/syscall_defs.zig). One Zig fn per syscall ID.
//   * io       — printf / puts on top of sys.write_fd. printf is a
//                comptime-format %d/%u/%x/%s/%c subset; output flushes
//                via sys.write_fd in a single syscall per call.
//   * heap     — bump allocator over sys.brk/sbrk. State-free; each
//                malloc(n) is a sys.sbrk(+n) returning the previous
//                break. No free.
//   * process  — fork / wait / exit / execve / chdir.
//                fork/wait/exit/chdir are direct passthroughs; `execve`
//                path form (slot 31).
//   * readline — raw line editor over fd 0. Pure byte → buffer state
//                machine + an SVC-driven driver layered on sys.read /
//                sys.write_fd. fsh consumes this; the pure layer is
//                host-tested in isolation.
//   * execvp   — bare-name → `/bin/<name>` resolver over sys.exec_path.
//                Pure path-build + an SVC driver gated the same way as
//                readline; no $PATH (env is future work).
//
// Re-exports below are the userland-facing surface; demo programs can
// `@import("flibc")` and stay one module deep. The sub-modules are
// public too for callers that need raw `flibc.sys.dump_free`
// directly.

pub const sys = @import("syscalls.zig");
pub const io = @import("io.zig");

// Shared user↔kernel ABI types, surfaced at the top level so coreutils
// name `flibc.Dirent` / `flibc.DT_DIR` without reaching into
// syscall_defs directly (mirrors `ReadlineOutcome` below). The raw call
// stays `flibc.sys.readdir`, like every other syscall wrapper. Canonical
// home is lib/syscall_defs.zig.
const defs = @import("syscall_defs");
pub const Dirent = defs.Dirent;
pub const DT_REG = defs.DT_REG;
pub const DT_DIR = defs.DT_DIR;
// Kernel-log ring capacity. Surfaced so `/bin/dmesg` sizes its
// read buffer to KLOG_SIZE without reaching into syscall_defs; the raw
// call stays `flibc.sys.klog_read`. Canonical home is lib/syscall_defs.zig.
pub const KLOG_SIZE = defs.KLOG_SIZE;
pub const heap = @import("heap.zig");
pub const process = @import("process.zig");
pub const readline_mod = @import("readline.zig");
pub const execvp_mod = @import("execvp.zig");

pub const printf = io.printf;
pub const puts = io.puts;

pub const malloc = heap.malloc;
pub const free = heap.free;

pub const fork = process.fork;
pub const wait = process.wait;
pub const exit = process.exit;
pub const execve = process.execve;
pub const chdir = process.chdir;

pub const readline = readline_mod.readline;
pub const readlineCompleting = readline_mod.readlineCompleting;
pub const readlineEdit = readline_mod.readlineEdit;
pub const Completion = readline_mod.Completion;
pub const ReadlineOutcome = readline_mod.Outcome;
pub const History = readline_mod.History;
pub const HistSlot = readline_mod.HistSlot;

pub const execvp = execvp_mod.execvp;

// Navigation seams. Re-exported so a
// full-screen tool reaches the key decoder + completion core one module deep.
// Unreferenced by the current boot binaries, so they stay byte-identical until
// the first consumer (/bin/mon) names them. readlineCompleting + Completion
// land in readline.zig alongside the fsh wiring.
pub const keys = @import("keys.zig");
pub const Key = keys.Key;
pub const KeyEvent = keys.Event;
pub const readKey = keys.readKey;
pub const completion = @import("completion.zig");
pub const pager = @import("pager.zig");
pub const Pager = pager.Pager;
