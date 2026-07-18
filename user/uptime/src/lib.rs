//! `/bin/uptime` -- one-shot uptime monitor.
//!
//! Prints the seconds since boot, humanised, as a single key/value row, then exits
//! -- the focused sibling of sysinfo's broader summary, the way cpuinfo focuses
//! temperature and clock. The value comes off the architectural counter, so it reads
//! the same under QEMU and on hardware.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_console_ui::{banner, screen};
#[cfg(target_os = "none")]
use flashos_flibc::{console_sink, Buf};
#[cfg(target_os = "none")]
use flashsdk_rt::{entry, Argv};

#[cfg(target_os = "none")]
fn main(_argc: usize, _argv: Argv) -> i32 {
    banner(console_sink, b"FlashOS uptime");
    screen::kv(console_sink, b"uptime", uptime_str().as_slice());
    0
}

/// Seconds since boot, humanised: `<h>h <m>m <s>s`, collapsing to `<s>s` under a
/// minute.
#[cfg(target_os = "none")]
fn uptime_str() -> Buf {
    let secs = flashos_flibc::sys::uptime();
    let (h, m, s) = (secs / 3600, (secs % 3600) / 60, secs % 60);
    let mut out = Buf::new();
    if h > 0 {
        out.udec(h).str(b"h ");
    }
    if h > 0 || m > 0 {
        out.udec(m).str(b"m ");
    }
    out.udec(s).byte(b's');
    out
}

#[cfg(target_os = "none")]
entry!(main);
