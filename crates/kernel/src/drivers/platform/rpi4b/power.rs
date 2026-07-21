//! BCM2711 power-manager watchdog reset.

use core::ptr::{read_volatile, write_volatile};

const LINEAR_MAP_BASE: usize = 0xFFFF_0000_0000_0000;
const DEVICE_BASE: usize = 0xFE00_0000;
const PM_BASE: usize = DEVICE_BASE + 0x0010_0000 + LINEAR_MAP_BASE;

const PM_RSTC: *mut u32 = (PM_BASE + 0x1c) as *mut u32;
const PM_WDOG: *mut u32 = (PM_BASE + 0x24) as *mut u32;
const PM_PASSWORD: u32 = 0x5A00_0000;
const PM_RSTC_WRCFG_CLR: u32 = 0xFFFF_FFCF;
const PM_RSTC_WRCFG_FULL_RESET: u32 = 0x0000_0020;
const PM_WDOG_TICKS: u32 = 10;

fn reset_control(current: u32) -> u32 {
    PM_PASSWORD | (current & PM_RSTC_WRCFG_CLR) | PM_RSTC_WRCFG_FULL_RESET
}

/// Arm a short watchdog timeout and request a full BCM2711 reset.
///
/// # Safety
/// The high device mapping is installed and the caller has exclusive control
/// of the machine's terminal reboot path.
pub unsafe fn reboot() -> ! {
    unsafe { write_volatile(PM_WDOG, PM_PASSWORD | PM_WDOG_TICKS) };
    let current = unsafe { read_volatile(PM_RSTC) };
    unsafe { write_volatile(PM_RSTC, reset_control(current)) };

    loop {
        #[cfg(target_arch = "aarch64")]
        unsafe {
            core::arch::asm!("wfe", options(nomem, nostack, preserves_flags));
        }
        #[cfg(not(target_arch = "aarch64"))]
        core::hint::spin_loop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn watchdog_write_carries_the_password_and_short_timeout() {
        assert_eq!(PM_PASSWORD | PM_WDOG_TICKS, 0x5A00_000A);
    }

    #[test]
    fn reset_control_preserves_unowned_bits_and_selects_full_reset() {
        let current = 0xA5A5_5A5A;
        let expected = PM_PASSWORD | (current & PM_RSTC_WRCFG_CLR) | PM_RSTC_WRCFG_FULL_RESET;
        assert_eq!(reset_control(current), expected);
        assert_eq!(reset_control(current) & 0x30, PM_RSTC_WRCFG_FULL_RESET);
    }
}
