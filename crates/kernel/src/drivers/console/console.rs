//! Board-agnostic console RX layer.
//!
//! A 256-byte single-producer / single-consumer ring buffered between the board
//! IRQ handler (mini-UART RX on Pi, PL011 RX on virt) and the unified `sys_read`
//! (slot 32) when it targets a console fd. The [`WaitQueue`] covers the
//! empty-ring blocking path; the wake-side fires from [`console_push`] when the
//! IRQ handler delivers a byte. The read-side drains short — the caller loops if
//! it needs N>1 bytes — matching POSIX TTY-read semantics and keeping the wait
//! discipline spurious-wake-free in one edge.
//!
//! Push and read are single-producer / single-consumer on single core: only the
//! entry path enters [`console_push`], only EL1 syscall context enters
//! [`console_read`]. Counter discipline mirrors [`crate::pipe`]: monotone u64
//! byte counters with modulo-indexed slot access, so full vs. empty is
//! distinguishable without a reserved slot.
//!
//! Echo policy lives in user space (future fsh) — `console_push` does not loop
//! the byte back through the TX path.

use core::cell::UnsafeCell;
use core::ptr::{addr_of, addr_of_mut, read_volatile, write_volatile};

use crate::wait_queue::{self, WaitQueue};

pub const RX_RING_SIZE: u64 = 256;

/// The production RX ring instance.
#[repr(C)]
pub struct ConsoleRx {
    ring: [u8; RX_RING_SIZE as usize],
    head: u64,
    tail: u64,
    wq: WaitQueue,
}

impl ConsoleRx {
    pub const fn new() -> Self {
        Self {
            ring: [0; RX_RING_SIZE as usize],
            head: 0,
            tail: 0,
            wq: WaitQueue::new(),
        }
    }
}

impl Default for ConsoleRx {
    fn default() -> Self {
        Self::new()
    }
}

struct Global(UnsafeCell<ConsoleRx>);

// SAFETY: single-core. The ring is a strict SPSC channel: the producer
// (`console_push`, IRQ context with IRQs masked at entry) only advances `head`,
// the consumer (`console_read`, EL1 syscall context) only advances `tail`. No
// two EL1h mutators race.
unsafe impl Sync for Global {}

static RX: Global = Global(UnsafeCell::new(ConsoleRx::new()));

#[inline]
fn production() -> *mut ConsoleRx {
    RX.0.get()
}

#[inline]
unsafe fn count(rx: *const ConsoleRx) -> u64 {
    // SAFETY: caller supplies a live ring; volatile reads keep an interrupting
    // producer visible.
    unsafe {
        let head = read_volatile(addr_of!((*rx).head));
        let tail = read_volatile(addr_of!((*rx).tail));
        head.wrapping_sub(tail)
    }
}

#[inline]
unsafe fn is_empty(rx: *const ConsoleRx) -> bool {
    // SAFETY: forwarded ring contract.
    unsafe { read_volatile(addr_of!((*rx).head)) == read_volatile(addr_of!((*rx).tail)) }
}

#[inline]
unsafe fn is_full(rx: *const ConsoleRx) -> bool {
    // SAFETY: forwarded ring contract.
    unsafe { count(rx) == RX_RING_SIZE }
}

#[cfg(target_os = "none")]
mod seam {
    unsafe extern "C" {
        pub fn preempt_disable();
        pub fn preempt_enable();
        pub fn schedule();
    }
}

#[cfg(not(target_os = "none"))]
mod seam {
    pub unsafe fn preempt_disable() {}
    pub unsafe fn preempt_enable() {}
    pub unsafe fn schedule() {}
}

/// Enqueue one byte from the board IRQ handler (IRQs masked at CPU level by the
/// exception entry). Drops the byte silently when the ring is full.
///
/// # Safety
/// `rx` points to a live ring; runs on the single kernel core.
unsafe fn push_impl(rx: *mut ConsoleRx, byte: u8) {
    // SAFETY: forwarded ring contract; SPSC producer advances only `head`.
    unsafe {
        if is_full(rx) {
            return;
        }
        let head = read_volatile(addr_of!((*rx).head));
        let index = (head % RX_RING_SIZE) as usize;
        write_volatile(addr_of_mut!((*rx).ring).cast::<u8>().add(index), byte);
        write_volatile(addr_of_mut!((*rx).head), head.wrapping_add(1));
        wait_queue::wake_one(addr_of_mut!((*rx).wq));
    }
}

/// Block until at least one byte is available, then drain up to `len` bytes (no
/// waiting for the full `len` — short reads are fine, the user wrapper loops).
/// Returns the number of bytes copied.
///
/// # Safety
/// `rx` points to a live ring, `buf` points to `len` writable bytes, and this
/// runs in EL1 syscall context on the single kernel core.
unsafe fn read_impl(rx: *mut ConsoleRx, buf: *mut u8, len: u64) -> i64 {
    if len == 0 {
        return 0;
    }
    let mut copied: u64 = 0;
    // SAFETY: forwarded ring/buffer contract.
    unsafe {
        while copied == 0 {
            wait_queue::prepare_to_wait(addr_of_mut!((*rx).wq));
            if !is_empty(rx) {
                wait_queue::finish_wait(addr_of_mut!((*rx).wq));
                seam::preempt_disable();
                while copied < len && !is_empty(rx) {
                    let tail = read_volatile(addr_of!((*rx).tail));
                    let index = (tail % RX_RING_SIZE) as usize;
                    let byte = read_volatile(addr_of!((*rx).ring).cast::<u8>().add(index));
                    write_volatile(buf.add(copied as usize), byte);
                    write_volatile(addr_of_mut!((*rx).tail), tail.wrapping_add(1));
                    copied += 1;
                }
                seam::preempt_enable();
                break;
            }
            seam::schedule();
        }
        wait_queue::finish_wait(addr_of_mut!((*rx).wq));
    }
    copied as i64
}

/// Debug-only sibling of [`push_impl`], called from EL1 syscall context
/// (`sys_console_inject`) — no IRQ-masking assumption, identical wake path.
///
/// # Safety
/// `rx` points to a live ring; runs on the single kernel core.
unsafe fn test_push_impl(rx: *mut ConsoleRx, byte: u8) {
    // SAFETY: forwarded ring contract.
    unsafe {
        seam::preempt_disable();
        if !is_full(rx) {
            let head = read_volatile(addr_of!((*rx).head));
            let index = (head % RX_RING_SIZE) as usize;
            write_volatile(addr_of_mut!((*rx).ring).cast::<u8>().add(index), byte);
            write_volatile(addr_of_mut!((*rx).head), head.wrapping_add(1));
        }
        seam::preempt_enable();
        wait_queue::wake_one(addr_of_mut!((*rx).wq));
    }
}

/// Enqueue one console byte from the board IRQ handler.
///
/// # Safety
/// Runs on the single kernel core; the caller is the exception entry path.
pub unsafe fn console_push(byte: u8) {
    // SAFETY: the production ring is live for the kernel lifetime.
    unsafe { push_impl(production(), byte) }
}

/// Drain up to `len` bytes into `buf`, blocking for the first byte.
///
/// # Safety
/// `buf` points to `len` writable bytes; EL1 syscall context.
pub unsafe fn console_read(buf: *mut u8, len: u64) -> i64 {
    // SAFETY: the production ring is live; buffer contract forwarded.
    unsafe { read_impl(production(), buf, len) }
}

/// Inject one byte from EL1 (deterministic console-echo coverage on QEMU).
///
/// # Safety
/// Runs on the single kernel core in EL1 syscall context.
pub unsafe fn console_test_push(byte: u8) {
    // SAFETY: the production ring is live for the kernel lifetime.
    unsafe { test_push_impl(production(), byte) }
}

// ---- Host tests ----
//
// `schedule` is inert on the host, so the blocking path is not host-testable
// (covered by the in-kernel run_console_echo scenario). These drive push/read
// on a stack-local ring — never the shared production static — so parallel test
// threads do not race, and assert ring bookkeeping plus wake-side wq state.
#[cfg(test)]
mod tests {
    use super::*;
    use flashos_abi::task::{TaskStruct, TASK_INTERRUPTIBLE, TASK_RUNNING};

    fn ring() -> ConsoleRx {
        ConsoleRx::new()
    }

    #[test]
    fn push_then_read_returns_the_byte() {
        let mut rx = ring();
        let mut buf = [0u8; 1];
        let n = unsafe {
            test_push_impl(addr_of_mut!(rx), 0x42);
            read_impl(addr_of_mut!(rx), buf.as_mut_ptr(), 1)
        };
        assert_eq!(n, 1);
        assert_eq!(buf[0], 0x42);
        assert!(unsafe { is_empty(addr_of!(rx)) });
    }

    #[test]
    fn ring_wraps_cleanly_when_head_crosses_size() {
        let mut rx = ring();
        // Seed near the wrap boundary so 8 pushes straddle modulo.
        rx.head = RX_RING_SIZE - 4;
        rx.tail = RX_RING_SIZE - 4;
        let mut buf = [0u8; 8];
        let n = unsafe {
            for i in 0..8u8 {
                test_push_impl(addr_of_mut!(rx), 0xC0 + i);
            }
            read_impl(addr_of_mut!(rx), buf.as_mut_ptr(), 8)
        };
        assert_eq!(n, 8);
        for i in 0..8u8 {
            assert_eq!(buf[i as usize], 0xC0 + i);
        }
    }

    #[test]
    fn is_full_rejects_further_pushes_silently() {
        let mut rx = ring();
        unsafe {
            for i in 0..RX_RING_SIZE as u32 {
                test_push_impl(addr_of_mut!(rx), i as u8);
            }
            assert!(is_full(addr_of!(rx)));
            let head_before = read_volatile(addr_of!(rx.head));
            test_push_impl(addr_of_mut!(rx), 0xFF);
            assert_eq!(read_volatile(addr_of!(rx.head)), head_before);
        }
    }

    #[test]
    fn test_push_wakes_a_fake_waiter() {
        let mut rx = ring();
        let mut t = TaskStruct {
            state: TASK_INTERRUPTIBLE,
            wq_next: core::ptr::null_mut(),
            ..TaskStruct::default()
        };
        rx.wq.head = addr_of_mut!(t);

        unsafe { test_push_impl(addr_of_mut!(rx), 0x55) };

        assert!(rx.wq.head.is_null());
        assert_eq!(t.state, TASK_RUNNING);
        assert!(t.wq_next.is_null());
    }

    #[test]
    fn short_read_drains_what_is_there() {
        let mut rx = ring();
        let mut buf = [0u8; 8];
        let n = unsafe {
            test_push_impl(addr_of_mut!(rx), 0xAA);
            test_push_impl(addr_of_mut!(rx), 0xBB);
            read_impl(addr_of_mut!(rx), buf.as_mut_ptr(), 8)
        };
        assert_eq!(n, 2);
        assert_eq!(buf[0], 0xAA);
        assert_eq!(buf[1], 0xBB);
    }

    #[test]
    fn empty_after_full_drain_restores_is_empty() {
        let mut rx = ring();
        let mut buf = [0u8; 2];
        unsafe {
            test_push_impl(addr_of_mut!(rx), 0x01);
            test_push_impl(addr_of_mut!(rx), 0x02);
            read_impl(addr_of_mut!(rx), buf.as_mut_ptr(), 2);
            assert!(is_empty(addr_of!(rx)));
            assert_eq!(count(addr_of!(rx)), 0);
        }
    }

    #[test]
    fn len_zero_read_returns_zero_without_blocking() {
        let mut rx = ring();
        let mut buf = [0u8; 1];
        let n = unsafe { read_impl(addr_of_mut!(rx), buf.as_mut_ptr(), 0) };
        assert_eq!(n, 0);
    }
}
