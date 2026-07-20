#![deny(unsafe_code)]

//! POSIX platform adapter for FlashShell.

use flashshell_platform::Platform;

/// POSIX adapter placeholder for process and terminal capabilities.
#[derive(Debug, Default)]
pub struct PosixPlatform;

impl Platform for PosixPlatform {}
