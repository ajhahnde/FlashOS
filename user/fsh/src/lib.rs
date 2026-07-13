//! The FlashOS shell.
//!
//! Only the pure engines so far: the shell's own body ports later, and this crate
//! carries no entry point until it does.

#![cfg_attr(not(test), no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

pub mod tokenize;
