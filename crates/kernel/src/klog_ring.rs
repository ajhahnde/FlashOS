//! Overwrite-oldest byte ring backing the kernel log.
//!
//! The ring is shared with the remaining Flash kernel through a fixed C layout.
//! Its raw-pointer operations deliberately avoid creating references: logging
//! may be interrupted and re-entered on the same core, so an outstanding Rust
//! reference would claim aliasing guarantees that the bridge cannot provide.

use core::ptr::{addr_of, addr_of_mut, read_volatile, write_volatile};

use flashos_abi::syscall::KLOG_SIZE;

pub const SIZE: usize = KLOG_SIZE as usize;

#[repr(C)]
pub struct Ring<const N: usize> {
    pub buf: [u8; N],
    pub head: u64,
    pub tail: u64,
}

pub type KlogRing = Ring<SIZE>;

impl<const N: usize> Ring<N> {
    pub const fn new() -> Self {
        Self {
            buf: [0; N],
            head: 0,
            tail: 0,
        }
    }
}

impl<const N: usize> Default for Ring<N> {
    fn default() -> Self {
        Self::new()
    }
}

const _: () = assert!(SIZE > 0);
const _: () = assert!(core::mem::offset_of!(KlogRing, head) == SIZE);
const _: () = assert!(core::mem::offset_of!(KlogRing, tail) == SIZE + 8);
const _: () = assert!(core::mem::size_of::<KlogRing>() == SIZE + 16);
const _: () = assert!(core::mem::align_of::<KlogRing>() == 8);

/// Return the number of retained bytes.
///
/// # Safety
/// `ring` must point to a live `Ring<N>` for the duration of the call.
pub unsafe fn available<const N: usize>(ring: *const Ring<N>) -> u64 {
    // SAFETY: the caller supplies a live ring. Volatile field reads prevent an
    // interrupting writer from being hidden behind cached values.
    let head = unsafe { read_volatile(addr_of!((*ring).head)) };
    // SAFETY: same live ring and field-read argument as above.
    let tail = unsafe { read_volatile(addr_of!((*ring).tail)) };
    head.wrapping_sub(tail)
}

/// Read the byte at an absolute monotone ring position.
///
/// # Safety
/// `ring` must point to a live non-zero-capacity `Ring<N>`.
pub unsafe fn byte_at<const N: usize>(ring: *const Ring<N>, pos: u64) -> u8 {
    debug_assert!(N > 0);
    let index = (pos % N as u64) as usize;
    // SAFETY: the modulo index is within the caller-provided live ring.
    let byte = unsafe { addr_of!((*ring).buf).cast::<u8>().add(index) };
    // SAFETY: `byte` points into the live ring buffer.
    unsafe { read_volatile(byte) }
}

/// Append one byte, overwriting the oldest byte when full.
///
/// # Safety
/// `ring` must point to a live non-zero-capacity `Ring<N>` whose storage may be
/// mutated for the duration of this call.
pub unsafe fn push<const N: usize>(ring: *mut Ring<N>, byte: u8) {
    debug_assert!(N > 0);
    // SAFETY: the caller supplies a live writable ring.
    let head = unsafe { read_volatile(addr_of!((*ring).head)) };
    let index = (head % N as u64) as usize;
    // SAFETY: the modulo index is within the writable ring buffer.
    let slot = unsafe { addr_of_mut!((*ring).buf).cast::<u8>().add(index) };
    // SAFETY: `slot` points into the writable ring buffer.
    unsafe { write_volatile(slot, byte) };

    let new_head = head.wrapping_add(1);
    // SAFETY: the head field belongs to the writable ring.
    unsafe { write_volatile(addr_of_mut!((*ring).head), new_head) };
    // SAFETY: the tail field belongs to the same live ring.
    let tail = unsafe { read_volatile(addr_of!((*ring).tail)) };
    if new_head.wrapping_sub(tail) > N as u64 {
        // SAFETY: the tail field belongs to the writable ring.
        unsafe { write_volatile(addr_of_mut!((*ring).tail), new_head.wrapping_sub(N as u64)) };
    }
}

/// Append a NUL-terminated byte string.
///
/// # Safety
/// `ring` satisfies [`push`]'s contract and `string` points to a readable,
/// NUL-terminated byte sequence.
pub unsafe fn push_c_str<const N: usize>(ring: *mut Ring<N>, string: *const u8) {
    let mut offset = 0usize;
    loop {
        // SAFETY: the caller guarantees a readable NUL-terminated sequence.
        let byte = unsafe { read_volatile(string.add(offset)) };
        if byte == 0 {
            return;
        }
        // SAFETY: forwarded from this function's ring contract.
        unsafe { push(ring, byte) };
        offset = offset.wrapping_add(1);
    }
}

/// Copy the newest retained window into `dst`, oldest byte first.
///
/// # Safety
/// `ring` points to a live non-zero-capacity ring and `dst` points to
/// `dst_len` writable bytes. The regions must not overlap.
pub unsafe fn snapshot<const N: usize>(
    ring: *const Ring<N>,
    dst: *mut u8,
    dst_len: usize,
) -> usize {
    // SAFETY: forwarded from this function's ring contract.
    let retained = unsafe { available(ring) };
    let count = core::cmp::min(retained, dst_len as u64) as usize;
    // Read head once, matching the old snapshot arithmetic.
    // SAFETY: the caller supplies a live ring.
    let head = unsafe { read_volatile(addr_of!((*ring).head)) };
    let start = head.wrapping_sub(count as u64);
    let mut i = 0usize;
    while i < count {
        // SAFETY: the selected position is inside the retained window.
        let byte = unsafe { byte_at(ring, start.wrapping_add(i as u64)) };
        // SAFETY: `i < dst_len`, and the caller guarantees writable storage.
        unsafe { write_volatile(dst.add(i), byte) };
        i += 1;
    }
    count
}

#[cfg(test)]
mod tests {
    use super::{available, push, snapshot, Ring, SIZE};

    type Ring8 = Ring<8>;

    fn push_bytes<const N: usize>(ring: &mut Ring<N>, bytes: &[u8]) {
        for &byte in bytes {
            // SAFETY: the stack-owned ring is live and exclusively used here.
            unsafe { push(ring, byte) };
        }
    }

    fn retained<const N: usize>(ring: &Ring<N>) -> u64 {
        // SAFETY: the stack-owned ring is live for this call.
        unsafe { available(ring) }
    }

    fn take_snapshot<const N: usize>(ring: &Ring<N>, dst: &mut [u8]) -> usize {
        // SAFETY: both stack-owned regions are live and do not overlap.
        unsafe { snapshot(ring, dst.as_mut_ptr(), dst.len()) }
    }

    #[test]
    fn push_then_snapshot_round_trips_bytes_in_order() {
        let mut ring = Ring8::new();
        assert_eq!(retained(&ring), 0);
        push_bytes(&mut ring, b"abc");
        assert_eq!(retained(&ring), 3);
        let mut buf = [0; 8];
        assert_eq!(take_snapshot(&ring, &mut buf), 3);
        assert_eq!(&buf[..3], b"abc");
        assert_eq!(retained(&ring), 3);
    }

    #[test]
    fn overwrite_oldest_keeps_the_most_recent_capacity_bytes() {
        let mut ring = Ring8::new();
        push_bytes(&mut ring, b"0123456789");
        assert_eq!(retained(&ring), 8);
        let mut buf = [0; 8];
        assert_eq!(take_snapshot(&ring, &mut buf), 8);
        assert_eq!(&buf, b"23456789");
    }

    #[test]
    fn snapshot_caps_to_destination_and_returns_the_recent_tail() {
        let mut ring = Ring8::new();
        push_bytes(&mut ring, b"ABCDE");
        let mut small = [0; 3];
        assert_eq!(take_snapshot(&ring, &mut small), 3);
        assert_eq!(&small, b"CDE");
    }

    #[test]
    fn snapshot_on_an_empty_ring_copies_nothing() {
        let ring = Ring8::new();
        let mut buf = [0; 8];
        assert_eq!(take_snapshot(&ring, &mut buf), 0);
    }

    #[test]
    fn snapshot_clamps_to_available_when_destination_is_larger() {
        let mut ring = Ring8::new();
        push_bytes(&mut ring, b"hi");
        let mut buf = [0; 8];
        assert_eq!(take_snapshot(&ring, &mut buf), 2);
        assert_eq!(&buf[..2], b"hi");
    }

    #[test]
    fn a_recent_marker_survives_an_overwrite() {
        let mut ring = Ring8::new();
        for _ in 0..50 {
            // SAFETY: the stack-owned ring is live and exclusively used here.
            unsafe { push(&mut ring, b'.') };
        }
        push_bytes(&mut ring, b"klog");
        let mut buf = [0; 8];
        let count = take_snapshot(&ring, &mut buf);
        assert_eq!(&buf[count - 4..count], b"klog");
    }

    #[test]
    fn counters_remain_ordered_across_u64_wraparound() {
        let mut ring = Ring8::new();
        ring.head = u64::MAX - 2;
        ring.tail = u64::MAX - 2;
        assert_eq!(retained(&ring), 0);
        push_bytes(&mut ring, b"XYZ");
        assert_eq!(retained(&ring), 3);
        let mut buf = [0; 8];
        assert_eq!(take_snapshot(&ring, &mut buf), 3);
        assert_eq!(&buf[..3], b"XYZ");
    }

    #[test]
    fn shipping_ring_overwrites_at_the_exact_boundary() {
        let mut ring = Ring::<SIZE>::new();
        for _ in 0..SIZE {
            // SAFETY: the stack-owned ring is live and exclusively used here.
            unsafe { push(&mut ring, b'a') };
        }
        assert_eq!(retained(&ring), SIZE as u64);
        // SAFETY: the stack-owned ring is live and exclusively used here.
        unsafe { push(&mut ring, b'Z') };
        assert_eq!(retained(&ring), SIZE as u64);
        let mut tail = [0];
        assert_eq!(take_snapshot(&ring, &mut tail), 1);
        assert_eq!(tail[0], b'Z');
    }
}
