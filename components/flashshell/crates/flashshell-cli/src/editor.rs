use std::error::Error;
use std::fmt;

/// Text rendered around one interactive edit buffer.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EditorPrompt {
    primary: String,
    continuation: String,
}

impl EditorPrompt {
    #[must_use]
    pub fn new(primary: impl Into<String>, continuation: impl Into<String>) -> Self {
        Self {
            primary: primary.into(),
            continuation: continuation.into(),
        }
    }

    #[must_use]
    pub fn primary(&self) -> &str {
        &self.primary
    }

    #[must_use]
    pub fn continuation(&self) -> &str {
        &self.continuation
    }
}

/// One editor result, independent of the terminal-editing implementation.
#[derive(Clone, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum EditorEvent {
    Submitted(String),
    Cancelled,
    EndOfInput,
    HostCommand(String),
    ExternalBreak(String),
}

/// Failure reported by the selected terminal editor.
#[derive(Debug)]
pub struct EditorError {
    message: String,
    source: Option<Box<dyn Error + Send + Sync>>,
}

impl EditorError {
    #[must_use]
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            source: None,
        }
    }

    pub(crate) fn with_source(
        message: impl Into<String>,
        source: impl Error + Send + Sync + 'static,
    ) -> Self {
        Self {
            message: message.into(),
            source: Some(Box::new(source)),
        }
    }
}

impl fmt::Display for EditorError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for EditorError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        self.source
            .as_deref()
            .map(|source| source as &(dyn Error + 'static))
    }
}

/// Synchronous input boundary consumed by an interactive FlashShell session.
pub trait LineEditor {
    fn read_line(&mut self, prompt: &EditorPrompt) -> Result<EditorEvent, EditorError>;
}
