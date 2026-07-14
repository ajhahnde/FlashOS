//! `cargo xtask` — the host orchestrator for the Rust side of FlashOS.
//!
//! During the port this coexists with `zig build`, which stays the production
//! oracle: xtask builds and boots the Rust canary and nothing else yet. The
//! command surface grows toward the one build.zig offers today (kernel, deploy,
//! populate-syms, iso, …) as the stages that own those artefacts land.

mod asm_defs;
mod build;
mod guard;
mod qemu;
mod toolchain;
mod ui_defs;

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use build::Board;
use toolchain::{Cmd, Toolchain};

const USAGE: &str = "\
cargo xtask <command> [options]

Commands:
  canary --board <rpi4b|virt>   Build the Rust canary kernel (ELF + raw image)
  smoke  --board <rpi4b|virt>   Build the canary, boot it in QEMU, assert the marker
  guard  --board <rpi4b|virt>   Build the canary under the clean-room guard (no zig/flashc)
  nm     --board <rpi4b|virt>   Dump the canary's symbol table
  asm-defs [--check]            Generate the assembly-visible layout facts from crates/abi;
                                --check diffs them against arch/aarch64/asm_defs_common.inc
  ui-defs [--check]             Diff the console look in crates/console-ui against the
                                Flash copy the kernel still compiles (lib/console_ui/)
  user <name> [--output <path>] [--feature <name>]...
                               Build a Rust EL0 payload (hello, clear, pid1, ...)
  test                          Run the Rust host tests (all crates but the canary)
  check-hygiene                 Run the repo's whitespace and hex-literal gates
  clean                         Remove rust-out/ and the cargo target dir
  help                          This text

The Zig build is untouched: `zig build …` remains the production build.";

fn main() -> ExitCode {
    match dispatch() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("xtask: {e}");
            ExitCode::FAILURE
        }
    }
}

fn dispatch() -> Result<(), String> {
    let root = repo_root()?;
    let mut args = std::env::args().skip(1);
    let cmd = args.next().unwrap_or_else(|| "help".into());
    let rest: Vec<String> = args.collect();

    match cmd.as_str() {
        "help" | "-h" | "--help" => {
            println!("{USAGE}");
            Ok(())
        }
        "canary" => {
            let board = board_of(&rest)?;
            let tc = Toolchain::discover()?;
            let p = build::canary(&root, board, &tc)?;
            println!("built {}", p.img().display());
            Ok(())
        }
        "smoke" => {
            let board = board_of(&rest)?;
            let tc = Toolchain::discover()?;
            let p = build::canary(&root, board, &tc)?;
            let marker = "[RUST-CANARY] kernel_main reached EL1 via boot.S";
            qemu::expect_marker(&p, board, marker, Duration::from_secs(60))?;
            println!("smoke PASS ({}): canary reached EL1", board.name());
            Ok(())
        }
        "guard" => {
            let board = board_of(&rest)?;
            let tc = Toolchain::discover()?;
            guard::run(&root, board, &tc)?;
            println!("guard PASS ({}): clean-room build", board.name());
            Ok(())
        }
        "nm" => {
            let board = board_of(&rest)?;
            let tc = Toolchain::discover()?;
            let p = build::Paths::new(&root, board);
            if !p.elf().exists() {
                return Err(format!(
                    "{} does not exist — run `cargo xtask canary --board {}` first",
                    p.elf().display(),
                    board.name()
                ));
            }
            let out = Cmd::new(tc.nm.clone(), &p.trace)
                .args(["-n".to_string(), p.elf().display().to_string()])
                .capture()?;
            print!("{out}");
            Ok(())
        }
        "asm-defs" => asm_defs::run(&root, rest.iter().any(|a| a == "--check")),
        "ui-defs" => ui_defs::run(&root, rest.iter().any(|a| a == "--check")),
        "user" => {
            let name = rest
                .first()
                .filter(|a| !a.starts_with("--"))
                .ok_or("usage: cargo xtask user <name> [--output <path>] [--feature <name>]...")?;
            let spec = build::user_elf(name)?;
            let tc = Toolchain::discover()?;
            let (output, features) = user_args_of(&rest[1..])?;
            let elf = build::build_user_elf(&root, &tc, spec, output.as_deref(), &features)?;
            println!("built {}", elf.display());
            Ok(())
        }
        "test" => Cmd::new("cargo", &root.join("rust-out/xtask-trace.log"))
            .cwd(&root)
            .args(["test", "--workspace", "--exclude", "flashos-canary"])
            .run(),
        "check-hygiene" => {
            let trace = root.join("rust-out/xtask-trace.log");
            for script in [
                "scripts/check_whitespace_hygiene.sh",
                "scripts/check_hex_hygiene.sh",
            ] {
                Cmd::new("sh", &trace)
                    .cwd(&root)
                    .arg(script)
                    .run()
                    .map_err(|e| format!("{script}: {e}"))?;
            }
            println!("hygiene OK");
            Ok(())
        }
        "clean" => {
            for dir in ["rust-out", "target"] {
                let p = root.join(dir);
                if p.exists() {
                    std::fs::remove_dir_all(&p)
                        .map_err(|e| format!("rm -rf {}: {e}", p.display()))?;
                    println!("removed {}", p.display());
                }
            }
            Ok(())
        }
        other => Err(format!("unknown command `{other}`\n\n{USAGE}")),
    }
}

/// The tail of a `user` invocation: where to put the ELF, and which cargo features to
/// build it with. Unknown flags are rejected rather than ignored -- a misspelt
/// `--feature boot-seltest` that silently produced a payload without the harness would
/// hand the watchdog a boot with no scenarios in it and no error to explain why.
fn user_args_of(args: &[String]) -> Result<(Option<PathBuf>, Vec<String>), String> {
    let mut output = None;
    let mut features = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if let Some(path) = a.strip_prefix("--output=") {
            output = Some(PathBuf::from(path));
        } else if a == "--output" {
            let path = it.next().ok_or("--output needs a path")?;
            output = Some(PathBuf::from(path));
        } else if let Some(name) = a.strip_prefix("--feature=") {
            features.push(name.to_string());
        } else if a == "--feature" {
            features.push(it.next().ok_or("--feature needs a name")?.clone());
        } else {
            return Err(format!(
                "user accepts only [--output <path>] [--feature <name>]..., got `{a}`"
            ));
        }
    }
    Ok((output, features))
}

fn board_of(args: &[String]) -> Result<Board, String> {
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a == "--board" {
            let v = it.next().ok_or("--board needs a value")?;
            return Board::parse(v);
        }
        if let Some(v) = a.strip_prefix("--board=") {
            return Board::parse(v);
        }
    }
    Err("missing --board <rpi4b|virt>".into())
}

/// The workspace root, i.e. the repo root — xtask/ lives directly below it.
fn repo_root() -> Result<PathBuf, String> {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| "xtask has no parent directory".into())
}
