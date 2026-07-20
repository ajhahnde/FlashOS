//! Small portable base userspace library for FlashOS.
//!
//! This crate owns the thin io / process / heap / spawn helpers built directly
//! on the syscall wrappers in [`flashsdk_rt`]. Its public surface grows only
//! under the consumer-first rule: every item added after the seed names a
//! shipped production consumer and carries tests. No speculative POSIX layer,
//! convenience framework, or kernel-internal export.
#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]

pub mod execvp;
pub mod heap;
pub mod io;
pub mod process;
