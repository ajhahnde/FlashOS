//! The stack-overflow scenario's payload: a recursion that never terminates.
//!
//! Each frame pushes 1 KiB (`sub sp, #1024` + a link-register store), so every call
//! deepens the stack by exactly that much. After enough frames the stack pointer
//! crosses into the guard page and the next store faults; the kernel's data-abort
//! handler recognises the guard fault, prints its diagnostic, and zombies the task.
//! The parent's wait then reaps it as usual, which is what returns the page balance
//! to its baseline -- the thing the harness actually measures.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

// Nothing here calls the runtime, but every no_std payload needs its panic handler,
// and an unreferenced dependency is not loaded -- so name it.
#[cfg(target_os = "none")]
extern crate flashsdk_rt as _;

#[cfg(target_os = "none")]
use flashsdk_abi::user::STACK_BUDGET;

// Each frame pushes 1 KiB. The recursion is only representative if the budget allows
// a real descent before the guard page stops it, so hold that floor here rather than
// discovering a one-frame "overflow" in a serial log.
#[cfg(target_os = "none")]
const _: () = assert!(
    STACK_BUDGET / 1024 >= 16,
    "stack budget too small for a representative recursion depth"
);

#[cfg(target_os = "none")]
core::arch::global_asm!(
    ".section .text._start,\"ax\",@progbits",
    ".globl _start",
    ".balign 8",
    "_start:",
    "1:",
    "    sub sp, sp, #1024",
    "    str x30, [sp]",
    "    bl 1b",
);
