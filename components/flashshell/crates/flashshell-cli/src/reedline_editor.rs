use std::borrow::Cow;

use flashshell_syntax::{ParseOutcome, SourceFile, SourceId, parse};
use nu_ansi_term::{Color, Style};
use reedline::{
    Completer, Highlighter, Prompt, PromptEditMode, PromptHistorySearch, Reedline, Signal, Span,
    StyledText, Suggestion, ValidationResult, Validator,
};

use crate::completion::{CompletionCatalog, CompletionEngine};
use crate::editor::{EditorError, EditorEvent, EditorPrompt, LineEditor};
use crate::highlight::{HighlightKind, SyntaxHighlighter};
use crate::history::{EditorHistory, HistoryError, HistorySelection};

/// macOS/Linux terminal editor backed by the pinned Reedline implementation.
pub struct ReedlineEditor {
    inner: Reedline,
}

impl ReedlineEditor {
    #[must_use]
    pub fn new() -> Self {
        Self {
            inner: editor_engine(),
        }
    }

    /// Constructs the editor with a FlashShell-selected history policy.
    pub fn with_history(selection: HistorySelection) -> Result<Self, HistoryError> {
        let history = EditorHistory::open(selection)?;
        Ok(Self {
            inner: editor_engine().with_history(history.into_backend()),
        })
    }
}

fn editor_engine() -> Reedline {
    let registry = flashshell_runtime::builtin::standard_registry();
    let scope = flashshell_runtime::ScopeStack::new();
    let catalog = CompletionCatalog::from_runtime(&registry, &scope);
    Reedline::create()
        .with_validator(Box::new(FlashShellValidator))
        .with_highlighter(Box::new(ReedlineSyntaxHighlighter))
        .with_completer(Box::new(ReedlineCompleter {
            engine: CompletionEngine::new(catalog),
        }))
}

impl Default for ReedlineEditor {
    fn default() -> Self {
        Self::new()
    }
}

impl LineEditor for ReedlineEditor {
    fn read_line(&mut self, prompt: &EditorPrompt) -> Result<EditorEvent, EditorError> {
        let prompt = ReedlinePrompt { prompt };
        let signal = self
            .inner
            .read_line(&prompt)
            .map_err(|error| EditorError::with_source("line editor failed", error))?;
        if matches!(signal, Signal::Success(_)) {
            self.inner.sync_history().map_err(|error| {
                EditorError::with_source("cannot synchronize interactive history", error)
            })?;
        }
        map_signal(signal)
    }
}

struct FlashShellValidator;

impl Validator for FlashShellValidator {
    fn validate(&self, line: &str) -> ValidationResult {
        let source = SourceFile::new(SourceId::new(0), "<interactive>", line);
        match parse(&source) {
            ParseOutcome::Incomplete(_) => ValidationResult::Incomplete,
            ParseOutcome::Complete(_) | ParseOutcome::Invalid(_) => ValidationResult::Complete,
        }
    }
}

struct ReedlineSyntaxHighlighter;

impl Highlighter for ReedlineSyntaxHighlighter {
    fn highlight(&self, line: &str, _cursor: usize) -> StyledText {
        let mut styled = StyledText::new();
        for segment in SyntaxHighlighter::new().highlight(line) {
            styled.push((highlight_style(segment.kind()), segment.text().to_owned()));
        }
        styled
    }
}

struct ReedlineCompleter {
    engine: CompletionEngine,
}

impl Completer for ReedlineCompleter {
    fn complete(&mut self, line: &str, pos: usize) -> Vec<Suggestion> {
        self.engine
            .complete(line, pos)
            .into_iter()
            .map(|completion| {
                let replacement = completion.replacement();
                Suggestion {
                    value: completion.value().to_owned(),
                    description: Some(format!("{:?}", completion.kind())),
                    span: Span::new(replacement.start, replacement.end),
                    append_whitespace: completion.append_whitespace(),
                    ..Suggestion::default()
                }
            })
            .collect()
    }
}

fn highlight_style(kind: HighlightKind) -> Style {
    match kind {
        HighlightKind::Plain => Style::new(),
        HighlightKind::Comment => Style::new().fg(Color::DarkGray).italic(),
        HighlightKind::Keyword => Style::new().fg(Color::Purple).bold(),
        HighlightKind::Literal => Style::new().fg(Color::Yellow),
        HighlightKind::String => Style::new().fg(Color::Green),
        HighlightKind::Escape => Style::new().fg(Color::LightYellow),
        HighlightKind::Expansion => Style::new().fg(Color::Cyan),
        HighlightKind::Operator => Style::new().fg(Color::LightBlue),
        HighlightKind::Delimiter => Style::new().fg(Color::Blue),
        HighlightKind::Invalid => Style::new().fg(Color::Red).underline(),
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

    #[test]
    fn parser_validation_continues_only_structurally_incomplete_input() {
        let validator = FlashShellValidator;

        for complete in ["", "echo hello", "if true {\n    echo yes\n}"] {
            assert!(matches!(
                validator.validate(complete),
                ValidationResult::Complete
            ));
        }

        let invalid = SourceFile::new(SourceId::new(7), "<test-invalid>", "else");
        assert!(matches!(parse(&invalid), ParseOutcome::Invalid(_)));
        assert!(matches!(
            validator.validate(invalid.text()),
            ValidationResult::Complete
        ));

        for incomplete in ["echo hello |", "echo >", "echo \"unterminated", "if true {"] {
            assert!(matches!(
                validator.validate(incomplete),
                ValidationResult::Incomplete
            ));
        }
    }

    #[test]
    fn reedline_highlighter_preserves_source_and_maps_semantic_styles() {
        let source = "let name = \"$value\" # note";
        let styled = ReedlineSyntaxHighlighter.highlight(source, source.len());

        assert_eq!(styled.raw_string(), source);
        assert!(styled.buffer.iter().any(|(style, text)| *style
            == highlight_style(HighlightKind::Keyword)
            && text == "let"));
        assert!(styled.buffer.iter().any(|(style, text)| {
            *style == highlight_style(HighlightKind::Expansion) && text == "$value"
        }));
        assert!(styled.buffer.iter().any(|(style, text)| {
            *style == highlight_style(HighlightKind::Comment) && text == "# note"
        }));
    }

    #[test]
    fn reedline_completer_preserves_replacement_span_and_spacing_policy() {
        let registry = flashshell_runtime::builtin::standard_registry();
        let scope = flashshell_runtime::ScopeStack::new();
        let mut completer = ReedlineCompleter {
            engine: CompletionEngine::new(CompletionCatalog::from_runtime(&registry, &scope)),
        };

        let suggestions = completer.complete("pw", 2);
        let pwd = suggestions
            .iter()
            .find(|suggestion| suggestion.value == "pwd")
            .expect("standard command should be bridged");
        assert_eq!(pwd.span, Span::new(0, 2));
        assert!(pwd.append_whitespace);
    }
}
