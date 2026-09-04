#![forbid(unsafe_code)]

//! Deterministic, read-only analysis of explicit Flash v1 source graphs.

mod scan;
mod sha256;

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::{self, Write as _};
use std::fs;
use std::path::{Path, PathBuf};

use flash_syntax::{
    LanguageDetection, ModuleImportSource, ParseOutcome, Script, SourceFile, SourceId, Span,
    StatementKind, VersionedParseOutcome, detect_source_language, parse, parse_v2,
};

use crate::scan::{ReferenceKind, SourceScan, scan};

pub const SCHEMA_VERSION: u16 = 1;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum MigrationFormat {
    #[default]
    Human,
    Json,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum FindingSeverity {
    Required,
    Suggested,
    Information,
}

impl FindingSeverity {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Required => "required",
            Self::Suggested => "suggested",
            Self::Information => "information",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MigrationEdit {
    pub start: usize,
    pub end: usize,
    pub replacement: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MigrationFinding {
    pub code: String,
    pub severity: FindingSeverity,
    pub start: usize,
    pub end: usize,
    pub message: String,
    pub edit: Option<MigrationEdit>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MigrationSource {
    pub source_uri: String,
    pub digest: String,
    pub detected_language: u16,
    pub target_language: u16,
    pub findings: Vec<MigrationFinding>,
    pub unresolved: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MigrationReport {
    pub schema: u16,
    pub sources: Vec<MigrationSource>,
}

impl MigrationReport {
    #[must_use]
    pub fn render(&self, format: MigrationFormat) -> String {
        match format {
            MigrationFormat::Human => self.render_human(),
            MigrationFormat::Json => self.render_json(),
        }
    }

    #[must_use]
    pub fn exit_status(&self) -> u8 {
        if self.sources.iter().any(|source| {
            source.unresolved
                || source
                    .findings
                    .iter()
                    .any(|finding| finding.severity == FindingSeverity::Required)
        }) {
            1
        } else {
            0
        }
    }

    fn render_human(&self) -> String {
        let mut output = String::new();
        for source in &self.sources {
            if source.findings.is_empty() {
                writeln!(output, "{}: clean", source.source_uri)
                    .expect("writing to a String cannot fail");
                continue;
            }
            for finding in &source.findings {
                writeln!(
                    output,
                    "{}:{}:{}: {} {}: {}",
                    source.source_uri,
                    finding.start,
                    finding.end,
                    finding.severity.as_str(),
                    finding.code,
                    finding.message
                )
                .expect("writing to a String cannot fail");
            }
        }
        output.pop();
        output
    }

    fn render_json(&self) -> String {
        let mut output = format!("{{\"schema\":{},\"sources\":[", self.schema);
        for (source_index, source) in self.sources.iter().enumerate() {
            if source_index != 0 {
                output.push(',');
            }
            write!(
                output,
                "{{\"source_uri\":{},\"digest\":{},\"detected_language\":{},\"target_language\":{},\"findings\":[",
                json_string(&source.source_uri),
                json_string(&source.digest),
                source.detected_language,
                source.target_language
            )
            .expect("writing to a String cannot fail");
            for (finding_index, finding) in source.findings.iter().enumerate() {
                if finding_index != 0 {
                    output.push(',');
                }
                write!(
                    output,
                    "{{\"code\":{},\"severity\":{},\"start\":{},\"end\":{},\"message\":{}",
                    json_string(&finding.code),
                    json_string(finding.severity.as_str()),
                    finding.start,
                    finding.end,
                    json_string(&finding.message)
                )
                .expect("writing to a String cannot fail");
                if let Some(edit) = &finding.edit {
                    write!(
                        output,
                        ",\"edit\":{{\"start\":{},\"end\":{},\"replacement\":{}}}",
                        edit.start,
                        edit.end,
                        json_string(&edit.replacement)
                    )
                    .expect("writing to a String cannot fail");
                }
                output.push('}');
            }
            write!(output, "],\"unresolved\":{}}}", source.unresolved)
                .expect("writing to a String cannot fail");
        }
        output.push_str("]}");
        output
    }
}

fn json_string(value: &str) -> String {
    serde_json::to_string(value).expect("serializing a UTF-8 string cannot fail")
}

pub trait SourceReader {
    fn canonicalize(&self, path: &Path) -> Result<PathBuf, String>;
    fn read(&self, path: &Path) -> Result<Vec<u8>, String>;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct NativeSourceReader;

impl SourceReader for NativeSourceReader {
    fn canonicalize(&self, path: &Path) -> Result<PathBuf, String> {
        fs::canonicalize(path).map_err(|error| error.to_string())
    }

    fn read(&self, path: &Path) -> Result<Vec<u8>, String> {
        fs::read(path).map_err(|error| error.to_string())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MigrationError {
    source_uri: String,
    operation: &'static str,
    detail: String,
}

impl fmt::Display for MigrationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "cannot {} migration source `{}`: {}",
            self.operation, self.source_uri, self.detail
        )
    }
}

impl std::error::Error for MigrationError {}

#[must_use = "migration analysis failures must be handled"]
pub fn analyze_roots(
    reader: &impl SourceReader,
    roots: &[PathBuf],
) -> Result<MigrationReport, MigrationError> {
    let mut graph = Graph::new(reader);
    for root in roots {
        graph.visit(root.clone(), root.clone())?;
    }
    Ok(graph.report())
}

struct Graph<'reader, Reader> {
    reader: &'reader Reader,
    nodes: Vec<SourceNode>,
    identities: BTreeMap<PathBuf, usize>,
}

impl<'reader, Reader: SourceReader> Graph<'reader, Reader> {
    fn new(reader: &'reader Reader) -> Self {
        Self {
            reader,
            nodes: Vec::new(),
            identities: BTreeMap::new(),
        }
    }

    fn visit(&mut self, requested: PathBuf, logical: PathBuf) -> Result<usize, MigrationError> {
        let source_uri = encode_path(&logical);
        let canonical = self
            .reader
            .canonicalize(&requested)
            .map_err(|detail| MigrationError {
                source_uri: source_uri.clone(),
                operation: "resolve",
                detail,
            })?;
        if let Some(index) = self.identities.get(&canonical) {
            return Ok(*index);
        }

        let bytes = self
            .reader
            .read(&canonical)
            .map_err(|detail| MigrationError {
                source_uri: source_uri.clone(),
                operation: "read",
                detail,
            })?;
        let digest = sha256::digest(&bytes);
        let text = String::from_utf8(bytes).map_err(|error| MigrationError {
            source_uri: source_uri.clone(),
            operation: "decode as UTF-8",
            detail: error.to_string(),
        })?;
        let source_id = u32::try_from(self.nodes.len() + 1).map_err(|_| MigrationError {
            source_uri: source_uri.clone(),
            operation: "identify",
            detail: "source graph exceeds the supported identity range".to_owned(),
        })?;
        let source = SourceFile::new(SourceId::new(source_id), source_uri.clone(), text);
        let parsed = ParsedSource::parse(&source);
        let imports = parsed.imports(&source);
        let index = self.nodes.len();
        self.nodes.push(SourceNode {
            canonical: canonical.clone(),
            logical,
            source,
            digest,
            parsed,
            imports,
        });
        self.identities.insert(canonical.clone(), index);

        let parent = canonical.parent().unwrap_or(Path::new(""));
        let logical_parent = self.nodes[index]
            .logical
            .parent()
            .unwrap_or(Path::new(""))
            .to_owned();
        for import_index in 0..self.nodes[index].imports.len() {
            let relative = self.nodes[index].imports[import_index].path.clone();
            let requested_import = if relative.is_absolute() {
                relative.clone()
            } else {
                parent.join(&relative)
            };
            let logical_import = if relative.is_absolute() {
                relative
            } else {
                logical_parent.join(relative)
            };
            let target = self.visit(requested_import, logical_import)?;
            self.nodes[index].imports[import_index].target = Some(target);
        }
        Ok(index)
    }

    fn report(&self) -> MigrationReport {
        let mut sources = Vec::with_capacity(self.nodes.len());
        for node in &self.nodes {
            sources.push(analyze_source(node));
        }
        MigrationReport {
            schema: SCHEMA_VERSION,
            sources,
        }
    }
}

struct SourceNode {
    #[allow(dead_code)]
    canonical: PathBuf,
    logical: PathBuf,
    source: SourceFile,
    digest: String,
    parsed: ParsedSource,
    imports: Vec<StaticImport>,
}

enum ParsedSource {
    V1(Script),
    V2(Script),
    Invalid(MigrationFinding),
}

impl ParsedSource {
    fn parse(source: &SourceFile) -> Self {
        if matches!(
            detect_source_language(source),
            LanguageDetection::Complete(_)
        ) {
            return match parse_v2(source) {
                VersionedParseOutcome::Complete(script) => Self::V2(script.into_script()),
                VersionedParseOutcome::Incomplete(incomplete) => Self::Invalid(parse_finding(
                    incomplete.span(),
                    "incomplete explicitly versioned source",
                )),
                VersionedParseOutcome::Invalid(diagnostics) => {
                    Self::Invalid(diagnostic_finding(&diagnostics))
                }
            };
        }
        match parse(source) {
            ParseOutcome::Complete(script) => Self::V1(script),
            ParseOutcome::Incomplete(incomplete) => {
                Self::Invalid(parse_finding(incomplete.span(), "incomplete v1 source"))
            }
            ParseOutcome::Invalid(diagnostics) => Self::Invalid(diagnostic_finding(&diagnostics)),
        }
    }

    fn script(&self) -> Option<&Script> {
        match self {
            Self::V1(script) | Self::V2(script) => Some(script),
            Self::Invalid(_) => None,
        }
    }

    fn imports(&self, source: &SourceFile) -> Vec<StaticImport> {
        let Some(script) = self.script() else {
            return Vec::new();
        };
        let mut imports = Vec::new();
        for statement in script.statements() {
            match statement.kind() {
                StatementKind::Import(import) => {
                    let path = quoted_path(source, import.path);
                    imports.push(StaticImport {
                        statement_span: statement.span(),
                        path,
                        names: import
                            .names
                            .iter()
                            .map(|name| {
                                source
                                    .slice(name.span())
                                    .expect("an import name belongs to its source")
                                    .to_owned()
                            })
                            .collect(),
                        target: None,
                    });
                }
                StatementKind::ModuleImport(import) => {
                    if let ModuleImportSource::Local { path } = import.source {
                        imports.push(StaticImport {
                            statement_span: statement.span(),
                            path: quoted_path(source, path),
                            names: Vec::new(),
                            target: None,
                        });
                    }
                }
                _ => {}
            }
        }
        imports
    }
}

fn diagnostic_finding(diagnostics: &[flash_syntax::Diagnostic]) -> MigrationFinding {
    let diagnostic = diagnostics
        .first()
        .expect("an invalid parse has at least one diagnostic");
    let span = diagnostic
        .labels()
        .first()
        .map_or(SpanBounds { start: 0, end: 0 }, |label| SpanBounds {
            start: label.span().start(),
            end: label.span().end(),
        });
    MigrationFinding {
        code: "MIG1001".to_owned(),
        severity: FindingSeverity::Required,
        start: span.start,
        end: span.end,
        message: format!("v1 source cannot be classified: {}", diagnostic.message()),
        edit: None,
    }
}

fn parse_finding(span: Span, message: &str) -> MigrationFinding {
    MigrationFinding {
        code: "MIG1001".to_owned(),
        severity: FindingSeverity::Required,
        start: span.start(),
        end: span.end(),
        message: message.to_owned(),
        edit: None,
    }
}

struct SpanBounds {
    start: usize,
    end: usize,
}

struct StaticImport {
    statement_span: Span,
    path: PathBuf,
    names: Vec<String>,
    #[allow(dead_code)]
    target: Option<usize>,
}

fn quoted_path(source: &SourceFile, span: Span) -> PathBuf {
    let quoted = source
        .slice(span)
        .expect("an import path belongs to its source");
    PathBuf::from(&quoted[1..quoted.len() - 1])
}

fn analyze_source(node: &SourceNode) -> MigrationSource {
    let detected_language = match node.parsed {
        ParsedSource::V2(_) => 2,
        ParsedSource::V1(_) | ParsedSource::Invalid(_) => 1,
    };
    let mut findings = Vec::new();
    let mut unresolved = false;
    match &node.parsed {
        ParsedSource::Invalid(finding) => {
            findings.push(finding.clone());
            unresolved = true;
        }
        ParsedSource::V2(_) => {}
        ParsedSource::V1(script) => {
            let (insertion, replacement) = language_insertion(node.source.text());
            findings.push(MigrationFinding {
                code: "MIG2001".to_owned(),
                severity: FindingSeverity::Required,
                start: insertion,
                end: insertion,
                message: "add 'language 2' before the first statement".to_owned(),
                edit: Some(MigrationEdit {
                    start: insertion,
                    end: insertion,
                    replacement,
                }),
            });
            let scan = scan(&node.source, script);
            analyze_reserved_names(&scan, &node.imports, &mut findings);
            unresolved |= analyze_imports(&node.source, &scan, &node.imports, &mut findings);
            analyze_length_operation(&node.source, &scan, &node.imports, &mut findings);
            analyze_known_argv_transport(&node.source, &mut findings);
            unresolved |= analyze_effects(&scan, &node.imports, &mut findings);
        }
    }
    findings.sort_by(|left, right| {
        (
            left.start,
            left.end,
            left.code.as_str(),
            left.message.as_str(),
        )
            .cmp(&(
                right.start,
                right.end,
                right.code.as_str(),
                right.message.as_str(),
            ))
    });
    findings.dedup();
    MigrationSource {
        source_uri: node.source.name().to_owned(),
        digest: node.digest.clone(),
        detected_language,
        target_language: 2,
        findings,
        unresolved,
    }
}

fn language_insertion(source: &str) -> (usize, String) {
    if !source.starts_with("#!") {
        return (0, "language 2\n\n".to_owned());
    }
    match source.find('\n') {
        Some(end) => (end + 1, "language 2\n\n".to_owned()),
        None => (source.len(), "\nlanguage 2\n".to_owned()),
    }
}

const NEW_RESERVED_WORDS: [&str; 5] = ["action", "enum", "language", "task", "type"];
const V2_RESERVED_WORDS: [&str; 26] = [
    "action", "break", "catch", "continue", "def", "else", "enum", "export", "false", "for", "if",
    "import", "in", "language", "let", "match", "mut", "null", "return", "task", "throw", "true",
    "try", "type", "unset", "while",
];

fn analyze_reserved_names(
    scan: &SourceScan,
    imports: &[StaticImport],
    findings: &mut Vec<MigrationFinding>,
) {
    let imported = imports
        .iter()
        .flat_map(|import| import.names.iter())
        .collect::<BTreeSet<_>>();
    for reserved in NEW_RESERVED_WORDS {
        if imported.contains(&reserved.to_owned()) {
            continue;
        }
        let bindings = scan
            .bindings
            .iter()
            .filter(|(name, _)| name == reserved)
            .collect::<Vec<_>>();
        if bindings.is_empty() {
            continue;
        }
        let replacement = collision_free_name(reserved, &scan.identifiers);
        for (_, span) in bindings {
            findings.push(rename_finding(*span, reserved, &replacement));
        }
        for reference in scan
            .references
            .iter()
            .filter(|reference| reference.name == reserved)
        {
            findings.push(rename_finding(reference.name_span, reserved, &replacement));
        }
    }
    for reserved in &scan.reserved_uses {
        findings.push(MigrationFinding {
            code: "MIG2002".to_owned(),
            severity: FindingSeverity::Required,
            start: reserved.start,
            end: reserved.end,
            message: format!(
                "preserve v1 data name `{}` across the Flash 2 reserved-word boundary",
                reserved.spelling
            ),
            edit: Some(MigrationEdit {
                start: reserved.start,
                end: reserved.end,
                replacement: reserved.replacement.clone(),
            }),
        });
    }
}

fn rename_finding(span: Span, name: &str, replacement: &str) -> MigrationFinding {
    MigrationFinding {
        code: "MIG2002".to_owned(),
        severity: FindingSeverity::Required,
        start: span.start(),
        end: span.end(),
        message: format!("rename v1 binding `{name}` because it is reserved by Flash 2"),
        edit: Some(MigrationEdit {
            start: span.start(),
            end: span.end(),
            replacement: replacement.to_owned(),
        }),
    }
}

fn collision_free_name(name: &str, occupied: &BTreeSet<String>) -> String {
    let base = format!("{name}_v1");
    if !occupied.contains(&base) {
        return base;
    }
    for suffix in 2_u32.. {
        let candidate = format!("{base}_{suffix}");
        if !occupied.contains(&candidate) {
            return candidate;
        }
    }
    unreachable!("the finite occupied set cannot contain every numeric suffix")
}

fn analyze_imports(
    source: &SourceFile,
    scan: &SourceScan,
    imports: &[StaticImport],
    findings: &mut Vec<MigrationFinding>,
) -> bool {
    let mut occupied = scan.identifiers.clone();
    let mut imported_counts = BTreeMap::<&str, usize>::new();
    for import in imports {
        for name in &import.names {
            *imported_counts.entry(name).or_default() += 1;
        }
    }
    let local_bindings = scan
        .top_level_bindings
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    let mut unresolved = false;
    for import in imports {
        let alias = import_alias(&import.path, &occupied);
        occupied.insert(alias.clone());
        let conflict = import.names.iter().find_map(|name| {
            if NEW_RESERVED_WORDS.contains(&name.as_str()) {
                Some(format!("imported name `{name}` is reserved by Flash 2"))
            } else if local_bindings.contains(name.as_str()) {
                Some(format!("imported name `{name}` is shadowed locally"))
            } else if imported_counts
                .get(name.as_str())
                .copied()
                .unwrap_or_default()
                > 1
            {
                Some(format!("imported name `{name}` has multiple sources"))
            } else if scan.exports.contains(name) {
                Some(format!("imported name `{name}` is publicly re-exported"))
            } else if scan.references.iter().any(|reference| {
                reference.name == *name
                    && reference.kind == ReferenceKind::Assignment
                    && !scan.reference_is_shadowed(name, reference.full_span)
            }) {
                Some(format!("imported name `{name}` is assigned"))
            } else if scan.references.iter().any(|reference| {
                reference.name == *name
                    && reference.kind == ReferenceKind::Spread
                    && !scan.reference_is_shadowed(name, reference.full_span)
            }) {
                Some(format!(
                    "imported name `{name}` is used as a command spread"
                ))
            } else {
                None
            }
        });
        let unsafe_names = conflict.is_some();
        let original_path = source
            .slice(import.statement_span)
            .expect("an import statement belongs to its source");
        let quoted = original_path
            .find('\'')
            .and_then(|start| {
                original_path
                    .rfind('\'')
                    .map(|end| &original_path[start..=end])
            })
            .unwrap_or("''");
        let replacement = format!("import {quoted} as {alias}");
        findings.push(MigrationFinding {
            code: "MIG2005".to_owned(),
            severity: FindingSeverity::Required,
            start: import.statement_span.start(),
            end: import.statement_span.end(),
            message: if unsafe_names {
                format!(
                    "v1 import needs a qualified alias, but {}",
                    conflict.expect("an unsafe import has a conflict")
                )
            } else {
                format!("rewrite v1 import through module alias `{alias}`")
            },
            edit: (!unsafe_names).then_some(MigrationEdit {
                start: import.statement_span.start(),
                end: import.statement_span.end(),
                replacement,
            }),
        });
        if unsafe_names {
            unresolved = true;
            continue;
        }
        for name in &import.names {
            for reference in scan.references.iter().filter(|reference| {
                reference.name == *name && !scan.reference_is_shadowed(name, reference.full_span)
            }) {
                let span = match reference.kind {
                    ReferenceKind::ExpressionValue | ReferenceKind::WordValue => {
                        reference.full_span
                    }
                    ReferenceKind::Name | ReferenceKind::Command => reference.name_span,
                    ReferenceKind::Spread | ReferenceKind::Assignment => continue,
                };
                let replacement = match reference.kind {
                    ReferenceKind::WordValue => format!("${{{alias}::{name}}}"),
                    ReferenceKind::ExpressionValue
                    | ReferenceKind::Name
                    | ReferenceKind::Command => format!("{alias}::{name}"),
                    ReferenceKind::Spread | ReferenceKind::Assignment => continue,
                };
                findings.push(MigrationFinding {
                    code: "MIG2005".to_owned(),
                    severity: FindingSeverity::Required,
                    start: span.start(),
                    end: span.end(),
                    message: format!("qualify imported name `{name}` through `{alias}`"),
                    edit: Some(MigrationEdit {
                        start: span.start(),
                        end: span.end(),
                        replacement,
                    }),
                });
            }
        }
    }
    unresolved
}

fn import_alias(path: &Path, occupied: &BTreeSet<String>) -> String {
    let raw = path
        .file_stem()
        .and_then(|name| name.to_str())
        .unwrap_or("module");
    let mut base = raw
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '_' {
                character
            } else {
                '_'
            }
        })
        .collect::<String>();
    if base.is_empty() || base.as_bytes()[0].is_ascii_digit() {
        base.insert_str(0, "module_");
    }
    if V2_RESERVED_WORDS.contains(&base.as_str()) {
        base.push_str("_module");
    }
    if !occupied.contains(&base) {
        return base;
    }
    for suffix in 2_u32.. {
        let candidate = format!("{base}_{suffix}");
        if !occupied.contains(&candidate) {
            return candidate;
        }
    }
    unreachable!("the finite occupied set cannot contain every numeric suffix")
}

fn analyze_length_operation(
    source: &SourceFile,
    scan: &SourceScan,
    imports: &[StaticImport],
    findings: &mut Vec<MigrationFinding>,
) {
    let imported_names = imports
        .iter()
        .flat_map(|import| import.names.iter())
        .collect::<BTreeSet<_>>();
    if imported_names.contains(&"length".to_owned()) {
        return;
    }
    let uses = scan
        .commands
        .iter()
        .filter(|command| {
            !command.forced_external
                && command.name.as_deref() == Some("length")
                && !scan.command_is_callable("length", command.span)
        })
        .collect::<Vec<_>>();
    if uses.is_empty() {
        return;
    }
    let alias = import_alias(Path::new("value"), &scan.identifiers);
    for command in uses {
        findings.push(MigrationFinding {
            code: "MIG2003".to_owned(),
            severity: FindingSeverity::Required,
            start: command.span.start(),
            end: command.span.end(),
            message: "qualify the v1 `length` operation through `std::value`".to_owned(),
            edit: Some(MigrationEdit {
                start: command.span.start(),
                end: command.span.end(),
                replacement: format!("{alias}::length"),
            }),
        });
    }
    let insertion = source.len();
    let prefix = if source.text().ends_with('\n') {
        ""
    } else {
        "\n"
    };
    findings.push(MigrationFinding {
        code: "MIG2003".to_owned(),
        severity: FindingSeverity::Required,
        start: insertion,
        end: insertion,
        message: "import the qualified Flash 2 value operation module".to_owned(),
        edit: Some(MigrationEdit {
            start: insertion,
            end: insertion,
            replacement: format!("{prefix}import std::value as {alias}\n"),
        }),
    });
}

fn analyze_known_argv_transport(source: &SourceFile, findings: &mut Vec<MigrationFinding>) {
    const BUILD_ARGV_TRANSPORT: &str = "^sh -c 'remaining=$1; shift; while [ \"$remaining\" -gt 0 ]; do shift; remaining=$((remaining - 1)); done; exec make \"$@\"' flash-build-argv $argument_index ...$args";
    let Some(start) = source.text().find(BUILD_ARGV_TRANSPORT) else {
        return;
    };
    findings.push(MigrationFinding {
        code: "MIG2004".to_owned(),
        severity: FindingSeverity::Suggested,
        start,
        end: start + BUILD_ARGV_TRANSPORT.len(),
        message:
            "replace the recognized build argv transport with the reviewed list-rest transformation"
                .to_owned(),
        edit: None,
    });
}

fn analyze_effects(
    scan: &SourceScan,
    imports: &[StaticImport],
    findings: &mut Vec<MigrationFinding>,
) -> bool {
    let imported_names = imports
        .iter()
        .flat_map(|import| import.names.iter())
        .collect::<BTreeSet<_>>();
    let mut effect_spans = scan.effect_spans.clone();
    for (name, span) in &scan.intrinsic_calls {
        if !imported_names.contains(name) && !scan.reference_is_shadowed(name, *span) {
            effect_spans.push(*span);
        }
    }
    for command in &scan.commands {
        let is_language_callable = command.name.as_ref().is_some_and(|name| {
            scan.command_is_callable(name, command.span) || imported_names.contains(name)
        });
        let permitted = !command.forced_external
            && command.name.as_deref().is_some_and(|name| {
                is_language_callable || matches!(name, "exit" | "help" | "length")
            });
        if !permitted {
            effect_spans.push(command.span);
        }
    }
    effect_spans.sort_by_key(|span| (span.start(), span.end()));
    effect_spans.dedup();
    for span in &effect_spans {
        findings.push(MigrationFinding {
            code: "AUTH2001".to_owned(),
            severity: FindingSeverity::Required,
            start: span.start(),
            end: span.end(),
            message: "ambient effectful execution is unavailable in the Flash 2 pure foundation"
                .to_owned(),
            edit: None,
        });
    }
    !effect_spans.is_empty()
}

fn encode_path(path: &Path) -> String {
    let mut encoded = String::new();
    for byte in path.as_os_str().as_encoded_bytes() {
        if byte.is_ascii_alphanumeric() || matches!(*byte, b'/' | b'-' | b'.' | b'_' | b'~' | b':')
        {
            encoded.push(char::from(*byte));
        } else {
            write!(encoded, "%{byte:02X}").expect("writing to a String cannot fail");
        }
    }
    encoded
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;

    #[derive(Default)]
    struct FakeReader {
        sources: BTreeMap<PathBuf, Vec<u8>>,
        aliases: BTreeMap<PathBuf, PathBuf>,
    }

    impl FakeReader {
        fn source(mut self, path: &str, text: &str) -> Self {
            self.sources
                .insert(PathBuf::from(path), text.as_bytes().to_vec());
            self
        }

        fn source_path(mut self, path: PathBuf, text: &str) -> Self {
            self.sources.insert(path, text.as_bytes().to_vec());
            self
        }

        fn alias(mut self, path: &str, canonical: &str) -> Self {
            self.aliases
                .insert(PathBuf::from(path), PathBuf::from(canonical));
            self
        }
    }

    impl SourceReader for FakeReader {
        fn canonicalize(&self, path: &Path) -> Result<PathBuf, String> {
            let normalized = normalize(path);
            Ok(self.aliases.get(&normalized).cloned().unwrap_or(normalized))
        }

        fn read(&self, path: &Path) -> Result<Vec<u8>, String> {
            self.sources
                .get(path)
                .cloned()
                .ok_or_else(|| "not found".to_owned())
        }
    }

    fn normalize(path: &Path) -> PathBuf {
        let mut normalized = PathBuf::new();
        for component in path.components() {
            match component {
                std::path::Component::CurDir => {}
                std::path::Component::ParentDir => {
                    normalized.pop();
                }
                component => normalized.push(component.as_os_str()),
            }
        }
        normalized
    }

    #[test]
    fn graph_order_alias_collapse_and_import_edits_are_stable() {
        let reader = FakeReader::default()
            .source(
                "/project/root.fsh",
                "import { answer } from './lib.fsh'\nanswer()\nimport './alias.fsh'\n",
            )
            .source(
                "/project/lib.fsh",
                "def answer() { return 42 }\nexport { answer }\n",
            )
            .alias("/project/alias.fsh", "/project/lib.fsh");
        let report = analyze_roots(&reader, &[PathBuf::from("/project/root.fsh")]).unwrap();

        assert_eq!(
            report
                .sources
                .iter()
                .map(|source| source.source_uri.as_str())
                .collect::<Vec<_>>(),
            ["/project/root.fsh", "/project/./lib.fsh"]
        );
        let root = &report.sources[0];
        assert!(root.findings.iter().any(|finding| {
            finding.code == "MIG2005"
                && finding
                    .edit
                    .as_ref()
                    .is_some_and(|edit| edit.replacement == "import './lib.fsh' as lib")
        }));
        assert!(root.findings.iter().any(|finding| {
            finding.code == "MIG2005"
                && finding
                    .edit
                    .as_ref()
                    .is_some_and(|edit| edit.replacement == "lib::answer")
        }));
    }

    #[test]
    fn import_alias_avoids_every_v2_keyword() {
        let reader = FakeReader::default()
            .source(
                "/project/root.fsh",
                "import { answer } from './let.fsh'\nanswer()\n",
            )
            .source(
                "/project/let.fsh",
                "def answer() { return 42 }\nexport { answer }\n",
            );
        let report = analyze_roots(&reader, &[PathBuf::from("/project/root.fsh")]).unwrap();

        assert!(report.sources[0].findings.iter().any(|finding| {
            finding
                .edit
                .as_ref()
                .is_some_and(|edit| edit.replacement == "import './let.fsh' as let_module")
        }));
        assert!(report.sources[0].findings.iter().any(|finding| {
            finding
                .edit
                .as_ref()
                .is_some_and(|edit| edit.replacement == "let_module::answer")
        }));
    }

    #[test]
    fn explicit_root_order_follows_each_depth_first_closure() {
        let reader = FakeReader::default()
            .source("/project/first.fsh", "import './shared.fsh'\n")
            .source("/project/shared.fsh", "let shared = 1\n")
            .source("/project/second.fsh", "let second = 2\n");
        let report = analyze_roots(
            &reader,
            &[
                PathBuf::from("/project/first.fsh"),
                PathBuf::from("/project/second.fsh"),
            ],
        )
        .unwrap();
        assert_eq!(
            report
                .sources
                .iter()
                .map(|source| source.source_uri.as_str())
                .collect::<Vec<_>>(),
            [
                "/project/first.fsh",
                "/project/./shared.fsh",
                "/project/second.fsh"
            ]
        );
    }

    #[cfg(unix)]
    #[test]
    fn native_non_utf8_root_units_are_percent_encoded_losslessly() {
        use std::ffi::OsString;
        use std::os::unix::ffi::OsStringExt as _;

        let path = PathBuf::from(OsString::from_vec(b"/project/\xff.fsh".to_vec()));
        let reader = FakeReader::default().source_path(path.clone(), "let value = 1\n");
        let report = analyze_roots(&reader, &[path]).unwrap();
        assert_eq!(report.sources[0].source_uri, "/project/%FF.fsh");
    }

    #[test]
    fn reserved_binding_and_references_share_one_collision_free_rename() {
        let reader = FakeReader::default().source(
            "/project/root.fsh",
            "let action = 1\nlet action_v1 = 2\n$action\n",
        );
        let report = analyze_roots(&reader, &[PathBuf::from("/project/root.fsh")]).unwrap();
        let edits = report.sources[0]
            .findings
            .iter()
            .filter(|finding| finding.code == "MIG2002")
            .map(|finding| finding.edit.as_ref().unwrap().replacement.as_str())
            .collect::<Vec<_>>();
        assert_eq!(edits, ["action_v1_2", "action_v1_2"]);
    }

    #[test]
    fn json_schema_has_stable_field_order_and_digest() {
        let reader = FakeReader::default().source("/project/root.fsh", "let value = 1\n");
        let report = analyze_roots(&reader, &[PathBuf::from("/project/root.fsh")]).unwrap();
        let rendered = report.render(MigrationFormat::Json);
        assert_eq!(
            rendered,
            "{\"schema\":1,\"sources\":[{\"source_uri\":\"/project/root.fsh\",\"digest\":\"sha256:ccdab916a2664126bae77709d63891fea8e32421e01f33fa9814de8abe9ba3e3\",\"detected_language\":1,\"target_language\":2,\"findings\":[{\"code\":\"MIG2001\",\"severity\":\"required\",\"start\":0,\"end\":0,\"message\":\"add 'language 2' before the first statement\",\"edit\":{\"start\":0,\"end\":0,\"replacement\":\"language 2\\n\\n\"}}],\"unresolved\":false}]}"
        );
        assert_eq!(
            report.render(MigrationFormat::Human),
            "/project/root.fsh:0:0: required MIG2001: add 'language 2' before the first statement"
        );
        assert_eq!(report.exit_status(), 1);
    }

    #[test]
    fn imported_references_follow_source_order_before_a_nested_shadow() {
        let reader = FakeReader::default()
            .source(
                "/project/root.fsh",
                "import { answer } from './support.fsh'\n\
                 def use() {\n\
                     answer()\n\
                     let answer = 7\n\
                     answer()\n\
                 }\n",
            )
            .source(
                "/project/support.fsh",
                "def answer() { return 42 }\nexport { answer }\n",
            );
        let report = analyze_roots(&reader, &[PathBuf::from("/project/root.fsh")]).unwrap();
        let qualified = report.sources[0]
            .findings
            .iter()
            .filter_map(|finding| finding.edit.as_ref())
            .filter(|edit| edit.replacement == "support::answer")
            .collect::<Vec<_>>();

        assert_eq!(qualified.len(), 1);
        assert_eq!(
            &reader.sources[Path::new("/project/root.fsh")][qualified[0].start..qualified[0].end],
            b"answer"
        );
    }

    #[test]
    fn imported_values_preserve_expression_and_word_contexts() {
        let reader = FakeReader::default()
            .source(
                "/project/root.fsh",
                "import { answer } from './support.fsh'\n\
                 let copy = $answer\n\
                 ^echo \"$answer\" $answer\n",
            )
            .source(
                "/project/support.fsh",
                "let answer = 42\nexport { answer }\n",
            );
        let report = analyze_roots(&reader, &[PathBuf::from("/project/root.fsh")]).unwrap();
        let replacements = report.sources[0]
            .findings
            .iter()
            .filter_map(|finding| finding.edit.as_ref())
            .map(|edit| edit.replacement.as_str())
            .filter(|replacement| replacement.contains("support::answer"))
            .collect::<Vec<_>>();

        assert_eq!(
            replacements,
            [
                "support::answer",
                "${support::answer}",
                "${support::answer}"
            ]
        );
    }

    #[test]
    fn imported_command_spread_is_unresolved_without_an_unsafe_edit() {
        let reader = FakeReader::default()
            .source(
                "/project/root.fsh",
                "import { values } from './support.fsh'\n^echo ...$values\n",
            )
            .source(
                "/project/support.fsh",
                "let values = ['one']\nexport { values }\n",
            );
        let report = analyze_roots(&reader, &[PathBuf::from("/project/root.fsh")]).unwrap();
        let root = &report.sources[0];
        let import = root
            .findings
            .iter()
            .find(|finding| {
                finding.code == "MIG2005" && finding.message.contains("used as a command spread")
            })
            .expect("the unrepresentable spread must be reported");

        assert!(import.edit.is_none());
        assert!(root.unresolved);
        assert!(!root.findings.iter().any(|finding| {
            finding
                .edit
                .as_ref()
                .is_some_and(|edit| edit.replacement.contains("support::values"))
        }));
    }

    #[test]
    fn host_intrinsics_and_commands_follow_source_order_and_authority() {
        let reader = FakeReader::default().source(
            "/project/root.fsh",
            "let inherited = env('HOME')\n\
             let matches = glob('*.fsh')\n\
             length\n\
             def length() { return 0 }\n\
             length\n\
             def env(value) { return $value }\n\
             let local = env('safe')\n\
             unknown\n",
        );
        let report = analyze_roots(&reader, &[PathBuf::from("/project/root.fsh")]).unwrap();
        let root = &report.sources[0];
        let authority = root
            .findings
            .iter()
            .filter(|finding| finding.code == "AUTH2001")
            .collect::<Vec<_>>();
        let length_edits = root
            .findings
            .iter()
            .filter(|finding| {
                finding.code == "MIG2003"
                    && finding
                        .edit
                        .as_ref()
                        .is_some_and(|edit| edit.replacement.ends_with("::length"))
            })
            .count();

        assert_eq!(authority.len(), 3);
        assert_eq!(length_edits, 1);
        assert!(root.unresolved);
    }
}
