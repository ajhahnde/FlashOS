//! Canonical syscall constants and `repr(C)` layouts shared by the kernel and
//! EL0, so the two sides of the ABI cannot drift apart.
//!
//! This crate owns *layout facts only* — the records, their field order, and the
//! numbers the syscall boundary and the assembly already agree on. The logic that
//! operates on them (the ELF parser, the `File` lifetime helpers, the fd table)
//! keeps its own home and moves in its own stage; a record living here does not
//! mean its module has been ported.
//!
//! Every layout carries compile-time size/alignment/offset assertions taken from
//! the pre-port reference build. They are the point of the crate: a reordered
//! field or a widened type would otherwise silently corrupt context switches and
//! on-disk records, and the assertions turn that into a build failure.
//!
//! Assembly consumes three of these facts by raw number
//! (`arch/aarch64/asm_defs_common.inc`): the exception-frame size, the syscall
//! dispatch cap, and the offset of `core_context` within `TaskStruct`.
//! `cargo xtask asm-defs --check` proves the include still agrees with what this
//! crate computes.

#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]

pub mod elf;
pub mod syscall;
pub mod task;
pub mod user;
