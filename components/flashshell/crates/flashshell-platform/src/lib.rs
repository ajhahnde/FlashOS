#![forbid(unsafe_code)]

//! Platform-neutral capability contracts for FlashShell.

/// Marker trait implemented by FlashShell platform adapters.
pub trait Platform: Send + Sync {}
