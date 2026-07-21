//! The shell tokenizer -- a whitespace splitter with one optional `|` split.
//!
//! Pure: no syscalls, no allocator. The shell body feeds in a submitted line plus a
//! caller-owned argv array and scratch buffer, both fixed-size and reused per line,
//! and this fills the argv slots and reports how the line decomposed.
//!
//! ## Decomposition
//!
//! Tokens are maximal runs of bytes that are neither whitespace nor `|`. The first
//! `|`, if there is one, splits the line into a left and a right command -- the shell
//! supports exactly one pipe stage. Each token is copied NUL-terminated into `buf`
//! and its argv slot points at that copy. The pipe boundary and the line end are each
//! marked by a null argv slot, so `argv[..]` is already an execve-ready
//! NULL-terminated vector for the left command and `argv[left_argc + 1..]` is one for
//! the right command. No second pass, no copy: the vector the kernel reads is the one
//! the tokenizer wrote.
//!
//! ## Overflow
//!
//! Overflow truncates. Once the argv array or `buf` is full the rest of the line is
//! dropped, matching the line editor's truncate-on-overflow rather than erroring out.
//! A second `|`, or a `|` with an empty side, is a hard error, the way the shells this
//! one imitates reject `a | | b` and `| b`.

use core::ptr::NonNull;

/// The argv capacity, counting the interleaved null separators (the pipe boundary and
/// the trailing terminator). Sixteen slots cover a command plus a generous argument
/// list; longer lines truncate.
pub const MAX_ARGS: usize = 16;

/// Why the two sides of a `|` cannot both be commands, or why a second `|` appeared.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Err {
    TooManyPipes,
    EmptySide,
}

/// A single-pipe decomposition. The right command's argv begins at
/// `argv[left_argc + 1]`, the `+ 1` skipping the null the tokenizer wrote at the pipe
/// boundary; both vectors are NULL-terminated in place.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Piped {
    pub left_argc: usize,
    pub right_argc: usize,
}

/// How a line decomposed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Result {
    /// A blank or whitespace-only line -- the shell just redraws the prompt.
    Empty,
    /// One command: `argv[..argc]` is valid and `argv[argc]` is null.
    Single(usize),
    /// One pipe stage; see [`Piped`].
    Piped(Piped),
    /// Malformed pipe usage.
    Err(Err),
}

/// One argv slot. [`NonNull`] rather than a plain raw pointer because its null niche
/// is what makes `None` occupy exactly one null pointer word: the array is handed to
/// `execve` as-is, so the in-memory NULL terminator has to be a real one.
pub type Arg = Option<NonNull<u8>>;

fn is_space(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\r' || c == b'\n'
}

/// Split `line` into `argv`, whose slots point into `buf`. See the module header for
/// the decomposition rules. `argv` and `buf` are caller-owned and reused per line, so
/// the slots stay valid only until the next call that reuses them.
pub fn tokenize(line: &[u8], argv: &mut [Arg; MAX_ARGS], buf: &mut [u8]) -> Result {
    // Every token byte is written through this one pointer rather than through `buf`
    // again, so the slots handed back to the caller keep a provenance that later
    // writes cannot invalidate.
    let cap = buf.len();
    let base: *mut u8 = buf.as_mut_ptr();

    let mut argc: usize = 0;
    let mut buf_pos: usize = 0;
    let mut pipe_at: Option<usize> = None;
    let mut pipes: usize = 0;

    let mut i: usize = 0;
    while i < line.len() {
        while i < line.len() && is_space(line[i]) {
            i += 1;
        }
        if i >= line.len() {
            break;
        }

        // The final slot is reserved for the trailing null terminator.
        if argc >= MAX_ARGS - 1 {
            break;
        }

        if line[i] == b'|' {
            pipes += 1;
            if pipes > 1 {
                return Result::Err(Err::TooManyPipes);
            }
            pipe_at = Some(argc);
            argv[argc] = None;
            argc += 1;
            i += 1;
            continue;
        }

        let start = i;
        while i < line.len() && !is_space(line[i]) && line[i] != b'|' {
            i += 1;
        }
        let tok = &line[start..i];

        // Room for the bytes plus a NUL, or the line truncates here.
        if buf_pos + tok.len() + 1 > cap {
            break;
        }
        // SAFETY: the bound above leaves `tok.len() + 1` bytes free at `buf_pos`
        // inside the caller's buffer, and `line` cannot overlap it -- `buf` is an
        // exclusive borrow for the call.
        unsafe {
            core::ptr::copy_nonoverlapping(tok.as_ptr(), base.add(buf_pos), tok.len());
            base.add(buf_pos + tok.len()).write(0);
            argv[argc] = Some(NonNull::new_unchecked(base.add(buf_pos)));
        }
        argc += 1;
        buf_pos += tok.len() + 1;
    }

    if argc < MAX_ARGS {
        argv[argc] = None;
    }

    if let Some(p) = pipe_at {
        let left_argc = p;
        let right_argc = argc - p - 1;
        if left_argc == 0 || right_argc == 0 {
            return Result::Err(Err::EmptySide);
        }
        return Result::Piped(Piped {
            left_argc,
            right_argc,
        });
    }

    if argc == 0 {
        return Result::Empty;
    }
    Result::Single(argc)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Read back the NUL-terminated token a slot points at.
    fn arg_at(argv: &[Arg; MAX_ARGS], idx: usize) -> &[u8] {
        let p = argv[idx].expect("slot holds a token").as_ptr();
        // SAFETY: the tokenizer NUL-terminates every token it places, and the buffer
        // the slot points into outlives the assertion.
        unsafe {
            let mut len = 0;
            while *p.add(len) != 0 {
                len += 1;
            }
            core::slice::from_raw_parts(p, len)
        }
    }

    fn fresh() -> ([Arg; MAX_ARGS], [u8; 64]) {
        ([None; MAX_ARGS], [0u8; 64])
    }

    #[test]
    fn empty_line() {
        let (mut argv, mut buf) = fresh();
        assert_eq!(Result::Empty, tokenize(b"", &mut argv, &mut buf));
    }

    #[test]
    fn whitespace_only_line_is_empty() {
        let (mut argv, mut buf) = fresh();
        assert_eq!(Result::Empty, tokenize(b"  \t  ", &mut argv, &mut buf));
    }

    #[test]
    fn single_token() {
        let (mut argv, mut buf) = fresh();
        let r = tokenize(b"exit", &mut argv, &mut buf);
        assert_eq!(Result::Single(1), r);
        assert_eq!(b"exit", arg_at(&argv, 0));
        assert_eq!(None, argv[1]);
    }

    #[test]
    fn multi_arg_command_collapses_surrounding_whitespace() {
        let (mut argv, mut buf) = fresh();
        let r = tokenize(b"  cd   /test  ", &mut argv, &mut buf);
        assert_eq!(Result::Single(2), r);
        assert_eq!(b"cd", arg_at(&argv, 0));
        assert_eq!(b"/test", arg_at(&argv, 1));
        assert_eq!(None, argv[2]);
    }

    #[test]
    fn one_pipe_splits_left_and_right_null_terminated_vectors() {
        let (mut argv, mut buf) = fresh();
        let r = tokenize(b"echo hi | cat", &mut argv, &mut buf);
        let Result::Piped(p) = r else {
            panic!("expected a piped decomposition");
        };
        assert_eq!(2, p.left_argc);
        assert_eq!(1, p.right_argc);
        // The left vector is argv[..left_argc], terminated by the pipe's null.
        assert_eq!(b"echo", arg_at(&argv, 0));
        assert_eq!(b"hi", arg_at(&argv, 1));
        assert_eq!(None, argv[p.left_argc]);
        // The right vector starts past that boundary null.
        assert_eq!(b"cat", arg_at(&argv, p.left_argc + 1));
        assert_eq!(None, argv[p.left_argc + 1 + p.right_argc]);
    }

    #[test]
    fn a_pipe_with_no_surrounding_spaces_still_splits() {
        let (mut argv, mut buf) = fresh();
        let r = tokenize(b"echo|cat", &mut argv, &mut buf);
        let Result::Piped(p) = r else {
            panic!("expected a piped decomposition");
        };
        assert_eq!(1, p.left_argc);
        assert_eq!(1, p.right_argc);
        assert_eq!(b"echo", arg_at(&argv, 0));
        assert_eq!(b"cat", arg_at(&argv, 2));
    }

    #[test]
    fn a_pipe_at_the_start_is_an_empty_side() {
        let (mut argv, mut buf) = fresh();
        assert_eq!(
            Result::Err(Err::EmptySide),
            tokenize(b"| cat", &mut argv, &mut buf)
        );
    }

    #[test]
    fn a_pipe_at_the_end_is_an_empty_side() {
        let (mut argv, mut buf) = fresh();
        assert_eq!(
            Result::Err(Err::EmptySide),
            tokenize(b"echo hi |", &mut argv, &mut buf)
        );
    }

    #[test]
    fn two_pipes_are_rejected() {
        let (mut argv, mut buf) = fresh();
        assert_eq!(
            Result::Err(Err::TooManyPipes),
            tokenize(b"a | b | c", &mut argv, &mut buf)
        );
    }

    #[test]
    fn argv_overflow_truncates_the_line() {
        let mut argv: [Arg; MAX_ARGS] = [None; MAX_ARGS];
        let mut buf = [0u8; 256];
        // Twenty single-character tokens: MAX_ARGS - 1 = 15 fit, and the sixteenth
        // slot is the trailing null.
        let r = tokenize(
            b"a b c d e f g h i j k l m n o p q r s t",
            &mut argv,
            &mut buf,
        );
        assert_eq!(Result::Single(MAX_ARGS - 1), r);
        assert_eq!(None, argv[MAX_ARGS - 1]);
    }

    #[test]
    fn buf_overflow_truncates_without_corrupting_placed_tokens() {
        let mut argv: [Arg; MAX_ARGS] = [None; MAX_ARGS];
        // Eight bytes fit "abc\0" plus "de\0" -- seven bytes -- so "fgh" drops.
        let mut buf = [0u8; 8];
        let r = tokenize(b"abc de fgh", &mut argv, &mut buf);
        assert_eq!(Result::Single(2), r);
        assert_eq!(b"abc", arg_at(&argv, 0));
        assert_eq!(b"de", arg_at(&argv, 1));
    }
}
