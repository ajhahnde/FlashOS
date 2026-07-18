//! `/bin/passwd` -- interactive password change.
//!
//! With no argument it changes the calling user's own password (uid -> login name via
//! `/etc/passwd`); with an argument (`passwd <user>`) it targets that record -- which
//! only root may do for records other than its own (the kernel enforces this, the tool
//! just passes it through). Prompts follow the Unix shape: the current password is
//! skipped when the caller is root (root resets without proof), the new password is
//! asked twice and must match. All password prompts run with kernel echo off.
//!
//! The KDF and the splice-safe shadow rewrite live in the kernel -- this tool only
//! collects strings and reports the verdict. Without a writable FAT32 shadow
//! (`/mnt/shadow` -- absent on QEMU virt and on a freshly formatted card) the kernel
//! answers -1 and the tool says so.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_flibc::{console_input, console_sink, err_sink, sys};
#[cfg(target_os = "none")]
use flashsdk_abi::syscall::EACCES;
#[cfg(target_os = "none")]
use flashsdk_rt::{arg, entry, Argv};

#[cfg(target_os = "none")]
const PASSWD_PATH: &[u8] = b"/etc/passwd\0";

#[cfg(target_os = "none")]
const PASSWD_MAX: usize = 512;

#[cfg(target_os = "none")]
fn main(argc: usize, argv: Argv) -> i32 {
    let mut user_buf = [0u8; 64];
    let mut old_buf = [0u8; 128];
    let mut new_buf = [0u8; 128];
    let mut retype_buf = [0u8; 128];

    let is_root = sys::geteuid() == 0;

    // The target user: argv[1], or the caller's own login name.
    let Some(user_len) = target_user(argc, argv, &mut user_buf) else {
        return 1;
    };

    console_sink(b"Changing password for ");
    console_sink(&user_buf[..user_len]);
    console_sink(b"\n");

    // Current password -- skipped for root: the kernel does not require it from euid 0,
    // which is the forgotten-password recovery path.
    let mut old_len = 0usize;
    if !is_root {
        sys::set_console_mode(0);
        console_sink(b"Current password: ");
        old_len = read_line(&mut old_buf);
        console_sink(b"\n");
    }

    // New password, asked twice, echo off.
    sys::set_console_mode(0);
    console_sink(b"New password: ");
    let new_len = read_line(&mut new_buf);
    console_sink(b"\n");
    console_sink(b"Retype new password: ");
    let retype_len = read_line(&mut retype_buf);
    console_sink(b"\n");

    if new_len == 0 {
        err_sink(b"passwd: empty password not allowed\n");
        return 1;
    }
    if new_buf[..new_len] != retype_buf[..retype_len] {
        err_sink(b"passwd: passwords do not match\n");
        return 1;
    }

    let ret = unsafe {
        sys::passwd(
            user_buf.as_ptr(),
            user_len,
            old_buf.as_ptr(),
            old_len,
            new_buf.as_ptr(),
            new_len,
        )
    };
    if ret == 0 {
        console_sink(b"passwd: password updated\n");
        0
    } else if ret == -i64::from(EACCES) {
        err_sink(b"passwd: authentication failure\n");
        1
    } else {
        err_sink(b"passwd: cannot write shadow (read-only or missing)\n");
        1
    }
}

/// Fill `buf` with the login name whose password is being changed and return its
/// length: `argv[1]` when given, otherwise the caller's own record, resolved uid ->
/// name through `/etc/passwd`. `None` once the failure has been reported.
#[cfg(target_os = "none")]
fn target_user(argc: usize, argv: Argv, buf: &mut [u8]) -> Option<usize> {
    if argc >= 2 {
        let name = unsafe { arg(argv, 1) }?;
        if name.is_empty() || name.len() > buf.len() {
            err_sink(b"passwd: bad user name\n");
            return None;
        }
        buf[..name.len()].copy_from_slice(name);
        return Some(name.len());
    }

    let uid_raw = sys::getuid();
    if uid_raw < 0 {
        err_sink(b"passwd: cannot read uid\n");
        return None;
    }

    let mut pw_buf = [0u8; PASSWD_MAX];
    let fd = unsafe { sys::open(PASSWD_PATH.as_ptr()) };
    if fd < 0 {
        err_sink(b"passwd: cannot open /etc/passwd\n");
        return None;
    }
    let mut n = 0usize;
    while n < pw_buf.len() {
        let r = sys::read(fd, &mut pw_buf[n..]);
        if r <= 0 {
            break;
        }
        n += r as usize;
    }
    sys::close(fd);

    let Some(entry) = flashos_pwfile::lookup_by_uid(&pw_buf[..n], uid_raw as u32) else {
        err_sink(b"passwd: no passwd entry for this uid\n");
        return None;
    };
    if entry.user.len() > buf.len() {
        err_sink(b"passwd: bad user name\n");
        return None;
    }
    buf[..entry.user.len()].copy_from_slice(entry.user);
    Some(entry.user.len())
}

/// Read one line from fd 0, one byte at a time, into `buf`, stopping at CR / LF or
/// EOF. Returns the byte count, excluding the terminator. This loop never echoes --
/// exactly right for password input, which the caller has already put behind echo-off.
#[cfg(target_os = "none")]
fn read_line(buf: &mut [u8]) -> usize {
    let mut n = 0usize;
    while n < buf.len() {
        let Some(c) = console_input() else {
            break;
        };
        if c == b'\n' || c == b'\r' {
            break;
        }
        buf[n] = c;
        n += 1;
    }
    n
}

#[cfg(target_os = "none")]
entry!(main);
