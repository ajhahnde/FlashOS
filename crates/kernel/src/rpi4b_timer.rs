//! BCM2711 system-timer compare channel 1.

use crate::utilc;
use core::ptr::{addr_of_mut, read_volatile, write_volatile};

const LINEAR_MAP_BASE: usize = 0xFFFF_0000_0000_0000;
const DEVICE_BASE: usize = 0xFE00_0000;
const TIMER_BASE: usize = DEVICE_BASE + 0x3000 + LINEAR_MAP_BASE;
const CLOCK_HZ: u32 = 1_000_000;
const MU: i32 = 0;

#[repr(C)]
struct SysTimerRegs {
    control_status: u32,
    counter_lo: u32,
    counter_hi: u32,
    compare: [u32; 4],
}

static mut CUR_LS32_1: u32 = 0;

fn next_compare(current: u32) -> u32 {
    current.wrapping_add(CLOCK_HZ)
}

/// Initialize system-timer compare 1. Compare 0 and 2 belong to VideoCore.
///
/// # Safety
/// The BCM2711 device mapping is installed and bring-up calls this once before
/// channel-1 interrupts can be delivered.
pub unsafe fn timer_init() {
    let regs = TIMER_BASE as *mut SysTimerRegs;
    let counter = unsafe { read_volatile(addr_of_mut!((*regs).counter_lo)) };
    let deadline = next_compare(counter);
    unsafe { CUR_LS32_1 = deadline };
    unsafe { write_volatile(addr_of_mut!((*regs).compare[1]), deadline) };
}

/// Advance and acknowledge system-timer compare 1.
///
/// # Safety
/// Called only from the serialized channel-1 IRQ path after initialization.
pub unsafe fn handle_sys_timer_1() {
    let regs = TIMER_BASE as *mut SysTimerRegs;
    let deadline = next_compare(unsafe { CUR_LS32_1 });
    unsafe { CUR_LS32_1 = deadline };
    unsafe { write_volatile(addr_of_mut!((*regs).compare[1]), deadline) };

    let status = unsafe { read_volatile(addr_of_mut!((*regs).control_status)) };
    unsafe { write_volatile(addr_of_mut!((*regs).control_status), status | (1 << 1)) };

    unsafe { utilc::main_output(MU, c"timer 1 interrupt\n".as_ptr().cast()) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_layout_matches_the_flash_driver() {
        assert_eq!(core::mem::offset_of!(SysTimerRegs, counter_lo), 0x04);
        assert_eq!(core::mem::offset_of!(SysTimerRegs, compare), 0x0c);
        assert_eq!(core::mem::size_of::<SysTimerRegs>(), 0x1c);
    }

    #[test]
    fn compare_deadline_advances_one_second() {
        assert_eq!(next_compare(41), 1_000_041);
    }

    #[test]
    fn compare_deadline_wraps_like_the_hardware_counter() {
        assert_eq!(next_compare(u32::MAX - 3), CLOCK_HZ - 4);
    }
}
