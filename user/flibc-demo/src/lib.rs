//! The flibc scenario's payload: exercises three flibc layers -- formatted output,
//! the bump allocator over the program break, and exit. fork, wait, and exec are
//! covered by the fork-stress and exec-elf scenarios through the same wrappers, so
//! this payload avoids a self-fork and stays a single loadable segment.
//!
//! The trace contract the scenario asserts:
//!
//! ```text
//! flibc hello 42      -- the integer round-trip
//! flibc malloc ok     -- 32 bytes bump-allocated, written, and verified
//! ```
//!
//! The entry is bespoke: the kernel enters at `_start` and this payload takes no
//! arguments, so it installs the symbol itself rather than going through the
//! runtime's argc/argv shim.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_flibc::{
    heap::malloc,
    printf, puts,
    Part::{Dec, Str},
};
#[cfg(target_os = "none")]
use flashsdk_rt::syscall;

#[cfg(target_os = "none")]
const ALLOC_BYTES: u64 = 32;

#[cfg(target_os = "none")]
#[no_mangle]
#[link_section = ".text._start"]
pub extern "C" fn _start() -> ! {
    printf(&[Str(b"flibc hello "), Dec(42), Str(b"\n")]);

    let buf = malloc(ALLOC_BYTES);
    if buf.is_null() {
        puts(b"flibc malloc fail");
        syscall::exit(0)
    }

    // Demand-allocate the heap page on the first write: the kernel classifies the
    // fault as in-range heap and stamps a fresh page before retrying. The pattern is
    // round-trip-verified below, so a stale TLB or a wrong physical page surfaces as
    // a "bad" line in the trace instead of a silent pass.
    let buf = unsafe { core::slice::from_raw_parts_mut(buf, ALLOC_BYTES as usize) };
    for (i, slot) in buf.iter_mut().enumerate() {
        *slot = (i as u8).wrapping_add(0x55);
    }
    let ok = buf
        .iter()
        .enumerate()
        .all(|(i, &b)| b == (i as u8).wrapping_add(0x55));

    puts(if ok {
        b"flibc malloc ok".as_slice()
    } else {
        b"flibc malloc bad".as_slice()
    });
    syscall::exit(0)
}
