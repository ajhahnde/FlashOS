//! The shared EL0 runtime: process entry, panic/abort, raw syscalls, C strings,
//! and freestanding memory primitives.
//!
//! FlashOS enters an ELF at `_start` with `x0 = argc` and `x1 = argv`. Programs
//! install that symbol through [`entry!`]; the runtime calls their Rust main and
//! exits through the kernel ABI if it returns. No allocator or formatting engine
//! is involved.

#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]

mod memory;
pub mod syscall;

pub use memory::{cstr_bytes, cstr_len, memcmp, memcpy, memmove, memset, strlen};

/// A null-terminated vector of null-terminated byte-string pointers.
pub type Argv = *const *const u8;

/// Signature implemented by every ordinary Rust EL0 program.
pub type Main = fn(argc: usize, argv: Argv) -> i32;

/// Invoke an EL0 program body and terminate the process with its result.
#[doc(hidden)]
#[cfg(target_os = "none")]
pub fn run_main(argc: usize, argv: Argv, main: Main) -> ! {
    let status = main(argc, argv);
    syscall::exit(status)
}

/// Install the conventional FlashOS ELF entry point for a Rust program.
///
/// The generated `_start` preserves the AAPCS64 `x0`/`x1` argument placement
/// established by `sys_execve`, then delegates termination to the runtime.
#[macro_export]
macro_rules! entry {
    ($main:path) => {
        #[no_mangle]
        #[link_section = ".text._start"]
        pub extern "C" fn _start(argc: usize, argv: $crate::Argv) -> ! {
            $crate::run_main(argc, argv, $main)
        }
    };
}

#[cfg(target_os = "none")]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo<'_>) -> ! {
    // Fixed bytes only: pulling core::fmt into every ELF would consume the
    // kernel's fixed symbol/image budget for no useful recovery path.
    let _ = syscall::write_all(syscall::STDERR, b"[RUST-EL0] PANIC\n");
    syscall::exit(1)
}
