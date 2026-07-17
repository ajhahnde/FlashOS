//! PL011 UART (UART4 on RPi4) — the dedicated trace interface, so trace output
//! stays out of the way of the mini-UART console. The hardware lives at the
//! BCM2711 device-MMIO window (0xFE201800), reachable through the linear map.
//!
//! The Flash/Zig original carried a comptime board gate that emitted empty stubs
//! on `virt`, where the BCM2711 device window is not mapped. The Rust kernel is
//! built for rpi4b only, so that branch is gone and this sits beside the other
//! `rpi4b_*` drivers: raw MMIO, reached only from the device build. A future
//! `virt` revival needs a board gate here before it may link this module — the
//! raw window would fault.

use crate::rpi4b_gpio;
use core::ptr::{addr_of_mut, read_volatile, write_volatile};

const LINEAR_MAP_BASE: usize = 0xFFFF_0000_0000_0000;
const DEVICE_BASE: usize = 0xFE00_0000;
const UART4_BASE: usize = DEVICE_BASE + 0x0020_1800 + LINEAR_MAP_BASE;

const TXD4: u8 = 8;
const RXD4: u8 = 9;
const GF_ALT4: u8 = 3;

#[repr(C)]
struct Pl011Regs {
    data: u32,
    rsrecr: u32,
    reserved: [u32; 4],
    flag: u32,
    reserved_1: u32,
    ilpr: u32,
    ibrd: u32,
    fbrd: u32,
    lcrh: u32,
    cr: u32,
    ifls: u32,
    imsc: u32,
    ris: u32,
    mis: u32,
    icr: u32,
    dmacr: u32,
    reserved_2: [u32; 13],
    itcr: u32,
    itip: u32,
    itop: u32,
    tdr: u32,
}

#[inline]
fn regs() -> *mut Pl011Regs {
    UART4_BASE as *mut Pl011Regs
}

/// Route GPIO8/9 to UART4 and bring the PL011 up for trace output.
///
/// # Safety
/// The high device mapping is installed and bring-up calls this once.
pub unsafe fn pl011_uart_init() {
    unsafe { rpi4b_gpio::gpio_pin_set_func(TXD4, GF_ALT4) };
    unsafe { rpi4b_gpio::gpio_pin_set_func(RXD4, GF_ALT4) };
    unsafe { rpi4b_gpio::gpio_pin_enable(TXD4) };
    unsafe { rpi4b_gpio::gpio_pin_enable(RXD4) };

    let r = regs();
    // SAFETY: the device mapping makes the register window addressable.
    unsafe {
        // 8-bit word size, no parity, FIFO enabled, no break
        write_volatile(addr_of_mut!((*r).lcrh), 0x70);
        // immediate interrupts
        write_volatile(addr_of_mut!((*r).ifls), 0);
        // baud rate divisors
        write_volatile(addr_of_mut!((*r).ibrd), 26);
        write_volatile(addr_of_mut!((*r).fbrd), 3);
        // mask all interrupts for now
        write_volatile(addr_of_mut!((*r).imsc), 0x7FF);
        // flow control + enable TX/RX + enable UART
        write_volatile(addr_of_mut!((*r).cr), 0xC301);
    }
}

/// Send one byte, spinning while the TX FIFO is full.
///
/// # Safety
/// `pl011_uart_init` ran and the device mapping is live.
#[inline(never)]
pub unsafe fn pl011_uart_send(c: u8) {
    let r = regs();
    // SAFETY: the device mapping makes the register window addressable.
    unsafe {
        while (read_volatile(addr_of_mut!((*r).flag)) & 0x20) != 0 {}
        write_volatile(addr_of_mut!((*r).data), u32::from(c));
    }
}

/// Receive one byte, spinning while the RX FIFO is empty.
///
/// # Safety
/// `pl011_uart_init` ran and the device mapping is live.
pub unsafe fn pl011_uart_recv() -> u8 {
    let r = regs();
    // SAFETY: the device mapping makes the register window addressable.
    unsafe {
        while (read_volatile(addr_of_mut!((*r).flag)) & 0x10) != 0 {}
        (read_volatile(addr_of_mut!((*r).data)) & 0xFF) as u8
    }
}

/// Send a NUL-terminated string, expanding LF to CRLF.
///
/// # Safety
/// `string` points at a NUL-terminated buffer and the device mapping is live.
#[inline(never)]
pub unsafe fn pl011_uart_send_string(string: *const u8) {
    // SAFETY: the caller guarantees the NUL terminator bounds the scan.
    unsafe {
        let mut i = 0;
        while *string.add(i) != 0 {
            let c = *string.add(i);
            if c == b'\n' {
                pl011_uart_send(b'\r');
            }
            pl011_uart_send(c);
            i += 1;
        }
    }
}
