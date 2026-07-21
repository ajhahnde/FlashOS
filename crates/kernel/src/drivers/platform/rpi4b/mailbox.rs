//! BCM2711 VideoCore property-mailbox MMIO transport.

use crate::mailbox;
use core::ptr::{addr_of_mut, read_volatile, write_volatile};

const LINEAR_MAP_BASE: usize = 0xFFFF_0000_0000_0000;
const DEVICE_BASE: usize = 0xFE00_0000;
const MBOX_BASE: usize = DEVICE_BASE + 0xB880 + LINEAR_MAP_BASE;
const STATUS_FULL: u32 = 0x8000_0000;
const STATUS_EMPTY: u32 = 0x4000_0000;
const SPIN: u32 = 1_000_000;

#[repr(C)]
struct MboxRegs {
    read: u32,
    reserved: [u32; 3],
    peek: u32,
    sender: u32,
    status: u32,
    config: u32,
    write: u32,
}

#[repr(align(16))]
struct AlignedMessage(mailbox::Msg);

static mut PROPERTY_BUFFER: AlignedMessage = AlignedMessage([0; 8]);

#[inline]
fn regs() -> *mut MboxRegs {
    MBOX_BASE as *mut MboxRegs
}

#[inline]
fn data_barrier() {
    #[cfg(target_arch = "aarch64")]
    unsafe {
        core::arch::asm!("dsb sy", options(nostack, preserves_flags));
    }
    #[cfg(not(target_arch = "aarch64"))]
    core::sync::atomic::compiler_fence(core::sync::atomic::Ordering::SeqCst);
}

/// Post the fixed property buffer and wait for its matching response.
///
/// # Safety
/// `message` is the aligned low-image property buffer, exclusively owned by
/// this serialized mailbox transaction.
unsafe fn transact(message: *mut mailbox::Msg) -> bool {
    let registers = regs();
    let doorbell = mailbox::doorbell(message as usize as u32, mailbox::CHANNEL_PROP);

    let mut drain = 0;
    while unsafe { read_volatile(addr_of_mut!((*registers).status)) } & STATUS_EMPTY == 0 {
        let _ = unsafe { read_volatile(addr_of_mut!((*registers).read)) };
        if drain >= SPIN {
            break;
        }
        drain += 1;
    }

    data_barrier();

    let mut spin = 0;
    while unsafe { read_volatile(addr_of_mut!((*registers).status)) } & STATUS_FULL != 0 {
        if spin >= SPIN {
            return false;
        }
        spin += 1;
    }
    unsafe { write_volatile(addr_of_mut!((*registers).write), doorbell) };

    spin = 0;
    loop {
        if spin >= SPIN {
            return false;
        }
        if unsafe { read_volatile(addr_of_mut!((*registers).status)) } & STATUS_EMPTY == 0
            && unsafe { read_volatile(addr_of_mut!((*registers).read)) } == doorbell
        {
            break;
        }
        spin += 1;
    }

    data_barrier();
    true
}

unsafe fn submit(request: mailbox::Msg) -> Option<mailbox::Msg> {
    let message = unsafe { addr_of_mut!(PROPERTY_BUFFER.0) };
    unsafe { message.write(request) };
    if !unsafe { transact(message) } {
        return None;
    }
    Some(unsafe { message.read() })
}

/// Query a VideoCore-managed clock rate in Hz, or zero on failure.
///
/// # Safety
/// Mailbox calls are serialized by the single-core kernel.
pub unsafe fn get_clock_rate(clock_id: u32) -> u32 {
    unsafe { submit(mailbox::build_get_clock_rate(clock_id)) }
        .and_then(|message| mailbox::parse_clock_rate(&message, clock_id))
        .unwrap_or(0)
}

/// Read the SoC temperature in milli-degrees Celsius, or zero on failure.
///
/// # Safety
/// Mailbox calls are serialized by the single-core kernel.
pub unsafe fn get_temperature() -> u32 {
    unsafe { submit(mailbox::build_get_temperature(0)) }
        .and_then(|message| mailbox::parse_temperature(&message, 0))
        .unwrap_or(0)
}

/// Read the firmware-reported ARM clock in Hz, or zero on failure.
///
/// # Safety
/// Mailbox calls are serialized by the single-core kernel.
pub unsafe fn get_cpu_clock() -> u32 {
    unsafe { get_clock_rate(mailbox::CLOCK_ID_ARM) }
}

/// Set one firmware-managed GPIO.
///
/// # Safety
/// Mailbox calls are serialized by the single-core kernel.
pub unsafe fn set_gpio_state(gpio: u32, state: u32) -> bool {
    unsafe { submit(mailbox::build_set_gpio_state(gpio, state)) }
        .is_some_and(|message| mailbox::check_response(&message))
}

/// Set one firmware-managed power rail.
///
/// # Safety
/// Mailbox calls are serialized by the single-core kernel.
pub unsafe fn set_power_state(device_id: u32, state: u32) -> bool {
    let want_on = state & mailbox::POWER_STATE_ON != 0;
    unsafe { submit(mailbox::build_set_power_state(device_id, state)) }
        .is_some_and(|message| mailbox::parse_power_state(&message, device_id, want_on))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_layout_matches_the_flash_driver() {
        assert_eq!(core::mem::offset_of!(MboxRegs, read), 0x00);
        assert_eq!(core::mem::offset_of!(MboxRegs, status), 0x18);
        assert_eq!(core::mem::offset_of!(MboxRegs, write), 0x20);
        assert_eq!(core::mem::size_of::<MboxRegs>(), 0x24);
    }

    #[test]
    fn property_buffer_reserves_the_doorbell_channel_nibble() {
        assert_eq!(core::mem::align_of::<AlignedMessage>(), 16);
        assert_eq!(core::mem::size_of::<AlignedMessage>(), 32);
    }
}
