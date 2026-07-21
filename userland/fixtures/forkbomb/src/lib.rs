//! `/bin/forkbomb` -- capped fork/reap loop.
//!
//! A leak detector, not a stress test: it forks a fixed 16 times, each child exits
//! at once, and the parent reaps each child right after forking it -- so at most one
//! child is ever live and the run never approaches exhaustion. forkbomb is never
//! driven to a failing fork: the kernel's out-of-memory path is graceful, and the
//! in-kernel scenario is what drives fork to the task-slot cap and asserts the clean
//! failure, reap, and restored page baseline.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_flibc::{
    printf,
    process::{exit, fork, wait},
    Part::{Str, Udec},
};
#[cfg(target_os = "none")]
use flashsdk_rt::{entry, Argv};

#[cfg(target_os = "none")]
const FORKS: u32 = 16;

#[cfg(target_os = "none")]
fn main(_argc: usize, _argv: Argv) -> i32 {
    let mut reaped: u32 = 0;
    let mut i: u32 = 0;
    while i < FORKS {
        let pid = fork();
        if pid == 0 {
            // Child: exit at once -- keeps at most one child live.
            exit(0);
        }
        if pid < 0 {
            break; // fork failed (must not happen while capped)
        }
        wait(); // parent reaps immediately
        reaped += 1;
        i += 1;
    }
    printf(&[
        Str(b"forkbomb: spawned and reaped "),
        Udec(reaped as u64),
        Str(b" children\n"),
    ]);
    0
}

#[cfg(target_os = "none")]
entry!(main);
