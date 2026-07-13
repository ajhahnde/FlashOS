//! Tab-completion core -- the discovery half of the shell-first navigation.
//!
//! The line editor calls in here when the user presses TAB. Everything in this
//! module is pure and host-tested:
//!
//!   * [`parse`] decides what is being completed -- the command (the first token) or
//!     a path argument (a later token) -- and splits a path token into a directory
//!     and a basename prefix.
//!   * [`has_prefix`] and [`common_prefix_len`] are the string folds the driver uses
//!     to filter candidates and to shrink them to a shared extension.
//!   * [`classify`] turns a candidate tally into the driver's branch point.
//!
//! Gathering the candidates themselves (a readdir walk over `/bin` or over the
//! path's directory, plus the shell's injected built-in names) is the syscall-driven
//! half and lives in the line editor, so this file stays pure, allocator-free, and
//! target-agnostic.

/// What a TAB is completing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// The first token -- match against `/bin` plus the shell's built-ins.
    Command,
    /// A later token -- match against the entries of `dir`.
    Path,
}

/// A parsed completion request. `dir` and `prefix` borrow from the caller's line
/// buffer (or are static literals). For a command, `dir` is empty because the driver
/// searches `/bin`. For a path, `dir` is the directory portion -- empty means the
/// cwd, `/` the root, `/bin` an absolute directory -- and `prefix` is the partial
/// basename to extend.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Context<'a> {
    pub kind: Kind,
    pub dir: &'a [u8],
    pub prefix: &'a [u8],
}

/// Parse the completion context from the current line. The token under completion is
/// the last whitespace-delimited run; if no earlier token precedes it, it is a
/// command, otherwise a path.
pub fn parse(line: &[u8]) -> Context<'_> {
    // Start of the last token: one past the last space or tab.
    let mut tok_start: usize = 0;
    let mut i: usize = 0;
    while i < line.len() {
        if line[i] == b' ' || line[i] == b'\t' {
            tok_start = i + 1;
        }
        i += 1;
    }
    // A non-space byte ahead of the token means an earlier token exists.
    let mut earlier = false;
    let mut j: usize = 0;
    while j < tok_start {
        if line[j] != b' ' && line[j] != b'\t' {
            earlier = true;
            break;
        }
        j += 1;
    }
    let token = &line[tok_start..];

    if !earlier {
        return Context {
            kind: Kind::Command,
            dir: b"",
            prefix: token,
        };
    }

    // Path token: split at the last '/'.
    let mut slash: Option<usize> = None;
    let mut k: usize = 0;
    while k < token.len() {
        if token[k] == b'/' {
            slash = Some(k);
        }
        k += 1;
    }
    if let Some(s) = slash {
        let dir: &[u8] = if s == 0 { b"/" } else { &token[..s] };
        return Context {
            kind: Kind::Path,
            dir,
            prefix: &token[s + 1..],
        };
    }
    Context {
        kind: Kind::Path,
        dir: b"",
        prefix: token,
    }
}

/// True when `name` starts with `prefix`.
pub fn has_prefix(name: &[u8], prefix: &[u8]) -> bool {
    if name.len() < prefix.len() {
        return false;
    }
    let mut i: usize = 0;
    while i < prefix.len() {
        if name[i] != prefix[i] {
            return false;
        }
        i += 1;
    }
    true
}

/// Length of the longest common prefix of `a` and `b`.
pub fn common_prefix_len(a: &[u8], b: &[u8]) -> usize {
    let m = if a.len() < b.len() { a.len() } else { b.len() };
    let mut i: usize = 0;
    while i < m && a[i] == b[i] {
        i += 1;
    }
    i
}

/// What a TAB press did to the line -- the driver's branch point for double-TAB
/// listing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TabClass {
    /// The line grew: either a unique match (which also gets a trailing separator) or
    /// the common prefix extended past what was typed. Resets the double-TAB streak.
    Progressed,
    /// Two or more candidates already sit at their common prefix -- nothing is left to
    /// insert. A second consecutive `Stuck` TAB lists them.
    Stuck,
    /// Nothing matched; the TAB is inert.
    Empty,
}

/// Classify a completion attempt from its candidate tally: `count` candidates share
/// the longest common prefix `best_len`, and the user has already typed `prefix_len`
/// bytes of the token.
///
/// A unique match always progresses -- the driver appends a `' '` or a `'/'` even when
/// the typed token already equals the name. Multiple candidates progress only while
/// their common prefix runs past the typed prefix; otherwise they are stuck, and a
/// redraw-listing is the only forward move.
pub fn classify(count: usize, best_len: usize, prefix_len: usize) -> TabClass {
    if count == 0 {
        return TabClass::Empty;
    }
    if count == 1 {
        return TabClass::Progressed;
    }
    if best_len > prefix_len {
        TabClass::Progressed
    } else {
        TabClass::Stuck
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_first_token_is_a_command() {
        let c = parse(b"ls");
        assert_eq!(c.kind, Kind::Command);
        assert_eq!(c.prefix, b"ls");
        assert_eq!(c.dir, b"");
    }

    #[test]
    fn an_empty_line_is_an_empty_command() {
        let c = parse(b"");
        assert_eq!(c.kind, Kind::Command);
        assert_eq!(c.prefix, b"");
    }

    #[test]
    fn a_token_after_a_space_is_a_path_in_the_cwd() {
        let c = parse(b"cat fo");
        assert_eq!(c.kind, Kind::Path);
        assert_eq!(c.dir, b"");
        assert_eq!(c.prefix, b"fo");
    }

    #[test]
    fn an_absolute_path_token_splits_dir_and_prefix() {
        let c = parse(b"cat /bin/l");
        assert_eq!(c.kind, Kind::Path);
        assert_eq!(c.dir, b"/bin");
        assert_eq!(c.prefix, b"l");
    }

    #[test]
    fn a_root_level_path_token_keeps_dir_as_slash() {
        let c = parse(b"ls /b");
        assert_eq!(c.kind, Kind::Path);
        assert_eq!(c.dir, b"/");
        assert_eq!(c.prefix, b"b");
    }

    #[test]
    fn a_trailing_slash_yields_an_empty_prefix() {
        let c = parse(b"ls /bin/");
        assert_eq!(c.kind, Kind::Path);
        assert_eq!(c.dir, b"/bin");
        assert_eq!(c.prefix, b"");
    }

    #[test]
    fn has_prefix_accepts_only_a_leading_run() {
        assert!(has_prefix(b"login", b"lo"));
        assert!(has_prefix(b"ls", b"ls"));
        assert!(!has_prefix(b"a", b"ab"));
        assert!(has_prefix(b"anything", b""));
    }

    #[test]
    fn common_prefix_len_counts_the_shared_head() {
        assert_eq!(common_prefix_len(b"login", b"logout"), 3); // "log"
        assert_eq!(common_prefix_len(b"a", b"b"), 0);
        assert_eq!(common_prefix_len(b"cat", b"cat"), 3);
    }

    #[test]
    fn no_candidates_is_empty() {
        assert_eq!(classify(0, 0, 3), TabClass::Empty);
    }

    #[test]
    fn a_unique_match_always_progresses() {
        // Extending ("l" -> "ls") and exact ("ls" with only "ls" matching) both
        // progress -- the exact case still earns its trailing separator.
        assert_eq!(classify(1, 2, 1), TabClass::Progressed);
        assert_eq!(classify(1, 2, 2), TabClass::Progressed);
    }

    #[test]
    fn ambiguous_but_still_extendable_progresses() {
        // Typed "l", three candidates share "lo": the common prefix runs ahead.
        assert_eq!(classify(3, 2, 1), TabClass::Progressed);
    }

    #[test]
    fn ambiguous_at_the_common_prefix_is_stuck() {
        // Typed "lo", three candidates share exactly "lo": nothing left to insert.
        assert_eq!(classify(3, 2, 2), TabClass::Stuck);
    }
}
