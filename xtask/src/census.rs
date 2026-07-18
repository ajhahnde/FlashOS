//! Source census for implementation languages retired from the maintained tree.

use std::path::{Path, PathBuf};

use crate::toolchain::Cmd;

// Frozen historical examples may be admitted only by exact repo-relative path.
// The maintained public tree currently needs no exceptions.
const ALLOWLIST: &[&str] = &[];

pub fn run(root: &Path) -> Result<(), String> {
    // Git's tracked + unignored view is the maintained-source boundary. It
    // catches a newly created candidate before it is staged, while leaving
    // ignored private and generated trees outside the public census.
    let listing = Cmd::new("git", &root.join("rust-out/xtask-trace.log"))
        .cwd(root)
        .args(["ls-files", "--cached", "--others", "--exclude-standard"])
        .capture()?;
    let violations = implementation_files(listing.lines());
    if !violations.is_empty() {
        let paths = violations
            .iter()
            .map(|path| format!("  {}", path.display()))
            .collect::<Vec<_>>()
            .join("\n");
        return Err(format!(
            "source census violation: maintained Flash/Zig implementation files are forbidden:\n\
             {paths}\n\
             move the implementation to Rust or allowlist an exact frozen historical example"
        ));
    }

    println!("source census OK: 0 Flash, 0 Zig implementation files");
    Ok(())
}

fn implementation_files<'a>(paths: impl IntoIterator<Item = &'a str>) -> Vec<PathBuf> {
    let mut violations: Vec<PathBuf> = paths
        .into_iter()
        .map(Path::new)
        .filter(|path| {
            path.extension()
                .and_then(|ext| ext.to_str())
                .is_some_and(|ext| {
                    ext.eq_ignore_ascii_case("flash") || ext.eq_ignore_ascii_case("zig")
                })
        })
        .filter(|path| !ALLOWLIST.iter().any(|allowed| *path == Path::new(allowed)))
        .map(Path::to_path_buf)
        .collect();
    violations.sort();
    violations
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rust_only_tree_passes() {
        let files = ["src/lib.rs", "src/nested/boot.S", "Cargo.toml"];
        assert!(implementation_files(files).is_empty());
    }

    #[test]
    fn retired_implementation_files_are_rejected_and_sorted() {
        let files = ["src/nested/kernel.ZIG", "src/board.flash"];

        assert_eq!(
            implementation_files(files),
            [
                PathBuf::from("src/board.flash"),
                PathBuf::from("src/nested/kernel.ZIG")
            ]
        );
    }

    #[test]
    fn source_like_text_and_directory_names_do_not_false_positive() {
        let files = ["docs/old-zig-build.md", "zig/examples.txt", "src/flash.rs"];
        assert!(implementation_files(files).is_empty());
    }
}
