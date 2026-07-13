//! A bump allocator over the kernel's `sbrk` -- the heap layer.
//!
//! State-free by design: every [`malloc`] is a thin `sbrk(+aligned_n)` that returns
//! the previous break as the pointer to the freshly-allocated region. No internal
//! bookkeeping means this layer emits no `.bss` / `.data`, which keeps a consuming
//! ELF at one PT_LOAD.
//!
//! The kernel rounds every break to a page, so this wastes the rest of the page
//! when the caller asks for less. That is deliberate at this scale; a free-list or
//! per-page sub-allocator is future work, and is why [`free`] is inert.

#[cfg(target_os = "none")]
use flashos_user_rt::syscall;

/// Every allocation is rounded up to this, so a returned pointer is safe to store
/// a 64-bit value through.
pub const ALIGN: u64 = 8;

/// Round `n` up to the allocation granularity -- the size [`malloc`] will actually
/// take from the break. Saturating, so a caller-supplied length near `u64::MAX`
/// cannot wrap to a small (and satisfiable) request.
pub const fn align_up(n: u64) -> u64 {
    n.saturating_add(ALIGN - 1) & !(ALIGN - 1)
}

/// Return a pointer to a freshly-allocated region of at least `n` bytes, or null on
/// failure. The memory is zeroed by the kernel on first touch, through the
/// demand-allocation path.
///
/// C's `malloc(0)` is implementation-defined; this returns null, so a caller must
/// distinguish an empty request from a failure itself.
#[cfg(target_os = "none")]
pub fn malloc(n: u64) -> *mut u8 {
    if n == 0 {
        return core::ptr::null_mut();
    }
    let previous_break = syscall::sbrk(align_up(n) as i64);
    if previous_break < 0 {
        return core::ptr::null_mut();
    }
    previous_break as usize as *mut u8
}

/// No-op. The bump allocator never reclaims an individual allocation; the kernel
/// reaps the whole heap when the process exits. Provided so a call site can keep
/// the alloc/free pairing readable even though the call is inert.
#[cfg(target_os = "none")]
pub fn free(_ptr: *mut u8) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allocations_round_up_to_the_eight_byte_granularity() {
        assert_eq!(align_up(1), 8);
        assert_eq!(align_up(8), 8);
        assert_eq!(align_up(9), 16);
    }

    #[test]
    fn a_near_maximal_request_saturates_instead_of_wrapping_to_a_small_one() {
        // A wrapping round-up would turn an absurd request into a satisfiable
        // 0-byte break move, and hand the caller a pointer to nothing.
        assert!(align_up(u64::MAX) >= u64::MAX - ALIGN);
        assert_ne!(align_up(u64::MAX), 0);
    }
}
