//! Kernel-private `repr(C)` layouts the kernel and its assembly agree on. EL0
//! never sees these: the public syscall ABI and the user virtual-address layout
//! live in the FlashSDK `flashsdk_abi` crate, which both sides consume.
//!
//! This crate owns *kernel-private layout facts only* — the task/register/fd
//! records, the ELF-loader records, and the user-page descriptor bits. The logic
//! that operates on them (the ELF parser, the `File` lifetime helpers, the fd
//! table) keeps its own home; a record living here does not mean its module has
//! been ported.
//!
//! Every layout carries compile-time size/alignment/offset assertions taken from
//! the pre-port reference build. They are the point of the crate: a reordered
//! field or a widened type would otherwise silently corrupt context switches and
//! on-disk records, and the assertions turn that into a build failure.
//!
//! Assembly consumes two of these facts by raw number
//! (`arch/aarch64/asm_defs_common.inc`): the exception-frame size and the offset
//! of `core_context` within `TaskStruct`. The third assembly-visible fact, the
//! syscall dispatch cap, is a public constant and lives in `flashsdk_abi`.
//! `cargo xtask asm-defs --check` proves the include still agrees with what the
//! two crates compute.

#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]

pub mod elf;
pub mod task;
pub mod user;
