//! `/bin/clear` -- wipe the terminal.
//!
//! The smallest console renderer there is, and for that reason the first tool to
//! run the whole userspace stack end to end: the shared screen layer emits the
//! escape, the flibc console sink turns it into a write syscall, and the EL0
//! runtime carries the entry and the exit. The escape bytes stay single-sourced --
//! this tool spells none of them itself.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashsdk_rt::{entry, Argv};

#[cfg(target_os = "none")]
fn main(_argc: usize, _argv: Argv) -> i32 {
    flashos_console_ui::screen::clear(flashos_flibc::console_sink);
    0
}

#[cfg(target_os = "none")]
entry!(main);
