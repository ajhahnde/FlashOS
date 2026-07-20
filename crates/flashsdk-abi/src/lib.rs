//! Public FlashOS syscall ABI.
//!
//! This crate owns *public layout facts only* — the syscall identifiers, the
//! errno surface, the records, and the user virtual-address constants that the
//! syscall boundary and the EL0 wrappers already agree on. A record living here
//! is a fact both sides of the ABI share; kernel-private task/register/file and
//! ELF-loader layouts, and the page-descriptor bits, deliberately live in the
//! FlashOS repository.
//!
//! Every layout carries compile-time size/alignment/offset assertions taken from
//! the pre-port reference build. They are the point of the crate: a reordered
//! field or a widened type would otherwise silently corrupt on-disk records or
//! misalign the syscall boundary, and the assertions turn that into a build
//! failure.
//!
//! `NR_SYSCALLS` is the one fact here the kernel dispatch also consumes by raw
//! number (`arch/aarch64/asm_defs_common.inc`); `cargo xtask asm-defs --check`
//! on the FlashOS side proves the include still agrees with what this crate
//! computes.

#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]

pub mod syscall;
pub mod user;
