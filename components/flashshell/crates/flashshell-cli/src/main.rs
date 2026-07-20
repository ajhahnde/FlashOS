#![forbid(unsafe_code)]

use std::env;
use std::process::ExitCode;

const HELP: &str = "FlashShell command shell

Usage: fsh [OPTIONS] [SCRIPT]

Options:
  -h, --help       Print help
  -V, --version    Print version
";

fn main() -> ExitCode {
    match env::args_os().nth(1).as_deref() {
        Some(arg) if arg == "--version" || arg == "-V" => {
            println!("fsh {}", flashshell_runtime::version());
            ExitCode::SUCCESS
        }
        Some(arg) if arg == "--help" || arg == "-h" => {
            print!("{HELP}");
            ExitCode::SUCCESS
        }
        _ => {
            print!("{HELP}");
            ExitCode::SUCCESS
        }
    }
}
