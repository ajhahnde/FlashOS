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
}

/// Throttle: emit one backtrace every N ticks. The timer tick is ~1 Hz on real
/// hardware (the only place it fires — QEMU never delivers the PPI), so N=1 is
/// one sample per second over the UART: legible, not a flood. Raise to sub-sample
/// a faster tick; N=0 disables emission entirely.
const THROTTLE_N: u64 = 1;
static mut TICK: u64 = 0;

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
        TICK = TICK.wrapping_add(1);
        if THROTTLE_N == 0 || TICK % THROTTLE_N != 0 {
            return;
        }

        utilc::main_output(MU, c"[trace] tick=".as_ptr().cast());
        utilc::main_output_u64(MU, TICK);
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
        // page base when the task carries a dedicated kernel stack; older tasks
        // run on the stack that shares the TaskStruct page, so fall back to it.
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
