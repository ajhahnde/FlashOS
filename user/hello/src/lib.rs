//! Minimal ELF payload for the `exec-elf` boot-contract scenario.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_user_rt::{entry, syscall, Argv};

#[cfg(target_os = "none")]
fn main(_argc: usize, _argv: Argv) -> i32 {
    let _ = syscall::write_all(syscall::STDOUT, b"elf hello\n");
    0
}

#[cfg(target_os = "none")]
entry!(main);
