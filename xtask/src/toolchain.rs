//! Locating the host tools, and the one place a subprocess may be spawned.
//!
//! Every command the build runs goes through [`Cmd`], which appends the exact
//! argv to a trace file. The clean-room guard reads that trace to prove which
//! compilers actually ran, so a spawn that bypasses `Cmd` is
//! invisible to the guard and therefore forbidden.

use std::ffi::OsString;
use std::fmt::Write as _;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

/// Tools shipped by the pinned Rust toolchain itself (rust-toolchain.toml), so
/// they need no separate install and cannot drift from the compiler.
pub struct Toolchain {
    /// `rust-lld`, invoked in GNU flavour to consume the existing linker scripts.
    pub lld: PathBuf,
    pub objcopy: PathBuf,
    pub nm: PathBuf,
    pub objdump: PathBuf,
    /// The assembler for the retained `.S` files. External prerequisite: the
    /// bare-metal target needs a C preprocessor, which the Rust toolchain does
    /// not ship; a pinned LLVM/Clang fills that slot.
    pub clang: OsString,
}

impl Toolchain {
    pub fn discover() -> Result<Self, String> {
        let sysroot = Command::new("rustc")
            .arg("--print")
            .arg("sysroot")
            .output()
            .map_err(|e| format!("rustc not on PATH ({e}). Is rustup's bin dir exported?"))?;
        if !sysroot.status.success() {
            return Err("`rustc --print sysroot` failed".into());
        }
        let sysroot = PathBuf::from(String::from_utf8_lossy(&sysroot.stdout).trim().to_string());

        let vv = Command::new("rustc")
            .arg("-vV")
            .output()
            .map_err(|e| format!("rustc -vV failed: {e}"))?;
        let vv = String::from_utf8_lossy(&vv.stdout);
        let host = vv
            .lines()
            .find_map(|l| l.strip_prefix("host: "))
            .ok_or("`rustc -vV` printed no host triple")?
            .trim();

        let bin = sysroot.join("lib/rustlib").join(host).join("bin");
        let need = |name: &str| -> Result<PathBuf, String> {
            let p = bin.join(name);
            if p.exists() {
                Ok(p)
            } else {
                Err(format!(
                    "{name} missing from {}. Install it with: rustup component add llvm-tools",
                    bin.display()
                ))
            }
        };

        let clang = std::env::var_os("FLASHOS_CLANG").unwrap_or_else(|| OsString::from("clang"));

        Ok(Self {
            lld: need("rust-lld")?,
            objcopy: need("llvm-objcopy")?,
            nm: need("llvm-nm")?,
            objdump: need("llvm-objdump")?,
            clang,
        })
    }
}

/// A subprocess invocation, traced.
pub struct Cmd {
    inner: Command,
    trace: PathBuf,
}

impl Cmd {
    pub fn new(program: impl Into<OsString>, trace: &Path) -> Self {
        Self {
            inner: Command::new(program.into()),
            trace: trace.to_path_buf(),
        }
    }

    pub fn arg(mut self, a: impl Into<OsString>) -> Self {
        self.inner.arg(a.into());
        self
    }

    pub fn args<I, S>(mut self, a: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        for x in a {
            self.inner.arg(x.into());
        }
        self
    }

    pub fn cwd(mut self, dir: &Path) -> Self {
        self.inner.current_dir(dir);
        self
    }

    fn record(&self) -> io::Result<String> {
        let mut line = String::new();
        let _ = write!(line, "{}", self.inner.get_program().to_string_lossy());
        for a in self.inner.get_args() {
            let _ = write!(line, " {}", a.to_string_lossy());
        }
        if let Some(parent) = self.trace.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut existing = fs::read_to_string(&self.trace).unwrap_or_default();
        existing.push_str(&line);
        existing.push('\n');
        fs::write(&self.trace, existing)?;
        Ok(line)
    }

    /// Run, streaming output; fail closed on a non-zero exit.
    pub fn run(mut self) -> Result<(), String> {
        let line = self
            .record()
            .map_err(|e| format!("trace write failed: {e}"))?;
        let status = self
            .inner
            .status()
            .map_err(|e| format!("failed to spawn `{line}`: {e}"))?;
        if !status.success() {
            return Err(format!("command failed ({status}): {line}"));
        }
        Ok(())
    }

    /// Run and capture stdout; fail closed on a non-zero exit.
    pub fn capture(mut self) -> Result<String, String> {
        let line = self
            .record()
            .map_err(|e| format!("trace write failed: {e}"))?;
        let out: Output = self
            .inner
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .output()
            .map_err(|e| format!("failed to spawn `{line}`: {e}"))?;
        if !out.status.success() {
            return Err(format!("command failed ({}): {line}", out.status));
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }

    /// Hand back the raw `Command` for the one caller that needs to own the
    /// child process (the QEMU smoke test reads its serial output live).
    pub fn into_command(self) -> Result<Command, String> {
        self.record()
            .map_err(|e| format!("trace write failed: {e}"))?;
        Ok(self.inner)
    }
}
