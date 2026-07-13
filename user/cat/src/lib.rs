//! `/bin/cat` -- concatenate files to fd 1.
//!
//! With no arguments it copies fd 0 to fd 1 until end-of-input (the `echo hi | cat`
//! case, where fd 0 is the pipe read end). With arguments it opens each path and
//! copies its bytes to fd 1; a path that cannot be opened prints a diagnostic to
//! fd 2 and the next path is still tried. No flags.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_abi::syscall::EACCES;
#[cfg(target_os = "none")]
use flashos_flibc::{console_sink, err_sink, sys};
#[cfg(target_os = "none")]
use flashos_user_rt::{arg_ptr, entry, Argv};

#[cfg(target_os = "none")]
const BUF_LEN: usize = 512;

/// Copy `fd` to fd 1 until it reports end-of-input or an error.
#[cfg(target_os = "none")]
fn drain(fd: i32) {
    let mut buf = [0u8; BUF_LEN];
    loop {
        let n = sys::read(fd, &mut buf);
        if n <= 0 {
            break;
        }
        console_sink(&buf[..n as usize]);
    }
}

#[cfg(target_os = "none")]
fn main(argc: usize, argv: Argv) -> i32 {
    if argc <= 1 {
        drain(sys::STDIN);
        return 0;
    }
    let mut i = 1;
    while i < argc {
        let Some(path) = (unsafe { arg_ptr(argv, i) }) else {
            break;
        };
        i += 1;
        let fd = unsafe { sys::open(path) };
        if fd < 0 {
            err_sink(if fd == -EACCES {
                b"cat: Permission denied\n".as_slice()
            } else {
                b"cat: cannot open\n".as_slice()
            });
            continue;
        }
        drain(fd);
        sys::close(fd);
    }
    0
}

#[cfg(target_os = "none")]
entry!(main);
