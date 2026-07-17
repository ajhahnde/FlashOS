//! Kernel console output, the byte movers, and the panic path.
//!
//! Everything the rest of the kernel reaches for when it needs to say something
//! or move memory. `main_output` is the one funnel: it tees each string into the
//! kernel log ring before handing it to a UART, so `dmesg` reads back exactly
//! what the boot printed. The tee is allocation-free and never re-enters
//! `main_output`, which is what makes it callable from any context — kernel,
//! syscall, IRQ, or before `current` exists.
//!
//! `memcpy`/`memset` are the kernel's own. Their strong definitions outrank the
//! weak ones `compiler_builtins` carries, so these byte loops are what every
//! caller in the image reaches — deliberately, because a wide-load
//! implementation would fault against `SCTLR_EL1.A` on the odd addresses the
//! cpio and path scanners hand them.

use flashos_abi::task::{KeRegs, TaskStruct};

use crate::klog_ring;

/// Mini-UART interface id.
pub const MU: i32 = 0;
/// PL011 interface id.
pub const PL: i32 = 1;

#[cfg(target_os = "none")]
mod seam {
    use crate::klog_ring;

    /// The trace UART is Rust-owned, so the PL011 sink is a plain call rather
    /// than a trip back out through the C ABI.
    pub use crate::trace::pl011_uart::pl011_uart_send_string;

    unsafe extern "C" {
        pub fn mini_uart_send_string(string: *const u8);
        pub fn mini_uart_recv() -> u8;
        pub fn err_hang() -> !;
        fn fos_klog_ring() -> *mut klog_ring::KlogRing;
    }

    /// The one kernel-wide log ring, still resident in the Flash module that
    /// declares its storage.
    ///
    /// # Safety
    /// Returns the address of a BSS-resident static; valid for the kernel's life.
    #[inline]
    pub unsafe fn klog_ring() -> *mut klog_ring::KlogRing {
        // SAFETY: the Flash module's getter returns its BSS-resident ring.
        unsafe { fos_klog_ring() }
    }
}

#[cfg(not(target_os = "none"))]
mod seam {
    use crate::klog_ring;

    /// Host builds have no UART. Emitted bytes land here so the rendering logic
    /// — the hex digits, the interface dispatch, the field order of a task dump
    /// — keeps a host oracle.
    pub static mut LAST_OUTPUT: [u8; 1024] = [0; 1024];
    pub static mut LAST_OUTPUT_LEN: usize = 0;
    /// Bytes `main_recv` hands back, oldest first.
    pub static mut RECV_QUEUE: [u8; 64] = [0; 64];
    pub static mut RECV_LEN: usize = 0;
    pub static mut RECV_POS: usize = 0;
    static mut HOST_RING: klog_ring::KlogRing = klog_ring::KlogRing::new();

    /// # Safety
    /// The host suite serializes access to the shared capture buffer.
    #[cfg(test)]
    pub unsafe fn reset_output() {
        // SAFETY: callers hold the module's test lock.
        unsafe {
            LAST_OUTPUT_LEN = 0;
            core::ptr::write_bytes(core::ptr::addr_of_mut!(LAST_OUTPUT).cast::<u8>(), 0, 1024);
        }
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
    /// The host suite serializes access to the shared receive queue.
    #[cfg(test)]
    pub unsafe fn set_recv_bytes(bytes: &[u8]) {
        // SAFETY: callers hold the module's test lock; the copy is bounded.
        unsafe {
            let base = core::ptr::addr_of_mut!(RECV_QUEUE).cast::<u8>();
            let len = bytes.len().min(64);
            core::ptr::copy_nonoverlapping(bytes.as_ptr(), base, len);
            RECV_LEN = len;
            RECV_POS = 0;
        }
    }

    /// # Safety
    /// `string` is NUL-terminated.
    pub unsafe fn mini_uart_send_string(string: *const u8) {
        // SAFETY: the caller guarantees the NUL terminator.
        unsafe { capture(string) };
    }

    /// # Safety
    /// `string` is NUL-terminated.
    pub unsafe fn pl011_uart_send_string(string: *const u8) {
        // SAFETY: the caller guarantees the NUL terminator.
        unsafe { capture(string) };
    }

    /// # Safety
    /// `string` is NUL-terminated.
    unsafe fn capture(string: *const u8) {
        // SAFETY: the scan stops at the caller's NUL; the append is bounded.
        unsafe {
            let base = core::ptr::addr_of_mut!(LAST_OUTPUT).cast::<u8>();
            let mut i = 0;
            while *string.add(i) != 0 {
                if LAST_OUTPUT_LEN < 1024 {
                    *base.add(LAST_OUTPUT_LEN) = *string.add(i);
                    LAST_OUTPUT_LEN += 1;
                }
                i += 1;
            }
        }
    }

    /// # Safety
    /// The host suite serializes access to the shared receive queue.
    pub unsafe fn mini_uart_recv() -> u8 {
        // SAFETY: the bound keeps the read inside the queue.
        unsafe {
            if RECV_POS >= RECV_LEN {
                return 0;
            }
            let byte = *core::ptr::addr_of!(RECV_QUEUE).cast::<u8>().add(RECV_POS);
            RECV_POS += 1;
            byte
        }
    }

    /// Host stand-in for the halt the kernel's error path never returns from.
    pub fn err_hang() -> ! {
        panic!("err_hang");
    }

    /// # Safety
    /// Returns the address of a host-only static; valid for the test's life.
    #[inline]
    pub unsafe fn klog_ring() -> *mut klog_ring::KlogRing {
        core::ptr::addr_of_mut!(HOST_RING)
    }
}

/// Render `value` as 16 hex chars into `buf`, most significant first. No NUL.
///
/// `inline(never)` here and on the emitters below is load-bearing, not a hint.
/// Every one of these was reached through a cross-language `extern` call before
/// the port, so each had exactly one body in the image and callers branched to
/// it. Left inlinable, LLVM fully unrolls this fixed 16-iteration loop and then
/// copies the unrolled digits into every caller — 6.7 KiB of `.text` measured,
/// enough to push `_kernel_pa_end` a page and move the frozen initramfs.
///
/// # Safety
/// `buf` is writable for 16 bytes.
#[inline(never)]
pub unsafe fn u64_to_char_array(value: u64, buf: *mut u8) {
    let mut i: u32 = 0;
    while i < 16 {
        let shift = (15 - i) * 4;
        let nibble = ((value >> shift) & 0xF) as u8;
        let digit = if nibble <= 9 {
            nibble + b'0'
        } else {
            nibble - 10 + b'a'
        };
        // SAFETY: `i < 16` and the caller guarantees 16 writable bytes.
        unsafe { *buf.add(i as usize) = digit };
        i += 1;
    }
}

/// # Safety
/// `buf` is writable for one byte.
pub unsafe fn char_to_char_array(byte: u8, buf: *mut u8) {
    // SAFETY: the caller guarantees one writable byte.
    unsafe { *buf = byte };
}

/// Emit one byte.
///
/// # Safety
/// Called in kernel, syscall, or IRQ context.
#[inline(never)]
pub unsafe fn main_output_char(interface: i32, byte: u8) {
    let printable = [byte, 0];
    // SAFETY: `printable` is NUL-terminated and outlives the call.
    unsafe { main_output(interface, printable.as_ptr()) };
}

/// Emit a NUL-terminated string, teeing it into the kernel log ring first.
///
/// # Safety
/// `string` is NUL-terminated and not retained past the call.
#[inline(never)]
pub unsafe fn main_output(interface: i32, string: *const u8) {
    // Tee before the UART: `push_c_str` is pure, allocation-free, and never
    // re-enters here, so this is safe from any context and leaves the free-page
    // baseline intact.
    // SAFETY: the ring is BSS-resident and the caller guarantees the terminator.
    unsafe { klog_ring::push_c_str(seam::klog_ring(), string) };
    match interface {
        // SAFETY: the caller guarantees the NUL terminator.
        MU => unsafe { seam::mini_uart_send_string(string) },
        // SAFETY: the caller guarantees the NUL terminator.
        PL => unsafe { seam::pl011_uart_send_string(string) },
        // SAFETY: the literal is static and NUL-terminated; MU cannot recurse
        // back into this arm.
        _ => unsafe { main_output(MU, c"main_output bad interface\n".as_ptr().cast()) },
    }
}

/// Emit `value` as 16 hex chars.
///
/// # Safety
/// Called in kernel, syscall, or IRQ context.
#[inline(never)]
pub unsafe fn main_output_u64(interface: i32, value: u64) {
    let mut printable = [0u8; 17];
    // SAFETY: the buffer holds the 16 digits plus the terminator left at [16].
    unsafe {
        u64_to_char_array(value, printable.as_mut_ptr());
        main_output(interface, printable.as_ptr());
    }
}

/// Dump a task record's scheduler fields.
///
/// # Safety
/// `task` points to a live `TaskStruct`.
#[inline(never)]
pub unsafe fn main_output_process(interface: i32, task: *mut TaskStruct) {
    // SAFETY: the caller supplies a live task; every literal is static and
    // NUL-terminated.
    unsafe {
        main_output(interface, c"task address: ".as_ptr().cast());
        main_output_u64(interface, task as u64);
        main_output(interface, c", state: ".as_ptr().cast());
        main_output_u64(interface, (*task).state as u64);
        main_output(interface, c", counter: ".as_ptr().cast());
        main_output_u64(interface, (*task).counter as u64);
        main_output(interface, c", priority: ".as_ptr().cast());
        main_output_u64(interface, (*task).priority as u64);
        main_output(interface, c", preempt_count: ".as_ptr().cast());
        main_output_u64(interface, (*task).preempt_count as u64);
        main_output(interface, c", pgd: ".as_ptr().cast());
        main_output_u64(interface, (*task).mm.pgd);
        main_output(interface, c"\n".as_ptr().cast());
    }
}

/// Read one byte from the console.
///
/// # Safety
/// Called in kernel or syscall context.
#[inline(never)]
pub unsafe fn main_recv(interface: i32) -> u8 {
    match interface {
        // SAFETY: the driver reads its own MMIO.
        MU => unsafe { seam::mini_uart_recv() },
        _ => {
            // SAFETY: the literal is static and NUL-terminated.
            unsafe { main_output(MU, c"main_recv bad interface\n".as_ptr().cast()) };
            0
        }
    }
}

/// Copy a saved register frame.
///
/// # Safety
/// Both pointers reference live, non-overlapping `KeRegs`.
pub unsafe fn copy_ke_regs(to: *mut KeRegs, from: *const KeRegs) {
    let mut i: usize = 0;
    while i < 31 {
        // SAFETY: `i < 31` indexes both frames' `regs` in bounds.
        unsafe { (*to).regs[i] = (*from).regs[i] };
        i += 1;
    }
    // SAFETY: the caller supplies live frames.
    unsafe {
        (*to).sp = (*from).sp;
        (*to).elr = (*from).elr;
        (*to).pstate = (*from).pstate;
    }
}

/// Fill `n` bytes at `dst` with the low byte of `value`.
///
/// # Safety
/// `dst` is writable for `n` bytes.
pub unsafe fn memset(dst: *mut u8, value: i32, n: u64) -> *mut u8 {
    let byte = (value as u32) as u8;
    let mut remaining = n;
    let mut p = dst;
    while remaining != 0 {
        // SAFETY: the counter keeps the write inside the caller's region.
        unsafe {
            *p = byte;
            p = p.add(1);
        }
        remaining -= 1;
    }
    dst
}

/// Byte-granular memory copy, with an 8-byte fast path when both sides are
/// already 8-aligned.
///
/// # Safety
/// `dst` is writable and `src` readable for `bytes`; the regions do not overlap.
pub unsafe fn memcpy(dst: *mut u8, src: *const u8, bytes: u64) -> *mut u8 {
    let mut d = dst;
    let mut s = src;
    let mut n = bytes;

    if (d as usize).is_multiple_of(8) && (s as usize).is_multiple_of(8) {
        let mut d64 = d.cast::<u64>();
        let mut s64 = s.cast::<u64>();
        while n >= 8 {
            // SAFETY: both sides are 8-aligned and `n >= 8` keeps the word
            // inside the caller's regions.
            unsafe {
                *d64 = *s64;
                d64 = d64.add(1);
                s64 = s64.add(1);
            }
            n -= 8;
        }
        d = d64.cast::<u8>();
        s = s64.cast::<u8>();
    }

    while n > 0 {
        // SAFETY: the counter keeps the byte inside the caller's regions.
        unsafe {
            *d = *s;
            d = d.add(1);
            s = s.add(1);
        }
        n -= 1;
    }
    dst
}

/// Print the message and halt. The kernel's terminal error path.
///
/// # Safety
/// `msg` is NUL-terminated.
pub unsafe fn panic(msg: *const u8) -> ! {
    // SAFETY: the literals are static and the caller guarantees the terminator.
    unsafe {
        main_output(MU, c"KERNEL PANIC: ".as_ptr().cast());
        main_output(MU, msg);
        main_output(MU, c"\n".as_ptr().cast());
        seam::err_hang()
    }
}

/// Byte-wise compare without alignment requirements.
///
/// The wide loads a slice compare lowers to under `ReleaseSmall` trip
/// `SCTLR_EL1.A`-asserted strict alignment when the operands live at odd VAs
/// (newc cpio entry names land at `cursor + 110`; mount-prefix matching starts
/// at arbitrary path offsets). The plain byte loop has no alignment
/// requirement; cost is irrelevant on these short scans.
///
/// # Safety
/// Both pointers are readable for `n` bytes.
pub unsafe fn mem_eql_bytes(a: *const u8, b: *const u8, n: u64) -> bool {
    let mut i: u64 = 0;
    while i < n {
        // SAFETY: `i < n` keeps both reads inside the caller's regions.
        if unsafe { *a.add(i as usize) != *b.add(i as usize) } {
            return false;
        }
        i += 1;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// The capture buffer and the receive queue are shared statics.
    static LOCK: Mutex<()> = Mutex::new(());

    fn captured_string() -> std::string::String {
        // SAFETY: the caller holds LOCK.
        std::string::String::from_utf8(unsafe { seam::captured() }).unwrap()
    }

    #[test]
    fn u64_to_char_array_renders_hex() {
        let mut buf = [0u8; 16];
        unsafe {
            u64_to_char_array(0x123456789ABCDEF0, buf.as_mut_ptr());
            assert_eq!(&buf, b"123456789abcdef0");

            u64_to_char_array(0x0, buf.as_mut_ptr());
            assert_eq!(&buf, b"0000000000000000");

            u64_to_char_array(0xFFFFFFFFFFFFFFFF, buf.as_mut_ptr());
            assert_eq!(&buf, b"ffffffffffffffff");
        }
    }

    #[test]
    fn char_to_char_array_sets_char() {
        let mut buf = [0u8; 1];
        unsafe { char_to_char_array(b'X', buf.as_mut_ptr()) };
        assert_eq!(buf[0], b'X');
    }

    #[test]
    fn main_output_sends_to_uart() {
        let _guard = LOCK.lock().unwrap();
        unsafe {
            seam::reset_output();
            main_output(MU, c"test output".as_ptr().cast());
        }
        assert_eq!(captured_string(), "test output");
    }

    #[test]
    fn main_output_routes_pl011() {
        let _guard = LOCK.lock().unwrap();
        unsafe {
            seam::reset_output();
            main_output(PL, c"pl011".as_ptr().cast());
        }
        assert_eq!(captured_string(), "pl011");
    }

    #[test]
    fn main_output_rejects_bad_interface() {
        let _guard = LOCK.lock().unwrap();
        unsafe {
            seam::reset_output();
            main_output(7, c"dropped".as_ptr().cast());
        }
        assert_eq!(captured_string(), "main_output bad interface\n");
    }

    #[test]
    fn main_output_char_sends_char() {
        let _guard = LOCK.lock().unwrap();
        unsafe {
            seam::reset_output();
            main_output_char(MU, b'Z');
        }
        assert_eq!(captured_string(), "Z");
    }

    #[test]
    fn main_output_u64_sends_hex() {
        let _guard = LOCK.lock().unwrap();
        unsafe {
            seam::reset_output();
            main_output_u64(MU, 0x1234);
        }
        assert_eq!(captured_string(), "0000000000001234");
    }

    #[test]
    fn main_output_process_sends_task_info() {
        let _guard = LOCK.lock().unwrap();
        let mut task: TaskStruct = unsafe { core::mem::zeroed() };
        task.state = 1;
        task.counter = 10;
        task.priority = 5;
        task.preempt_count = 0;
        task.mm.pgd = 0xDEADBEEF;

        unsafe {
            seam::reset_output();
            main_output_process(MU, &mut task);
        }
        let out = captured_string();
        assert!(out.contains("task address: "));
        assert!(out.contains(", state: 0000000000000001"));
        assert!(out.contains(", counter: 000000000000000a"));
        assert!(out.contains(", priority: 0000000000000005"));
        assert!(out.contains(", preempt_count: 0000000000000000"));
        assert!(out.contains(", pgd: 00000000deadbeef"));
        assert!(out.ends_with('\n'));
    }

    #[test]
    fn main_recv_reads_queued_bytes() {
        let _guard = LOCK.lock().unwrap();
        unsafe {
            seam::set_recv_bytes(b"ab");
            assert_eq!(main_recv(MU), b'a');
            assert_eq!(main_recv(MU), b'b');
        }
    }

    #[test]
    fn main_recv_rejects_bad_interface() {
        let _guard = LOCK.lock().unwrap();
        unsafe {
            seam::reset_output();
            assert_eq!(main_recv(PL), 0);
        }
        assert_eq!(captured_string(), "main_recv bad interface\n");
    }

    #[test]
    fn memset_fills_memory() {
        let mut buf = [0u8; 10];
        unsafe { memset(buf.as_mut_ptr(), b'A' as i32, 5) };
        assert_eq!(&buf[0..5], b"AAAAA");
        assert_eq!(buf[5], 0);
    }

    #[test]
    fn memcpy_copies_aligned() {
        let src = b"Hello, World!";
        let mut src_buf = [0u64; 2];
        let mut dst = [0u64; 2];
        unsafe {
            core::ptr::copy_nonoverlapping(src.as_ptr(), src_buf.as_mut_ptr().cast::<u8>(), 13);
            memcpy(
                dst.as_mut_ptr().cast::<u8>(),
                src_buf.as_ptr().cast::<u8>(),
                13,
            );
            assert_eq!(
                core::slice::from_raw_parts(dst.as_ptr().cast::<u8>(), 13),
                src
            );
        }
    }

    #[test]
    fn memcpy_copies_unaligned() {
        let mut src = [0u8; 20];
        for (i, byte) in src.iter_mut().enumerate() {
            *byte = i as u8;
        }
        let mut dst = [0u8; 20];
        unsafe { memcpy(dst.as_mut_ptr().add(1), src.as_ptr().add(5), 9) };
        assert_eq!(&dst[1..10], &src[5..14]);
    }

    #[test]
    fn memcpy_copies_31_bytes() {
        let mut src = [0u64; 4];
        let mut dst = [0u64; 4];
        unsafe {
            let src_bytes = src.as_mut_ptr().cast::<u8>();
            for i in 0..31 {
                *src_bytes.add(i) = i as u8;
            }
            memcpy(dst.as_mut_ptr().cast::<u8>(), src_bytes, 31);
            assert_eq!(
                core::slice::from_raw_parts(dst.as_ptr().cast::<u8>(), 31),
                core::slice::from_raw_parts(src_bytes, 31)
            );
        }
    }

    #[test]
    fn copy_ke_regs_copies_regs() {
        let mut from: KeRegs = unsafe { core::mem::zeroed() };
        let mut to: KeRegs = unsafe { core::mem::zeroed() };
        unsafe {
            core::ptr::write_bytes((&raw mut from).cast::<u8>(), 0xAA, 1);
            core::ptr::write_bytes((&raw mut to).cast::<u8>(), 0xBB, 1);
        }
        for (i, reg) in from.regs.iter_mut().enumerate() {
            *reg = 0xAAAA_0000 + i as u64;
        }
        from.sp = 0x1000;
        from.elr = 0x2000;
        from.pstate = 0x3000;

        unsafe { copy_ke_regs(&mut to, &from) };
        assert_eq!(to.regs, from.regs);
        assert_eq!(to.sp, from.sp);
        assert_eq!(to.elr, from.elr);
        assert_eq!(to.pstate, from.pstate);
    }

    #[test]
    fn mem_eql_bytes_compares() {
        let a = b"abcdef";
        let b = b"abcdeX";
        unsafe {
            assert!(mem_eql_bytes(a.as_ptr(), b.as_ptr(), 5));
            assert!(!mem_eql_bytes(a.as_ptr(), b.as_ptr(), 6));
            assert!(mem_eql_bytes(a.as_ptr(), b.as_ptr(), 0));
        }
    }

    #[test]
    fn mem_eql_bytes_ignores_alignment() {
        let a = b"..abcdef";
        let b = b".abcdef";
        unsafe {
            assert!(mem_eql_bytes(a.as_ptr().add(2), b.as_ptr().add(1), 6));
        }
    }
}
