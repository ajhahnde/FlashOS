//! Canonical syscall constants and `repr(C)` layouts shared by the kernel and
//! EL0, so the two sides of the ABI cannot drift apart.
//!
//! Placeholder: the crate exists so the workspace, build pipeline, and CI are in
//! place before any product code is translated.

#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]
