#![forbid(unsafe_code)]

use std::env;
use std::ffi::OsStr;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;

fn main() {
    let report_path = env::var_os("FLASH_PROBE_REPORT").expect("report path is required");
    let value = env::var_os("FLASH_PROBE_VALUE").unwrap_or_default();
    let path = env::var_os("PATH").unwrap_or_default();
    let fd_open = env::var("FLASH_PROBE_FD")
        .ok()
        .map(|descriptor| PathBuf::from(format!("/dev/fd/{descriptor}")))
        .is_some_and(|path| path.exists());
    let cwd = env::current_dir().expect("cwd should be readable");
    let argv: Vec<_> = env::args_os().collect();

    let mut report = Vec::new();
    write_field(&mut report, cwd.as_os_str());
    write_field(&mut report, &value);
    write_field(&mut report, &path);
    report.push(u8::from(fd_open));
    report.extend_from_slice(&(argv.len() as u32).to_le_bytes());
    for argument in &argv {
        write_field(&mut report, argument);
    }

    fs::write(report_path, report).expect("report should be written");
}

fn write_field(output: &mut Vec<u8>, value: &OsStr) {
    let bytes = value.as_bytes();
    output.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    output.extend_from_slice(bytes);
}
