//! Kernel console and the in-memory kernel-log ring.
// This directory groups the console driver; the file keeps the name `console.rs` for history continuity.
#[allow(clippy::module_inception)]
pub mod console;
pub mod klog_ring;
