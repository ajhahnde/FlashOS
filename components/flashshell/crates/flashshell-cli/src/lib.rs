#![forbid(unsafe_code)]

//! Interactive client boundaries for FlashShell.

pub mod editor;
pub mod interactive;

#[cfg(any(target_os = "macos", target_os = "linux"))]
mod reedline_editor;

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub use reedline_editor::ReedlineEditor;
