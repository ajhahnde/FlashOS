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

/// Symbol-table lines belonging to `core::fmt`, over *demangled* nm output.
///
/// The formatting engine is a code-size and symbol-count multiplier that eats the
/// kernel's fixed 128 KiB symbol budget, so no production binary may link it. Rust
/// reaches it through paths that do not look like formatting at the call site: any
/// formatted panic message (`copy_from_slice`, `unwrap`, an overflow assert) builds
/// `fmt::Arguments` and pulls the engine in behind it.
pub fn fmt_symbols(demangled_nm: &str) -> Vec<&str> {
    demangled_nm
        .lines()
        .filter(|l| l.contains("core::fmt") || l.contains("core..fmt"))
        .collect()
}

/// Disassembly lines that use a vector or floating-point register -- which FlashOS
/// never saves, so a payload that touches one is silently corrupted across a context
/// switch.
///
/// The check reads the mnemonic and its operands, not the raw line: a single-segment
/// payload folds its read-only data into the executable segment, so objdump renders
/// string bytes as `.word 0x…` and a plain substring scan reports any constant that
/// happens to spell an instruction (`0xd0fadd61` contains `fadd`).
pub fn fp_simd_lines(disassembly: &str) -> Vec<&str> {
    disassembly
        .lines()
        .filter(|line| {
            // "  4000c8: d2800020  mov x0, #1" -- drop the address, then the raw byte
            // columns, and what remains starts at the mnemonic.
            let Some((_, code)) = line.split_once(':') else {
                return false;
            };
            let mut fields = code
                .split_whitespace()
                .skip_while(|f| f.len() == 2 && f.chars().all(|c| c.is_ascii_hexdigit()));
            let Some(mnemonic) = fields.next() else {
                return false;
            };
            // Data rendered as an instruction (".word", ".byte") is not code at all.
            if mnemonic.starts_with('.') {
                return false;
            }
            if FP_MNEMONICS.iter().any(|m| mnemonic.starts_with(m)) {
                return true;
            }
            // A vector register operand: v0.16b, q1, d2, s3 -- a register name is a
            // whole token, never a fragment of a hex constant.
            fields.any(|operand| {
                operand
                    .trim_end_matches(',')
                    .split(['.', '[', ']'])
                    .next()
                    .is_some_and(is_vector_register)
            })
        })
        .collect()
}

/// Mnemonic prefixes that mean the FP unit. Prefix-matched so `fmov`/`fcvtzs`/`fadd`
/// and friends are all covered without listing the whole encoding space.
const FP_MNEMONICS: &[&str] = &[
    "fmov", "fadd", "fsub", "fmul", "fdiv", "fcvt", "fcmp", "fneg", "fabs", "fsqrt", "fmadd",
    "fmsub", "scvtf", "ucvtf",
];

/// Whether a token names an AArch64 vector/FP register (`v12`, `q0`, `d3`, `s1`).
fn is_vector_register(token: &str) -> bool {
    let mut chars = token.chars();
    let Some(prefix) = chars.next() else {
        return false;
    };
    if !matches!(prefix, 'v' | 'q' | 'd' | 's' | 'h' | 'b') {
        return false;
    }
    let digits = chars.as_str();
    !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit())
}

/// One Rust EL0 payload: the cargo package that builds it, the retained linker
/// script that lays it out, and the ELF name the initramfs stages it under.
pub struct UserElf {
    /// Basename of the produced ELF, e.g. `hello.elf`.
    pub elf: &'static str,
    /// Cargo package name, e.g. `flashos-hello`.
    pub package: &'static str,
    /// Staticlib cargo emits for that package, e.g. `libflashos_hello.a`.
    pub archive: &'static str,
    /// Retained linker script, relative to the repository root.
    pub linker_script: &'static str,
}

/// Every EL0 payload the Rust side owns today. A payload joins this table when its
/// stage ports it; the Zig build reads each one back through `cargo xtask user`.
pub const USER_ELFS: &[UserElf] = &[
    UserElf {
        elf: "hello.elf",
        package: "flashos-hello",
        archive: "libflashos_hello.a",
        linker_script: "tools/hello_linker.ld",
    },
    UserElf {
        elf: "clear.elf",
        package: "flashos-clear",
        archive: "libflashos_clear.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "cat.elf",
        package: "flashos-cat",
        archive: "libflashos_cat.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "cp.elf",
        package: "flashos-cp",
        archive: "libflashos_cp.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "cpuinfo.elf",
        package: "flashos-cpuinfo",
        archive: "libflashos_cpuinfo.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "dmesg.elf",
        package: "flashos-dmesg",
        archive: "libflashos_dmesg.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "echo.elf",
        package: "flashos-echo",
        archive: "libflashos_echo.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "forkbomb.elf",
        package: "flashos-forkbomb",
        archive: "libflashos_forkbomb.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "grep.elf",
        package: "flashos-grep",
        archive: "libflashos_grep.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "login.elf",
        package: "flashos-login",
        archive: "libflashos_login.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "ls.elf",
        package: "flashos-ls",
        archive: "libflashos_ls.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "meminfo.elf",
        package: "flashos-meminfo",
        archive: "libflashos_meminfo.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "mv.elf",
        package: "flashos-mv",
        archive: "libflashos_mv.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "passwd.elf",
        package: "flashos-passwd",
        archive: "libflashos_passwd.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "rm.elf",
        package: "flashos-rm",
        archive: "libflashos_rm.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "sysinfo.elf",
        package: "flashos-sysinfo",
        archive: "libflashos_sysinfo.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "uptime.elf",
        package: "flashos-uptime",
        archive: "libflashos_uptime.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    // The two full-screen tools. Both drive the TUI render core and both take the same
    // single-PT_LOAD layout as the coreutils -- the interactive half needs no linker
    // treatment of its own, only a bigger stack, which the layout already grants.
    UserElf {
        elf: "less.elf",
        package: "flashos-less",
        archive: "libflashos_less.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    UserElf {
        elf: "edit.elf",
        package: "flashos-edit",
        archive: "libflashos_edit.a",
        linker_script: "tools/coreutil_linker.ld",
    },
    // The harness payloads. Each keeps the retained script its old counterpart used:
    // argv_echo's own (it carries the over-a-page padding), flibc_demo's folded
    // single-segment layout, and the generic one stackbomb shares with hello.
    UserElf {
        elf: "argv_echo.elf",
        package: "flashos-argv-echo",
        archive: "libflashos_argv_echo.a",
        linker_script: "tools/argv_echo_linker.ld",
    },
    UserElf {
        elf: "flibc_demo.elf",
        package: "flashos-flibc-demo",
        archive: "libflashos_flibc_demo.a",
        linker_script: "tools/flibc_demo_linker.ld",
    },
    UserElf {
        elf: "stackbomb.elf",
        package: "flashos-stackbomb",
        archive: "libflashos_stackbomb.a",
        linker_script: "tools/hello_linker.ld",
    },
];

/// Look a payload up by ELF basename, minus the extension (`hello`, `clear`).
pub fn user_elf(name: &str) -> Result<&'static UserElf, String> {
    USER_ELFS
        .iter()
        .find(|u| u.elf.trim_end_matches(".elf") == name)
        .ok_or_else(|| {
            let known: Vec<&str> = USER_ELFS
                .iter()
                .map(|u| u.elf.trim_end_matches(".elf"))
                .collect();
            format!(
                "unknown user payload `{name}` (known: {})",
                known.join(", ")
            )
        })
}

/// Build one Rust EL0 payload and link it with its retained single-PT_LOAD linker
/// script. The old kernel consumes the ELF without knowing or caring which
/// implementation language produced it.
pub fn build_user_elf(
    root: &Path,
    tc: &Toolchain,
    spec: &UserElf,
    requested_output: Option<&Path>,
) -> Result<PathBuf, String> {
    let out = root.join("rust-out/user");
    let trace = out.join("xtask-trace.log");
    fs::create_dir_all(&out).map_err(|e| format!("mkdir {}: {e}", out.display()))?;
    let _ = fs::remove_file(&trace);

    Cmd::new("cargo", &trace)
        .cwd(root)
        .args(["build", "--release", "-p", spec.package, "--target", TARGET])
        .run()?;
    let archive = root
        .join("target")
        .join(TARGET)
        .join("release")
        .join(spec.archive);
    if !archive.exists() {
        return Err(format!("cargo produced no {}", archive.display()));
    }

    let stem = spec.elf.trim_end_matches(".elf");
    let unstripped = out.join(format!("{stem}.unstripped.elf"));
    Cmd::new(tc.lld.clone(), &trace)
        .args([
            "-flavor".to_string(),
            "gnu".to_string(),
            "-T".to_string(),
            root.join(spec.linker_script).display().to_string(),
            "-z".to_string(),
            "max-page-size=0x80".to_string(),
            "--no-gc-sections".to_string(),
            "-o".to_string(),
            unstripped.display().to_string(),
            archive.display().to_string(),
        ])
        .run()?;

    inspect_user_elf(spec, &unstripped, &trace, tc, true)?;

    let output = requested_output
        .map(Path::to_path_buf)
        .unwrap_or_else(|| out.join(spec.elf));
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    Cmd::new(tc.strip.clone(), &trace)
        .args([
            "--strip-all".to_string(),
            "-o".to_string(),
            output.display().to_string(),
            unstripped.display().to_string(),
        ])
        .run()?;

    inspect_user_elf(spec, &output, &trace, tc, false)?;
    Ok(output)
}

fn inspect_user_elf(
    spec: &UserElf,
    elf: &Path,
    trace: &Path,
    tc: &Toolchain,
    inspect_symbols: bool,
) -> Result<(), String> {
    let headers = Cmd::new(tc.readobj.clone(), trace)
        .args([
            "--file-headers".to_string(),
            "--program-headers".to_string(),
            "--sections".to_string(),
            elf.display().to_string(),
        ])
        .capture()?;
    for required in [
        "Format: elf64-littleaarch64",
        "Type: Executable",
        "Machine: EM_AARCH64",
        "Entry: 0x0",
        "ProgramHeaderCount: 1",
        "Alignment: 128",
    ] {
        if !headers.contains(required) {
            return Err(format!(
                "{} lacks ELF invariant `{required}`",
                elf.display()
            ));
        }
    }
    if headers.matches("Type: PT_LOAD").count() != 1
        || !headers.contains("PF_R")
        || !headers.contains("PF_X")
        || headers.contains("PF_W")
    {
        return Err(format!(
            "{} must contain exactly one read/execute, non-writable PT_LOAD",
            elf.display()
        ));
    }

    if inspect_symbols {
        let undefined = Cmd::new(tc.nm.clone(), trace)
            .args(["-u".to_string(), elf.display().to_string()])
            .capture()?;
        if !undefined.trim().is_empty() {
            return Err(format!(
                "undefined symbols in {}:\n{}",
                elf.display(),
                undefined
            ));
        }

        // Demangled: Rust's v0 mangling spells the path `..4core3fmt..`, so a scan for
        // the source spelling reads clean on a payload that in fact carries the whole
        // formatting engine. Ask nm to undo the mangling and match what it prints.
        let symbols = Cmd::new(tc.nm.clone(), trace)
            .args([
                "-n".to_string(),
                "--demangle".to_string(),
                elf.display().to_string(),
            ])
            .capture()?;
        for required in ["_start", "memcpy", "memset", "memmove", "memcmp", "strlen"] {
            let count = symbols
                .lines()
                .filter(|line| line.split_whitespace().last() == Some(required))
                .count();
            if count != 1 {
                return Err(format!(
                    "{} must define `{required}` exactly once, found {count}",
                    elf.display()
                ));
            }
        }
        let fmt = fmt_symbols(&symbols);
        if !fmt.is_empty() {
            return Err(format!(
                "core::fmt linked into {} ({} symbols, e.g. {}); the payload formats \
                 somewhere it must not -- a formatted panic (`copy_from_slice`, \
                 `unwrap`, an arithmetic assert) is the usual source",
                elf.display(),
                fmt.len(),
                fmt[0].trim()
            ));
        }

        let disassembly = Cmd::new(tc.objdump.clone(), trace)
            .args([
                "-d".to_string(),
                "--no-show-raw-insn".to_string(),
                elf.display().to_string(),
            ])
            .capture()?;
        let forbidden = fp_simd_lines(&disassembly);
        if !forbidden.is_empty() {
            return Err(format!(
                "FP/SIMD instructions in {}:\n{}",
                elf.display(),
                forbidden
                    .iter()
                    .take(10)
                    .copied()
                    .collect::<Vec<_>>()
                    .join("\n")
            ));
        }
    }

    let size = fs::metadata(elf)
        .map_err(|e| format!("stat {}: {e}", elf.display()))?
        .len();
    println!(
        "  {} {size} bytes, AArch64 ET_EXEC, entry 0x0, one R+X PT_LOAD, 0 undefined",
        spec.elf
    );
    Ok(())
}

/// Artefact inspection: the checks that would otherwise only fail on hardware.
fn inspect(p: &Paths, tc: &Toolchain) -> Result<(), String> {
    // Demangled, so the core::fmt check below sees v0-mangled names for what they are.
    let syms = Cmd::new(tc.nm.clone(), &p.trace)
        .args([
            "-n".to_string(),
            "--demangle".to_string(),
            p.elf().display().to_string(),
        ])
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
    let fmt = fmt_symbols(&syms);
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
    let fp = fp_simd_lines(&dis);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_vector_or_floating_point_instruction_is_reported() {
        let dis = "\
   4000c8: 3d800020     str q0, [x1]
   4000cc: 1e604020     fmov d0, d1
   4000d0: 4e208400     add v0.16b, v0.16b, v0.16b
   4000d4: 1e620000     scvtf d0, w0";
        assert_eq!(fp_simd_lines(dis).len(), 4);
    }

    #[test]
    fn integer_code_and_data_words_are_not_reported() {
        // The `.word` is the trap this check was rewritten for: a single-segment
        // payload disassembles its own read-only data, and the constant 0xd0fadd61
        // spells "fadd" to a substring scan while being a string byte, not code.
        let dis = "\
   4000c8: d2800020     mov x0, #1
   4000cc: 91000421     add x1, x1, #1
   27308: 61 dd fa d0  .word 0xd0fadd61
   2730c: 00 f0 fa d0  .word 0xd0faf000";
        assert!(fp_simd_lines(dis).is_empty());
    }

    #[test]
    fn the_fmt_scan_reads_demangled_names() {
        // The hole this closes: nm's raw output spells the path `4core3fmt`, so the
        // scan for the source spelling passed a payload carrying 347 fmt symbols.
        // Everything here must therefore be fed through nm --demangle.
        let demangled = "\
0000000000000f84 t core::fmt::float::float_to_decimal_common_exact
00000000000008b8 T core::panicking::assert_failed";
        assert_eq!(fmt_symbols(demangled).len(), 1);

        let clean = "\
0000000000000000 T _start
0000000000000100 t flashos_grep::matcher::line_contains";
        assert!(fmt_symbols(clean).is_empty());
    }

    #[test]
    fn every_payload_names_a_distinct_elf_and_package() {
        // Two entries sharing an ELF name would have the second silently overwrite
        // the first's artefact in the shared output directory.
        for (i, a) in USER_ELFS.iter().enumerate() {
            for b in USER_ELFS.iter().skip(i + 1) {
                assert_ne!(a.elf, b.elf, "duplicate ELF name");
                assert_ne!(a.package, b.package, "duplicate cargo package");
                assert_ne!(a.archive, b.archive, "duplicate staticlib archive");
            }
        }
    }
}
