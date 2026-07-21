#![forbid(unsafe_code)]

use std::env;
use std::ffi::OsStr;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::ExitCode;

use flashshell_platform_posix::PosixPlatform;
use flashshell_runtime::builtin::standard_registry;
use flashshell_runtime::eval::SystemClock;
use flashshell_runtime::plan::SessionOptions;
use flashshell_runtime::resolve::ExecutableProbe;
use flashshell_runtime::script::execute_script;
use flashshell_runtime::{Environment, Status};

const HELP: &str = "FlashShell command shell

Usage: fsh [OPTIONS] [SCRIPT]

Options:
  -h, --help       Print help
  -V, --version    Print version
";

fn main() -> ExitCode {
    let mut arguments = env::args_os().skip(1);
    match arguments.next().as_deref() {
        Some(arg) if arg == "--version" || arg == "-V" => {
            println!("fsh {}", flashshell_runtime::version());
            ExitCode::SUCCESS
        }
        Some(arg) if arg == "--help" || arg == "-h" => {
            print!("{HELP}");
            ExitCode::SUCCESS
        }
        None => {
            print!("{HELP}");
            ExitCode::SUCCESS
        }
        Some(script) => {
            if arguments.next().is_some() {
                eprintln!("fsh: expected one script path");
                return ExitCode::from(2);
            }
            run_script(Path::new(script))
        }
    }
}

fn run_script(path: &Path) -> ExitCode {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) => {
            eprintln!("fsh: {}: {error}", path.display());
            return ExitCode::FAILURE;
        }
    };
    let text = match String::from_utf8(bytes) {
        Ok(text) => text,
        Err(error) => {
            eprintln!(
                "fsh: {}: source is not UTF-8 at byte {}",
                path.display(),
                error.utf8_error().valid_up_to()
            );
            return ExitCode::FAILURE;
        }
    };
    let cwd = match env::current_dir() {
        Ok(cwd) => cwd,
        Err(error) => {
            eprintln!("fsh: cannot read the current directory: {error}");
            return ExitCode::FAILURE;
        }
    };
    let mut environment = Environment::from_snapshot(
        env::vars_os()
            .filter_map(|(name, value)| name.into_string().ok().map(|name| (name, value))),
    );
    let registry = standard_registry();
    let result = execute_script(
        path.to_string_lossy(),
        text,
        &cwd,
        &mut environment,
        &registry,
        &NativeExecutableProbe,
        &SessionOptions::default(),
        &PosixPlatform,
        &SystemClock::new(),
    );

    match result {
        Ok(completion) => completion.status().map_or(ExitCode::SUCCESS, status_exit),
        Err(error) => {
            eprint!("{}", error.render());
            ExitCode::FAILURE
        }
    }
}

fn status_exit(status: &Status) -> ExitCode {
    let code = match (status.code(), status.signal()) {
        (Some(code), None) => u8::try_from(code).unwrap_or(1),
        (None, Some(signal)) => signal
            .number()
            .and_then(|number| u8::try_from(128_i64.saturating_add(number)).ok())
            .unwrap_or(1),
        _ => 1,
    };
    ExitCode::from(code)
}

struct NativeExecutableProbe;

impl ExecutableProbe for NativeExecutableProbe {
    fn is_executable(&self, path: &OsStr) -> bool {
        fs::metadata(Path::new(path))
            .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
    }
}
