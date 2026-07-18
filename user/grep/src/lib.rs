//! `/bin/grep` -- print the lines of the input that contain a literal pattern.
//!
//!   grep [-i] PATTERN [FILE...]
//!
//! With no FILE it reads fd 0 (the `cat foo | grep bar` pipe case); with one or more
//! FILEs it opens each and searches it in turn. Matching lines go to fd 1, each
//! followed by a newline. `-i` folds ASCII case on both sides. The pattern is a
//! literal substring -- no regex. An empty pattern matches every line, the GNU
//! convention.
//!
//! The matching itself is `flibc::grep_match::line_contains`, which is pure and
//! host-tested -- and shared: the editor's ctrl-W search drives the same core. This
//! file is only the driver: flag and argv parsing, open/read, and streaming line
//! assembly. Streaming rather than slurping the whole file is what lets one code path
//! serve an unseekable pipe and a regular file alike.
//!
//! Deliberate scope limits, documented rather than hidden:
//!
//! * No filename prefix on matches, even with several FILEs -- bare matching lines
//!   only (GNU grep prefixes `file:` once there is more than one file). The shell's
//!   use is single-file or pipe, which this matches exactly.
//! * A line longer than [`LINE_MAX`] is matched and printed truncated to its first
//!   [`LINE_MAX`] bytes; the overrun is scanned for the newline but dropped.
//!   Serial-console lines sit far below the cap.
//! * Exit status does not distinguish match from no-match from error; the shell has
//!   no `$?` yet. Errors still go to fd 2 so they stay visible.

// Gated on the target, not on `test`: the payload is a staticlib, so a host build of
// this same lib has to reach std for its panic handler, while the EL0 build stays
// no_std. (`not(test)` would leave the host lib no_std and unlinkable.)
#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashsdk_abi::syscall::EACCES;
#[cfg(target_os = "none")]
use flashos_flibc::{console_sink, err_sink, grep_match, sys};
#[cfg(target_os = "none")]
use flashsdk_rt::{arg, arg_ptr, entry, Argv};

/// Read granularity from the source descriptor: one syscall per chunk.
#[cfg(target_os = "none")]
const CHUNK: usize = 512;
/// Longest line buffered for matching and printing.
#[cfg(target_os = "none")]
const LINE_MAX: usize = 1024;
/// Pattern copy bound. The pattern arrives as an argv C string and is copied into a
/// sized slice, so the matcher takes plain bytes and the length stays bounded.
#[cfg(target_os = "none")]
const PAT_MAX: usize = 256;

/// Emit `line` to fd 1, plus the newline stripped during scanning, when it matches.
#[cfg(target_os = "none")]
fn emit_match(line: &[u8], pat: &[u8], ignore_case: bool) {
    if grep_match::line_contains(line, pat, ignore_case) {
        console_sink(line);
        console_sink(b"\n");
    }
}

/// Read `fd` to end-of-input, splitting on newline and testing each line. The newline
/// is not stored; a final line without one is still tested at the end.
#[cfg(target_os = "none")]
fn grep_stream(fd: i32, pat: &[u8], ignore_case: bool) {
    let mut chunk = [0u8; CHUNK];
    let mut line = [0u8; LINE_MAX];
    let mut line_len = 0usize;
    loop {
        let n = sys::read(fd, &mut chunk);
        if n <= 0 {
            break;
        }
        for &c in &chunk[..n as usize] {
            if c == b'\n' {
                emit_match(&line[..line_len], pat, ignore_case);
                line_len = 0;
            } else if line_len < LINE_MAX {
                line[line_len] = c;
                line_len += 1;
            }
            // else: past LINE_MAX -- drop the byte, keep scanning for the newline.
        }
    }
    if line_len > 0 {
        emit_match(&line[..line_len], pat, ignore_case);
    }
}

#[cfg(target_os = "none")]
fn main(argc: usize, argv: Argv) -> i32 {
    let mut ai = 1;
    let mut ignore_case = false;

    // Leading flags: only -i, bundled characters allowed (it is the lone option, so
    // this is forward room). Parsing stops at the first non-flag argument, at a bare
    // "-", or at the end of argv.
    while ai < argc {
        let Some(a) = (unsafe { arg(argv, ai) }) else {
            break;
        };
        if !a.starts_with(b"-") || a.len() == 1 {
            break;
        }
        for &f in &a[1..] {
            if f != b'i' {
                err_sink(b"grep: unknown option\n");
                return 0;
            }
            ignore_case = true;
        }
        ai += 1;
    }

    if ai >= argc {
        err_sink(b"usage: grep [-i] PATTERN [FILE...]\n");
        return 0;
    }
    let Some(pat_arg) = (unsafe { arg(argv, ai) }) else {
        return 0;
    };
    ai += 1;

    // Copied byte by byte on purpose: `copy_from_slice` panics on a length mismatch
    // with a *formatted* message, which drags the whole formatting engine into the
    // payload (the artefact gate rejects it, and it would cost ~170 KiB of text).
    let mut pat_buf = [0u8; PAT_MAX];
    let mut pat_len = 0;
    while pat_len < pat_arg.len() && pat_len < PAT_MAX {
        pat_buf[pat_len] = pat_arg[pat_len];
        pat_len += 1;
    }
    let pat = &pat_buf[..pat_len];

    if ai >= argc {
        // No FILE -- search fd 0 (the pipe case).
        grep_stream(sys::STDIN, pat, ignore_case);
        return 0;
    }
    while ai < argc {
        let Some(path) = (unsafe { arg_ptr(argv, ai) }) else {
            break;
        };
        ai += 1;
        let fd = unsafe { sys::open(path) };
        if fd < 0 {
            err_sink(if fd == -EACCES {
                b"grep: Permission denied\n".as_slice()
            } else {
                b"grep: cannot open\n".as_slice()
            });
            continue;
        }
        grep_stream(fd, pat, ignore_case);
        sys::close(fd);
    }
    0
}

#[cfg(target_os = "none")]
entry!(main);
