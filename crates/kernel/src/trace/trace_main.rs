//! Dynamic kernel tracing — patches `bl hook` into the `mov x9, lr` slots at the
//! entry of every function compiled with `-fpatchable-function-entry=2`.
//!
//! The patchable-function-entries section contains the four hand-written
//! trampolines in `src/trace/patchable_trampolines.S`.

use crate::trace::ksyms;
use crate::trace::utils::{trace_output, trace_output_insn, trace_output_u64, PL};

const MOV_X9_LR: u32 = 0xAA1E_03E9;
const BL_OP: u32 = 0x9400_0000;
const BL_MASK: u32 = 0x03FF_FFFF;

/// Kernel high-mapping base. Same constant as the syscall and process-loader
/// modules. `trace_relocate` ORs it into each link-time low-VA entry to obtain
/// the runtime kernel-virtual alias the patch path needs.
const LINEAR_MAP_BASE: u64 = 0xFFFF_0000_0000_0000;

#[cfg(target_os = "none")]
mod seam {
    unsafe extern "C" {
        static __start_patchable_functions: u64;
        static __stop_patchable_functions: u64;
        static hook: u64;
    }

    /// Address of the hook trampoline every patched entry branches to.
    pub fn hook_addr() -> u64 {
        core::ptr::addr_of!(hook) as u64
    }

    /// The linker-placed table of patchable entry addresses.
    pub fn patchable_bounds() -> (*mut u64, *mut u64) {
        (
            core::ptr::addr_of!(__start_patchable_functions) as *mut u64,
            core::ptr::addr_of!(__stop_patchable_functions) as *mut u64,
        )
    }

    /// Write an instruction word and force I-/D-cache coherency for
    /// self-modifying code.
    ///
    /// The `dc cvau` / `ic ivau` / `isb` sequence is required: without it the
    /// freshly written bytes stay invisible to the instruction-fetch path and the
    /// patched slot keeps reading as a NOP. Recipe from the ARMv8 reference
    /// (B2.2.5, "Self-modifying code"). `dsb ish` completes the data-side push to
    /// PoU before `ic ivau` / `isb` starts the instruction-side flush.
    ///
    /// # Safety
    /// `addr` points at a mapped, writable instruction word in the kernel image.
    pub unsafe fn modify_code(addr: u64, insn: u32) {
        // SAFETY: the caller guarantees the slot is a mapped instruction word.
        unsafe {
            core::ptr::write_volatile(addr as *mut u32, insn);
            core::arch::asm!(
                "dc cvau, {a}",
                "dsb ish",
                "ic ivau, {a}",
                "dsb ish",
                "isb",
                a = in(reg) addr,
                options(nostack, preserves_flags),
            );
        }
    }
}

#[cfg(not(target_os = "none"))]
mod seam {
    /// Host builds patch nothing. Each would-be code write lands here so the
    /// patch encoder — the `mov x9, lr` slot, the `bl` displacement, the second-
    /// nop offset — keeps a host oracle.
    pub static mut PATCHES: [(u64, u32); 32] = [(0, 0); 32];
    pub static mut PATCH_COUNT: usize = 0;

    /// A hook address far enough from the fake entries to exercise a real
    /// displacement in both directions.
    pub fn hook_addr() -> u64 {
        0x4000_8000
    }

    pub fn patchable_bounds() -> (*mut u64, *mut u64) {
        (core::ptr::null_mut(), core::ptr::null_mut())
    }

    /// # Safety
    /// The host suite serializes access to the shared patch log.
    #[cfg(test)]
    pub unsafe fn reset_patches() {
        // SAFETY: callers hold the module's test lock.
        unsafe { PATCH_COUNT = 0 };
    }

    /// # Safety
    /// The host suite serializes access to the shared patch log.
    #[cfg(test)]
    pub unsafe fn patches() -> std::vec::Vec<(u64, u32)> {
        // SAFETY: callers hold the module's test lock.
        unsafe {
            let base = core::ptr::addr_of!(PATCHES).cast::<(u64, u32)>();
            (0..PATCH_COUNT).map(|i| *base.add(i)).collect()
        }
    }

    /// # Safety
    /// Records the write instead of performing it.
    pub unsafe fn modify_code(addr: u64, insn: u32) {
        // SAFETY: the append is bounded by the log's length.
        unsafe {
            if PATCH_COUNT < 32 {
                let base = core::ptr::addr_of_mut!(PATCHES).cast::<(u64, u32)>();
                *base.add(PATCH_COUNT) = (addr, insn);
                PATCH_COUNT += 1;
            }
        }
    }
}

/// Endless loop demonstrating the tracing functionality.
pub fn do_trace() -> ! {
    let mut k: u32 = 0;
    loop {
        // SAFETY: a literal carries its own terminator.
        unsafe { trace_output(PL, c"TRACE..\n".as_ptr().cast()) };
        for _ in 0..1_000_000u32 {
            k = k.wrapping_add(1);
        }
        let _ = k;
    }
}

/// Stub: ideally sends IPIs to spin all cores during code patching.
pub fn gather_cores() {}

/// Stub: releases gathered cores.
pub fn put_back_cores() {}

/// Instruction-count offset from `addr` to `hook`. Signed; assumes the distance
/// stays inside the 26-bit `bl` displacement.
pub fn trace_calculate_offset(addr: u64) -> i32 {
    let hook_addr = seam::hook_addr() as i64;
    let here = addr as i64;
    ((hook_addr - here) / 4) as i32
}

/// Generate a `bl <offset>` instruction word.
pub fn trace_generate_bl(offset_in: i32) -> u32 {
    let insn = BL_OP | ((offset_in as u32) & BL_MASK);
    // SAFETY: the literals carry their own terminators.
    unsafe {
        trace_output(PL, c"generated: ".as_ptr().cast());
        trace_output_u64(PL, u64::from(insn));
        trace_output(PL, c"\n".as_ptr().cast());
    }
    insn
}

/// Write a 32-bit instruction word at `addr`, coherently for self-modifying code.
///
/// # Safety
/// `addr` points at a mapped, writable instruction word in the kernel image.
pub unsafe fn trace_modify_code(addr: u64, insn: u32) {
    // SAFETY: forwarded mapped-slot contract.
    unsafe { seam::modify_code(addr, insn) };
}

/// Promote each link-time low-VA entry to its kernel-virtual high alias.
///
/// # Safety
/// `start`/`end` bound the linker-placed entry table.
pub unsafe fn trace_relocate(start: *mut u64, end: *mut u64) {
    let count = (end as usize - start as usize) / core::mem::size_of::<u64>();
    for i in 0..count {
        // SAFETY: i is bounded by the table the caller passed.
        unsafe { *start.add(i) |= LINEAR_MAP_BASE };
    }
}

/// Replace the first nop of every patchable entry with `mov x9, lr`.
///
/// # Safety
/// `start`/`end` bound the linker-placed entry table and each entry addresses a
/// patchable instruction slot.
pub unsafe fn trace_setup_movx9lr(start: *mut u64, end: *mut u64) {
    let count = (end as usize - start as usize) / core::mem::size_of::<u64>();
    for i in 0..count {
        // SAFETY: the caller guarantees each entry is a patchable slot.
        unsafe {
            let slot = *start.add(i);
            trace_modify_code(slot, MOV_X9_LR);
            trace_output_insn(PL, slot);
        }
    }
}

/// Inject `bl hook` at the second nop of every patchable entry.
///
/// # Safety
/// `start`/`end` bound the linker-placed entry table and each entry addresses a
/// patchable instruction slot.
pub unsafe fn trace_enable(start: *mut u64, end: *mut u64) {
    let count = (end as usize - start as usize) / core::mem::size_of::<u64>();
    gather_cores();
    for i in 0..count {
        // SAFETY: the caller guarantees each entry is a patchable slot.
        unsafe {
            let slot = *start.add(i) + 4;
            let offset = trace_calculate_offset(slot);
            let insn = trace_generate_bl(offset);
            trace_modify_code(slot, insn);
            trace_output_insn(PL, slot);
        }
    }
    put_back_cores();
}

/// Initialize dynamic tracing: relocate the address table and patch entries.
///
/// # Safety
/// Bring-up calls this once, after the trace UART is up.
pub unsafe fn trace_init() {
    let (start, end) = seam::patchable_bounds();
    if start.is_null() || end.is_null() {
        return;
    }
    // SAFETY: the linker places both bounds around the entry table.
    unsafe {
        trace_relocate(start, end);
        trace_setup_movx9lr(start, end);
        trace_output(PL, c"modified mov x9, lr\n".as_ptr().cast());
        trace_enable(start, end);
    }
}

/// Called from `hook.S` after a patched `bl hook` — looks up and prints the
/// symbol of the function that was entered.
///
/// # Safety
/// Reached from the hook trampoline with the patched entry's address.
pub unsafe fn traced(real_func_entry: u64) {
    // SAFETY: the lookup returns either null or a NUL-terminated table name.
    unsafe {
        let name = ksyms::ksym_name_from_addr(real_func_entry - 8);
        if name.is_null() {
            trace_output(PL, c"NOT FOUND!\n".as_ptr().cast());
        } else {
            trace_output(PL, name);
        }
        trace_output(PL, c"\n".as_ptr().cast());
    }
}

#[cfg(test)]
mod tests {
    use super::{
        seam, trace_calculate_offset, trace_enable, trace_generate_bl, trace_relocate,
        trace_setup_movx9lr, BL_OP, LINEAR_MAP_BASE, MOV_X9_LR,
    };
    use crate::trace::CAPTURE_LOCK;

    fn patched(body: impl FnOnce()) -> std::vec::Vec<(u64, u32)> {
        // The shared lock: `trace_setup_movx9lr` / `trace_enable` emit into the
        // output-capture buffer `utils` tests read, so this must serialize
        // against them, not just against other `trace_main` tests.
        let _guard = CAPTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // SAFETY: the lock serializes access to the patch log.
        unsafe {
            seam::reset_patches();
            body();
            seam::patches()
        }
    }

    #[test]
    fn positive_offset_encodes_into_the_bl_word() {
        assert_eq!(trace_generate_bl(2), BL_OP | 2);
    }

    #[test]
    fn negative_offset_keeps_its_twos_complement_bits() {
        // A backward branch is a two's-complement displacement truncated to 26
        // bits — the same word the assembler would emit.
        assert_eq!(trace_generate_bl(-1), BL_OP | 0x03FF_FFFF);
    }

    #[test]
    fn offset_is_masked_to_twenty_six_bits() {
        // Anything above bit 25 belongs to the opcode field and must not leak in.
        assert_eq!(trace_generate_bl(0x0400_0000), BL_OP);
    }

    #[test]
    fn offset_is_the_instruction_count_to_the_hook() {
        // Four bytes per instruction, signed both ways around the hook.
        let hook = seam::hook_addr();
        assert_eq!(trace_calculate_offset(hook - 16), 4);
        assert_eq!(trace_calculate_offset(hook + 16), -4);
        assert_eq!(trace_calculate_offset(hook), 0);
    }

    #[test]
    fn relocate_promotes_every_entry_to_the_high_alias() {
        let mut entries = [0x4000_1000u64, 0x4000_2000];
        let start = entries.as_mut_ptr();
        // SAFETY: the bounds are the local array's own.
        unsafe { trace_relocate(start, start.add(2)) };
        assert_eq!(entries[0], 0x4000_1000 | LINEAR_MAP_BASE);
        assert_eq!(entries[1], 0x4000_2000 | LINEAR_MAP_BASE);
    }

    #[test]
    fn relocate_is_idempotent_on_an_already_high_entry() {
        let mut entries = [0x4000_1000u64 | LINEAR_MAP_BASE];
        let start = entries.as_mut_ptr();
        // SAFETY: the bounds are the local array's own.
        unsafe { trace_relocate(start, start.add(1)) };
        assert_eq!(entries[0], 0x4000_1000 | LINEAR_MAP_BASE);
    }

    #[test]
    fn setup_writes_mov_x9_lr_to_the_first_slot_of_each_entry() {
        let mut entries = [0x4000_1000u64, 0x4000_2000];
        let log = patched(|| {
            let start = entries.as_mut_ptr();
            // SAFETY: the bounds are the local array's own; the host seam records
            // the writes instead of performing them.
            unsafe { trace_setup_movx9lr(start, start.add(2)) };
        });
        assert_eq!(log, [(0x4000_1000, MOV_X9_LR), (0x4000_2000, MOV_X9_LR)]);
    }

    #[test]
    fn enable_writes_a_bl_to_the_hook_at_the_second_slot() {
        let mut entries = [0x4000_1000u64];
        let log = patched(|| {
            let start = entries.as_mut_ptr();
            // SAFETY: the bounds are the local array's own; the host seam records
            // the writes instead of performing them.
            unsafe { trace_enable(start, start.add(1)) };
        });
        // The bl lands at entry+4 (the second nop) and branches to the hook.
        let slot = 0x4000_1004u64;
        let expected = trace_generate_bl(trace_calculate_offset(slot));
        assert_eq!(log, [(slot, expected)]);
    }
}
