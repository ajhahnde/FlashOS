//! `/bin/echo` -- write the arguments to fd 1.
//!
//! Arguments are written space-separated and newline-terminated; argv[0] is
//! skipped. No flags. Output is batched through a buffered writer and drained by
//! the flibc console sink -- the OS side of the io seam: the program decides which
//! bytes to emit, the write syscall puts them on the wire. The syscall stays in
//! flibc, the one place userland touches a descriptor, so `echo hi | cat` still
//! redirects fd 1 onto the pipe.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_flibc::Writer;
#[cfg(target_os = "none")]
use flashsdk_rt::{arg, entry, Argv};

#[cfg(target_os = "none")]
fn main(argc: usize, argv: Argv) -> i32 {
    let mut buf = [0u8; 256];
    let mut w = Writer::new(flashos_flibc::console_sink, &mut buf);
    let mut i = 1;
    while i < argc {
        let Some(s) = (unsafe { arg(argv, i) }) else {
            break;
        };
        w.write_all(s);
        if i + 1 < argc {
            w.write_all(b" ");
        }
        i += 1;
    }
    w.write_all(b"\n");
    w.flush();
    0
}

#[cfg(target_os = "none")]
entry!(main);
