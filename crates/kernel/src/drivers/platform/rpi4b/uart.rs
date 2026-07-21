//! BCM2711 AUX mini-UART console driver.

use crate::{console, rpi4b_gpio};
use core::ptr::{addr_of_mut, read_volatile, write_volatile};

const LINEAR_MAP_BASE: usize = 0xFFFF_0000_0000_0000;
const DEVICE_BASE: usize = 0xFE00_0000;
const AUX_BASE: usize = DEVICE_BASE + 0x0021_5000 + LINEAR_MAP_BASE;

const GF_ALT5: u8 = 2;
const TXD0: u8 = 14;
const RXD0: u8 = 15;

#[repr(C)]
struct AuxRegs {
    irq_status: u32,
    enables: u32,
    reserved: [u32; 14],
    mu_io: u32,
    mu_ier: u32,
    mu_iir: u32,
    mu_lcr: u32,
    mu_mcr: u32,
    mu_lsr: u32,
    mu_msr: u32,
    mu_scratch: u32,
    mu_control: u32,
    mu_status: u32,
    mu_baud_rate: u32,
}

#[cfg(target_os = "none")]
unsafe extern "C" {
    fn irq_disable();
    fn irq_enable();
}

#[cfg(not(target_os = "none"))]
unsafe fn irq_disable() {}

#[cfg(not(target_os = "none"))]
unsafe fn irq_enable() {}

#[inline]
fn regs() -> *mut AuxRegs {
    AUX_BASE as *mut AuxRegs
}

/// Initialize GPIO14/15 and the AUX mini-UART for 115200 8N1.
///
/// # Safety
/// The high device mapping is installed and bring-up calls this once before
/// enabling the AUX interrupt.
pub unsafe fn mini_uart_init() {
    unsafe { rpi4b_gpio::gpio_pin_set_func(TXD0, GF_ALT5) };
    unsafe { rpi4b_gpio::gpio_pin_set_func(RXD0, GF_ALT5) };
    unsafe { rpi4b_gpio::gpio_pin_enable(TXD0) };
    unsafe { rpi4b_gpio::gpio_pin_enable(RXD0) };

    let aux = regs();
    unsafe { write_volatile(addr_of_mut!((*aux).enables), 1) };
    unsafe { write_volatile(addr_of_mut!((*aux).mu_control), 0) };
    unsafe { write_volatile(addr_of_mut!((*aux).mu_ier), 0xD) };
    unsafe { write_volatile(addr_of_mut!((*aux).mu_lcr), 3) };
    unsafe { write_volatile(addr_of_mut!((*aux).mu_mcr), 0) };
    unsafe { write_volatile(addr_of_mut!((*aux).mu_baud_rate), 541) };
    unsafe { write_volatile(addr_of_mut!((*aux).mu_control), 3) };

    while unsafe { read_volatile(addr_of_mut!((*aux).mu_lsr)) } & 1 != 0 {
        let _ = unsafe { read_volatile(addr_of_mut!((*aux).mu_io)) };
    }

    unsafe { mini_uart_send(b'\r') };
    unsafe { mini_uart_send(b'\n') };
    unsafe { mini_uart_send(b'\n') };
}

/// Send one byte through the AUX mini-UART.
///
/// # Safety
/// The mini-UART is initialized and the device mapping remains installed.
#[inline(never)]
pub unsafe fn mini_uart_send(byte: u8) {
    let aux = regs();
    while unsafe { read_volatile(addr_of_mut!((*aux).mu_lsr)) } & 0x20 == 0 {}
    unsafe { write_volatile(addr_of_mut!((*aux).mu_io), u32::from(byte)) };
}

/// Block until and return one received byte.
///
/// # Safety
/// The mini-UART is initialized and the caller may block on RX.
#[inline(never)]
pub unsafe fn mini_uart_recv() -> u8 {
    let aux = regs();
    while unsafe { read_volatile(addr_of_mut!((*aux).mu_lsr)) } & 1 == 0 {}
    unsafe { read_volatile(addr_of_mut!((*aux).mu_io)) as u8 }
}

/// Whether the RX FIFO currently has at least one byte ready.
///
/// # Safety
/// The mini-UART is initialized and the device mapping remains installed.
pub unsafe fn mini_uart_rx_pending() -> bool {
    (unsafe { read_volatile(addr_of_mut!((*regs()).mu_lsr)) }) & 1 != 0
}

/// Drain pending RX bytes into the shared console ring outside IRQ context.
///
/// # Safety
/// Called by the single-core idle loop with the mini-UART initialized.
pub unsafe fn poll_rx_into_console() {
    unsafe { irq_disable() };
    while unsafe { mini_uart_rx_pending() } {
        let byte = unsafe { mini_uart_recv() };
        unsafe { console::console_push(byte) };
    }
    unsafe { irq_enable() };
}

unsafe fn emit_c_string(mut string: *const u8, mut emit: impl FnMut(u8)) {
    loop {
        let byte = unsafe { string.read() };
        if byte == 0 {
            return;
        }
        if byte == b'\n' {
            emit(b'\r');
        }
        emit(byte);
        string = unsafe { string.add(1) };
    }
}

/// Send a NUL-terminated string, translating LF to CRLF.
///
/// # Safety
/// `string` points to a readable NUL-terminated byte string and the mini-UART
/// is initialized.
#[inline(never)]
pub unsafe fn mini_uart_send_string(string: *const u8) {
    unsafe { emit_c_string(string, |byte| mini_uart_send(byte)) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_layout_matches_the_flash_driver() {
        assert_eq!(core::mem::offset_of!(AuxRegs, enables), 0x04);
        assert_eq!(core::mem::offset_of!(AuxRegs, mu_io), 0x40);
        assert_eq!(core::mem::offset_of!(AuxRegs, mu_lsr), 0x54);
        assert_eq!(core::mem::offset_of!(AuxRegs, mu_control), 0x60);
        assert_eq!(core::mem::offset_of!(AuxRegs, mu_baud_rate), 0x68);
        assert_eq!(core::mem::size_of::<AuxRegs>(), 0x6c);
    }

    #[test]
    fn c_string_output_translates_lf_to_crlf() {
        let mut output = std::vec::Vec::new();
        unsafe { emit_c_string(c"one\ntwo".as_ptr().cast(), |byte| output.push(byte)) };
        assert_eq!(output, b"one\r\ntwo");
    }

    #[test]
    fn c_string_output_stops_at_the_first_nul() {
        let mut output = std::vec::Vec::new();
        unsafe { emit_c_string(b"ok\0ignored".as_ptr(), |byte| output.push(byte)) };
        assert_eq!(output, b"ok");
    }
}
