//! `/bin/meminfo` -- free-page reporter.
//!
//! The standalone form of the shell's `free` built-in: one line carrying the
//! kernel's current free-page count, then exit.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_flibc::{
    printf,
    Part::{Str, Udec},
};
#[cfg(target_os = "none")]
use flashos_user_rt::{entry, Argv};

#[cfg(target_os = "none")]
fn main(_argc: usize, _argv: Argv) -> i32 {
    printf(&[
        Str(b"free pages: "),
        Udec(flashos_flibc::sys::dump_free()),
        Str(b"\n"),
    ]);
    0
}

#[cfg(target_os = "none")]
entry!(main);
