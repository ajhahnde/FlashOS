//! Clean-room guard: proof that a Rust-side build invoked neither `zig` nor
//! `flashc`.
//!
//! Two independent checks, because either alone can be fooled:
//!
//! 1. **Trace check** — every subprocess xtask spawns is appended to the build's
//!    trace file by `Cmd`; the guard greps it. This catches a direct call.
//! 2. **PATH shim** — the build is re-run with a shim directory prepended to
//!    `PATH` holding executables named `zig` and `flashc` that record their
//!    invocation and exit non-zero. This catches an *indirect* call — a build
//!    script, a wrapper, a cargo hook — that the trace would never see.
//!
//! A build that passes both did not use the old toolchain, which is the property
//! the port requires: the Rust build must stand on its own.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use crate::build::{self, Board, Paths};
use crate::toolchain::Toolchain;

const FORBIDDEN: [&str; 2] = ["zig", "flashc"];

/// Create (or refresh) the shim dir and return it.
fn shim_dir(root: &Path) -> Result<PathBuf, String> {
    let dir = root.join("rust-out/guard-shims");
    fs::create_dir_all(&dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    let witness = dir.join("invoked.log");
    let _ = fs::remove_file(&witness);

    for tool in FORBIDDEN {
        let path = dir.join(tool);
        let script = format!(
            "#!/bin/sh\n\
             # Clean-room guard shim. Refuses to run and records the attempt.\n\
             printf '%s %s\\n' \"{tool}\" \"$*\" >> \"{}\"\n\
             echo \"clean-room violation: {tool} was invoked by the Rust build\" >&2\n\
             exit 1\n",
            witness.display()
        );
        fs::write(&path, script).map_err(|e| format!("write {}: {e}", path.display()))?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755))
            .map_err(|e| format!("chmod {}: {e}", path.display()))?;
    }
    Ok(dir)
}

/// Build the canary under the shim PATH, then assert both checks.
pub fn run(root: &Path, board: Board, tc: &Toolchain) -> Result<(), String> {
    let dir = shim_dir(root)?;
    let old_path = std::env::var("PATH").unwrap_or_default();
    // SAFETY-of-process note: xtask is single-threaded here, and the shimmed PATH
    // must be inherited by cargo and every tool it spawns.
    std::env::set_var("PATH", format!("{}:{}", dir.display(), old_path));

    let built = build::canary(root, board, tc);

    std::env::set_var("PATH", &old_path);
    let p = built?;

    verify(&p, &dir)
}

/// Assert the two checks against an already-produced build.
pub fn verify(p: &Paths, shims: &Path) -> Result<(), String> {
    let witness = shims.join("invoked.log");
    if witness.exists() {
        let what = fs::read_to_string(&witness).unwrap_or_default();
        return Err(format!(
            "clean-room violation: a shimmed tool ran during the build:\n{what}"
        ));
    }

    let trace = fs::read_to_string(&p.trace)
        .map_err(|e| format!("no build trace at {}: {e}", p.trace.display()))?;
    let hits: Vec<&str> = trace
        .lines()
        .filter(|l| {
            let prog = l.split_whitespace().next().unwrap_or("");
            let base = Path::new(prog)
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default();
            FORBIDDEN.contains(&base.as_str())
        })
        .collect();
    if !hits.is_empty() {
        return Err(format!(
            "clean-room violation: the build trace shows the old toolchain:\n{}",
            hits.join("\n")
        ));
    }

    let n = trace.lines().filter(|l| !l.trim().is_empty()).count();
    println!("  clean-room OK: {n} traced commands, no zig, no flashc (trace + PATH shim)");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    /// A guard that cannot fail proves nothing, so each rejection path is
    /// exercised against a synthetic build directory.
    fn scratch(tag: &str) -> PathBuf {
        let n = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("xtask-guard-{tag}-{n}"));
        fs::create_dir_all(dir.join("shims")).unwrap();
        fs::create_dir_all(dir.join("out")).unwrap();
        dir
    }

    fn paths(dir: &Path, trace: &str) -> Paths {
        let out = dir.join("out");
        let t = out.join("xtask-trace.log");
        fs::write(&t, trace).unwrap();
        Paths { trace: t, out }
    }

    #[test]
    fn clean_trace_passes() {
        let dir = scratch("clean");
        let p = paths(&dir, "cargo build --release\n/usr/bin/clang -c boot.S\n");
        assert!(verify(&p, &dir.join("shims")).is_ok());
    }

    #[test]
    fn traced_zig_invocation_is_rejected() {
        let dir = scratch("zig");
        let p = paths(
            &dir,
            "cargo build\n/opt/homebrew/bin/zig build-obj foo.zig\n",
        );
        let err = verify(&p, &dir.join("shims")).unwrap_err();
        assert!(err.contains("build trace"), "{err}");
    }

    #[test]
    fn traced_flashc_invocation_is_rejected() {
        let dir = scratch("flashc");
        let p = paths(&dir, "flashc --backend=zig src/main.flash\n");
        assert!(verify(&p, &dir.join("shims")).is_err());
    }

    /// The shim witness catches an *indirect* call the trace never sees.
    #[test]
    fn shim_witness_is_rejected() {
        let dir = scratch("witness");
        let p = paths(&dir, "cargo build\n");
        fs::write(dir.join("shims/invoked.log"), "zig build-lib\n").unwrap();
        let err = verify(&p, &dir.join("shims")).unwrap_err();
        assert!(err.contains("shimmed tool"), "{err}");
    }

    /// A missing trace must fail closed: no evidence is not a pass.
    #[test]
    fn missing_trace_is_rejected() {
        let dir = scratch("notrace");
        let p = Paths {
            out: dir.join("out"),
            trace: dir.join("out/absent.log"),
        };
        assert!(verify(&p, &dir.join("shims")).is_err());
    }
}
