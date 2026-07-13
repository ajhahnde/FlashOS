//! `/bin/grep`.
//!
//! Only the pattern matcher so far: the tool that drives it ports later, and this
//! crate carries no entry point until it does.

#![cfg_attr(not(test), no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

pub mod matcher;
