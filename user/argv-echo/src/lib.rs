//! The execve scenario's payload: prove argv arrives on the freshly mapped user
//! stack as `x0 = argc`, `x1 = argv`, and that a payload larger than one page loads.
//!
//! The body walks argv and prints each argument on its own line. The ELF is
//! deliberately over 4 KiB so it can only travel the kernel's segment-streaming
//! loader; a single-page payload would also have fitted the long-retired snapshot
//! cap and so would prove nothing about the cap being gone.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_flibc::{printf, Part::Str};
#[cfg(target_os = "none")]
use flashsdk_rt::{arg, entry, Argv};

/// Read-only padding that pushes the linked ELF past one page.
#[cfg(target_os = "none")]
#[used]
#[link_section = ".rodata"]
static PAD: [u8; 4096] = [0xAB; 4096];

/// Make the padding's address escape through an opaque asm block, so neither the
/// compiler nor `--gc-sections` can drop a global nothing else reads.
#[cfg(target_os = "none")]
fn keep_pad() {
    // The operand has to appear in the template or the assembler rejects it, so it
    // lands in a comment: the point is only that the address is handed to a block the
    // compiler cannot see through.
    unsafe {
        core::arch::asm!("/* {0} */", in(reg) PAD.as_ptr(), options(nostack, nomem));
    }
}

#[cfg(target_os = "none")]
fn main(argc: usize, argv: Argv) -> i32 {
    keep_pad();
    let mut i = 0;
    while i < argc {
        let Some(s) = (unsafe { arg(argv, i) }) else {
            break;
        };
        printf(&[Str(s), Str(b"\n")]);
        i += 1;
    }
    0
}

#[cfg(target_os = "none")]
entry!(main);
