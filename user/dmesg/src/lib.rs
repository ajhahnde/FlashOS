//! `/bin/dmesg` -- kernel-log dumper.
//!
//! Reads the retained kernel log in a single snapshot and writes it to fd 1, so the
//! boot log can be inspected over the console without a serial adapter. The buffer
//! is a stack array sized to the whole ring, so one read captures the retained log
//! with no cursor and no tearing.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_abi::syscall::KLOG_SIZE;
#[cfg(target_os = "none")]
use flashos_user_rt::{entry, Argv};

#[cfg(target_os = "none")]
fn main(_argc: usize, _argv: Argv) -> i32 {
    let mut buf = [0u8; KLOG_SIZE as usize];
    let n = flashos_flibc::sys::klog_read(&mut buf);
    if n > 0 {
        flashos_flibc::console_sink(&buf[..n as usize]);
    }
    0
}

#[cfg(target_os = "none")]
entry!(main);
