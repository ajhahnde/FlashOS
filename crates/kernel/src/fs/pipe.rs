//! Anonymous SPSC byte pipe.
//!
//! One page per [`Pipe`]: the header at offset 0, the byte ring filling the rest
//! (`PAGE_SIZE - HEADER_SIZE`). `head`/`tail` are monotone u64 byte counters
//! indexed modulo `RING_CAP`, so full vs. empty is distinguishable without a
//! reserved slot. Page lifetime is owned by `Pipe.refs`, not `mm.*_pages`;
//! [`unref`] is the only path back to the allocator. Single-producer /
//! single-consumer per end.

use core::ptr::{addr_of, addr_of_mut, null_mut};

use crate::wait_queue::{self, WaitQueue};

pub const PAGE_SIZE: u64 = 1 << 12;

/// Pipe header. The ring data follows in the same page; see [`ring_base`].
#[repr(C)]
pub struct Pipe {
    pub refs: u32,
    _pad: u32,
    pub head: u64,
    pub tail: u64,
    pub readers_wq: WaitQueue,
    pub writers_wq: WaitQueue,
}

impl Pipe {
    pub const fn new() -> Self {
        Self {
            refs: 0,
            _pad: 0,
            head: 0,
            tail: 0,
            readers_wq: WaitQueue::new(),
            writers_wq: WaitQueue::new(),
        }
    }
}

impl Default for Pipe {
    fn default() -> Self {
        Self::new()
    }
}

pub const HEADER_SIZE: u64 = core::mem::size_of::<Pipe>() as u64;
pub const RING_CAP: u64 = PAGE_SIZE - HEADER_SIZE;

const _: () = assert!(core::mem::offset_of!(Pipe, refs) == 0);
const _: () = assert!(core::mem::offset_of!(Pipe, head) == 8);
const _: () = assert!(core::mem::offset_of!(Pipe, tail) == 16);
const _: () = assert!(core::mem::offset_of!(Pipe, readers_wq) == 24);
const _: () = assert!(core::mem::offset_of!(Pipe, writers_wq) == 32);
const _: () = assert!(HEADER_SIZE == 40);
const _: () = assert!(core::mem::align_of::<Pipe>() == 8);

// In the freestanding kernel build the page allocator hands out a physical
// address; the kernel reads/writes the page through its TTBR1 linear-map alias
// at `pa | LINEAR_MAP_BASE`. The host test build allocates from a static arena
// and returns a bare host VA — no alias, identity mapping.
#[cfg(target_os = "none")]
const LINEAR_MAP_BASE: u64 = 0xFFFF_0000_0000_0000;

#[cfg(target_os = "none")]
#[inline]
fn page_kva(pa: u64) -> u64 {
    pa | LINEAR_MAP_BASE
}

#[cfg(not(target_os = "none"))]
#[inline]
fn page_kva(pa: u64) -> u64 {
    pa
}

#[cfg(target_os = "none")]
#[inline]
fn page_pa(kva: u64) -> u64 {
    kva & !LINEAR_MAP_BASE
}

#[cfg(not(target_os = "none"))]
#[inline]
fn page_pa(kva: u64) -> u64 {
    kva
}

#[cfg(target_os = "none")]
mod seam {
    unsafe extern "C" {
        pub fn get_free_page() -> u64;
        pub fn free_page(page: u64);
        pub fn preempt_disable();
        pub fn preempt_enable();
        pub fn schedule();
    }
}

// Host seam: a leaking page bump-arena (the bump allocator never recycles) plus
// inert scheduler hooks. Atomic bump so parallel test threads never hand out
// the same page.
#[cfg(not(target_os = "none"))]
mod seam {
    use super::PAGE_SIZE;
    use core::sync::atomic::{AtomicUsize, Ordering};

    // Alignment-only storage: the bytes are addressed through raw pointers, so
    // the field itself is never read by name.
    #[repr(align(4096))]
    struct Page(#[allow(dead_code)] [u8; PAGE_SIZE as usize]);

    const PAGES: usize = 64;
    static mut ARENA: [Page; PAGES] = [const { Page([0; PAGE_SIZE as usize]) }; PAGES];
    static NEXT: AtomicUsize = AtomicUsize::new(0);

    pub unsafe fn get_free_page() -> u64 {
        let index = NEXT.fetch_add(1, Ordering::Relaxed);
        if index >= PAGES {
            return 0;
        }
        // SAFETY: `index < PAGES` selects a distinct in-bounds arena slot.
        unsafe { core::ptr::addr_of_mut!(ARENA).cast::<Page>().add(index) as u64 }
    }

    pub unsafe fn free_page(_page: u64) {}
    pub unsafe fn preempt_disable() {}
    pub unsafe fn preempt_enable() {}
    pub unsafe fn schedule() {}
}

#[inline]
unsafe fn ring_base(pipe: *mut Pipe) -> *mut u8 {
    // SAFETY: caller supplies a live one-page pipe; the ring starts one header
    // past the base and stays within the page.
    unsafe { (pipe as *mut u8).add(HEADER_SIZE as usize) }
}

#[inline]
unsafe fn count(pipe: *const Pipe) -> u64 {
    // SAFETY: caller supplies a live pipe.
    unsafe {
        let head = addr_of!((*pipe).head).read();
        let tail = addr_of!((*pipe).tail).read();
        head.wrapping_sub(tail)
    }
}

#[inline]
unsafe fn is_empty(pipe: *const Pipe) -> bool {
    // SAFETY: forwarded pipe contract.
    unsafe { addr_of!((*pipe).head).read() == addr_of!((*pipe).tail).read() }
}

#[inline]
unsafe fn is_full(pipe: *const Pipe) -> bool {
    // SAFETY: forwarded pipe contract.
    unsafe { count(pipe) == RING_CAP }
}

#[inline]
unsafe fn refs(pipe: *const Pipe) -> u32 {
    // SAFETY: forwarded pipe contract.
    unsafe { addr_of!((*pipe).refs).read() }
}

/// Allocate and zero a [`Pipe`]. Returns null on allocator failure. `refs`
/// starts at 0; the installer takes the first ref.
///
/// # Safety
/// Runs on the single kernel core.
pub unsafe fn alloc() -> *mut Pipe {
    // SAFETY: `get_free_page` yields a fresh writable page or 0.
    unsafe {
        let pa = seam::get_free_page();
        if pa == 0 {
            return null_mut();
        }
        let pipe = page_kva(pa) as *mut Pipe;
        core::ptr::write(pipe, Pipe::new());
        pipe
    }
}

/// Take one ref.
///
/// # Safety
/// `pipe` points to a live pipe; runs on the single kernel core.
pub unsafe fn pipe_ref(pipe: *mut Pipe) {
    // SAFETY: forwarded pipe contract.
    unsafe {
        seam::preempt_disable();
        let count = refs(pipe).wrapping_add(1);
        addr_of_mut!((*pipe).refs).write(count);
        seam::preempt_enable();
    }
}

/// Drop one ref. On the last drop, wake both wait queues (woken tasks observe
/// `refs == 0` on re-entry) and free the page.
///
/// # Safety
/// `pipe` points to a live pipe; runs on the single kernel core.
pub unsafe fn unref(pipe: *mut Pipe) {
    // SAFETY: forwarded pipe contract.
    unsafe {
        seam::preempt_disable();
        let count = refs(pipe).wrapping_sub(1);
        addr_of_mut!((*pipe).refs).write(count);
        let last = count == 0;
        seam::preempt_enable();
        if !last {
            return;
        }
        // Wake runs after the `refs == 0` decision. No other ref exists, so no
        // concurrent reader or writer can race the free.
        wait_queue::wake_all(addr_of_mut!((*pipe).readers_wq));
        wait_queue::wake_all(addr_of_mut!((*pipe).writers_wq));
        seam::free_page(page_pa(pipe as u64));
    }
}

/// Block until a byte is available, then drain up to `len` bytes. Returns 0 on
/// EOF (`refs <= 1` and empty: no writer can wake the reader). Negative is
/// reserved for future short-read errors.
///
/// # Safety
/// `pipe` is live, `buf` points to `len` writable bytes; single kernel core.
pub unsafe fn read(pipe: *mut Pipe, buf: *mut u8, len: u64) -> i64 {
    let mut written: u64 = 0;
    // SAFETY: forwarded pipe/buffer contract.
    unsafe {
        while written < len {
            wait_queue::prepare_to_wait(addr_of_mut!((*pipe).readers_wq));
            if is_empty(pipe) {
                // Last-writer-closed EOF: caller's fd is the only ref.
                if refs(pipe) <= 1 {
                    wait_queue::finish_wait(addr_of_mut!((*pipe).readers_wq));
                    break;
                }
                seam::schedule();
                continue;
            }
            wait_queue::finish_wait(addr_of_mut!((*pipe).readers_wq));
            seam::preempt_disable();
            let ring = ring_base(pipe);
            while written < len && !is_empty(pipe) {
                let tail = addr_of!((*pipe).tail).read();
                let byte = ring.add((tail % RING_CAP) as usize).read();
                buf.add(written as usize).write(byte);
                addr_of_mut!((*pipe).tail).write(tail.wrapping_add(1));
                written += 1;
            }
            seam::preempt_enable();
            wait_queue::wake_one(addr_of_mut!((*pipe).writers_wq));
            // One drain per call: short read is POSIX-conformant for pipes.
            break;
        }
        wait_queue::finish_wait(addr_of_mut!((*pipe).readers_wq));
    }
    written as i64
}

/// Push bytes until `len` are written or the pipe loses all readers. Returns the
/// number of bytes pushed; negative is reserved.
///
/// # Safety
/// `pipe` is live, `buf` points to `len` readable bytes; single kernel core.
pub unsafe fn write(pipe: *mut Pipe, buf: *const u8, len: u64) -> i64 {
    let mut pushed: u64 = 0;
    // SAFETY: forwarded pipe/buffer contract.
    unsafe {
        while pushed < len {
            wait_queue::prepare_to_wait(addr_of_mut!((*pipe).writers_wq));
            if is_full(pipe) {
                // Last reader closed. Short write of bytes pushed so far.
                // TODO: SIGPIPE / signal delivery not implemented.
                if refs(pipe) <= 1 {
                    wait_queue::finish_wait(addr_of_mut!((*pipe).writers_wq));
                    break;
                }
                seam::schedule();
                continue;
            }
            wait_queue::finish_wait(addr_of_mut!((*pipe).writers_wq));
            seam::preempt_disable();
            let ring = ring_base(pipe);
            while pushed < len && !is_full(pipe) {
                let head = addr_of!((*pipe).head).read();
                let byte = buf.add(pushed as usize).read();
                ring.add((head % RING_CAP) as usize).write(byte);
                addr_of_mut!((*pipe).head).write(head.wrapping_add(1));
                pushed += 1;
            }
            seam::preempt_enable();
            wait_queue::wake_one(addr_of_mut!((*pipe).readers_wq));
        }
        wait_queue::finish_wait(addr_of_mut!((*pipe).writers_wq));
    }
    pushed as i64
}

// ---- Host tests ----
#[cfg(test)]
mod tests {
    use super::*;

    /// Set `refs` without going through the ref/unref discipline (tests own the
    /// pipe exclusively). The host arena leaks — no `unref` is called.
    unsafe fn set_refs(pipe: *mut Pipe, value: u32) {
        unsafe { addr_of_mut!((*pipe).refs).write(value) };
    }

    #[test]
    fn empty_pipe_reports_empty_not_full_zero_count() {
        unsafe {
            let p = alloc();
            assert!(!p.is_null());
            set_refs(p, 1);
            assert!(is_empty(p));
            assert!(!is_full(p));
            assert_eq!(count(p), 0);
        }
    }

    #[test]
    fn write_then_read_round_trips_bytes() {
        unsafe {
            let p = alloc();
            assert!(!p.is_null());
            set_refs(p, 2); // two fds installed
            let payload = b"hello-pipe";
            let n_w = write(p, payload.as_ptr(), payload.len() as u64);
            assert_eq!(n_w, payload.len() as i64);
            assert_eq!(count(p), payload.len() as u64);

            let mut buf = [0u8; 16];
            let n_r = read(p, buf.as_mut_ptr(), payload.len() as u64);
            assert_eq!(n_r, payload.len() as i64);
            assert_eq!(&buf[..n_r as usize], payload);
            assert!(is_empty(p));
        }
    }

    #[test]
    fn head_tail_wraparound_preserves_byte_order() {
        unsafe {
            let p = alloc();
            assert!(!p.is_null());
            set_refs(p, 2);
            // Seed head/tail near wrap so the next write+read straddles modulo.
            addr_of_mut!((*p).head).write(RING_CAP - 4);
            addr_of_mut!((*p).tail).write(RING_CAP - 4);
            let payload = b"ABCDEFGH"; // 8 bytes — last 4 wrap to ring[0..4]
            write(p, payload.as_ptr(), payload.len() as u64);
            assert_eq!(count(p), 8);
            let mut buf = [0u8; 8];
            read(p, buf.as_mut_ptr(), payload.len() as u64);
            assert_eq!(&buf, payload);
        }
    }

    #[test]
    fn eof_empty_pipe_with_one_ref_returns_zero() {
        unsafe {
            let p = alloc();
            assert!(!p.is_null());
            set_refs(p, 1); // caller holds only the read end
            let mut buf = [0u8; 4];
            let n = read(p, buf.as_mut_ptr(), buf.len() as u64);
            assert_eq!(n, 0);
        }
    }

    #[test]
    fn is_full_and_is_empty_mutually_exclusive_at_boundaries() {
        unsafe {
            let p = alloc();
            assert!(!p.is_null());
            set_refs(p, 2);
            // count == 0 → empty, not full.
            assert!(is_empty(p));
            assert!(!is_full(p));
            // count == RING_CAP → full, not empty.
            addr_of_mut!((*p).head).write(RING_CAP);
            addr_of_mut!((*p).tail).write(0);
            assert!(is_full(p));
            assert!(!is_empty(p));
        }
    }
}
