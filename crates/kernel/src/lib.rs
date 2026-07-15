//! The `no_std` kernel and its board modules.
//!
//! This crate is the Rust-owned half of the kernel's logic, and it is a plain
//! `no_std` library: it links nothing, exports no C ABI, and carries no panic
//! handler, so it compiles for the host and its tests run in the ordinary host
//! suite. `crates/klib` wraps it in the staticlib the Zig-linked `kernel8.elf`
//! swallows during the mixed-language bridge, and owns the C-ABI seam and the
//! panic path — both of which disappear once the last Flash module is gone.

#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(test)]
extern crate std;

pub mod block_dev;
pub mod elf;
pub mod fat32;
pub mod fat32_backend;
pub mod file;
pub mod initramfs;
pub mod initramfs_backend;
pub mod klog_ring;
pub mod mailbox;
pub mod overlay;
pub mod path;
pub mod perm;
pub mod sdhci_cmd;
pub mod sha256;
pub mod shadow;
pub mod usb_descriptors;
pub mod usb_tx_ring;
pub mod vfs;
