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

/// Serializes every host-side output capture across the whole subsystem.
///
/// The trace emitters all append to one process-wide buffer
/// (`utils::seam::LAST_OUTPUT`). Tests live in several modules — `utils` reads
/// the buffer directly, while `trace_main`'s patch tests emit into it as a side
/// effect of `trace_output_insn`. A per-module lock only serializes a module
/// against itself, so a task dump in `utils` could read bytes a `trace_main`
/// test wrote. One shared lock is the only correct serialization.
#[cfg(all(test, not(target_os = "none")))]
pub(crate) static CAPTURE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
