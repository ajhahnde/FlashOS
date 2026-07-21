#![deny(unsafe_code)]

//! POSIX platform adapter for FlashShell.
//!
//! macOS and Linux provide every FlashShell platform capability. The concrete
//! process, descriptor, and terminal implementations are built out as the
//! features that need them land; this adapter already reports the full
//! capability set so the runtime resolves internal-vs-external and plan
//! preflight against a truthful host profile.

use flashshell_platform::{Capabilities, Platform};

/// POSIX adapter for process and terminal capabilities.
#[derive(Debug, Default, Clone, Copy)]
pub struct PosixPlatform;

impl Platform for PosixPlatform {
    fn capabilities(&self) -> Capabilities {
        Capabilities::full()
    }
}
