//! The `no_std` kernel and its board modules.
//!
//! This crate owns the kernel's logic, and it is a plain
//! `no_std` library: it links nothing, exports no C ABI, and carries no panic
//! handler, so it compiles for the host and its tests run in the ordinary host
//! suite. `crates/klib` wraps it in the staticlib linked into `kernel8.elf` and
//! owns the unmangled ABI facade plus the bare-metal panic path required by the
//! retained assembly.

#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(test)]
extern crate std;

pub mod diagnostics;
pub mod drivers;
pub mod fs;
pub mod kmain;
pub mod mm;
pub mod process;
pub mod security;
pub mod syscall;
pub mod util;

// Flat re-exports preserving the pre-grouping module paths. Assembly, the
// `crates/klib` ABI seam, and `xtask` address these services by their original
// names; keeping them here confines the grouping to the module tree.
pub use crate::diagnostics::{generic_timer, trace};
pub use crate::drivers::block::{block_dev, sdhci_cmd};
pub use crate::drivers::console::{console, klog_ring};
pub use crate::drivers::platform::rpi4b::{
    emmc2 as rpi4b_emmc2, gpio as rpi4b_gpio, irq as rpi4b_irq, mailbox as rpi4b_mailbox,
    power as rpi4b_power, timer as rpi4b_timer, uart as rpi4b_uart, usb as rpi4b_usb,
};
pub use crate::drivers::usb::{usb_descriptors, usb_tx_ring};
pub use crate::fs::{
    fat32, fat32_backend, fdtable, file, initramfs, initramfs_backend, overlay, path, perm, pipe,
    vfs,
};
pub use crate::mm::{page_alloc, user as mm_user};
pub use crate::process::{elf, execve, fork, sched, wait_queue};
pub use crate::security::{hwrng, sha256, shadow};
pub use crate::syscall::sys;
pub use crate::util::{mailbox, utilc};
