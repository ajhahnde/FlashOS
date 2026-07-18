//! Statistical kernel profiler — the trace sampler.
//!
//! Reached from `handle_irq` BEFORE `timer_tick`, with the saved exception frame
//! the entry stub (`arch/aarch64/entry.S`) built at the kernel SP. We run in IRQ
//! context: TTBR0 may still hold the interrupted user process's pgd, so we touch
//! only globals reachable from there — `current` (exactly what `timer_tick`
//! dereferences in the same context) and the symbol table via `ksyms` (which
//! promotes its own low-VA literal to the linear-map alias). The current task's
//! `KeRegs` lives on the kernel stack we are executing on, so the frame is always
//! readable.
//!
//! The walk is allocation-free, lock-free and fault-free by construction: every
//! step is bounded by the current task's kernel-stack page plus a monotonic
//! frame-pointer guard, so a garbage FP terminates the walk rather than faulting.
//! This is a *statistical* profiler — leaf frames and hand-written-asm frames
//! that carry no standard AAPCS64 frame record are simply skipped.

use flashos_abi::task::KeRegs;

use crate::trace::{fp_walk, ksyms};
use crate::utilc;

const PAGE_SIZE: u64 = 1 << 12;
/// Boot console: the Mini-UART. (The dedicated trace UART is deliberately not
/// used here, so a sample lands on the same cable as the rest of the boot log.)
const MU: i32 = utilc::MU;
const MAX_DEPTH: usize = 32;

#[cfg(target_os = "none")]
mod seam {
    use flashos_abi::task::TaskStruct;

    unsafe extern "C" {
        /// The same global `timer_tick` reads; reachable from IRQ context.
        static mut current: *mut TaskStruct;
    }

    /// # Safety
    /// The scheduler owns writes to the exported pointer.
    #[inline]
    pub unsafe fn current_task() -> *mut TaskStruct {
        // SAFETY: forwarded scheduler-ownership contract.
        unsafe { core::ptr::addr_of!(current).read() }
    }

    /// Free-running physical counter — the wall clock the throttle rate-limits
    /// against, the same clock `rpi4b_usb` and `delay_us` read.
    #[inline]
    pub fn now_ticks() -> u64 {
        let value: u64;
        // SAFETY: CNTPCT_EL0 is an unprivileged read with no side effects.
        unsafe {
            core::arch::asm!("mrs {v}, cntpct_el0", v = out(reg) value,
                options(nomem, nostack, preserves_flags));
        }
        value
    }

    /// Generic-timer frequency the firmware programmed (Hz), or 0 if unset.
    #[inline]
    pub fn clock_hz() -> u64 {
        let value: u64;
        // SAFETY: CNTFRQ_EL0 is an unprivileged read with no side effects.
        unsafe {
            core::arch::asm!("mrs {v}, cntfrq_el0", v = out(reg) value,
                options(nomem, nostack, preserves_flags));
        }
        value
    }
}

#[cfg(not(target_os = "none"))]
mod seam {
    use flashos_abi::task::TaskStruct;

    /// Host builds have no scheduler. Tests stage the task the sampler will see.
    pub static mut CURRENT: *mut TaskStruct = core::ptr::null_mut();

    /// # Safety
    /// The host suite serializes access to the staged pointer.
    #[inline]
    pub unsafe fn current_task() -> *mut TaskStruct {
        // SAFETY: callers hold the module's test lock.
        unsafe { CURRENT }
    }

    /// Host builds have no generic timer; the throttle is exercised through the
    /// pure `should_sample` decision instead.
    #[inline]
    pub fn now_ticks() -> u64 {
        0
    }

    /// Host builds have no generic timer.
    #[inline]
    pub fn clock_hz() -> u64 {
        0
    }
}

/// Wall-clock throttle: emit at most one backtrace per this many seconds. The
/// sampler runs at the head of `handle_irq`, which fires on **every** interrupt
/// (timer, mini-UART RX, generic timer), so the emit rate follows the IRQ rate —
/// under load that is thousands per second, not the ~1 Hz the timer tick alone
/// would give. A call-counter throttle cannot bound that — it would saturate the
/// UART and wedge the console; rate-limiting against the free-running counter caps
/// the output no matter how fast interrupts arrive.
const THROTTLE_SECS: u64 = 1;
/// CNTPCT value at the last emitted sample. `0` means "never sampled".
static mut LAST_EMIT: u64 = 0;
/// Monotonic count of *emitted* samples — the number printed in the `tick=`
/// header, so the wire shows a clean 1,2,3,… once per throttle window rather
/// than a per-IRQ counter.
static mut EMITTED: u64 = 0;

/// Should a sample be emitted now, given the counter reading `now`, the reading
/// at the previous emit `last`, and the `interval` in counter ticks? Pure so the
/// rate limit is host-tested without a live generic timer.
///
/// The elapsed span uses `wrapping_sub` so a counter rollover between two reads
/// still yields the true gap rather than a huge value. The clock-unset case
/// (`interval == 0`, which passes here as `_ >= 0`) is handled at the call site
/// by suppressing emission outright, since with no wall clock there is nothing
/// to pace against.
fn should_sample(now: u64, last: u64, interval: u64) -> bool {
    now.wrapping_sub(last) >= interval
}

/// Print one frame: its PC and, if the table resolves it, the enclosing symbol.
///
/// # Safety
/// The mini-UART is up and `ksyms_init` has run.
unsafe fn emit_frame(pc: u64) {
    // SAFETY: the literals carry their own terminators; the resolved name is
    // NUL-terminated inside the symbol table.
    unsafe {
        utilc::main_output(MU, c"  ".as_ptr().cast());
        utilc::main_output_u64(MU, pc);
        let name = ksyms::ksym_nearest(pc);
        if !name.is_null() {
            utilc::main_output(MU, c" ".as_ptr().cast());
            utilc::main_output(MU, name);
        }
        utilc::main_output_char(MU, b'\n');
    }
}

/// Sample the interrupted context and emit a bounded backtrace.
///
/// # Safety
/// Called from the IRQ path with the exception frame the entry stub saved on the
/// kernel stack we are running on.
pub unsafe fn trace_sample(frame: *mut KeRegs) {
    // SAFETY: the frame is the entry stub's, live on our own kernel stack.
    unsafe {
        // Rate-limit against the free-running counter, not the call count: this
        // path fires per-IRQ, so a call-count throttle floods the UART under load.
        // With no wall clock (firmware left CNTFRQ unset) there is nothing to pace
        // against, so suppress rather than risk the flood.
        let hz = seam::clock_hz();
        if hz == 0 {
            return;
        }
        let now = seam::now_ticks();
        let interval = hz.saturating_mul(THROTTLE_SECS);
        if !should_sample(now, LAST_EMIT, interval) {
            return;
        }
        LAST_EMIT = now;
        EMITTED = EMITTED.wrapping_add(1);

        utilc::main_output(MU, c"[trace] tick=".as_ptr().cast());
        utilc::main_output_u64(MU, EMITTED);
        utilc::main_output_char(MU, b'\n');

        // Leaf: the interrupted PC.
        emit_frame((*frame).elr);

        // EL0t — the interrupt hit user code. The kernel frame chain only begins
        // below this exception, and the user stack is not ours to walk.
        if ((*frame).pstate & 0xF) == 0 {
            utilc::main_output(MU, c"  [user]\n".as_ptr().cast());
            return;
        }

        // Bound the walk to the current task's kernel-stack page. `kstack` is the
        // page base when the task carries a dedicated kernel stack; init_task
        // and the boot context have no such allocation, so fall back to the
        // task page for their legacy frame location.
        // The FP-chain decode itself lives in fp_walk::walk_chain (host-tested);
        // here we just hand it a view of the page and emit the LRs it returns.
        //
        // Note: under a size-optimized build most kernel frames omit the x29
        // record, so this is best-effort — it resolves whatever frames LLVM kept,
        // and the guards turn a missing chain into an empty walk, never a fault.
        let cur = seam::current_task();
        if cur.is_null() {
            return;
        }
        let base = if (*cur).kstack != 0 {
            (*cur).kstack
        } else {
            cur as u64
        };
        let page = core::slice::from_raw_parts(base as *const u8, PAGE_SIZE as usize);
        let mut lrs = [0u64; MAX_DEPTH];
        let n = fp_walk::walk_chain(page, base, (*frame).regs[29], &mut lrs);
        for lr in &lrs[..n] {
            emit_frame(*lr);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::should_sample;

    #[test]
    fn emits_once_a_full_interval_has_elapsed() {
        assert!(should_sample(1_000, 0, 1_000));
    }

    #[test]
    fn suppresses_within_the_interval() {
        assert!(!should_sample(999, 0, 1_000));
    }

    #[test]
    fn the_first_sample_after_boot_emits() {
        // LAST_EMIT starts at 0; the very first live reading is a full clock into
        // the counter, so the opening sample is never suppressed.
        assert!(should_sample(1_000_000, 0, 1_000));
    }

    #[test]
    fn is_wrap_safe_across_a_counter_rollover() {
        // `now` has wrapped past u64::MAX; the elapsed span is still one interval.
        let last = u64::MAX - 500;
        let now = last.wrapping_add(1_000);
        assert!(should_sample(now, last, 1_000));
        assert!(!should_sample(last.wrapping_add(999), last, 1_000));
    }
}
