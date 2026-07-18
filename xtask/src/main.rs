//! `cargo xtask` — the host orchestrator for FlashOS.
//!
//! It owns the native Rust production build, retained assembly, generated
//! artefacts, host tests, and clean-room checks.

mod asm_defs;
mod build;
mod guard;
mod initramfs;
mod qemu;
mod shadow;
mod syms;
mod toolchain;

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use build::Board;
use toolchain::{Cmd, Toolchain};

const USAGE: &str = "\
cargo xtask <command> [options]

Commands:
  build  --board <rpi4b|virt> [--boot-selftest] [--ci-login-seed] [--trace] [--verbose-fork]
                               Build the full production kernel image natively (payloads,
                               initramfs, kernel link) — no zig. `kernel` is an alias.
  canary --board <rpi4b|virt>   Build the Rust canary kernel (ELF + raw image)
  armstub                       Build the rpi4b EL3->EL1 shim (armstub8.elf + .bin)
  smoke  --board <rpi4b|virt>   Build the canary, boot it in QEMU, assert the marker
  guard  --board <rpi4b|virt> [--full] [gate flags]
                               Build under the clean-room guard (no zig/flashc): the
                               canary by default, or the full production kernel with --full
  nm     --board <rpi4b|virt>   Dump the canary's symbol table
  asm-defs [--check]            Generate the assembly-visible layout facts from crates/abi;
                                --check diffs them against arch/aarch64/asm_defs_common.inc
  user <name> [--output <path>] [--feature <name>]...
                               Build a Rust EL0 payload (hello, clear, pid1, ...)
  klib [--output <path>] [--feature <name>]...
                               Build the Rust kernel staticlib the Zig kernel links
  populate-syms --board <..> [gate flags]
                               Relink the kernel, then regenerate src/symbol_area.S
                               from its symbol table. Re-run `build` to relink with it.
  clear-syms                    Reset src/symbol_area.S to an empty (placeholder)
                               table of the same size, for a from-scratch two-pass
  gen-shadow --output <path>    Bake /etc/shadow with the kernel's own PBKDF2
  test                          Run the Rust host tests (all crates but the bare-metal ones)
  check-hygiene                 Run the repo's whitespace and hex-literal gates
  clean                         Remove rust-out/ and the cargo target dir
  help                          This text

";

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
        "armstub" => {
            let tc = Toolchain::discover()?;
            let bin = build::armstub(&root, &tc)?;
            println!("built {}", bin.display());
            Ok(())
        }
        "build" | "kernel" => {
            let board = board_of(&rest)?;
            let feats = kernel_features_of(&rest)?;
            let tc = Toolchain::discover()?;
            let p = build::build(&root, board, &tc, feats)?;
            println!("built {}", p.img().display());
            Ok(())
        }
        "populate-syms" => {
            let board = board_of(&rest)?;
            let feats = kernel_features_of(&rest)?;
            let tc = Toolchain::discover()?;
            // Relink first so the symbol table reflects the current code, then read
            // it back with the same `nm -n | grep -v '$' | grep -v 'compiler_rt.'`
            // filter the old shell pipeline used. `-n` (no --demangle): the generator
            // carries its own v0 decoder so it can emit path-only names under the
            // fixed-width field, which rustc's full demangling would overflow.
            let p = build::build(&root, board, &tc, feats)?;
            let nm = Cmd::new(tc.nm.clone(), &p.trace)
                .args(["-n".to_string(), p.elf().display().to_string()])
                .capture()?;
            let filtered: String = nm
                .lines()
                .filter(|l| syms::keep_nm_line(l))
                .collect::<Vec<_>>()
                .join("\n");
            let (content, used) = syms::generate(&filtered)?;
            let dst = root.join("src/symbol_area.S");
            std::fs::write(&dst, content).map_err(|e| format!("write {}: {e}", dst.display()))?;
            println!("       -> symbol area: {used} bytes");
            println!(
                "wrote {} — re-run `cargo xtask build` to relink",
                dst.display()
            );
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
            if rest.iter().any(|a| a == "--full") {
                // --full is the guard's own flag; the rest are the kernel gate flags.
                let gates: Vec<String> = rest.iter().filter(|a| *a != "--full").cloned().collect();
                let feats = kernel_features_of(&gates)?;
                guard::run_full(&root, board, &tc, feats)?;
                println!(
                    "guard PASS ({}): clean-room full production build",
                    board.name()
                );
            } else {
                guard::run(&root, board, &tc)?;
                println!("guard PASS ({}): clean-room canary build", board.name());
            }
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
        "klib" => {
            let (output, features) = user_args_of(&rest)?;
            let a = build::klib(&root, output.as_deref(), &features)?;
            println!("built {}", a.display());
            Ok(())
        }
        "clear-syms" => {
            let dst = root.join("src/symbol_area.S");
            std::fs::write(&dst, syms::clear())
                .map_err(|e| format!("write {}: {e}", dst.display()))?;
            println!("cleared {}", dst.display());
            Ok(())
        }
        "gen-shadow" => {
            let (output, _) = user_args_of(&rest)?;
            let out = output.ok_or("usage: cargo xtask gen-shadow --output <path>")?;
            shadow::run(&out)?;
            println!("wrote {}", out.display());
            Ok(())
        }
        // The bare-metal staticlibs are excluded: they carry a #[panic_handler] and
        // cannot link for the host at all. Neither holds testable logic — the
        // canary is a boot marker, and flashos-klib is the C-ABI seam over
        // flashos-kernel, whose tests DO run here.
        "test" => Cmd::new("cargo", &root.join("rust-out/xtask-trace.log"))
            .cwd(&root)
            .args([
                "test",
                "--workspace",
                "--exclude",
                "flashos-canary",
                "--exclude",
                "flashos-klib",
            ])
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

/// The build-time gate flags for `build`/`kernel`, mirroring the `-D…` options
/// The native build threads these through. Unknown `--flags` are board/other options the
/// caller already parsed, so only the four gates are recognised here; anything
/// that looks like a gate but is misspelt is rejected rather than silently off,
/// the same fail-loud rule `user_args_of` follows.
fn kernel_features_of(args: &[String]) -> Result<build::KernelFeatures, String> {
    let mut f = build::KernelFeatures::default();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--boot-selftest" => f.boot_selftest = true,
            "--ci-login-seed" => f.ci_login_seed = true,
            "--trace" => f.trace = true,
            "--verbose-fork" => f.verbose_fork = true,
            "--board" => {
                it.next();
            }
            other if other.starts_with("--board=") => {}
            other => {
                return Err(format!(
                    "build accepts --board <..> [--boot-selftest] [--ci-login-seed] \
                     [--trace] [--verbose-fork], got `{other}`"
                ));
            }
        }
    }
    Ok(f)
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
