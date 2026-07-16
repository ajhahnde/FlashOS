//! The kernel staticlib: the archive the Zig-linked `kernel8.elf` swallows.
//!
//! Transitional by construction. It exists because two languages currently share
//! one kernel image: `ffi` is the only surface the remaining Flash code sees, and
//! the panic handler below is the one a bare-metal Rust archive must carry. The
//! kernel's actual logic lives in `flashos-kernel`, which stays a plain host-
//! testable library. When the last Flash module ports, the kernel links from Rust
//! directly and this crate is deleted whole.
//!
//! `memcpy`/`memset` are the kernel's own, and `ffi` exports them from here.
//! Their strong definitions override the weak ones `compiler_builtins` carries,
//! so what the image links is the kernel's byte loop and not a wide-load copy
//! that would fault against `SCTLR_EL1.A`. The symbol gate proves that on every
//! build.

#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]

pub mod ffi;

/// Kernel-side panic path.
///
/// Routes into the kernel's own panic, so a Rust panic is observably the same
/// event as any other kernel panic — same marker, same halt. The
/// message is a fixed NUL-terminated literal, never formatted: pulling
/// `core::fmt` in here would multiply the symbol table against a fixed 128 KiB
/// budget, for output nobody reads.
#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    // SAFETY: the kernel's panic never returns and takes a NUL-terminated string;
    // this literal is static and NUL-terminated.
    unsafe { ffi::panic(c"rust: panic".as_ptr() as *const u8) }
}
