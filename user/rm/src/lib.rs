//! `/bin/rm` -- remove files.
//!
//!   rm FILE...
//!
//! Unlinks each argument in turn: the kernel tombstones the directory entry and
//! frees the file's cluster chain. Files only -- a directory is refused by the
//! syscall (there is no `-r`). A file that cannot be removed (missing, a directory,
//! a read-only mount) prints a diagnostic to fd 2 and the next argument is still
//! tried. No flags.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_flibc::{err_sink, sys};
#[cfg(target_os = "none")]
use flashos_user_rt::{arg_ptr, entry, Argv};

#[cfg(target_os = "none")]
fn main(argc: usize, argv: Argv) -> i32 {
    if argc < 2 {
        err_sink(b"usage: rm FILE...\n");
        return 0;
    }
    let mut i = 1;
    while i < argc {
        let Some(path) = (unsafe { arg_ptr(argv, i) }) else {
            break;
        };
        i += 1;
        if unsafe { sys::unlink(path) } < 0 {
            err_sink(b"rm: cannot remove file\n");
        }
    }
    0
}

#[cfg(target_os = "none")]
entry!(main);
