//! Allocation-free absolute path resolution.

const MAX_DEPTH: usize = 64;
const WORK_MAX: usize = 512;

/// Normalize `rel` against `cwd` into `out`.
///
/// Duplicate slashes and `.` components are removed, `..` pops one component
/// without crossing root, and an absolute `rel` bypasses `cwd`.
pub fn join_resolve<'a>(cwd: &[u8], rel: &[u8], out: &'a mut [u8]) -> Option<&'a mut [u8]> {
    let mut work = [0u8; WORK_MAX];
    let work_len;

    if rel.first() == Some(&b'/') {
        if rel.len() > WORK_MAX {
            return None;
        }
        work[..rel.len()].copy_from_slice(rel);
        work_len = rel.len();
    } else {
        let mut len = if cwd.is_empty() {
            work[0] = b'/';
            1
        } else {
            if cwd.len() > WORK_MAX {
                return None;
            }
            work[..cwd.len()].copy_from_slice(cwd);
            cwd.len()
        };
        if len == 0 || work[len - 1] != b'/' {
            if len == WORK_MAX {
                return None;
            }
            work[len] = b'/';
            len += 1;
        }
        let end = len.checked_add(rel.len())?;
        if end > WORK_MAX {
            return None;
        }
        work[len..end].copy_from_slice(rel);
        work_len = end;
    }

    let mut stack = [0usize; MAX_DEPTH];
    let mut depth = 0;
    let mut out_len = 0;
    let mut i = 0;

    while i < work_len {
        while i < work_len && work[i] == b'/' {
            i += 1;
        }
        if i >= work_len {
            break;
        }
        let mut j = i;
        while j < work_len && work[j] != b'/' {
            j += 1;
        }
        let component = &work[i..j];
        i = j;

        if component == b"." {
            continue;
        }
        if component == b".." {
            if depth > 0 {
                depth -= 1;
                out_len = stack[depth];
            }
            continue;
        }
        if depth >= MAX_DEPTH {
            return None;
        }
        let end = out_len.checked_add(1)?.checked_add(component.len())?;
        if end > out.len() {
            return None;
        }
        stack[depth] = out_len;
        depth += 1;
        out[out_len] = b'/';
        out[out_len + 1..end].copy_from_slice(component);
        out_len = end;
    }

    if out_len == 0 {
        if out.is_empty() {
            return None;
        }
        out[0] = b'/';
        out_len = 1;
    }
    Some(&mut out[..out_len])
}

#[cfg(test)]
mod tests {
    use super::{join_resolve, WORK_MAX};

    fn resolves(cwd: &[u8], rel: &[u8]) -> [u8; 128] {
        let mut out = [0u8; 128];
        let len = join_resolve(cwd, rel, &mut out).unwrap().len();
        out[len] = 0;
        out
    }

    fn value(buf: &[u8]) -> &[u8] {
        &buf[..buf.iter().position(|b| *b == 0).unwrap()]
    }

    #[test]
    fn relative_against_root() {
        assert_eq!(value(&resolves(b"/", b"bin/fsh")), b"/bin/fsh");
    }
    #[test]
    fn relative_against_non_root_cwd() {
        assert_eq!(value(&resolves(b"/etc", b"fshrc")), b"/etc/fshrc");
    }
    #[test]
    fn absolute_rel_bypasses_cwd() {
        assert_eq!(value(&resolves(b"/etc", b"/bin/fsh")), b"/bin/fsh");
    }
    #[test]
    fn dot_segments_are_dropped() {
        assert_eq!(
            value(&resolves(b"/usr", b"./local/./bin")),
            b"/usr/local/bin"
        );
    }
    #[test]
    fn parent_collapses_one_component() {
        assert_eq!(
            value(&resolves(b"/usr/local/bin", b"../lib")),
            b"/usr/local/lib"
        );
    }
    #[test]
    fn mid_path_parent_collapses_correctly() {
        assert_eq!(value(&resolves(b"/", b"a/./b/../c")), b"/a/c");
    }
    #[test]
    fn parent_past_root_stays_at_root() {
        assert_eq!(value(&resolves(b"/", b"../../foo")), b"/foo");
    }
    #[test]
    fn bare_parent_from_root_is_root() {
        assert_eq!(value(&resolves(b"/", b"..")), b"/");
    }
    #[test]
    fn double_slashes_fold() {
        assert_eq!(value(&resolves(b"/foo", b"//bar//baz")), b"/bar/baz");
    }
    #[test]
    fn empty_rel_resolves_to_cwd() {
        assert_eq!(value(&resolves(b"/etc", b"")), b"/etc");
    }
    #[test]
    fn trailing_slash_is_dropped() {
        assert_eq!(value(&resolves(b"/", b"etc/")), b"/etc");
    }
    #[test]
    fn dot_only_rel_resolves_to_cwd() {
        assert_eq!(value(&resolves(b"/var/log", b".")), b"/var/log");
    }
    #[test]
    fn popping_everything_collapses_to_root() {
        assert_eq!(value(&resolves(b"/a/b", b"../..")), b"/");
    }
    #[test]
    fn out_buffer_overflow_returns_none() {
        let mut tiny = [0u8; 4];
        assert!(join_resolve(b"/", b"abcdefg", &mut tiny).is_none());
    }
    #[test]
    fn oversize_composition_returns_none() {
        let mut out = [0u8; 4096];
        let long_rel = [b'x'; WORK_MAX + 1];
        assert!(join_resolve(b"/", &long_rel, &mut out).is_none());
    }
    #[test]
    fn empty_cwd_resolves_under_root() {
        assert_eq!(value(&resolves(b"", b"foo")), b"/foo");
    }
}
