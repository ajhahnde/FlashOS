//! `/bin/cp` -- copy SRC to DST.
//!
//!   cp SRC DST
//!
//! Opens SRC read-only, creates DST fresh, and streams SRC's bytes into it in
//! 512-byte chunks. DST must not already exist -- create fails closed on a name
//! collision, so there is no clobber -- and its name must fit 8.3. Errors print a
//! diagnostic to fd 2 and stop the copy.
//!
//! The first consumer of the create syscall, and so what exercises create -> write
//! -> persist end to end: the acceptance loop copies a file, reboots, and reads it
//! back.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_flibc::{err_sink, sys};
#[cfg(target_os = "none")]
use flashsdk_rt::{arg_ptr, entry, Argv};

#[cfg(target_os = "none")]
const BUF_LEN: usize = 512;

#[cfg(target_os = "none")]
fn main(argc: usize, argv: Argv) -> i32 {
    if argc < 3 {
        err_sink(b"usage: cp SRC DST\n");
        return 0;
    }
    let (Some(src), Some(dst)) = (unsafe { arg_ptr(argv, 1) }, unsafe { arg_ptr(argv, 2) }) else {
        return 0;
    };

    let sfd = unsafe { sys::open(src) };
    if sfd < 0 {
        err_sink(b"cp: cannot open source\n");
        return 0;
    }
    let dfd = unsafe { sys::create(dst) };
    if dfd < 0 {
        err_sink(b"cp: cannot create destination\n");
        sys::close(sfd);
        return 0;
    }

    let mut buf = [0u8; BUF_LEN];
    loop {
        let n = sys::read(sfd, &mut buf);
        if n <= 0 {
            break;
        }
        // A FAT32 write pushes the whole chunk in one call, so a short write is an
        // error (no space, or a fault), not a partial that wants a retry loop.
        if sys::write(dfd, &buf[..n as usize]) != n {
            err_sink(b"cp: write error\n");
            break;
        }
    }
    sys::close(sfd);
    sys::close(dfd);
    0
}

#[cfg(target_os = "none")]
entry!(main);
