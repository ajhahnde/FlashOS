use std::borrow::Cow;

use reedline::{Prompt, PromptEditMode, PromptHistorySearch, Reedline, Signal};

use crate::editor::{EditorError, EditorEvent, EditorPrompt, LineEditor};

/// macOS/Linux terminal editor backed by the pinned Reedline implementation.
pub struct ReedlineEditor {
    inner: Reedline,
}

impl ReedlineEditor {
    #[must_use]
    pub fn new() -> Self {
        Self {
            inner: Reedline::create(),
        }
    }
}

impl Default for ReedlineEditor {
    fn default() -> Self {
        Self::new()
    }
}

impl LineEditor for ReedlineEditor {
    fn read_line(&mut self, prompt: &EditorPrompt) -> Result<EditorEvent, EditorError> {
        let prompt = ReedlinePrompt { prompt };
        self.inner
            .read_line(&prompt)
            .map_err(|error| EditorError::with_source("line editor failed", error))
            .and_then(map_signal)
    }
}

fn map_signal(signal: Signal) -> Result<EditorEvent, EditorError> {
    match signal {
        Signal::Success(buffer) => Ok(EditorEvent::Submitted(buffer)),
        Signal::CtrlC => Ok(EditorEvent::Cancelled),
        Signal::CtrlD => Ok(EditorEvent::EndOfInput),
        Signal::HostCommand(command) => Ok(EditorEvent::HostCommand(command)),
        Signal::ExternalBreak(buffer) => Ok(EditorEvent::ExternalBreak(buffer)),
        _ => Err(EditorError::new(
            "line editor returned an unsupported event",
        )),
    }
}

struct ReedlinePrompt<'prompt> {
    prompt: &'prompt EditorPrompt,
}

impl Prompt for ReedlinePrompt<'_> {
    fn render_prompt_left(&self) -> Cow<'_, str> {
        Cow::Borrowed(self.prompt.primary())
    }

    fn render_prompt_right(&self) -> Cow<'_, str> {
        Cow::Borrowed("")
    }

    fn render_prompt_indicator(&self, _prompt_mode: PromptEditMode) -> Cow<'_, str> {
        Cow::Borrowed("")
    }

    fn render_prompt_multiline_indicator(&self) -> Cow<'_, str> {
        Cow::Borrowed(self.prompt.continuation())
    }

    fn render_prompt_history_search_indicator(
        &self,
        _history_search: PromptHistorySearch,
    ) -> Cow<'_, str> {
        Cow::Borrowed("")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_reedline_signal_crosses_as_an_editor_owned_event() {
        let cases = [
            (
                Signal::Success("echo hello".to_owned()),
                EditorEvent::Submitted("echo hello".to_owned()),
            ),
            (Signal::CtrlC, EditorEvent::Cancelled),
            (Signal::CtrlD, EditorEvent::EndOfInput),
            (
                Signal::HostCommand("host-action".to_owned()),
                EditorEvent::HostCommand("host-action".to_owned()),
            ),
            (
                Signal::ExternalBreak("partial input".to_owned()),
                EditorEvent::ExternalBreak("partial input".to_owned()),
            ),
        ];

        for (signal, expected) in cases {
            assert_eq!(
                map_signal(signal).expect("known signal should map"),
                expected
            );
        }
    }

    #[test]
    fn prompt_bridge_preserves_primary_and_continuation_text() {
        let prompt = EditorPrompt::new("fsh> ", "...> ");
        let bridge = ReedlinePrompt { prompt: &prompt };

        assert_eq!(bridge.render_prompt_left(), "fsh> ");
        assert_eq!(bridge.render_prompt_multiline_indicator(), "...> ");
    }
}
