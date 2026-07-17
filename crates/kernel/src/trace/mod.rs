//! The kernel trace subsystem: dynamic function tracing, the statistical
//! sampler, the symbol table both resolve against, and the dedicated trace UART.
//!
//! The trace assembly (`hook.S`, `patchable_trampolines.S`) stays assembly and
//! reaches this module by symbol through the C-ABI seam in `crates/klib`.

pub mod fp_walk;
pub mod ksyms;
pub mod pl011_uart;
pub mod sampler;
pub mod trace_main;
pub mod utils;
