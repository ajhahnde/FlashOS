//! The Rust-side kernel build pipeline: cargo → clang → rust-lld → objcopy.
//!
//! It reproduces the artefact contract of the current `zig build` (kernel8.elf +
//! kernel8.img, board linker script, the retained `.S` files) for the canary
//! image only. The Zig build remains the production oracle until the kernel itself is ported.

use std::fs;
use std::path::{Path, PathBuf};

use crate::toolchain::{Cmd, Toolchain};

pub const TARGET: &str = "aarch64-unknown-none-softfloat";

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Board {
    Rpi4b,
    Virt,
}

impl Board {
    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "rpi4b" => Ok(Board::Rpi4b),
            "virt" => Ok(Board::Virt),
            other => Err(format!("unknown board `{other}` (expected rpi4b or virt)")),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Board::Rpi4b => "rpi4b",
            Board::Virt => "virt",
        }
    }

    /// Board-specific assembly, appended after the common files. Mirrors the
    /// board switch in build.zig's `asm_files`.
    fn board_asm(self) -> &'static [&'static str] {
        match self {
            Board::Rpi4b => &["boot_quirks.S"],
            // The Linux arm64 image header must precede the boot code; the
            // linker script pins it via its own .text.boot.header section.
            Board::Virt => &["image_header.S", "boot_quirks.S"],
        }
    }
}

/// Order is load-bearing: within `.text.boot` the linker keeps input order, and
/// boot_quirks.S also contributes to that section. If boot.S is not first,
/// `_start` moves off the image base and the firmware jumps into the wrong code.
const COMMON_ASM: &[&str] = &[
    "arch/aarch64/boot.S",
    "arch/aarch64/entry.S",
    "arch/aarch64/utils.S",
    "arch/aarch64/mm.S",
    "arch/aarch64/sched.S",
    "arch/aarch64/irq.S",
    "arch/aarch64/generic_timer.S",
];

pub struct Paths {
    pub out: PathBuf,
    pub trace: PathBuf,
}

impl Paths {
    pub fn new(root: &Path, board: Board) -> Self {
        let out = root.join("rust-out").join(board.name());
        Self {
            trace: out.join("xtask-trace.log"),
            out,
        }
    }

    pub fn elf(&self) -> PathBuf {
        self.out.join("kernel8.elf")
    }

    pub fn img(&self) -> PathBuf {
        self.out.join("kernel8.img")
    }
}

/// Build the canary kernel image for `board`. Returns the paths it produced.
pub fn canary(root: &Path, board: Board, tc: &Toolchain) -> Result<Paths, String> {
    let p = Paths::new(root, board);
    fs::create_dir_all(p.out.join("obj")).map_err(|e| format!("mkdir {}: {e}", p.out.display()))?;
    // Fresh trace per build so the clean-room guard never reads a stale verdict.
    let _ = fs::remove_file(&p.trace);

    // 1. The Rust half: a staticlib for the bare-metal soft-float target. The
    //    target's own defaults carry +strict-align and -neon, which is what the
    //    kernel's SCTLR_EL1.A setting requires.
    let mut cargo = Cmd::new("cargo", &p.trace).cwd(root).args([
        "build",
        "--release",
        "-p",
        "flashos-canary",
        "--target",
        TARGET,
    ]);
    if board == Board::Virt {
        cargo = cargo.args(["--features", "virt"]);
    }
    cargo.run()?;
    let staticlib = root
        .join("target")
        .join(TARGET)
        .join("release")
        .join("libflashos_canary.a");
    if !staticlib.exists() {
        return Err(format!("cargo produced no {}", staticlib.display()));
    }

    // 2. Assemble the retained .S files. Same three include dirs build.zig uses:
    //    arch/aarch64 (asm_defs.inc), src, and the board's board_asm_defs.inc.
    let board_dir = root.join("src/board").join(board.name());
    let mut objs: Vec<PathBuf> = Vec::new();
    let sources: Vec<PathBuf> = COMMON_ASM
        .iter()
        .map(|s| root.join(s))
        .chain(board.board_asm().iter().map(|s| board_dir.join(s)))
        .collect();

    for src in &sources {
        let stem = src
            .file_stem()
            .ok_or_else(|| format!("no stem: {}", src.display()))?;
        let obj = p
            .out
            .join("obj")
            .join(format!("{}.o", stem.to_string_lossy()));
        Cmd::new(tc.clang.clone(), &p.trace)
            .args([
                "--target=aarch64-unknown-none-elf".into(),
                "-c".into(),
                "-ffreestanding".into(),
                "-fno-pic".into(),
                format!("-I{}", root.join("arch/aarch64").display()),
                format!("-I{}", root.join("src").display()),
                format!("-I{}", board_dir.display()),
                "-o".into(),
                obj.display().to_string(),
                src.display().to_string(),
            ])
            .run()?;
        objs.push(obj);
    }

    // 3. Link against the real board linker script. `--no-gc-sections` and the
    //    4 KiB max page size match build.zig; the entry point comes from the
    //    script + boot.S, not from a linker default.
    let script = board_dir.join("linker.ld");
    Cmd::new(tc.lld.clone(), &p.trace)
        .args([
            "-flavor".to_string(),
            "gnu".to_string(),
            "-T".to_string(),
            script.display().to_string(),
            "-z".to_string(),
            "max-page-size=0x1000".to_string(),
            "--no-gc-sections".to_string(),
            "-o".to_string(),
            p.elf().display().to_string(),
        ])
        .args(objs.iter().map(|o| o.display().to_string()))
        .arg(staticlib.display().to_string())
        .run()?;

    // 4. Raw image, exactly as the firmware expects to find it.
    Cmd::new(tc.objcopy.clone(), &p.trace)
        .args([
            "-O".to_string(),
            "binary".to_string(),
            p.elf().display().to_string(),
            p.img().display().to_string(),
        ])
        .run()?;

    inspect(&p, tc)?;
    Ok(p)
}

/// Artefact inspection: the checks that would otherwise only fail on hardware.
fn inspect(p: &Paths, tc: &Toolchain) -> Result<(), String> {
    let syms = Cmd::new(tc.nm.clone(), &p.trace)
        .args(["-n".to_string(), p.elf().display().to_string()])
        .capture()?;

    // `_start` must sit at the image base: the firmware jumps to the first byte.
    let start = syms
        .lines()
        .find(|l| l.ends_with(" _start"))
        .ok_or("no _start in the linked kernel")?;
    let start_addr = start.split_whitespace().next().unwrap_or("");
    let expected = match p.out.file_name().and_then(|s| s.to_str()) {
        Some("rpi4b") => "0000000000080000",
        _ => "0000000040080040", // behind the 64-byte Linux arm64 image header
    };
    if start_addr != expected {
        return Err(format!(
            "_start is at 0x{start_addr}, expected 0x{expected} — object order or linker script drifted"
        ));
    }

    // No undefined symbols: a bare-metal image has nothing to resolve them.
    let undef = Cmd::new(tc.nm.clone(), &p.trace)
        .args(["-u".to_string(), p.elf().display().to_string()])
        .capture()?;
    let undef: Vec<&str> = undef.lines().filter(|l| !l.trim().is_empty()).collect();
    if !undef.is_empty() {
        return Err(format!(
            "undefined symbols in the kernel:\n{}",
            undef.join("\n")
        ));
    }

    // The panic path must not drag in core::fmt — it is the symbol-budget and
    // code-size multiplier the port is explicitly avoiding.
    let fmt: Vec<&str> = syms
        .lines()
        .filter(|l| l.contains("core..fmt") || l.contains("core::fmt"))
        .collect();
    if !fmt.is_empty() {
        return Err(format!(
            "core::fmt linked into the kernel ({} symbols); the panic path regressed",
            fmt.len()
        ));
    }

    // FP/SIMD would be silently corrupted: FlashOS saves no vector state.
    let dis = Cmd::new(tc.objdump.clone(), &p.trace)
        .args([
            "-d".to_string(),
            "--no-show-raw-insn".to_string(),
            p.elf().display().to_string(),
        ])
        .capture()?;
    let fp: Vec<&str> = dis
        .lines()
        .filter(|l| {
            let t = l.trim();
            // Instruction lines only; the operand columns start after the mnemonic.
            t.contains(" q0")
                || t.contains(" q1")
                || t.contains(" v0.")
                || t.contains(" v1.")
                || t.contains("fmov")
                || t.contains("fadd")
        })
        .collect();
    if !fp.is_empty() {
        return Err(format!(
            "FP/SIMD instructions in the kernel image:\n{}",
            fp.iter().take(10).cloned().collect::<Vec<_>>().join("\n")
        ));
    }

    let size = fs::metadata(p.img())
        .map_err(|e| format!("stat {}: {e}", p.img().display()))?
        .len();
    println!(
        "  kernel8.img {} bytes, _start 0x{start_addr}, 0 undefined, 0 core::fmt, 0 FP/SIMD",
        size
    );
    Ok(())
}
