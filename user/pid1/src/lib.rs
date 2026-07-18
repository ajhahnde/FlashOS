//! PID 1.
//!
//! Built as a standalone freestanding AArch64 executable and staged into the initramfs
//! at `/sbin/init`. The kernel finds that entry and hands its bytes to the same ELF
//! loader the test payloads travel through; the loader honours the entry point and the
//! segment addresses, so section placement is the linker script's job and this file
//! pins nothing itself.
//!
//! What runs here is the whole of userspace's beginning: announce that EL0 came up, run
//! the boot self-test suite where a watchdog is watching, and hand the machine to the
//! login supervisor. It never returns -- the exec replaces this image, and the exit
//! below is only the failure path.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

pub mod marks;
pub mod probe;

#[cfg(target_os = "none")]
mod harness;

#[cfg(target_os = "none")]
use flashsdk_rt::{entry, syscall as sys, Argv};

/// The login supervisor PID 1 hands the machine to.
#[cfg(target_os = "none")]
const LOGIN_PATH: &[u8] = b"/bin/login\0";

/// The credentials the unattended boot authenticates with. QEMU has no typist and feeds
/// the console from `/dev/null`, so with the seed gate on, PID 1 pushes these bytes into
/// the console RX ring before exec'ing the supervisor, and the real login path drains
/// them as though they had been typed. They must match a seeded account; this one is
/// unprivileged, so the boot also exercises the privilege drop.
///
/// The gate is off by default and a hardware deploy leaves it off: the Pi stops at a real
/// `login:` prompt and demands a real password.
#[cfg(all(target_os = "none", feature = "ci-login-seed"))]
const LOGIN_SCRIPT: &[u8] = b"flash\nflash\n";

#[cfg(target_os = "none")]
fn main(_argc: usize, _argv: Argv) -> i32 {
    // Nothing below EL0 can attest that userspace actually started -- the kernel only
    // knows that it handed off -- so PID 1 announces its own arrival, through the same
    // renderers the boot log uses but over a syscall rather than the UART.
    flashos_console_ui::logger(flashos_flibc::console_sink).ok(b"Userspace init");

    // The boot-as-test path the QEMU watchdog asserts. Gated so a deploy boots clean
    // straight to the login prompt.
    #[cfg(feature = "boot-selftest")]
    {
        let result = harness::run_all();
        harness::print_tally(result.passed, result.total);
    }

    // Seed the console before the exec, not after: the supervisor's first read would
    // otherwise race an empty ring.
    #[cfg(feature = "ci-login-seed")]
    for &b in LOGIN_SCRIPT {
        sys::console_inject(b);
    }

    // Hand PID 1 over. The supervisor authenticates against the shadow database, drops
    // privilege, and execs the user's shell -- whose homescreen line is the marker the
    // watchdog waits for. Neither it nor the shell dumps the free-page count, so the
    // checkpoint tally stays deterministic. This call returns only on failure.
    let argv = [LOGIN_PATH.as_ptr(), core::ptr::null()];
    unsafe {
        sys::exec_path(LOGIN_PATH.as_ptr(), argv.as_ptr());
    }
    1
}

#[cfg(target_os = "none")]
entry!(main);
