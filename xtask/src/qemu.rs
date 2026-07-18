//! Booting an image in QEMU and asserting on what comes out of the serial port.

use std::io::{BufRead, BufReader};
use std::process::Stdio;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use crate::build::{Board, Paths};
use crate::toolchain::Cmd;

/// The QEMU argv per board, preserving the retired build graph's machine setup.
/// raspi4b exposes two serial ports: the first is the PL011, the second the
/// mini-UART — which is the one FlashOS (and the canary) drives, hence
/// `-serial null -serial stdio`.
fn args(board: Board, img: &str) -> Vec<String> {
    let common = ["-kernel".to_string(), img.to_string()];
    let mut v: Vec<String> = match board {
        Board::Rpi4b => vec![
            "-M", "raspi4b", "-display", "none", "-serial", "null", "-serial", "stdio",
        ],
        Board::Virt => vec![
            "-M",
            "virt,gic-version=3",
            "-cpu",
            "cortex-a72",
            "-m",
            "1G",
            "-nographic",
        ],
    }
    .into_iter()
    .map(String::from)
    .collect();
    v.extend(common);
    v
}

/// Boot `p`'s image and wait for `marker` on the serial console. Returns the
/// captured output; errors if the marker does not appear within `timeout`.
pub fn expect_marker(
    p: &Paths,
    board: Board,
    marker: &str,
    timeout: Duration,
) -> Result<String, String> {
    let mut cmd = Cmd::new("qemu-system-aarch64", &p.trace)
        .args(args(board, &p.img().display().to_string()))
        .into_command()?;

    let mut child = cmd
        .stdout(Stdio::piped())
        .stdin(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|e| format!("qemu-system-aarch64 failed to start: {e}"))?;

    let stdout = child.stdout.take().ok_or("qemu produced no stdout pipe")?;
    let (tx, rx) = mpsc::channel::<String>();
    thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });

    let deadline = Instant::now() + timeout;
    let mut log = String::new();
    let mut found = false;
    while Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(250)) {
            Ok(line) => {
                log.push_str(&line);
                log.push('\n');
                if line.contains(marker) {
                    found = true;
                    break;
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    // QEMU never exits on its own here: the canary halts in a wfe loop.
    let _ = child.kill();
    let _ = child.wait();

    if !found {
        return Err(format!(
            "marker `{marker}` never appeared within {}s. Serial output was:\n{}",
            timeout.as_secs(),
            if log.is_empty() {
                "<nothing>".into()
            } else {
                log
            }
        ));
    }
    Ok(log)
}
