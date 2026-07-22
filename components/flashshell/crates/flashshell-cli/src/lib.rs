#![forbid(unsafe_code)]

//! Interactive client boundaries for FlashShell.

pub mod completion;
#[cfg(any(target_os = "macos", target_os = "linux"))]
pub mod config;
pub mod editor;
pub mod highlight;
pub mod hint;
#[cfg(any(target_os = "macos", target_os = "linux"))]
pub mod history;
pub mod interactive;

#[cfg(any(target_os = "macos", target_os = "linux"))]
mod reedline_editor;

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub use reedline_editor::ReedlineEditor;
