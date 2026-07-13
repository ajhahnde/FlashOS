//! `/bin/cpuinfo` -- one-shot CPU monitor.
//!
//! Prints the SoC temperature and the ARM core clock as aligned key/value rows, then
//! exits. Both come from the VideoCore mailbox and read 0 = unknown on a board
//! without one, rendered `n/a` -- cpuinfo never fabricates a reading. CPU load is
//! deliberately absent: a busy/idle percentage needs idle-task accounting the
//! scheduler does not keep, so it waits for that layer rather than being faked.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_console_ui::{banner, screen};
#[cfg(target_os = "none")]
use flashos_flibc::{console_sink, Buf};
#[cfg(target_os = "none")]
use flashos_user_rt::{entry, Argv};

#[cfg(target_os = "none")]
fn main(_argc: usize, _argv: Argv) -> i32 {
    banner(console_sink, b"FlashOS cpu");
    screen::kv(console_sink, b"temp", temp_str().as_slice());
    screen::kv(console_sink, b"freq", freq_str().as_slice());
    0
}

/// SoC temperature in whole degrees Celsius, or `n/a` when unknown (0 -- virt's
/// stub, or a mailbox timeout on real hardware). The syscall reports
/// milli-degrees. ASCII `C` keeps every byte single-width on any console.
#[cfg(target_os = "none")]
fn temp_str() -> Buf {
    let mut out = Buf::new();
    let milli = flashos_flibc::sys::cpu_temp();
    if milli == 0 {
        out.str(b"n/a");
    } else {
        out.udec(milli / 1000).str(b" C");
    }
    out
}

/// ARM core clock in MHz, or `n/a` when unknown. The syscall reports Hz.
#[cfg(target_os = "none")]
fn freq_str() -> Buf {
    let mut out = Buf::new();
    let hz = flashos_flibc::sys::cpu_freq();
    if hz == 0 {
        out.str(b"n/a");
    } else {
        out.udec(hz / 1_000_000).str(b" MHz");
    }
    out
}

#[cfg(target_os = "none")]
entry!(main);
