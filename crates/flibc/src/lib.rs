//! The `no_std` userspace library the EL0 tools are built on.
//!
//! A thin layer over the kernel ABI, not a libc: console I/O and its sinks, the
//! process calls, and a bump heap. The raw syscall transport, the ELF entry point,
//! and the freestanding `mem*` primitives live one level down, in the EL0 runtime.
//!
//! No allocator is installed and no formatting engine is linked -- see [`io`] for
//! why `printf` takes a part list rather than a format string.

#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]

pub mod completion;
pub mod execvp;
pub mod gapbuf;
pub mod grep_match;
pub mod heap;
pub mod io;
pub mod keys;
pub mod pager;
pub mod process;
pub mod readline;
pub mod tui;

pub use io::{Buf, Part, Sink, Writer};

/// The raw kernel ABI, one level down. A tool that needs a call this library does
/// not wrap (the file surface, the hardware monitors, the kernel log) reaches it
/// here rather than re-deriving the trap.
#[cfg(target_os = "none")]
pub use flashos_user_rt::syscall as sys;

#[cfg(target_os = "none")]
pub use heap::{free, malloc};
#[cfg(target_os = "none")]
pub use io::{
    alt_enter, alt_leave, console_input, console_sink, eprintf, err_sink, park_cursor, printf, puts,
};
#[cfg(target_os = "none")]
pub use process::{chdir, execve, exit, fork, wait};
