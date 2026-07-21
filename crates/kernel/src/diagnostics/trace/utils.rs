//! Trace I/O helpers — rendering and output over the PL011 trace UART.

use flashos_kernel_abi::task::TaskStruct;

/// PL011 interface id — the only interface the trace side speaks.
pub const PL: i32 = 1;

const ENTRIES_PER_TABLE: usize = 512;

#[cfg(target_os = "none")]
mod seam {
    use crate::trace::pl011_uart;

    const ID_MAP_PAGES: usize = 3;
    const HIGH_MAP_PAGES: usize = 6;

    unsafe extern "C" {
        static id_pg_dir: u64;
        static high_pg_dir: u64;
    }

    /// # Safety
    /// `string` is NUL-terminated and the trace UART is up.
    #[inline]
    pub unsafe fn send_string(string: *const u8) {
        // SAFETY: forwarded NUL-termination contract.
        unsafe { pl011_uart::pl011_uart_send_string(string) };
    }

    /// # Safety
    /// The trace UART is up.
    #[inline]
    pub unsafe fn recv() -> u8 {
        // SAFETY: the caller guarantees bring-up ordering.
        unsafe { pl011_uart::pl011_uart_recv() }
    }

    /// The kernel's page-table windows: each base and how many tables follow it.
    pub fn kernel_pt_windows() -> [(*mut u64, usize); 2] {
        [
            (core::ptr::addr_of!(id_pg_dir) as *mut u64, ID_MAP_PAGES),
            (core::ptr::addr_of!(high_pg_dir) as *mut u64, HIGH_MAP_PAGES),
        ]
    }

    /// Read the instruction word at `addr`.
    ///
    /// # Safety
    /// `addr` is mapped and 8-byte aligned.
    #[inline]
    pub unsafe fn read_insn(addr: u64) -> u64 {
        // SAFETY: forwarded mapped-address contract. Volatile because the patch
        // path rewrites these words.
        unsafe { core::ptr::read_volatile(addr as *const u64) }
    }
}

#[cfg(not(target_os = "none"))]
mod seam {
    /// Host builds have no UART. Emitted bytes land here so the rendering logic —
    /// the hex digits, the interface dispatch, the field order of a task dump —
    /// keeps a host oracle.
    pub static mut LAST_OUTPUT: [u8; 4096] = [0; 4096];
    pub static mut LAST_OUTPUT_LEN: usize = 0;

    /// # Safety
    /// The host suite serializes access to the shared capture buffer.
    #[cfg(test)]
    pub unsafe fn reset_output() {
        // SAFETY: callers hold the module's test lock.
        unsafe { LAST_OUTPUT_LEN = 0 };
    }

    /// # Safety
    /// The host suite serializes access to the shared capture buffer.
    #[cfg(test)]
    pub unsafe fn captured() -> std::vec::Vec<u8> {
        // SAFETY: callers hold the module's test lock.
        unsafe {
            let base = core::ptr::addr_of!(LAST_OUTPUT).cast::<u8>();
            (0..LAST_OUTPUT_LEN).map(|i| *base.add(i)).collect()
        }
    }

    /// # Safety
    /// `string` is NUL-terminated.
    pub unsafe fn send_string(string: *const u8) {
        // SAFETY: the scan stops at the caller's NUL; the append is bounded.
        unsafe {
            let base = core::ptr::addr_of_mut!(LAST_OUTPUT).cast::<u8>();
            let mut i = 0;
            while *string.add(i) != 0 {
                if LAST_OUTPUT_LEN < 4096 {
                    *base.add(LAST_OUTPUT_LEN) = *string.add(i);
                    LAST_OUTPUT_LEN += 1;
                }
                i += 1;
            }
        }
    }

    /// # Safety
    /// Host builds have no UART to receive from.
    pub unsafe fn recv() -> u8 {
        0
    }

    /// Host builds have no linker-placed page tables to walk.
    pub fn kernel_pt_windows() -> [(*mut u64, usize); 2] {
        [(core::ptr::null_mut(), 0), (core::ptr::null_mut(), 0)]
    }

    /// Host builds have no kernel image to read instructions out of.
    ///
    /// # Safety
    /// Reads nothing.
    pub unsafe fn read_insn(_addr: u64) -> u64 {
        0
    }
}

/// Send a NUL-terminated string to `interface`.
///
/// The emitters below stay out of line on purpose: they are called from every
/// trace site, and letting the inliner copy the hex renderer and the UART send
/// loop into each one grows `.text` past a page boundary, which moves
/// `_kernel_pa_end` and the initramfs — addresses the port must keep frozen.
///
/// # Safety
/// `string` points at a NUL-terminated buffer.
#[inline(never)]
pub unsafe fn trace_output(interface: i32, string: *const u8) {
    // SAFETY: forwarded NUL-termination contract; the literal carries its own.
    unsafe {
        if interface == PL {
            seam::send_string(string);
        } else {
            seam::send_string(c"trace_output bad interface\n".as_ptr().cast());
        }
    }
}

/// Render `input` as 16 lowercase hex digits into `buf`.
///
/// # Safety
/// `buf` has room for 16 bytes.
#[inline(never)]
pub unsafe fn trace_u64_to_char_array(input: u64, buf: *mut u8) {
    for i in 0..16u32 {
        let shift = (15 - i) * 4;
        let nibble = ((input >> shift) & 0xF) as u8;
        let digit = if nibble <= 9 {
            nibble + b'0'
        } else {
            nibble - 10 + b'a'
        };
        // SAFETY: the caller guarantees 16 bytes of room; i < 16.
        unsafe { *buf.add(i as usize) = digit };
    }
}

/// Place `ch` at the front of `buf`.
///
/// # Safety
/// `buf` has room for one byte.
pub unsafe fn trace_char_to_char_array(ch: u8, buf: *mut u8) {
    // SAFETY: the caller guarantees the byte of room.
    unsafe { *buf = ch };
}

/// Send one character to `interface`.
///
/// # Safety
/// The trace UART is initialized.
pub unsafe fn trace_output_char(interface: i32, ch: u8) {
    let printable = [ch, 0];
    // SAFETY: the local array carries its own terminator and outlives the call.
    unsafe { trace_output(interface, printable.as_ptr()) };
}

/// Send `input` to `interface` as 16 hex digits.
///
/// # Safety
/// The trace UART is initialized.
#[inline(never)]
pub unsafe fn trace_output_u64(interface: i32, input: u64) {
    let mut printable = [0u8; 17];
    printable[16] = 0;
    // SAFETY: the local array has the 16 bytes the renderer writes, plus the
    // terminator it does not touch.
    unsafe {
        trace_u64_to_char_array(input, printable.as_mut_ptr());
        trace_output(interface, printable.as_ptr());
    }
}

/// Dump a task's scheduler fields and page-table root.
///
/// # Safety
/// `p` points at a live `TaskStruct`.
pub unsafe fn trace_output_process(interface: i32, p: *mut TaskStruct) {
    // SAFETY: the caller guarantees the task is live; every read is a plain
    // field of it, and the literals carry their own terminators.
    unsafe {
        trace_output(interface, c"task address: ".as_ptr().cast());
        trace_output_u64(interface, p as u64);
        trace_output(interface, c", state: ".as_ptr().cast());
        trace_output_u64(interface, (*p).state as u64);
        trace_output(interface, c", counter: ".as_ptr().cast());
        trace_output_u64(interface, (*p).counter as u64);
        trace_output(interface, c", priority: ".as_ptr().cast());
        trace_output_u64(interface, (*p).priority as u64);
        trace_output(interface, c", preempt_count: ".as_ptr().cast());
        trace_output_u64(interface, (*p).preempt_count as u64);
        trace_output(interface, c", pgd: ".as_ptr().cast());
        trace_output_u64(interface, (*p).mm.pgd);
        trace_output(interface, c"\n".as_ptr().cast());
    }
}

/// Dump the instruction word at `addr_in`, rounded down to an 8-byte boundary.
///
/// # Safety
/// The rounded address is mapped and readable.
pub unsafe fn trace_output_insn(interface: i32, addr_in: u64) {
    let addr = addr_in & !0x7u64;
    // SAFETY: the caller guarantees the address is mapped; the literals carry
    // their own terminators.
    unsafe {
        trace_output(interface, c"instruction address: ".as_ptr().cast());
        trace_output_u64(interface, addr);
        trace_output(interface, c", instruction: ".as_ptr().cast());
        trace_output_u64(interface, seam::read_insn(addr));
        trace_output(interface, c"\n".as_ptr().cast());
    }
}

/// Dump one 512-entry page table, two entries per line.
///
/// # Safety
/// `page` points at a mapped table of `ENTRIES_PER_TABLE` entries.
#[inline(never)]
pub unsafe fn trace_output_pt(interface: i32, page: *mut u64) {
    for i in 0..ENTRIES_PER_TABLE {
        // SAFETY: the caller guarantees the table is mapped and full-length.
        unsafe {
            let entry = page.add(i);
            trace_output_u64(interface, entry as u64);
            trace_output(interface, c": ".as_ptr().cast());
            trace_output_u64(interface, *entry);
            if (i % 2) != 0 {
                trace_output(interface, c"\n".as_ptr().cast());
            } else {
                trace_output(interface, c"  ".as_ptr().cast());
            }
        }
    }
}

/// Dump the kernel's identity and high-half page tables.
///
/// The `interface` argument is ignored — the dump always goes to the PL011, as
/// it did before the port.
///
/// # Safety
/// The linker-provided page-table windows are mapped; bring-up calls this once.
pub unsafe fn trace_output_kernel_pts(_interface: i32) {
    for (base, tables) in seam::kernel_pt_windows() {
        let mut pt = base;
        for _ in 0..tables {
            // SAFETY: the seam hands back linker-placed tables of the stated
            // length, or an empty window the loop never enters.
            unsafe {
                trace_output(PL, c"pt = ".as_ptr().cast());
                trace_output_u64(PL, pt as u64);
                trace_output(PL, c"\n".as_ptr().cast());
                trace_output_pt(PL, pt);
                pt = pt.add(ENTRIES_PER_TABLE);
            }
        }
    }
}

/// Receive one byte from `interface`.
///
/// # Safety
/// The trace UART is initialized.
pub unsafe fn trace_recv(interface: i32) -> u8 {
    // SAFETY: the caller guarantees the UART is up; the literal carries its own
    // terminator.
    unsafe {
        if interface == PL {
            seam::recv()
        } else {
            trace_output(PL, c"main_recv bad interface\n".as_ptr().cast());
            0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        seam, trace_output, trace_output_char, trace_output_process, trace_output_u64, trace_recv,
        PL,
    };
    use crate::trace::CAPTURE_LOCK;
    use flashos_kernel_abi::task::TaskStruct;

    fn emitted(body: impl FnOnce()) -> std::string::String {
        let _guard = CAPTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // SAFETY: the lock serializes access to the capture buffer.
        unsafe {
            seam::reset_output();
            body();
            std::string::String::from_utf8(seam::captured()).unwrap()
        }
    }

    #[test]
    fn u64_renders_as_sixteen_lowercase_hex_digits() {
        let out = emitted(|| unsafe { trace_output_u64(PL, 0xDEAD_BEEF) });
        assert_eq!(out, "00000000deadbeef");
    }

    #[test]
    fn u64_renders_the_full_width_without_truncating() {
        let out = emitted(|| unsafe { trace_output_u64(PL, u64::MAX) });
        assert_eq!(out, "ffffffffffffffff");
    }

    #[test]
    fn zero_renders_as_all_zero_digits() {
        let out = emitted(|| unsafe { trace_output_u64(PL, 0) });
        assert_eq!(out, "0000000000000000");
    }

    #[test]
    fn a_bad_interface_says_so_instead_of_emitting_the_string() {
        let out = emitted(|| unsafe { trace_output(PL + 1, c"payload".as_ptr().cast()) });
        assert_eq!(out, "trace_output bad interface\n");
    }

    #[test]
    fn output_char_emits_exactly_one_byte() {
        let out = emitted(|| unsafe { trace_output_char(PL, b'x') });
        assert_eq!(out, "x");
    }

    #[test]
    fn recv_on_a_bad_interface_reports_and_returns_zero() {
        let mut got = 1u8;
        let out = emitted(|| got = unsafe { trace_recv(PL + 1) });
        assert_eq!(got, 0);
        assert_eq!(out, "main_recv bad interface\n");
    }

    // Field-by-field on a defaulted struct is clearer here than a struct
    // literal, since `task.mm.pgd` reaches into a nested sub-struct.
    #[allow(clippy::field_reassign_with_default)]
    #[test]
    fn a_task_dump_keeps_its_field_order_and_labels() {
        let mut task = TaskStruct::default();
        task.state = 1;
        task.counter = 2;
        task.priority = 3;
        task.preempt_count = 4;
        task.mm.pgd = 0x1000;
        let out = emitted(|| unsafe { trace_output_process(PL, &raw mut task) });
        assert!(out.starts_with("task address: "), "{out}");
        assert!(out.contains(", state: 0000000000000001"), "{out}");
        assert!(out.contains(", counter: 0000000000000002"), "{out}");
        assert!(out.contains(", priority: 0000000000000003"), "{out}");
        assert!(out.contains(", preempt_count: 0000000000000004"), "{out}");
        assert!(out.ends_with(", pgd: 0000000000001000\n"), "{out}");
    }
}
