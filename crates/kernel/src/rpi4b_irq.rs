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

const ENTRY_ERROR_MESSAGES: [&core::ffi::CStr; 19] = [
    c"SYNC_INVALID_EL1t",
    c"IRQ_INVALID_EL1t",
    c"FIQ_INVALID_EL1t",
    c"SERROR_INVALID_EL1t",
    c"SYNC_INVALID_EL1h",
    c"IRQ_INVALID_EL1h",
    c"FIQ_INVALID_EL1h",
    c"SERROR_INVALID_EL1h",
    c"SYNC_INVALID_EL0_64",
    c"IRQ_INVALID_EL0_64",
    c"FIQ_INVALID_EL0_64",
    c"SERROR_INVALID_EL0_64",
    c"SYNC_INVALID_EL0_32",
    c"IRQ_INVALID_EL0_32",
    c"FIQ_INVALID_EL0_32",
    c"SERROR_INVALID_EL0_32",
    c"SYNC_ERROR",
    c"SYSCALL_ERROR",
    c"DATA_ABORT_ERROR",
];

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
    let message = ENTRY_ERROR_MESSAGES
        .get(typ as usize)
        .copied()
        .unwrap_or(c"UNKNOWN_ENTRY");
    unsafe { utilc::main_output(MU, message.as_ptr().cast()) };
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
    fn entry_error_table_matches_the_vector_contract() {
        assert_eq!(ENTRY_ERROR_MESSAGES.len(), 19);
        assert_eq!(ENTRY_ERROR_MESSAGES[0], c"SYNC_INVALID_EL1t");
        assert_eq!(ENTRY_ERROR_MESSAGES[18], c"DATA_ABORT_ERROR");
    }
}
