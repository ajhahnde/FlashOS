//! Repository layout guard — enforces the structural invariants the tree is
//! organized around so they do not erode as the codebase grows.
//!
//! Every rule is a pure filesystem check over the repository root: no build, no
//! subprocess, no network. Violations are accumulated and reported together so a
//! single run surfaces the whole picture rather than one error at a time. The
//! payload and initramfs facts (which EL0 binaries ship, and where) are read from
//! `build.rs`'s own tables — the single source of truth for the production image —
//! rather than duplicated here.

use std::path::{Path, PathBuf};

use crate::build::{self, ArcSource};

/// Fixture payloads that intentionally ship in the current production initramfs.
/// The image ships these test binaries today; whether it should is a separate
/// ship-content decision. Until that decision is made they are grandfathered in,
/// keyed by their initramfs archive path, while any *new* fixture payload added to
/// the image is rejected on sight.
const INITRAMFS_FIXTURE_EXCEPTIONS: &[&str] = &[
    "bin/forkbomb",
    "test/argv_echo.elf",
    "test/flibc_demo.elf",
    "test/hello.elf",
    "test/stackbomb.elf",
];

/// Initramfs entries whose checked-in source path under `rootfs/` deliberately
/// differs from the archive path they are staged under. The convention is that the
/// two match; this list documents any sanctioned divergence. Empty by design — the
/// current image stages every `rootfs/` file at its own relative path.
const ROOTFS_PATH_EXCEPTIONS: &[(&str, &str)] = &[];

/// Meta files a vendor drop owns that are not themselves vendored payloads, so they
/// carry no `SHA256SUMS` line of their own.
const VENDOR_META_FILES: &[&str] = &["SHA256SUMS", "README.md"];

/// Enforce every repository layout invariant. Returns a joined report of all
/// violations, or `Ok(())` when the tree is clean.
pub fn run(root: &Path) -> Result<(), String> {
    let mut violations: Vec<String> = Vec::new();

    check_no_platform_files_in_kernel_root(root, &mut violations);
    check_no_new_fixtures_in_initramfs(root, &mut violations)?;
    check_vendor_checksums_and_readme(root, &mut violations);
    check_symbol_area_banner(root, &mut violations);
    check_rootfs_paths_match_initramfs(&mut violations);
    check_workspace_members_resolve(root, &mut violations)?;

    if violations.is_empty() {
        println!("layout OK: 6 invariants satisfied");
        Ok(())
    } else {
        Err(format!(
            "repository layout violations:\n{}",
            violations
                .iter()
                .map(|v| format!("  - {v}"))
                .collect::<Vec<_>>()
                .join("\n")
        ))
    }
}

/// Rule 1: no board-specific `rpi4b_*.rs` file directly under `crates/kernel/src/`.
/// The platform layer lives under `crates/kernel/src/drivers/platform/rpi4b/`; a
/// stray board file at the crate root leaks hardware specifics into portable code.
fn check_no_platform_files_in_kernel_root(root: &Path, out: &mut Vec<String>) {
    let dir = root.join("crates/kernel/src");
    let Ok(entries) = std::fs::read_dir(&dir) else {
        out.push(format!("cannot read {}", dir.display()));
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with("rpi4b_") && name.ends_with(".rs") {
            out.push(format!(
                "board file crates/kernel/src/{name} must live under \
                 crates/kernel/src/drivers/platform/rpi4b/"
            ));
        }
    }
}

/// Rule 2: no fixture payload joins the production initramfs beyond the documented
/// exceptions. Fixtures are the EL0 packages under `userland/fixtures/`; the
/// initramfs entry list and the payload table both come from `build.rs`.
fn check_no_new_fixtures_in_initramfs(root: &Path, out: &mut Vec<String>) -> Result<(), String> {
    let fixture_packages = fixture_package_names(root)?;
    for (arc, _mode, source) in build::INITRAMFS {
        let ArcSource::User(stem) = source else {
            continue;
        };
        let spec = build::user_elf(stem)?;
        if fixture_packages.iter().any(|p| p == spec.package)
            && !INITRAMFS_FIXTURE_EXCEPTIONS.contains(arc)
        {
            out.push(format!(
                "fixture payload `{}` ({}) ships in the initramfs at `{arc}` but is not on \
                 the documented exception list — fixtures are test binaries and do not belong \
                 in the production image",
                spec.package, spec.elf
            ));
        }
    }
    Ok(())
}

/// The cargo package name of every EL0 program under `userland/fixtures/`.
fn fixture_package_names(root: &Path) -> Result<Vec<String>, String> {
    let dir = root.join("userland/fixtures");
    let mut names = Vec::new();
    let entries = std::fs::read_dir(&dir).map_err(|e| format!("read {}: {e}", dir.display()))?;
    for entry in entries.flatten() {
        let manifest = entry.path().join("Cargo.toml");
        if !manifest.is_file() {
            continue;
        }
        let text = std::fs::read_to_string(&manifest)
            .map_err(|e| format!("read {}: {e}", manifest.display()))?;
        if let Some(name) = package_name(&text) {
            names.push(name);
        }
    }
    Ok(names)
}

/// The `name` field of a Cargo manifest's `[package]` section. A minimal reader:
/// the manifests here also carry a `[lib]` with its own `name`, so the section must
/// be tracked rather than grabbing the first `name =` line.
fn package_name(manifest: &str) -> Option<String> {
    let mut in_package = false;
    for line in manifest.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_package = line == "[package]";
            continue;
        }
        if in_package {
            if let Some(rest) = line.strip_prefix("name") {
                let value = rest.trim_start().strip_prefix('=')?.trim();
                return Some(value.trim_matches('"').to_string());
            }
        }
    }
    None
}

/// Rule 3: every vendored payload has a `SHA256SUMS` line and every vendor drop
/// carries a `README.md`. A vendor drop is a directory under `vendor/` that owns a
/// `SHA256SUMS`; its checksum manifest and README are its provenance record.
fn check_vendor_checksums_and_readme(root: &Path, out: &mut Vec<String>) {
    let vendor = root.join("vendor");
    if !vendor.is_dir() {
        return;
    }
    for sums in walk_files(&vendor)
        .into_iter()
        .filter(|p| p.file_name().is_some_and(|n| n == "SHA256SUMS"))
    {
        let drop = sums.parent().unwrap_or(&vendor).to_path_buf();
        let display = drop
            .strip_prefix(root)
            .unwrap_or(&drop)
            .display()
            .to_string();

        if !drop.join("README.md").is_file() {
            out.push(format!("vendor drop {display} has no README.md"));
        }

        let Ok(text) = std::fs::read_to_string(&sums) else {
            out.push(format!("cannot read {}", sums.display()));
            continue;
        };
        // Each line is `<hex>  ./<relative path>`; keep the path column.
        let listed: Vec<String> = text
            .lines()
            .filter_map(|l| l.split_whitespace().nth(1))
            .map(|p| p.trim_start_matches("./").to_string())
            .collect();

        for file in walk_files(&drop) {
            let rel = file
                .strip_prefix(&drop)
                .unwrap_or(&file)
                .to_string_lossy()
                .to_string();
            if VENDOR_META_FILES.contains(&rel.as_str()) {
                continue;
            }
            if !listed.contains(&rel) {
                out.push(format!(
                    "vendored file {display}/{rel} has no SHA256SUMS line"
                ));
            }
        }
    }
}

/// Rule 4: the generated symbol table begins with its DO-NOT-EDIT banner, so a
/// hand edit that skipped the generator is caught before it is committed.
fn check_symbol_area_banner(root: &Path, out: &mut Vec<String>) {
    let path = root.join("crates/kernel/generated/symbol_area.S");
    match std::fs::read_to_string(&path) {
        Ok(text) if text.starts_with(crate::syms::HEADER) => {}
        Ok(_) => out.push(format!(
            "{} does not start with the generated DO-NOT-EDIT banner — regenerate it with \
             `cargo xtask populate-syms`",
            path.display()
        )),
        Err(e) => out.push(format!("read {}: {e}", path.display())),
    }
}

/// Rule 5: every initramfs entry sourced from `rootfs/` is staged at the archive
/// path that matches its source path under `rootfs/`, unless the divergence is on
/// the documented exception list.
fn check_rootfs_paths_match_initramfs(out: &mut Vec<String>) {
    for (arc, _mode, source) in build::INITRAMFS {
        let ArcSource::Static(rel) = source else {
            continue;
        };
        let Some(under_rootfs) = rel.strip_prefix("rootfs/") else {
            continue;
        };
        if under_rootfs == *arc {
            continue;
        }
        if ROOTFS_PATH_EXCEPTIONS.contains(&(*rel, *arc)) {
            continue;
        }
        out.push(format!(
            "initramfs source `{rel}` is staged at `{arc}`, but a rootfs file must be staged at \
             its own relative path (`{under_rootfs}`)"
        ));
    }
}

/// Rule 6: every root workspace member resolves to an existing directory under a
/// known top-level category (`crates/`, `userland/`, or `xtask`).
fn check_workspace_members_resolve(root: &Path, out: &mut Vec<String>) -> Result<(), String> {
    let manifest = root.join("Cargo.toml");
    let text = std::fs::read_to_string(&manifest)
        .map_err(|e| format!("read {}: {e}", manifest.display()))?;
    for member in workspace_members(&text) {
        let known =
            member == "xtask" || member.starts_with("crates/") || member.starts_with("userland/");
        if !known {
            out.push(format!(
                "workspace member `{member}` is not under a known top-level category \
                 (crates/, userland/, xtask)"
            ));
            continue;
        }
        let dir = root.join(&member);
        if !dir.join("Cargo.toml").is_file() {
            out.push(format!(
                "workspace member `{member}` does not resolve to a crate directory"
            ));
        }
    }
    Ok(())
}

/// The entries of the root manifest's `[workspace] members = [ ... ]` array.
fn workspace_members(manifest: &str) -> Vec<String> {
    let mut members = Vec::new();
    let mut in_array = false;
    for line in manifest.lines() {
        let trimmed = line.trim();
        if !in_array {
            if let Some(rest) = trimmed.strip_prefix("members") {
                if rest.trim_start().starts_with('=') && trimmed.contains('[') {
                    in_array = true;
                    collect_quoted(trimmed, &mut members);
                    if trimmed.contains(']') {
                        break;
                    }
                }
            }
            continue;
        }
        collect_quoted(trimmed, &mut members);
        if trimmed.contains(']') {
            break;
        }
    }
    members
}

/// Push every double-quoted substring of `line` onto `out`.
fn collect_quoted(line: &str, out: &mut Vec<String>) {
    let mut rest = line;
    while let Some(open) = rest.find('"') {
        let after = &rest[open + 1..];
        let Some(close) = after.find('"') else { break };
        out.push(after[..close].to_string());
        rest = &after[close + 1..];
    }
}

/// Every regular file under `dir`, recursively. Order is unspecified; callers scan
/// for membership, not sequence.
fn walk_files(dir: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            match entry.file_type() {
                Ok(t) if t.is_dir() => stack.push(path),
                Ok(t) if t.is_file() => files.push(path),
                _ => {}
            }
        }
    }
    files
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn package_name_reads_the_package_section_not_the_lib_section() {
        let manifest = "\
[package]
name = \"flashos-hello\"
version = \"0.1.0\"

[lib]
name = \"flashos_hello\"
crate-type = [\"staticlib\"]
";
        assert_eq!(package_name(manifest).as_deref(), Some("flashos-hello"));
    }

    #[test]
    fn package_name_is_none_without_a_package_section() {
        assert_eq!(package_name("[lib]\nname = \"x\"\n"), None);
    }

    #[test]
    fn workspace_members_parses_a_multiline_array() {
        let manifest = "\
[workspace]
resolver = \"2\"
members = [
    \"xtask\",
    \"crates/kernel\",
    \"userland/coreutils/cat\",
]
exclude = [\"components/flashshell\"]
";
        assert_eq!(
            workspace_members(manifest),
            vec!["xtask", "crates/kernel", "userland/coreutils/cat"]
        );
    }

    #[test]
    fn workspace_members_does_not_capture_the_exclude_array() {
        let manifest = "\
members = [\"xtask\"]
exclude = [\"components/flashshell\"]
";
        assert_eq!(workspace_members(manifest), vec!["xtask"]);
    }

    #[test]
    fn collect_quoted_extracts_every_quoted_token() {
        let mut out = Vec::new();
        collect_quoted("    \"a\", \"b/c\",", &mut out);
        assert_eq!(out, vec!["a", "b/c"]);
    }
}
