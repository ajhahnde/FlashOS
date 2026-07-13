//! `/bin/ls` -- list directory entries.
//!
//! With no arguments it lists the working directory; with arguments it lists each
//! path in turn. Each entry's basename goes to fd 1, a trailing `/` appended for a
//! directory, then a newline. No flags, no recursion.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_abi::syscall::{Dirent, DT_DIR};
#[cfg(target_os = "none")]
use flashos_flibc::{console_sink, sys};
#[cfg(target_os = "none")]
use flashos_user_rt::{arg_ptr, entry, Argv};

/// Walk the directory at `path` by index. The readdir syscall is stateless -- there
/// is no open handle -- so the walk counts up until the kernel stops filling entries.
///
/// # Safety
///
/// `path` must point at a NUL-terminated string.
#[cfg(target_os = "none")]
unsafe fn list_dir(path: *const u8) {
    let mut d = Dirent::default();
    let mut i: u64 = 0;
    while unsafe { sys::readdir(path, i, &mut d) } == 0 {
        let name = &d.name[..d.name.iter().position(|&b| b == 0).unwrap_or(d.name.len())];
        console_sink(name);
        if d.d_type == DT_DIR {
            console_sink(b"/");
        }
        console_sink(b"\n");
        i += 1;
    }
}

#[cfg(target_os = "none")]
fn main(argc: usize, argv: Argv) -> i32 {
    if argc <= 1 {
        unsafe { list_dir(c".".as_ptr() as *const u8) };
        return 0;
    }
    let mut a = 1;
    while a < argc {
        let Some(path) = (unsafe { arg_ptr(argv, a) }) else {
            break;
        };
        unsafe { list_dir(path) };
        a += 1;
    }
    0
}

#[cfg(target_os = "none")]
entry!(main);
