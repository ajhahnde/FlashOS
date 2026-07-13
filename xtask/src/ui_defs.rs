//! The cross-language half of the console look.
//!
//! `crates/console-ui` owns the FlashOS terminal look for everything Rust. The
//! kernel is still Flash, though, and keeps its own copy in `lib/console_ui/` until
//! it is ported. For as long as both exist, the frozen bytes live in two languages:
//! the six-column status tags, the ANSI palette they tint from, the `[TEST]` /
//! `[PASS]` / `[FAIL]` / `[Debug]` markers the harness emits, and the boot-success
//! marker `scripts/run_qemu_test.sh` greps three times per boot.
//!
//! Nothing would catch a drift between them — a reworded tag or a shifted escape
//! would pass every compiler and only surface as a boot-contract failure, or worse,
//! not at all. So this module parses the Flash source and diffs every one of those
//! facts against the Rust constants. Same shape as `asm-defs`: the numbers are
//! derived, never transcribed, and a mismatch fails the build.
//!
//! It retires with the Flash kernel: once `lib/console_ui/` is gone, so is this.

use std::fmt::Write as _;
use std::fs;
use std::path::Path;

use flashos_console_ui::{palette, tags, MARKER_READY};

const PALETTE_FLASH: &str = "lib/console_ui/palette.flash";
const TAGS_FLASH: &str = "lib/console_ui/tags.flash";
const CONSOLE_UI_FLASH: &str = "lib/console_ui/console_ui.flash";

/// One byte-for-byte fact, as the two sides spell it.
#[derive(Debug)]
struct Fact {
    name: String,
    rust: Vec<u8>,
    flash: Vec<u8>,
}

impl Fact {
    fn agrees(&self) -> bool {
        self.rust == self.flash
    }
}

/// Render bytes so an escape is legible in a diff report.
fn show(bytes: &[u8]) -> String {
    let mut s = String::new();
    for &b in bytes {
        match b {
            0x1b => s.push_str("ESC"),
            b'\n' => s.push_str("\\n"),
            b'\r' => s.push_str("\\r"),
            0x20..=0x7e => s.push(b as char),
            other => {
                let _ = write!(s, "\\x{other:02x}");
            }
        }
    }
    s
}

// ---- the Flash side --------------------------------------------------------

/// Every double-quoted literal on a line, in order. The console_ui Flash sources
/// spell their literals plainly (the one escape, `\x1b[`, is the `esc` constant
/// this module resolves itself), so a scan for quote pairs is enough and pulls in
/// no dependency.
fn literals(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = line;
    while let Some(open) = rest.find('"') {
        let after = &rest[open + 1..];
        let Some(close) = after.find('"') else { break };
        out.push(after[..close].to_string());
        rest = &after[close + 1..];
    }
    out
}

/// Strip a trailing `// ...` comment, so a literal quoted inside one is not read as
/// source.
fn strip_comment(line: &str) -> &str {
    match line.find("//") {
        Some(i) => &line[..i],
        None => line,
    }
}

/// The declared value of `pub const <name> bool = <true|false>`.
fn flash_bool(source: &str, name: &str) -> Result<bool, String> {
    for line in source.lines().map(strip_comment) {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix(&format!("pub const {name} bool = ")) {
            return match rest.trim() {
                "true" => Ok(true),
                "false" => Ok(false),
                other => Err(format!("{name}: cannot read `{other}` as a bool")),
            };
        }
    }
    Err(format!("{name}: not declared in the Flash source"))
}

/// The palette, resolved to the bytes it actually emits.
///
/// Flash spells each entry `pub const red = if (color) esc ++ "31m" else ""`, and
/// `grey` as a bare alias of `bright_black`. Both forms resolve here against the
/// same `color` knob the Rust side compiles with, so what is compared is the byte
/// stream, not the spelling.
fn flash_palette(source: &str, color: bool) -> Result<Vec<(String, Vec<u8>)>, String> {
    let mut out: Vec<(String, Vec<u8>)> = Vec::new();
    for line in source.lines().map(strip_comment) {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("pub const ") else {
            continue;
        };
        let Some((name, value)) = rest.split_once(" = ") else {
            continue;
        };
        let name = name.trim();
        // The two knobs are typed (`name bool`) and handled by flash_bool.
        if name.contains(' ') {
            continue;
        }

        let value = value.trim();
        let bytes = if value.starts_with("if (color)") {
            let Some(code) = literals(value).into_iter().next() else {
                return Err(format!("{name}: no escape literal in `{value}`"));
            };
            if color {
                let mut b = b"\x1b[".to_vec();
                b.extend_from_slice(code.as_bytes());
                b
            } else {
                Vec::new()
            }
        } else if let Some((_, aliased)) = out.iter().find(|(n, _)| n == value) {
            // A bare alias, e.g. `grey = bright_black`.
            aliased.clone()
        } else {
            continue;
        };
        out.push((name.to_string(), bytes));
    }
    if out.is_empty() {
        return Err("no palette entries found in the Flash source".into());
    }
    Ok(out)
}

/// A tag as the Flash source spells it: the three spans plus the palette entry it
/// tints from.
struct FlashTag {
    name: String,
    pre: String,
    word: String,
    post: String,
    color: String,
}

fn flash_tags(source: &str) -> Result<Vec<FlashTag>, String> {
    let mut out = Vec::new();
    for line in source.lines().map(strip_comment) {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("pub const ") else {
            continue;
        };
        let Some((name, value)) = rest.split_once(" = ") else {
            continue;
        };
        let value = value.trim();
        if !value.starts_with("tag(") {
            continue;
        }
        let spans = literals(value);
        if spans.len() != 3 {
            return Err(format!(
                "{}: expected three quoted spans in `{value}`, found {}",
                name.trim(),
                spans.len()
            ));
        }
        let color = value
            .rsplit_once("palette.")
            .map(|(_, c)| c.trim_end_matches(')').trim().to_string())
            .ok_or_else(|| format!("{}: no palette entry in `{value}`", name.trim()))?;
        out.push(FlashTag {
            name: name.trim().to_string(),
            pre: spans[0].clone(),
            word: spans[1].clone(),
            post: spans[2].clone(),
            color,
        });
    }
    if out.is_empty() {
        return Err("no tags found in the Flash source".into());
    }
    Ok(out)
}

/// The value of a plain `pub const <name> = "..."` string constant.
fn flash_str(source: &str, name: &str) -> Result<Vec<u8>, String> {
    for line in source.lines().map(strip_comment) {
        let line = line.trim();
        let Some(rest) = line.strip_prefix(&format!("pub const {name} = ")) else {
            continue;
        };
        let Some(value) = literals(rest).into_iter().next() else {
            return Err(format!("{name}: no string literal in `{rest}`"));
        };
        return Ok(value.into_bytes());
    }
    Err(format!("{name}: not declared in the Flash source"))
}

// ---- the comparison --------------------------------------------------------

/// Diff every Rust console-ui fact against the Flash source it must still match.
fn compare(palette_src: &str, tags_src: &str, console_src: &str) -> Result<Vec<Fact>, String> {
    let mut facts = Vec::new();

    // The knobs first: every palette entry below is resolved through them, so a
    // disagreement here would otherwise show up as a confusing wall of escape
    // mismatches rather than the one root cause.
    let flash_color = flash_bool(palette_src, "color")?;
    let flash_unicode = flash_bool(palette_src, "unicode")?;
    facts.push(Fact {
        name: "palette.color".into(),
        rust: vec![palette::COLOR as u8],
        flash: vec![flash_color as u8],
    });
    facts.push(Fact {
        name: "palette.unicode".into(),
        rust: vec![palette::UNICODE as u8],
        flash: vec![flash_unicode as u8],
    });

    let flash_palette = flash_palette(palette_src, flash_color)?;
    let rust_palette: &[(&str, &[u8])] = &[
        ("black", palette::BLACK),
        ("red", palette::RED),
        ("green", palette::GREEN),
        ("yellow", palette::YELLOW),
        ("blue", palette::BLUE),
        ("magenta", palette::MAGENTA),
        ("cyan", palette::CYAN),
        ("white", palette::WHITE),
        ("bright_black", palette::BRIGHT_BLACK),
        ("bright_red", palette::BRIGHT_RED),
        ("bright_green", palette::BRIGHT_GREEN),
        ("bright_yellow", palette::BRIGHT_YELLOW),
        ("grey", palette::GREY),
        ("bold", palette::BOLD),
        ("dim", palette::DIM),
        ("reset", palette::RESET),
    ];
    for (name, rust) in rust_palette {
        let flash = flash_palette
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, b)| b.clone())
            .ok_or_else(|| format!("palette.{name}: missing from the Flash source"))?;
        facts.push(Fact {
            name: format!("palette.{name}"),
            rust: rust.to_vec(),
            flash,
        });
    }

    let flash_tags = flash_tags(tags_src)?;
    let rust_tags: &[(&str, tags::Tag)] = &[
        ("ok", tags::OK),
        ("info", tags::INFO),
        ("load", tags::LOAD),
        ("warn", tags::WARN),
        ("fail", tags::FAIL),
        ("skip", tags::SKIP),
    ];
    for (name, rust) in rust_tags {
        let flash = flash_tags
            .iter()
            .find(|t| &t.name == name)
            .ok_or_else(|| format!("tag {name}: missing from the Flash source"))?;
        let flash_ansi = flash_palette
            .iter()
            .find(|(n, _)| n == &flash.color)
            .map(|(_, b)| b.clone())
            .ok_or_else(|| format!("tag {name}: tints from unknown palette.{}", flash.color))?;

        // The whole rendered label, not the three spans separately: it is the
        // rendered byte stream the boot log and the grep contract see.
        let mut rust_bytes = rust.pre.to_vec();
        rust_bytes.extend_from_slice(rust.ansi);
        rust_bytes.extend_from_slice(rust.word);
        rust_bytes.extend_from_slice(palette::RESET);
        rust_bytes.extend_from_slice(rust.post);

        let mut flash_bytes = flash.pre.clone().into_bytes();
        flash_bytes.extend_from_slice(&flash_ansi);
        flash_bytes.extend_from_slice(flash.word.as_bytes());
        flash_bytes.extend_from_slice(if flash_color { b"\x1b[0m" } else { b"" });
        flash_bytes.extend_from_slice(flash.post.as_bytes());

        facts.push(Fact {
            name: format!("tag {name}"),
            rust: rust_bytes,
            flash: flash_bytes,
        });
    }

    for (name, rust) in [
        ("test_mark", tags::TEST_MARK),
        ("pass_mark", tags::PASS_MARK),
        ("fail_mark", tags::FAIL_MARK),
        ("debug_mark", tags::DEBUG_MARK),
    ] {
        facts.push(Fact {
            name: name.into(),
            rust: rust.to_vec(),
            flash: flash_str(tags_src, name)?,
        });
    }

    facts.push(Fact {
        name: "marker_ready".into(),
        rust: MARKER_READY.to_vec(),
        flash: flash_str(console_src, "marker_ready")?,
    });

    Ok(facts)
}

/// Report every fact, and fail on the first drift.
pub fn run(root: &Path, check: bool) -> Result<(), String> {
    let read = |rel: &str| -> Result<String, String> {
        fs::read_to_string(root.join(rel)).map_err(|e| format!("read {rel}: {e}"))
    };
    let facts = compare(
        &read(PALETTE_FLASH)?,
        &read(TAGS_FLASH)?,
        &read(CONSOLE_UI_FLASH)?,
    )?;

    let mut drifted = Vec::new();
    for fact in &facts {
        if fact.agrees() {
            if !check {
                println!("  {:<22} {}", fact.name, show(&fact.rust));
            }
        } else {
            drifted.push(format!(
                "  {:<22} rust={} flash={}",
                fact.name,
                show(&fact.rust),
                show(&fact.flash)
            ));
        }
    }

    if !drifted.is_empty() {
        return Err(format!(
            "the Rust and Flash console looks have drifted apart ({} of {} facts):\n{}\n\nThese bytes are frozen: the boot contract greps them. Reconcile \
             crates/console-ui with lib/console_ui/ before continuing.",
            drifted.len(),
            facts.len(),
            drifted.join("\n")
        ));
    }

    println!("ui-defs OK — {} facts, 0 drift", facts.len());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const PALETTE: &str = r#"
pub const color bool = true
pub const unicode bool = false
const esc = "\x1b["
pub const black = if (color) esc ++ "30m" else ""
pub const red = if (color) esc ++ "31m" else ""
pub const green = if (color) esc ++ "32m" else ""
pub const yellow = if (color) esc ++ "33m" else ""
pub const blue = if (color) esc ++ "34m" else ""
pub const magenta = if (color) esc ++ "35m" else ""
pub const cyan = if (color) esc ++ "36m" else ""
pub const white = if (color) esc ++ "37m" else ""
pub const bright_black = if (color) esc ++ "90m" else ""
pub const bright_red = if (color) esc ++ "91m" else ""
pub const bright_green = if (color) esc ++ "92m" else ""
pub const bright_yellow = if (color) esc ++ "93m" else ""
pub const grey = bright_black
pub const bold = if (color) esc ++ "1m" else ""
pub const dim = if (color) esc ++ "2m" else ""
pub const reset = if (color) esc ++ "0m" else ""
"#;

    const TAGS: &str = r#"
pub const ok = tag("[ ", "OK", " ]", palette.green)
pub const info = tag("[", "INFO", "]", palette.cyan)
pub const load = tag("[", "LOAD", "]", palette.yellow)
pub const warn = tag("[", "WARN", "]", palette.yellow)
pub const fail = tag("[", "FAIL", "]", palette.red)
pub const skip = tag("[", "SKIP", "]", palette.grey)
pub const test_mark = "[TEST] "
pub const pass_mark = "[PASS] "
pub const fail_mark = "[FAIL] "
pub const debug_mark = "[Debug] "
"#;

    const CONSOLE: &str = r#"
pub const marker_ready = " - type 'help' for commands"
"#;

    fn drift(facts: &[Fact]) -> Vec<&str> {
        facts
            .iter()
            .filter(|f| !f.agrees())
            .map(|f| f.name.as_str())
            .collect()
    }

    #[test]
    fn the_live_flash_source_still_matches_the_rust_crate() {
        // The gate itself, run against the real tree — not a fixture.
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        run(root, true).expect("console-ui drifted from lib/console_ui");
    }

    #[test]
    fn identical_sources_report_no_drift() {
        let facts = compare(PALETTE, TAGS, CONSOLE).unwrap();
        assert!(drift(&facts).is_empty());
        assert!(facts.len() >= 22);
    }

    #[test]
    fn a_reworded_tag_is_caught() {
        // The [FAIL] -> [ERR] rename that would silently break the harness grep.
        let tampered = TAGS.replace(r#"tag("[", "FAIL", "]""#, r#"tag("[", "ERR ", "]""#);
        let facts = compare(PALETTE, &tampered, CONSOLE).unwrap();
        assert_eq!(drift(&facts), ["tag fail"]);
    }

    #[test]
    fn a_shifted_palette_escape_is_caught() {
        // Green tags rendered in red: same width, same words, wrong bytes.
        let tampered = PALETTE.replace(
            r#"green = if (color) esc ++ "32m""#,
            r#"green = if (color) esc ++ "31m""#,
        );
        let facts = compare(&tampered, TAGS, CONSOLE).unwrap();
        // The palette entry itself, and the ok tag that tints from it.
        assert_eq!(drift(&facts), ["palette.green", "tag ok"]);
    }

    #[test]
    fn a_reworded_boot_marker_is_caught() {
        // The one the boot watchdog greps three times per boot.
        let tampered = CONSOLE.replace("type 'help' for commands", "type `help` for commands");
        let facts = compare(PALETTE, TAGS, &tampered).unwrap();
        assert_eq!(drift(&facts), ["marker_ready"]);
    }

    #[test]
    fn a_reworded_harness_marker_is_caught() {
        let tampered = TAGS.replace(r#"pass_mark = "[PASS] ""#, r#"pass_mark = "[PASSED] ""#);
        let facts = compare(PALETTE, &tampered, CONSOLE).unwrap();
        assert_eq!(drift(&facts), ["pass_mark"]);
    }

    #[test]
    fn flipping_the_color_knob_off_on_one_side_is_caught() {
        // Every escape would collapse to nothing on the Flash side while Rust kept
        // emitting them: the knob is reported directly, not as 16 escape diffs.
        let tampered = PALETTE.replace(
            "pub const color bool = true",
            "pub const color bool = false",
        );
        let facts = compare(&tampered, TAGS, CONSOLE).unwrap();
        assert!(drift(&facts).contains(&"palette.color"));
    }

    #[test]
    fn a_literal_quoted_inside_a_comment_is_not_read_as_source() {
        let commented = format!("{TAGS}\n// pub const pass_mark = \"[NOPE] \"\n");
        let facts = compare(PALETTE, &commented, CONSOLE).unwrap();
        assert!(drift(&facts).is_empty());
    }

    #[test]
    fn a_missing_declaration_fails_loudly_rather_than_passing_vacuously() {
        // A parser that silently finds nothing would report "0 drift" forever.
        let gutted = CONSOLE.replace("pub const marker_ready", "pub const something_else");
        let err = compare(PALETTE, TAGS, &gutted).unwrap_err();
        assert!(err.contains("marker_ready"), "unexpected error: {err}");
    }
}
