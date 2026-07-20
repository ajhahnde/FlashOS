#![forbid(unsafe_code)]

use std::process::Command;

fn fsh(args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_fsh"))
        .args(args)
        .output()
        .expect("fsh should start")
}

#[test]
fn version_reports_binary_name_and_package_version() {
    let output = fsh(&["--version"]);

    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap(), "fsh 0.1.0\n");
    assert!(output.stderr.is_empty());
}

#[test]
fn help_identifies_the_placeholder_cli() {
    let output = fsh(&["--help"]);

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.starts_with("FlashShell command shell\n"));
    assert!(stdout.contains("Usage: fsh [OPTIONS] [SCRIPT]\n"));
    assert!(stdout.contains("--version"));
    assert!(output.stderr.is_empty());
}
