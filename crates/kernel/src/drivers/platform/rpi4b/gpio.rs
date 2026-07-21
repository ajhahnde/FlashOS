//! BCM2711 GPIO pin-function and pull-control registers.

use core::ptr::{addr_of_mut, read_volatile, write_volatile};

const LINEAR_MAP_BASE: usize = 0xFFFF_0000_0000_0000;
const DEVICE_BASE: usize = 0xFE00_0000;
const GPIO_BASE: usize = DEVICE_BASE + 0x0020_0000 + LINEAR_MAP_BASE;

#[repr(C)]
struct GpioPinData {
    reserved: u32,
    data: [u32; 2],
}

#[repr(C)]
struct GpioRegs {
    func_select: [u32; 6],
    output_set: GpioPinData,
    output_clear: GpioPinData,
    level: GpioPinData,
    ev_detect_status: GpioPinData,
    re_detect_enable: GpioPinData,
    fe_detect_enable: GpioPinData,
    hi_detect_enable: GpioPinData,
    lo_detect_enable: GpioPinData,
    async_re_detect: GpioPinData,
    async_fe_detect: GpioPinData,
    reserved: u32,
    pupd_enable: u32,
    pupd_enable_clocks: [u32; 2],
    reserved2: [u32; 18],
    pullup_pulldown: [u32; 4],
}

fn replace_field(value: u32, shift: u32, mask: u32, field: u32) -> u32 {
    (value & !(mask << shift)) | (field << shift)
}

/// Set the alternate function for a GPIO pin.
///
/// # Safety
/// The kernel has installed the BCM2711 device mapping and `pin_number` names
/// a GPIO represented by the controller's six function-select registers.
pub unsafe fn gpio_pin_set_func(pin_number: u8, func: u8) {
    let register = usize::from(pin_number / 10);
    let shift = u32::from((pin_number % 10) * 3);
    let regs = GPIO_BASE as *mut GpioRegs;
    let selector = unsafe {
        addr_of_mut!((*regs).func_select)
            .cast::<u32>()
            .add(register)
    };
    let value = unsafe { read_volatile(selector) };
    unsafe {
        write_volatile(
            selector,
            replace_field(value, shift, 0b111, u32::from(func)),
        )
    };
}

/// Disable pull-up/pull-down for a GPIO pin.
///
/// # Safety
/// The kernel has installed the BCM2711 device mapping and `pin_number` names
/// a GPIO represented by the controller's four pull-control registers.
pub unsafe fn gpio_pin_enable(pin_number: u8) {
    let register = usize::from(pin_number / 16);
    let shift = u32::from((pin_number % 16) * 2);
    let regs = GPIO_BASE as *mut GpioRegs;
    let control = unsafe {
        addr_of_mut!((*regs).pullup_pulldown)
            .cast::<u32>()
            .add(register)
    };
    let value = unsafe { read_volatile(control) };
    unsafe { write_volatile(control, replace_field(value, shift, 0b11, 0)) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_layout_matches_the_flash_driver() {
        assert_eq!(core::mem::offset_of!(GpioRegs, func_select), 0x00);
        assert_eq!(core::mem::offset_of!(GpioRegs, pullup_pulldown), 0xe8);
        assert_eq!(core::mem::size_of::<GpioRegs>(), 0xf8);
    }

    #[test]
    fn function_select_replaces_only_the_requested_three_bits() {
        let original = 0xA5A5_5A5A;
        let updated = replace_field(original, 12, 0b111, 5);
        assert_eq!(updated & !(0b111 << 12), original & !(0b111 << 12));
        assert_eq!((updated >> 12) & 0b111, 5);
    }

    #[test]
    fn pin_enable_clears_only_the_requested_pull_pair() {
        let original = u32::MAX;
        let updated = replace_field(original, 18, 0b11, 0);
        assert_eq!(updated, original & !(0b11 << 18));
    }
}
