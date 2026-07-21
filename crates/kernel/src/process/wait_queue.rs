//! Blocking-syscall wait queue.
//!
//! Single source of truth for the kernel's block/wake discipline; a future
//! signal / `do_wait` migration reuses it. FlashOS is single-core:
//!
//! * The wait-side links the running task at the head, flips its state to
//!   `INTERRUPTIBLE`, drops preempt, then schedules. The wake-side reverses
//!   both (pop + flip to `RUNNING` + clear `wq_next`).
//! * `wq_next` lives in `TaskStruct` (crates/kernel-abi) — a task can only be on one
//!   queue at a time, mirroring Linux's `wq_node`.
//! * `preempt_disable` around the head mutation is enough on single core
//!   because no two callers can race on the same queue. IRQ callers (mini-UART
//!   RX) are fine because the entry path masks IRQs and there is no concurrent
//!   mutator from EL1h.
//!
//! The queue is embedded in aliasable memory (pipe pages, console statics), so
//! every operation is a raw-pointer free function: no Rust reference is formed
//! to a queue or task the scheduler or IRQ path may also touch.

use core::ptr::{addr_of, addr_of_mut, null_mut};

use flashos_kernel_abi::task::{TaskStruct, TASK_INTERRUPTIBLE, TASK_RUNNING};

/// Intrusive singly-linked wait queue head. The list threads through each
/// task's `wq_next`; an empty queue is a null head.
#[repr(C)]
pub struct WaitQueue {
    pub head: *mut TaskStruct,
}

impl WaitQueue {
    pub const fn new() -> Self {
        Self { head: null_mut() }
    }
}

impl Default for WaitQueue {
    fn default() -> Self {
        Self::new()
    }
}

const _: () = assert!(core::mem::size_of::<WaitQueue>() == 8);
const _: () = assert!(core::mem::align_of::<WaitQueue>() == 8);

// Kernel seam. In the freestanding build these resolve to the Flash scheduler's
// exported C symbols; direct `bl`/extern-static relocations the high-half linker
// fills correctly (no absolute Rust pointer table). On the host they are inert:
// the wake-side is exercised directly and the wait-side (which needs `current`
// and a real `schedule`) is covered by the in-kernel pipe/console scenarios.
#[cfg(target_os = "none")]
mod seam {
    use super::TaskStruct;

    unsafe extern "C" {
        pub fn preempt_disable();
        pub fn preempt_enable();
        pub fn schedule();
        pub static current: *mut TaskStruct;
    }

    /// The running task, or null when there is none.
    #[inline]
    pub unsafe fn current_task() -> *mut TaskStruct {
        // SAFETY: `current` is a scheduler-owned global pointer; we only read
        // its value. Single-core: no concurrent EL1h mutator during a
        // preempt-disabled section.
        unsafe { core::ptr::addr_of!(current).read() }
    }
}

#[cfg(not(target_os = "none"))]
mod seam {
    use super::TaskStruct;

    pub unsafe fn preempt_disable() {}
    pub unsafe fn preempt_enable() {}
    pub unsafe fn schedule() {}

    #[inline]
    pub unsafe fn current_task() -> *mut TaskStruct {
        core::ptr::null_mut()
    }
}

#[inline]
unsafe fn set_state(task: *mut TaskStruct, state: i64) {
    // SAFETY: caller supplies a live task; state is a plain i64 field.
    unsafe { addr_of_mut!((*task).state).write(state) };
}

#[inline]
unsafe fn wq_next(task: *mut TaskStruct) -> *mut TaskStruct {
    // SAFETY: caller supplies a live task.
    unsafe { addr_of!((*task).wq_next).read() }
}

#[inline]
unsafe fn set_wq_next(task: *mut TaskStruct, next: *mut TaskStruct) {
    // SAFETY: caller supplies a live task.
    unsafe { addr_of_mut!((*task).wq_next).write(next) };
}

/// Link the running task onto `queue` (idempotent) and mark it interruptible.
///
/// # Safety
/// `queue` points to a live `WaitQueue`; runs on the single kernel core.
pub unsafe fn prepare_to_wait(queue: *mut WaitQueue) {
    // SAFETY: single-core scheduler seam; forwarded queue contract.
    unsafe {
        seam::preempt_disable();
        let c = seam::current_task();
        if !c.is_null() {
            let head = addr_of!((*queue).head).read();
            // Link only if not already queued.
            if wq_next(c).is_null() && head != c {
                set_wq_next(c, head);
                addr_of_mut!((*queue).head).write(c);
            }
            set_state(c, TASK_INTERRUPTIBLE);
        }
        seam::preempt_enable();
    }
}

/// Wake the running task and unlink it from `queue` if still present.
///
/// # Safety
/// `queue` points to a live `WaitQueue`; runs on the single kernel core.
pub unsafe fn finish_wait(queue: *mut WaitQueue) {
    // SAFETY: single-core scheduler seam; forwarded queue contract.
    unsafe {
        seam::preempt_disable();
        let c = seam::current_task();
        if !c.is_null() {
            set_state(c, TASK_RUNNING);
            let head = addr_of!((*queue).head).read();
            if head == c {
                addr_of_mut!((*queue).head).write(wq_next(c));
                set_wq_next(c, null_mut());
            } else {
                let mut prev = head;
                while !prev.is_null() {
                    if wq_next(prev) == c {
                        set_wq_next(prev, wq_next(c));
                        set_wq_next(c, null_mut());
                        break;
                    }
                    prev = wq_next(prev);
                }
            }
        }
        seam::preempt_enable();
    }
}

/// Block the running task on `queue` until a wake pops it.
///
/// # Safety
/// `queue` points to a live `WaitQueue`; runs on the single kernel core.
pub unsafe fn wait(queue: *mut WaitQueue) {
    // SAFETY: single-core scheduler seam; forwarded queue contract.
    unsafe {
        seam::preempt_disable();
        let c = seam::current_task();
        if !c.is_null() {
            let head = addr_of!((*queue).head).read();
            if wq_next(c).is_null() && head != c {
                set_wq_next(c, head);
                addr_of_mut!((*queue).head).write(c);
            }
            set_state(c, TASK_INTERRUPTIBLE);
        }
        seam::preempt_enable();
        seam::schedule();
        finish_wait(queue);
    }
}

/// Pop and wake the head task, if any (LIFO — head-insert order).
///
/// # Safety
/// `queue` points to a live `WaitQueue`; runs on the single kernel core.
pub unsafe fn wake_one(queue: *mut WaitQueue) {
    // SAFETY: single-core scheduler seam; forwarded queue contract.
    unsafe {
        seam::preempt_disable();
        let head = addr_of!((*queue).head).read();
        if !head.is_null() {
            addr_of_mut!((*queue).head).write(wq_next(head));
            set_wq_next(head, null_mut());
            set_state(head, TASK_RUNNING);
        }
        seam::preempt_enable();
    }
}

/// Drain and wake every queued task, resetting each `wq_next` and state.
///
/// # Safety
/// `queue` points to a live `WaitQueue`; runs on the single kernel core.
pub unsafe fn wake_all(queue: *mut WaitQueue) {
    // SAFETY: single-core scheduler seam; forwarded queue contract.
    unsafe {
        seam::preempt_disable();
        let mut node = addr_of!((*queue).head).read();
        addr_of_mut!((*queue).head).write(null_mut());
        while !node.is_null() {
            let next = wq_next(node);
            set_wq_next(node, null_mut());
            set_state(node, TASK_RUNNING);
            node = next;
        }
        seam::preempt_enable();
    }
}

// ---- Host tests ----
//
// `schedule` is inert on the host, so these exercise the wake-side directly;
// the blocking wait-side is covered by the in-kernel pipe/console scenarios.
#[cfg(test)]
mod tests {
    use super::*;

    /// A task already parked in the interruptible state, so the wake-side's
    /// reset to `RUNNING` is an observable transition.
    fn waiter() -> TaskStruct {
        TaskStruct {
            state: TASK_INTERRUPTIBLE,
            ..TaskStruct::default()
        }
    }

    #[test]
    fn wake_one_pops_in_lifo_order() {
        let mut t1 = waiter();
        let mut t2 = waiter();
        let mut t3 = waiter();
        let mut q = WaitQueue::new();

        // Manual head-insert mirrors `wait` without the schedule round-trip.
        unsafe {
            t1.wq_next = null_mut();
            q.head = addr_of_mut!(t1);
            t2.wq_next = q.head;
            q.head = addr_of_mut!(t2);
            t3.wq_next = q.head;
            q.head = addr_of_mut!(t3);

            wake_one(addr_of_mut!(q));
        }
        assert_eq!(q.head, addr_of_mut!(t2));
        assert!(t3.wq_next.is_null());
        assert_eq!(t3.state, TASK_RUNNING);
        assert_eq!(t2.state, TASK_INTERRUPTIBLE);
    }

    #[test]
    fn wake_one_on_empty_queue_is_a_noop() {
        let mut q = WaitQueue::new();
        unsafe { wake_one(addr_of_mut!(q)) };
        assert!(q.head.is_null());
    }

    #[test]
    fn wake_all_drains_and_resets_state_and_wq_next() {
        let mut t1 = waiter();
        let mut t2 = waiter();
        let mut t3 = waiter();
        let mut q = WaitQueue::new();

        unsafe {
            t1.wq_next = null_mut();
            q.head = addr_of_mut!(t1);
            t2.wq_next = q.head;
            q.head = addr_of_mut!(t2);
            t3.wq_next = q.head;
            q.head = addr_of_mut!(t3);

            wake_all(addr_of_mut!(q));
        }
        assert!(q.head.is_null());
        assert!(t1.wq_next.is_null());
        assert!(t2.wq_next.is_null());
        assert!(t3.wq_next.is_null());
        assert_eq!(t1.state, TASK_RUNNING);
        assert_eq!(t2.state, TASK_RUNNING);
        assert_eq!(t3.state, TASK_RUNNING);
    }

    #[test]
    fn wake_all_on_empty_queue_is_a_noop() {
        let mut q = WaitQueue::new();
        unsafe { wake_all(addr_of_mut!(q)) };
        assert!(q.head.is_null());
    }
}
