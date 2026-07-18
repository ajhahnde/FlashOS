//! Build smoke test: the smallest Rust `kernel_main` that the real FlashOS boot
//! assembly and the real board linker script carry to EL1 with the MMU on. It
//! writes one marker over the board's UART and halts.
//!
//! This is not product code. It is the permanent proof that the Rust toolchain,
//! the assembler, the linker script, and the image layout still agree with the
//! boot firmware — the thing that would otherwise only be discovered by a dead
//! board mid-port. `cargo xtask smoke --board <b>` boots it and greps the marker.

#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]

use core::panic::PanicInfo;
use core::ptr;

pub const MARKER: &[u8] = b"\r\n[RUST-CANARY] kernel_main reached EL1 via boot.S\r\n";

const LINEAR_MAP_BASE: usize = 0xFFFF_0000_0000_0000;

#[cfg(not(feature = "virt"))]
unsafe fn mmio_write(addr: usize, val: u32) {
    unsafe { ptr::write_volatile(addr as *mut u32, val) };
}

#[cfg(not(feature = "virt"))]
unsafe fn mmio_read(addr: usize) -> u32 {
    unsafe { ptr::read_volatile(addr as *const u32) }
}

// ---------------------------------------------------------------------------
// rpi4b: AUX mini-UART on GPIO14/15, matching the native board driver.
// ---------------------------------------------------------------------------

#[cfg(not(feature = "virt"))]
mod uart {
    use super::{mmio_read, mmio_write, LINEAR_MAP_BASE};

    const DEVICE_BASE: usize = 0xFE00_0000;
    const GPIO_BASE: usize = LINEAR_MAP_BASE + DEVICE_BASE + 0x0020_0000;
    const AUX_BASE: usize = LINEAR_MAP_BASE + DEVICE_BASE + 0x0021_5000;

    const AUX_ENABLES: usize = AUX_BASE + 0x04;
    const MU_IO: usize = AUX_BASE + 0x40;
    const MU_IER: usize = AUX_BASE + 0x44;
    const MU_LCR: usize = AUX_BASE + 0x4C;
    const MU_MCR: usize = AUX_BASE + 0x50;
    const MU_LSR: usize = AUX_BASE + 0x54;
    const MU_CNTL: usize = AUX_BASE + 0x60;
    const MU_BAUD: usize = AUX_BASE + 0x68;

    /// GPIO 14/15 -> ALT5 (mini-UART); ALT5 is 0b010 in the func-select field.
    unsafe fn gpio_alt5(sel_reg: usize) {
        unsafe {
            let mut sel = mmio_read(sel_reg);
            sel &= !(7 << 12); // pin 14
            sel |= 2 << 12;
            sel &= !(7 << 15); // pin 15
            sel |= 2 << 15;
            mmio_write(sel_reg, sel);
        }
    }

    pub unsafe fn init() {
        unsafe {
            gpio_alt5(GPIO_BASE + 0x04); // GPFSEL1: pins 10..19
            mmio_write(AUX_ENABLES, 1);
            mmio_write(MU_CNTL, 0);
            mmio_write(MU_IER, 0);
            mmio_write(MU_LCR, 3); // 8-bit
            mmio_write(MU_MCR, 0);
            mmio_write(MU_BAUD, 541); // 115200 @ 250 MHz core clock
            mmio_write(MU_CNTL, 3); // TX+RX enable
        }
    }

    pub unsafe fn put(c: u8) {
        unsafe {
            while mmio_read(MU_LSR) & 0x20 == 0 {} // TX empty
            mmio_write(MU_IO, c as u32);
        }
    }
}

// ---------------------------------------------------------------------------
// virt: QEMU's PL011 is already programmed at kernel entry, so writing DR is
// the whole driver. Matches the native virt board setup.
// ---------------------------------------------------------------------------

#[cfg(feature = "virt")]
mod uart {
    use super::{ptr, LINEAR_MAP_BASE};

    const PL011_DR: usize = LINEAR_MAP_BASE + 0x0900_0000;

    pub unsafe fn init() {}

    pub unsafe fn put(c: u8) {
        unsafe { ptr::write_volatile(PL011_DR as *mut u32, c as u32) };
    }
}

unsafe fn puts(s: &[u8]) {
    for &b in s {
        unsafe { uart::put(b) };
    }
}

/// Entry point reached from arch/aarch64/boot.S (`bl kernel_main`): EL1, MMU on.
#[no_mangle]
pub extern "C" fn kernel_main() -> ! {
    unsafe {
        uart::init();
        puts(MARKER);
    }
    loop {
        unsafe { core::arch::asm!("wfe", options(nomem, nostack)) };
    }
}

// ---------------------------------------------------------------------------
// Symbols the boot and exception assembly references. The canary never takes an
// interrupt or a fault; these exist only to close the link. `irq_enable` and
// `irq_disable` are deliberately absent — arch/aarch64/irq.S defines them, and a
// Rust stub would be a duplicate-symbol error.
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn handle_irq() {}
#[no_mangle]
pub extern "C" fn preempt_enable() {}
#[no_mangle]
pub extern "C" fn do_data_abort(_esr: u64, _far: u64) {}
#[no_mangle]
pub extern "C" fn do_instruction_abort(_esr: u64, _far: u64) {}
#[no_mangle]
pub extern "C" fn do_el0_sync_fault(_esr: u64, _far: u64) {}

/// Physical base of the kernel image, written by boot.S (`adr x1, KERNEL_PA_BASE`).
#[no_mangle]
pub static mut KERNEL_PA_BASE: u64 = 0;

/// The syscall table entry.S indexes. Empty here.
#[no_mangle]
pub static sys_call_table: [usize; 64] = [0; 64];

// ---------------------------------------------------------------------------
// Freestanding mem*. Rust's precompiled compiler_builtins for
// aarch64-unknown-none-softfloat ships no mem* at all, and the Zig-side copies
// are local symbols, so the Rust side must export its own. Byte loops only:
// SCTLR_EL1.A is set, so a wide unaligned store would fault.
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn memcpy(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    let mut i = 0;
    while i < n {
        unsafe { *dst.add(i) = *src.add(i) };
        i += 1;
    }
    dst
}

#[no_mangle]
pub unsafe extern "C" fn memset(dst: *mut u8, c: i32, n: usize) -> *mut u8 {
    let mut i = 0;
    while i < n {
        unsafe { *dst.add(i) = c as u8 };
        i += 1;
    }
    dst
}

#[no_mangle]
pub unsafe extern "C" fn memmove(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    if (dst as usize) < (src as usize) {
        let mut i = 0;
        while i < n {
            unsafe { *dst.add(i) = *src.add(i) };
            i += 1;
        }
    } else {
        let mut i = n;
        while i > 0 {
            i -= 1;
            unsafe { *dst.add(i) = *src.add(i) };
        }
    }
    dst
}

#[no_mangle]
pub unsafe extern "C" fn memcmp(a: *const u8, b: *const u8, n: usize) -> i32 {
    let mut i = 0;
    while i < n {
        let (x, y) = unsafe { (*a.add(i), *b.add(i)) };
        if x != y {
            return x as i32 - y as i32;
        }
        i += 1;
    }
    0
}

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    unsafe { puts(b"\r\n[RUST-CANARY] PANIC\r\n") };
    loop {
        unsafe { core::arch::asm!("wfe", options(nomem, nostack)) };
    }
}
