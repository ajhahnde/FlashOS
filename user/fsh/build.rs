//! Carry the project version into the shell's homescreen banner.
//!
//! `build.zig.zon` owns the version — a release bumps it there and every consumer
//! follows. The Zig build hands it to its payloads through `build_options`; this is
//! the Rust side of that same single source, read at compile time and exposed as
//! `FLASHOS_VERSION` so no version literal is spelled in the shell.
//!
//! When the Zig build retires, the `.version` field moves into the Cargo manifest and
//! this file collapses into `CARGO_PKG_VERSION`.

use std::path::PathBuf;

fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("workspace root");
    let zon = root.join("build.zig.zon");
    println!("cargo:rerun-if-changed={}", zon.display());

    let text = std::fs::read_to_string(&zon).expect("read build.zig.zon");
    let version = parse_version(&text).expect("build.zig.zon has a .version field");
    println!("cargo:rustc-env=FLASHOS_VERSION={version}");
}

/// Pull the value out of `.version = "x.y.z",`. A hand-rolled scan rather than a ZON
/// parser: one field, one shape, and a build script that needs no dependency.
fn parse_version(text: &str) -> Option<String> {
    let after = text.split(".version").nth(1)?;
    let open = after.find('"')?;
    let rest = &after[open + 1..];
    let close = rest.find('"')?;
    Some(rest[..close].to_string())
}

#[cfg(test)]
mod tests {
    use super::parse_version;

    #[test]
    fn version_is_read_out_of_the_zon_field() {
        assert_eq!(
            parse_version("    .name = .flashos,\n    .version = \"0.8.0\",\n").as_deref(),
            Some("0.8.0")
        );
        assert_eq!(parse_version(".name = .flashos,").as_deref(), None);
    }
}
