//! BCM2711 GICv2 interrupt controller and IRQ dispatch.

use crate::{console, rpi4b_timer, rpi4b_uart, utilc};
use core::ptr::{read_volatile, write_volatile};
use flashos_abi::task::KeRegs;

const LINEAR_MAP_BASE: usize = 0xFFFF_0000_0000_0000;
const GIC_BASE: usize = 0xFF84_0000 + LINEAR_MAP_BASE;
const GICD_BASE: usize = GIC_BASE + 0x1000;
const GICC_BASE: usize = GIC_BASE + 0x2000;
const GICD_ISENABLER_BASE: usize = GICD_BASE + 0x100;
const GICD_ITARGETSR_BASE: usize = GICD_BASE + 0x800;
const GICC_CTLR: *mut u32 = GICC_BASE as *mut u32;
const GICC_PMR: *mut u32 = (GICC_BASE + 0x04) as *mut u32;
const GICC_IAR: *mut u32 = (GICC_BASE + 0x0c) as *mut u32;
const GICC_EOIR: *mut u32 = (GICC_BASE + 0x10) as *mut u32;

const NS_PHYS_TIMER_IRQ: u32 = 30;
const VC_TIMER_IRQ_1: u32 = 97;
const VC_AUX_IRQ: u32 = 125;
const MU: i32 = 0;

#[cfg(target_os = "none")]
unsafe extern "C" {
    fn handle_generic_timer();
    fn timer_tick();
    fn get_core() -> u32;
}

#[cfg(not(target_os = "none"))]
unsafe fn handle_generic_timer() {}
#[cfg(not(target_os = "none"))]
unsafe fn timer_tick() {}
#[cfg(not(target_os = "none"))]
unsafe fn get_core() -> u32 {
    0
}

/// The DWC2 gadget, reached by direct call. IRQ landed before the USB port, so
/// this path used to reach the driver through a C trampoline; it consumes the
/// module natively now.
#[cfg(target_os = "none")]
use crate::rpi4b_usb::{enumerated as board_usb_enumerated, poll as board_usb_poll};

#[cfg(not(target_os = "none"))]
unsafe fn board_usb_poll() {}
#[cfg(not(target_os = "none"))]
unsafe fn board_usb_enumerated() -> bool {
    true
}

/// The 19 exception-entry failure names plus the out-of-range fallback, as one
/// NUL-separated blob addressed by integer span.
///
/// This must NOT be a `[&CStr; 19]`, and the lookup must NOT be a `match` on the
/// type index. Both lower to a table of *absolute* pointers holding the strings'
/// low link addresses (`ldr x1, [table, i*16]`); that pointer faults the moment
/// this path runs with TTBR0 on a user pgd — and it runs in exactly that state,
/// from the terminal EL0 exception handler, so the fault would be a silent
/// fault-while-faulting. A single blob is reached PC-relative — one base address
/// plus an integer offset — so every message pointer lands in the high linear-map
/// alias like the rest of this function's string arguments. Order matches the
/// `typ` the entry stub passes; index 19 is the fallback.
static ENTRY_ERROR_MESSAGES: &[u8] = b"\
SYNC_INVALID_EL1t\0IRQ_INVALID_EL1t\0FIQ_INVALID_EL1t\0SERROR_INVALID_EL1t\0\
SYNC_INVALID_EL1h\0IRQ_INVALID_EL1h\0FIQ_INVALID_EL1h\0SERROR_INVALID_EL1h\0\
SYNC_INVALID_EL0_64\0IRQ_INVALID_EL0_64\0FIQ_INVALID_EL0_64\0SERROR_INVALID_EL0_64\0\
SYNC_INVALID_EL0_32\0IRQ_INVALID_EL0_32\0FIQ_INVALID_EL0_32\0SERROR_INVALID_EL0_32\0\
SYNC_ERROR\0SYSCALL_ERROR\0DATA_ABORT_ERROR\0UNKNOWN_ENTRY\0";

/// Index the entry-message blob and return a C-string pointer to the `typ`-th
/// name, or the `UNKNOWN_ENTRY` fallback for an out-of-range index. The returned
/// pointer is `blob_base + integer_offset` — never loaded from a pointer table —
/// so it inherits the base's PC-relative high-alias addressing.
fn entry_message_ptr(typ: u32) -> *const u8 {
    let target = if typ <= 18 { typ as usize } else { 19 };
    let base = ENTRY_ERROR_MESSAGES.as_ptr();
    let mut seen = 0usize;
    let mut start = 0usize;
    let mut i = 0usize;
    while i < ENTRY_ERROR_MESSAGES.len() {
        if seen == target {
            break;
        }
        if ENTRY_ERROR_MESSAGES[i] == 0 {
            seen += 1;
            start = i + 1;
        }
        i += 1;
    }
    base.wrapping_add(start)
}

fn interrupt_id(iar: u32) -> u32 {
    iar & 0x3ff
}

/// Hand the saved exception frame to the sampler, which is compiled in only for
/// a trace build.
#[inline]
fn trace_sample(frame: *mut KeRegs) {
    #[cfg(feature = "trace")]
    // SAFETY: we are on the IRQ path, and `frame` is the exception frame the
    // entry stub saved on the kernel stack we are running on.
    unsafe {
        crate::trace::sampler::trace_sample(frame)
    };
    #[cfg(not(feature = "trace"))]
    let _ = frame;
}

/// Print the decoded exception-entry failure and its architectural fields.
///
/// # Safety
/// Called from the terminal exception path with the mini-UART initialized.
pub unsafe fn show_invalid_entry_message(typ: u32, esr: u64, address: u64) {
    unsafe { utilc::main_output(MU, c"ERROR CAUGHT: ".as_ptr().cast()) };
    unsafe { utilc::main_output(MU, entry_message_ptr(typ)) };
    unsafe { utilc::main_output(MU, c", ESR: ".as_ptr().cast()) };
    unsafe { utilc::main_output_u64(MU, esr) };
    unsafe { utilc::main_output(MU, c", Address: ".as_ptr().cast()) };
    unsafe { utilc::main_output_u64(MU, address) };
    unsafe { utilc::main_output(MU, c"\n".as_ptr().cast()) };
}

/// Enable one interrupt in the GIC distributor.
///
/// # Safety
/// The GIC device mapping is installed and `intid` is in the distributor.
pub unsafe fn enable_gic_distributor(intid: u32) {
    let register = (GICD_ISENABLER_BASE as *mut u32).wrapping_add((intid / 32) as usize);
    let value = unsafe { read_volatile(register) };
    unsafe { write_volatile(register, value | (1 << (intid % 32))) };
}

/// Route one interrupt to a CPU interface.
///
/// # Safety
/// The GIC device mapping is installed and both identifiers are valid.
pub unsafe fn assign_interrupt_core(intid: u32, core: u32) {
    let register = (GICD_ITARGETSR_BASE as *mut u32).wrapping_add((intid / 4) as usize);
    let shift = (intid % 4) * 8 + core;
    let value = unsafe { read_volatile(register) };
    unsafe { write_volatile(register, value | (1 << shift)) };
}

/// Enable and route one interrupt.
///
/// # Safety
/// Satisfies both component operations' contracts.
pub unsafe fn enable_interrupt_gic(intid: u32, core: u32) {
    unsafe { enable_gic_distributor(intid) };
    unsafe { assign_interrupt_core(intid, core) };
}

/// Dispatch one acknowledged GIC interrupt and write its EOI.
///
/// # Safety
/// Called only from the serialized EL1 IRQ vector with a live saved frame.
pub unsafe fn handle_irq(frame: *mut KeRegs) {
    trace_sample(frame);
    let iar = unsafe { read_volatile(GICC_IAR) };
    match interrupt_id(iar) {
        VC_TIMER_IRQ_1 => {
            unsafe { rpi4b_timer::handle_sys_timer_1() };
            unsafe { write_volatile(GICC_EOIR, iar) };
        }
        VC_AUX_IRQ => {
            while unsafe { rpi4b_uart::mini_uart_rx_pending() } {
                let byte = unsafe { rpi4b_uart::mini_uart_recv() };
                unsafe { console::console_push(byte) };
            }
            unsafe { write_volatile(GICC_EOIR, iar) };
        }
        NS_PHYS_TIMER_IRQ => {
            unsafe { handle_generic_timer() };
            unsafe { write_volatile(GICC_EOIR, iar) };
            if unsafe { get_core() } == 0 {
                if !unsafe { board_usb_enumerated() } {
                    unsafe { board_usb_poll() };
                }
                unsafe { timer_tick() };
            }
        }
        _ => unsafe { utilc::main_output(MU, c"unknown pending irq\n".as_ptr().cast()) },
    }
}

/// Enable the non-secure GICv2 CPU interface for the calling core.
///
/// # Safety
/// Called during serialized board bring-up with the GIC mapping installed.
pub unsafe fn board_irq_init() {
    unsafe { write_volatile(GICC_PMR, 0xf0) };
    let control = unsafe { read_volatile(GICC_CTLR) };
    unsafe { write_volatile(GICC_CTLR, control | 1) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iar_uses_all_ten_gicv2_interrupt_id_bits() {
        assert_eq!(interrupt_id(0xffff_ffff), 0x3ff);
        assert_eq!(interrupt_id(0x300), 0x300);
    }

    #[test]
    fn entry_error_blob_matches_the_vector_contract() {
        // Read back a message the same way the fault path does — through the
        // integer-span walk, not an array index — so the test also exercises the
        // lookup that replaced the absolute-pointer table.
        fn name(typ: u32) -> &'static [u8] {
            let p = entry_message_ptr(typ);
            // SAFETY: `p` points into the static blob at the start of a
            // NUL-terminated name; the test process maps it.
            unsafe { core::ffi::CStr::from_ptr(p.cast()) }.to_bytes()
        }
        assert_eq!(name(0), b"SYNC_INVALID_EL1t");
        assert_eq!(name(3), b"SERROR_INVALID_EL1t");
        assert_eq!(name(18), b"DATA_ABORT_ERROR");
        // Out-of-range indices fall back to the fallback name, never past the blob.
        assert_eq!(name(19), b"UNKNOWN_ENTRY");
        assert_eq!(name(255), b"UNKNOWN_ENTRY");
    }
}
