//! Raw EL0-to-EL1 syscall transport and the minimal process I/O surface.

#[cfg(any(target_os = "none", test))]
use flashos_abi::syscall::{SYS_EXIT, SYS_WRITE};

pub const STDOUT: i32 = 1;
pub const STDERR: i32 = 2;

/// The AArch64 register image consumed by `arch/aarch64/entry.S:el0_svc`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Registers {
    pub x: [u64; 6],
    pub x8: u64,
}

/// Place a syscall number and up to six arguments in the kernel ABI registers.
pub const fn place(number: u64, args: [u64; 6]) -> Registers {
    Registers {
        x: args,
        x8: number,
    }
}

/// Trap into the FlashOS kernel and return `x0`.
///
/// # Safety
///
/// The caller must satisfy the pointed-to memory and lifetime contract of the
/// selected syscall. The transport itself does not validate user pointers.
#[cfg(target_os = "none")]
pub unsafe fn raw(number: u64, args: [u64; 6]) -> i64 {
    let regs = place(number, args);
    let mut x0 = regs.x[0];
    unsafe {
        core::arch::asm!(
            "svc #0",
            inlateout("x0") x0,
            in("x1") regs.x[1],
            in("x2") regs.x[2],
            in("x3") regs.x[3],
            in("x4") regs.x[4],
            in("x5") regs.x[5],
            in("x8") regs.x8,
            options(nostack),
        );
    }
    x0 as i64
}

/// Write bytes to a unified file descriptor.
#[cfg(target_os = "none")]
pub fn write(fd: i32, bytes: &[u8]) -> i64 {
    unsafe {
        raw(
            SYS_WRITE,
            [
                fd as u64,
                bytes.as_ptr() as u64,
                bytes.len() as u64,
                0,
                0,
                0,
            ],
        )
    }
}

/// Write the complete slice, stopping on the first kernel error or zero write.
#[cfg(target_os = "none")]
pub fn write_all(fd: i32, mut bytes: &[u8]) -> Result<(), i64> {
    while !bytes.is_empty() {
        let written = write(fd, bytes);
        if written <= 0 {
            return Err(written);
        }
        let written = written as usize;
        if written > bytes.len() {
            return Err(-1);
        }
        bytes = &bytes[written..];
    }
    Ok(())
}

/// Terminate the current task. The current kernel ignores `status`, but it is
/// placed in x0 so the userspace ABI need not change when status propagation is
/// added later.
#[cfg(target_os = "none")]
pub fn exit(status: i32) -> ! {
    let _ = unsafe { raw(SYS_EXIT, [status as u64, 0, 0, 0, 0, 0]) };
    loop {
        unsafe { core::arch::asm!("wfe", options(nomem, nostack)) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn syscall_arguments_land_in_x0_through_x5_and_number_in_x8() {
        let regs = place(33, [10, 11, 12, 13, 14, 15]);
        assert_eq!(regs.x, [10, 11, 12, 13, 14, 15]);
        assert_eq!(regs.x8, 33);
    }

    #[test]
    fn write_uses_the_canonical_dispatch_slot() {
        let regs = place(SYS_WRITE, [STDOUT as u64, 0x1234, 7, 0, 0, 0]);
        assert_eq!(regs.x8, 33);
        assert_eq!(regs.x[..3], [1, 0x1234, 7]);
    }

    #[test]
    fn exit_uses_the_canonical_dispatch_slot() {
        let regs = place(SYS_EXIT, [9, 0, 0, 0, 0, 0]);
        assert_eq!(regs.x8, 2);
        assert_eq!(regs.x[0], 9);
    }
}
