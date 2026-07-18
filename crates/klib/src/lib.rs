//! The kernel staticlib linked into `kernel8.elf`.
//!
//! It stays separate from the host-testable `flashos-kernel` rlib because a
//! bare-metal staticlib must carry a panic handler and the unmangled symbols the
//! retained assembly calls. Kernel logic remains in `flashos-kernel`; this crate
//! contains only that link facade and panic path.
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
