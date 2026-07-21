//! Round-robin scheduler state and task lifecycle.
//!
//! The retained AArch64 assembly owns the register swap and TTBR0 write. This
//! module owns task selection, state transitions, zombie teardown, and the
//! scheduler's global-state discipline. All scheduler-visible objects are
//! accessed through raw pointers: task records are also aliased by assembly,
//! IRQ handlers, wait queues, retained assembly, and sibling Rust modules.

use core::ptr::{addr_of, addr_of_mut, null_mut};

use flashos_kernel_abi::task::{
    CoreContext, FdSlot, MmStruct, UserPage, CWD_SIZE, FD_TABLE_SIZE, KTHREAD, MAX_PAGE_COUNT,
    TASK_INTERRUPTIBLE, TASK_RUNNING, TASK_ZOMBIE,
};

pub use flashos_kernel_abi::task::TaskStruct;

use crate::fdtable;

pub const NR_TASKS: usize = 64;

const EMPTY_USER_PAGE: UserPage = UserPage {
    pa: 0,
    uva: 0,
    flags: 0,
};

const EMPTY_FD: FdSlot = FdSlot {
    ptr: null_mut(),
    kind: 0,
    _pad: [0; 7],
};

const fn root_cwd() -> [u8; CWD_SIZE] {
    let mut cwd = [0; CWD_SIZE];
    cwd[0] = b'/';
    cwd
}

const fn initial_task() -> TaskStruct {
    TaskStruct {
        core_context: CoreContext {
            x19: 0,
            x20: 0,
            x21: 0,
            x22: 0,
            x23: 0,
            x24: 0,
            x25: 0,
            x26: 0,
            x27: 0,
            x28: 0,
            fp: 0,
            sp: 0,
            lr: 0,
        },
        state: TASK_RUNNING,
        counter: 0,
        priority: 1,
        preempt_count: 0,
        flags: KTHREAD,
        mm: MmStruct {
            pgd: 0,
            user_pages: [EMPTY_USER_PAGE; MAX_PAGE_COUNT],
            kernel_pages: [0; MAX_PAGE_COUNT],
            brk: 0,
        },
        parent: null_mut(),
        pid: 0,
        wq_next: null_mut(),
        fds: [EMPTY_FD; FD_TABLE_SIZE],
        cwd: root_cwd(),
        uid: 0,
        gid: 0,
        euid: 0,
        egid: 0,
        kstack: 0,
    }
}

static mut INIT_TASK: TaskStruct = initial_task();

// Cross-language scheduler storage, formerly provided by `src/sched.zig`'s
// `export var`. It stayed on the Zig side only so the last Flash/Zig consumers
// would reach it through a plain data symbol instead of a low-half GOT pointer
// that unmaps once TTBR0 switches to a user page table. Every consumer is now
// Rust, and the kernel ELF carries no GOT at all (all references are
// PC-relative to the high-VA alias), so the storage moves into the Rust image
// with no relocation hazard. The unmangled C names keep the sibling modules
// (fork, execve, kmain, the trace sampler) resolving the same four words.
#[cfg(target_os = "none")]
mod globals {
    use super::{TaskStruct, NR_TASKS};
    use core::ptr::null_mut;

    #[no_mangle]
    pub static mut current: *mut TaskStruct = null_mut();
    #[no_mangle]
    pub static mut task: [*mut TaskStruct; NR_TASKS] = [null_mut(); NR_TASKS];
    #[no_mangle]
    pub static mut nr_tasks: i32 = 1;
    #[no_mangle]
    pub static mut next_pid: i32 = 1;
}

#[cfg(target_os = "none")]
mod seam {
    use super::{TaskStruct, NR_TASKS};
    use core::ptr::{addr_of, addr_of_mut};

    unsafe extern "C" {
        static mut current: *mut TaskStruct;
        static mut task: [*mut TaskStruct; NR_TASKS];

        fn core_switch_to(previous: *mut TaskStruct, next: *mut TaskStruct);
        fn set_pgd(pgd: u64);
        fn irq_enable();
        fn irq_disable();
        fn free_page(page: u64);
        fn free_kernel_page(page: u64);

        #[link_name = "_schedule"]
        fn schedule_trampoline();
    }

    #[inline]
    pub unsafe fn current_task() -> *mut TaskStruct {
        // SAFETY: the scheduler serializes writes to its exported pointer.
        unsafe { addr_of!(current).read() }
    }

    #[inline]
    pub unsafe fn set_current(value: *mut TaskStruct) {
        // SAFETY: caller holds the scheduler's single-core exclusion rule.
        unsafe { addr_of_mut!(current).write(value) };
    }

    #[inline]
    pub fn task_base() -> *mut *mut TaskStruct {
        addr_of_mut!(task).cast::<*mut TaskStruct>()
    }

    #[inline]
    pub unsafe fn core_switch(previous: *mut TaskStruct, next: *mut TaskStruct) {
        // SAFETY: forwarded live-task/context-switch contract.
        unsafe { core_switch_to(previous, next) };
    }

    #[inline]
    pub unsafe fn switch_pgd(pgd: u64) {
        // SAFETY: caller supplies the live next task's PGD.
        unsafe { set_pgd(pgd) };
    }

    #[inline]
    pub unsafe fn enable_irqs() {
        // SAFETY: timer_tick mirrors the reference IRQ transition.
        unsafe { irq_enable() };
    }

    #[inline]
    pub unsafe fn disable_irqs() {
        // SAFETY: timer_tick mirrors the reference IRQ transition.
        unsafe { irq_disable() };
    }

    #[inline]
    pub unsafe fn free_user_page(page: u64) {
        // SAFETY: the zombie/unpublished child exclusively owns this page.
        unsafe { free_page(page) };
    }

    #[inline]
    pub unsafe fn free_task_page(page: u64) {
        // SAFETY: the reap path has unpublished every alias first.
        unsafe { free_kernel_page(page) };
    }

    #[inline]
    pub unsafe fn schedule_entry() {
        // SAFETY: caller preserves the patchable scheduler trampoline ABI.
        unsafe { schedule_trampoline() };
    }
}

#[cfg(not(target_os = "none"))]
mod seam {
    use super::{TaskStruct, NR_TASKS};
    use core::ptr::{addr_of, addr_of_mut, null_mut};

    #[cfg(test)]
    use core::sync::atomic::{AtomicUsize, Ordering};

    static mut CURRENT: *mut TaskStruct = null_mut();
    static mut TASKS: [*mut TaskStruct; NR_TASKS] = [null_mut(); NR_TASKS];

    #[cfg(test)]
    static FREED_PAGES: AtomicUsize = AtomicUsize::new(0);

    #[inline]
    pub unsafe fn current_task() -> *mut TaskStruct {
        // SAFETY: host scheduler tests are serialized around this local state.
        unsafe { addr_of!(CURRENT).read() }
    }

    #[inline]
    pub unsafe fn set_current(value: *mut TaskStruct) {
        // SAFETY: host scheduler tests are serialized around this local state.
        unsafe { addr_of_mut!(CURRENT).write(value) };
    }

    #[inline]
    pub fn task_base() -> *mut *mut TaskStruct {
        addr_of_mut!(TASKS).cast::<*mut TaskStruct>()
    }

    pub unsafe fn core_switch(_: *mut TaskStruct, _: *mut TaskStruct) {}
    pub unsafe fn switch_pgd(_: u64) {}
    pub unsafe fn enable_irqs() {}
    pub unsafe fn disable_irqs() {}

    pub unsafe fn free_user_page(_: u64) {
        #[cfg(test)]
        FREED_PAGES.fetch_add(1, Ordering::Relaxed);
    }

    pub unsafe fn free_task_page(_: u64) {}
    pub unsafe fn schedule_entry() {}

    #[cfg(test)]
    pub fn reset_free_count() {
        FREED_PAGES.store(0, Ordering::Relaxed);
    }

    #[cfg(test)]
    pub fn free_count() -> usize {
        FREED_PAGES.load(Ordering::Relaxed)
    }
}

#[inline]
unsafe fn task_at(index: usize) -> *mut TaskStruct {
    // SAFETY: callers prove `index < NR_TASKS`.
    unsafe { seam::task_base().add(index).read() }
}

#[inline]
unsafe fn set_task_at(index: usize, value: *mut TaskStruct) {
    // SAFETY: callers prove `index < NR_TASKS` and hold scheduler exclusion.
    unsafe { seam::task_base().add(index).write(value) };
}

/// The active task, as published by the scheduler.
///
/// The scheduler owns `current` and the task table; consumers that must read
/// them (the kill syscall walks the table) go through here rather than
/// redeclaring the globals, so the host build has one task state, not one per
/// module.
///
/// # Safety
/// Scheduler initialization has published a live current task.
pub unsafe fn current_task() -> *mut TaskStruct {
    // SAFETY: forwarded publication contract.
    unsafe { seam::current_task() }
}

/// Base of the scheduler's `NR_TASKS`-slot task table.
pub fn task_base() -> *mut *mut TaskStruct {
    seam::task_base()
}

/// Publish a current task and table contents for host tests.
///
/// # Safety
/// The caller owns the referenced storage for the duration of the test.
#[cfg(test)]
pub(crate) unsafe fn set_test_state(current: *mut TaskStruct, tasks: &[*mut TaskStruct]) {
    // SAFETY: the host suite drives this state single-threaded.
    unsafe {
        seam::set_current(current);
        let base = seam::task_base();
        let mut index = 0;
        while index < NR_TASKS {
            base.add(index)
                .write(tasks.get(index).copied().unwrap_or(core::ptr::null_mut()));
            index += 1;
        }
    }
}

/// Increment the active task's preemption nesting count.
///
/// # Safety
/// `current` identifies a live task on the single kernel core.
pub unsafe fn preempt_disable() {
    let active = unsafe { seam::current_task() };
    // SAFETY: the caller guarantees a live current task; raw access avoids a
    // reference to state also observed by the timer IRQ.
    unsafe {
        let field = addr_of_mut!((*active).preempt_count);
        field.write(field.read().wrapping_add(1));
    }
}

/// Decrement the active task's preemption nesting count.
///
/// # Safety
/// Matches a preceding [`preempt_disable`] for the live current task.
pub unsafe fn preempt_enable() {
    let active = unsafe { seam::current_task() };
    // SAFETY: forwarded current-task and nesting contract.
    unsafe {
        let field = addr_of_mut!((*active).preempt_count);
        field.write(field.read().wrapping_sub(1));
    }
}

/// Index of the running task with the highest counter. Ties keep the lower
/// index. The input is an array of raw task pointers; null slots are skipped.
///
/// # Safety
/// `tasks` points to `len` readable slots, and every non-null task remains live
/// for the duration of the scan.
pub unsafe fn pick_next_running(tasks: *const *mut TaskStruct, len: usize) -> Option<usize> {
    let mut best = None;
    let mut best_counter = -1i64;
    let mut index = 0;
    while index < len {
        // SAFETY: caller provides `len` readable slots.
        let candidate = unsafe { tasks.add(index).read() };
        if !candidate.is_null() {
            // SAFETY: non-null entries remain live for the scan.
            let state = unsafe { addr_of!((*candidate).state).read() };
            let counter = unsafe { addr_of!((*candidate).counter).read() };
            if state == TASK_RUNNING && counter > best_counter {
                best_counter = counter;
                best = Some(index);
            }
        }
        index += 1;
    }
    best
}

/// Refill every populated task counter to `(counter >> 1) + priority`.
///
/// # Safety
/// `tasks` points to `len` readable slots; non-null entries are live and may
/// have their counter updated under scheduler exclusion.
pub unsafe fn refill_counters(tasks: *const *mut TaskStruct, len: usize) {
    let mut index = 0;
    while index < len {
        // SAFETY: caller provides `len` readable slots.
        let candidate = unsafe { tasks.add(index).read() };
        if !candidate.is_null() {
            // SAFETY: caller permits the counter mutation for this live task.
            unsafe {
                let counter = addr_of_mut!((*candidate).counter);
                let priority = addr_of!((*candidate).priority).read();
                counter.write((counter.read() >> 1).wrapping_add(priority));
            }
        }
        index += 1;
    }
}

/// Mark `task` zombie and wake an interruptible parent.
///
/// # Safety
/// `task` and its non-null parent are live. Caller holds preemption exclusion.
pub unsafe fn zombify_and_wake_parent(task: *mut TaskStruct) {
    // SAFETY: forwarded live-task contract; raw writes preserve scheduler
    // aliases without manufacturing references.
    unsafe {
        addr_of_mut!((*task).state).write(TASK_ZOMBIE);
        let parent = addr_of!((*task).parent).read();
        if !parent.is_null() && addr_of!((*parent).state).read() == TASK_INTERRUPTIBLE {
            addr_of_mut!((*parent).state).write(TASK_RUNNING);
        }
    }
}

/// Body reached through the patchable `_schedule` assembly trampoline.
///
/// # Safety
/// Scheduler initialization has published a live current task and task table.
pub unsafe fn schedule_impl() {
    unsafe { preempt_disable() };
    let tasks = seam::task_base().cast_const();
    let selected = loop {
        if let Some(index) = unsafe { pick_next_running(tasks, NR_TASKS) } {
            let candidate = unsafe { task_at(index) };
            // SAFETY: the selected table entry is non-null and live.
            if unsafe { addr_of!((*candidate).counter).read() } != 0 {
                break candidate;
            }
        }
        unsafe { refill_counters(tasks, NR_TASKS) };
    };
    unsafe { switch_to(selected) };
    unsafe { preempt_enable() };
}

/// Yield the current task through the patchable scheduler entry.
///
/// # Safety
/// Scheduler initialization has published a live current task.
pub unsafe fn schedule() {
    let active = unsafe { seam::current_task() };
    // SAFETY: current is live; the counter is scheduler-owned state.
    unsafe { addr_of_mut!((*active).counter).write(0) };
    unsafe { seam::schedule_entry() };
}

/// Switch the active task, its TTBR0 user page table, and callee-saved context.
///
/// # Safety
/// `next` and `current` are live task records and scheduling is serialized.
pub unsafe fn switch_to(next: *mut TaskStruct) {
    let previous = unsafe { seam::current_task() };
    if previous == next {
        return;
    }
    unsafe { seam::set_current(next) };
    // SAFETY: next is live for the switch.
    let pgd = unsafe { addr_of!((*next).mm.pgd).read() };
    if pgd != 0 {
        unsafe { seam::switch_pgd(pgd) };
    }
    unsafe { seam::core_switch(previous, next) };
}

/// Account one timer tick and preempt when the current budget expires.
///
/// # Safety
/// Called from the serialized timer IRQ path after scheduler initialization.
pub unsafe fn timer_tick() {
    let active = unsafe { seam::current_task() };
    // SAFETY: timer IRQ owns the active task's tick update.
    let (counter, preempt_count) = unsafe {
        let counter_field = addr_of_mut!((*active).counter);
        let counter = counter_field.read().wrapping_sub(1);
        counter_field.write(counter);
        (counter, addr_of!((*active).preempt_count).read())
    };
    if counter > 0 || preempt_count > 0 {
        return;
    }
    // SAFETY: active remains live until the scheduler switches context.
    unsafe { addr_of_mut!((*active).counter).write(0) };
    unsafe { seam::enable_irqs() };
    unsafe { seam::schedule_entry() };
    unsafe { seam::disable_irqs() };
}

/// Mark the running task zombie, wake its parent, and yield forever.
///
/// # Safety
/// Called by the active task from serialized kernel context.
pub unsafe fn exit_process() {
    unsafe { preempt_disable() };
    let active = unsafe { seam::current_task() };
    unsafe { zombify_and_wake_parent(active) };
    unsafe { preempt_enable() };
    unsafe { schedule() };
}

/// Free every populated user-mapped and page-table page owned by `task`.
///
/// # Safety
/// `task` is an unpublished child or zombie exclusively owned by its reaper.
pub unsafe fn release_user_mm(task: *mut TaskStruct) {
    // SAFETY: caller exclusively owns this task's mm arrays.
    let user_pages = unsafe { addr_of!((*task).mm.user_pages).cast::<UserPage>() };
    let mut index = 0;
    while index < MAX_PAGE_COUNT {
        // SAFETY: fixed-size array bounds and exclusive teardown ownership.
        let page = unsafe { user_pages.add(index).read().pa };
        if page != 0 {
            unsafe { seam::free_user_page(page) };
        }
        index += 1;
    }

    // SAFETY: same exclusive mm ownership as above.
    let kernel_pages = unsafe { addr_of!((*task).mm.kernel_pages).cast::<u64>() };
    index = 0;
    while index < MAX_PAGE_COUNT {
        // SAFETY: fixed-size array bounds.
        let page = unsafe { kernel_pages.add(index).read() };
        if page != 0 {
            unsafe { seam::free_user_page(page) };
        }
        index += 1;
    }
}

/// Reap a zombie child, block until one exits, or return -1 with no children.
///
/// # Safety
/// Called by the active task from serialized syscall context.
pub unsafe fn do_wait_impl() -> i32 {
    unsafe { preempt_disable() };
    loop {
        let active = unsafe { seam::current_task() };
        let mut have_children = false;
        let mut index = 0;
        while index < NR_TASKS {
            let child = unsafe { task_at(index) };
            if !child.is_null() {
                // SAFETY: the published task entry stays live under preemption
                // exclusion until this function clears it.
                let is_child = unsafe { addr_of!((*child).parent).read() == active };
                if is_child {
                    have_children = true;
                    let state = unsafe { addr_of!((*child).state).read() };
                    if state == TASK_ZOMBIE {
                        let pid = unsafe { addr_of!((*child).pid).read() };
                        let kstack = unsafe { addr_of!((*child).kstack).read() };
                        unsafe { fdtable::close_all(child) };
                        unsafe { release_user_mm(child) };
                        unsafe { set_task_at(index, null_mut()) };
                        if kstack != 0 {
                            unsafe { seam::free_task_page(kstack) };
                        }
                        unsafe { seam::free_task_page(child as u64) };
                        unsafe { preempt_enable() };
                        return pid;
                    }
                }
            }
            index += 1;
        }

        if !have_children {
            unsafe { preempt_enable() };
            return -1;
        }

        // SAFETY: active remains the blocked parent until schedule switches.
        unsafe { addr_of_mut!((*active).state).write(TASK_INTERRUPTIBLE) };
        unsafe { preempt_enable() };
        unsafe { schedule() };
        unsafe { preempt_disable() };
    }
}

/// Publish the boot task as scheduler slot zero and current.
///
/// # Safety
/// Called once during single-core kernel bring-up before task creation.
pub unsafe fn sched_init() {
    let init = addr_of_mut!(INIT_TASK);
    unsafe { seam::set_current(init) };
    unsafe { set_task_at(0, init) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refill_counters_applies_half_plus_priority() {
        let mut first = TaskStruct {
            priority: 4,
            counter: 10,
            ..TaskStruct::default()
        };
        let mut second = TaskStruct {
            priority: 2,
            counter: 0,
            ..TaskStruct::default()
        };
        let tasks = [addr_of_mut!(first), null_mut(), addr_of_mut!(second)];
        unsafe { refill_counters(tasks.as_ptr(), tasks.len()) };
        assert_eq!(first.counter, 9);
        assert_eq!(second.counter, 2);
    }

    #[test]
    fn refill_counters_skips_null_slots() {
        let tasks = [null_mut(); 4];
        unsafe { refill_counters(tasks.as_ptr(), tasks.len()) };
    }

    #[test]
    fn refill_counters_arithmetic_shifts_negative_values() {
        let mut task = TaskStruct {
            priority: 5,
            counter: -3,
            ..TaskStruct::default()
        };
        let tasks = [addr_of_mut!(task)];
        unsafe { refill_counters(tasks.as_ptr(), tasks.len()) };
        assert_eq!(task.counter, 3);
    }

    #[test]
    fn pick_next_running_returns_highest_counter_index() {
        let mut first = TaskStruct {
            counter: 5,
            ..TaskStruct::default()
        };
        let mut second = TaskStruct {
            counter: 9,
            ..TaskStruct::default()
        };
        let mut third = TaskStruct {
            counter: 7,
            ..TaskStruct::default()
        };
        let tasks = [
            addr_of_mut!(first),
            addr_of_mut!(second),
            addr_of_mut!(third),
        ];
        assert_eq!(
            unsafe { pick_next_running(tasks.as_ptr(), tasks.len()) },
            Some(1)
        );
    }

    #[test]
    fn pick_next_running_ignores_non_running_tasks() {
        let mut zombie = TaskStruct {
            state: TASK_ZOMBIE,
            counter: 99,
            ..TaskStruct::default()
        };
        let mut sleeping = TaskStruct {
            state: TASK_INTERRUPTIBLE,
            counter: 50,
            ..TaskStruct::default()
        };
        let mut running = TaskStruct {
            counter: 3,
            ..TaskStruct::default()
        };
        let tasks = [
            addr_of_mut!(zombie),
            addr_of_mut!(sleeping),
            addr_of_mut!(running),
        ];
        assert_eq!(
            unsafe { pick_next_running(tasks.as_ptr(), tasks.len()) },
            Some(2)
        );
    }

    #[test]
    fn pick_next_running_returns_none_without_a_running_task() {
        let mut zombie = TaskStruct {
            state: TASK_ZOMBIE,
            ..TaskStruct::default()
        };
        let tasks = [addr_of_mut!(zombie), null_mut()];
        assert_eq!(
            unsafe { pick_next_running(tasks.as_ptr(), tasks.len()) },
            None
        );
    }

    #[test]
    fn pick_next_running_keeps_first_counter_tie() {
        let mut first = TaskStruct {
            counter: 5,
            ..TaskStruct::default()
        };
        let mut second = TaskStruct {
            counter: 5,
            ..TaskStruct::default()
        };
        let tasks = [addr_of_mut!(first), addr_of_mut!(second)];
        assert_eq!(
            unsafe { pick_next_running(tasks.as_ptr(), tasks.len()) },
            Some(0)
        );
    }

    #[test]
    fn zombify_wakes_an_interruptible_parent() {
        let mut parent = TaskStruct {
            state: TASK_INTERRUPTIBLE,
            ..TaskStruct::default()
        };
        let mut child = TaskStruct {
            parent: addr_of_mut!(parent),
            ..TaskStruct::default()
        };
        unsafe { zombify_and_wake_parent(addr_of_mut!(child)) };
        assert_eq!(child.state, TASK_ZOMBIE);
        assert_eq!(parent.state, TASK_RUNNING);
    }

    #[test]
    fn zombify_leaves_a_running_parent_running() {
        let mut parent = TaskStruct::default();
        let mut child = TaskStruct {
            parent: addr_of_mut!(parent),
            ..TaskStruct::default()
        };
        unsafe { zombify_and_wake_parent(addr_of_mut!(child)) };
        assert_eq!(child.state, TASK_ZOMBIE);
        assert_eq!(parent.state, TASK_RUNNING);
    }

    #[test]
    fn zombify_leaves_a_zombie_parent_zombie() {
        let mut parent = TaskStruct {
            state: TASK_ZOMBIE,
            ..TaskStruct::default()
        };
        let mut child = TaskStruct {
            parent: addr_of_mut!(parent),
            ..TaskStruct::default()
        };
        unsafe { zombify_and_wake_parent(addr_of_mut!(child)) };
        assert_eq!(child.state, TASK_ZOMBIE);
        assert_eq!(parent.state, TASK_ZOMBIE);
    }

    #[test]
    fn zombify_accepts_a_null_parent() {
        let mut child = TaskStruct::default();
        unsafe { zombify_and_wake_parent(addr_of_mut!(child)) };
        assert_eq!(child.state, TASK_ZOMBIE);
    }

    #[test]
    fn release_user_mm_frees_every_populated_page() {
        seam::reset_free_count();
        let mut task = TaskStruct::default();
        task.mm.user_pages[0].pa = 0x4000_1000;
        task.mm.user_pages[1].pa = 0x4000_2000;
        task.mm.kernel_pages[0] = 0x4000_3000;
        task.mm.kernel_pages[1] = 0x4000_4000;
        unsafe { release_user_mm(addr_of_mut!(task)) };
        assert_eq!(seam::free_count(), 4);
    }

    #[test]
    fn release_user_mm_is_a_noop_for_an_empty_mm() {
        seam::reset_free_count();
        let mut task = TaskStruct::default();
        unsafe { release_user_mm(addr_of_mut!(task)) };
        assert_eq!(seam::free_count(), 0);
    }
}
