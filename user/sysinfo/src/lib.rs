//! `/bin/sysinfo` -- one-shot system summary.
//!
//! A print-and-exit coreutil that lays the available system facts out as aligned
//! key/value rows through the console_ui screen layer. It shows only what the kernel
//! can answer today: the FlashOS version, the logged-in user (getuid -> `/etc/passwd`
//! through the shared pwfile parser), the free-page count, and the hardware-monitoring
//! metrics -- memory use and uptime (board-independent), plus CPU temperature and
//! clock from the VideoCore mailbox. temp / freq read 0 = unknown on a board without
//! the mailbox (virt) and render `n/a`: sysinfo never fabricates a reading.
//!
//! Print-and-exit, so it needs neither the alt-screen buffer nor key decoding. Like
//! meminfo it is kept out of the CI shell script: the free-page value is
//! non-deterministic and would break the baseline checkpoint count.

#![cfg_attr(target_os = "none", no_std)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
use flashos_console_ui::{banner, screen};
#[cfg(target_os = "none")]
use flashos_flibc::{console_sink, sys, Buf};
#[cfg(target_os = "none")]
use flashsdk_rt::{entry, Argv};

/// The one version string in the Rust tree, inherited from the Cargo workspace.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(target_os = "none")]
const PASSWD_PATH: &[u8] = b"/etc/passwd\0";

#[cfg(target_os = "none")]
const PASSWD_MAX: usize = 512;

#[cfg(target_os = "none")]
fn main(_argc: usize, _argv: Argv) -> i32 {
    banner(console_sink, b"FlashOS system");

    screen::kv(console_sink, b"version", VERSION.as_bytes());

    // user: getuid -> /etc/passwd through pwfile. The slurp buffer is on this frame,
    // so the login-name slice it lends out stays valid for the whole row.
    let mut pw_buf = [0u8; PASSWD_MAX];
    let n = slurp_passwd(&mut pw_buf);
    screen::kv(console_sink, b"user", current_user(&pw_buf[..n]));

    screen::kv(console_sink, b"free", free_pages().as_slice());
    screen::kv(console_sink, b"mem", mem_usage().as_slice());
    screen::kv(console_sink, b"uptime", uptime_str().as_slice());
    screen::kv(console_sink, b"temp", temp_str().as_slice());
    screen::kv(console_sink, b"freq", freq_str().as_slice());
    0
}

/// Read `/etc/passwd` into `buf`, returning the byte count -- 0 when it cannot be
/// opened, which [`current_user`] renders as an unknown user rather than an error.
#[cfg(target_os = "none")]
fn slurp_passwd(buf: &mut [u8]) -> usize {
    let fd = unsafe { sys::open(PASSWD_PATH.as_ptr()) };
    if fd < 0 {
        return 0;
    }
    let mut n = 0usize;
    while n < buf.len() {
        let r = sys::read(fd, &mut buf[n..]);
        if r <= 0 {
            break;
        }
        n += r as usize;
    }
    sys::close(fd);
    n
}

/// The real uid's login name, or `?` when the uid cannot be read or has no entry. The
/// row wants a value, and a numeric fallback would need a formatter this summary does
/// not warrant.
#[cfg(target_os = "none")]
fn current_user(passwd: &[u8]) -> &[u8] {
    let uid = sys::getuid();
    if uid < 0 {
        return b"?";
    }
    match flashos_pwfile::lookup_by_uid(passwd, uid as u32) {
        Some(entry) => entry.user,
        None => b"?",
    }
}

/// `<count> pages` -- the live kernel free-page count.
#[cfg(target_os = "none")]
fn free_pages() -> Buf {
    let mut out = Buf::new();
    out.udec(sys::dump_free()).str(b" pages");
    out
}

/// `<used> KiB / <total> MiB`: the pages currently in use (total - free) against the
/// frozen allocatable pool. Used is rendered in KiB (`<< 2` -- 4 KiB pages), not MiB:
/// an idle system's live footprint is tens of pages, and a `>> 8` MiB conversion would
/// floor that to a meaningless 0. Total stays in MiB (the pool is GiB-scale). The two
/// reads are separate syscalls, so a concurrent allocation could skew `used` by a page
/// -- harmless for a one-shot summary.
#[cfg(target_os = "none")]
fn mem_usage() -> Buf {
    let total_pages = sys::mem_total();
    let free = sys::dump_free();
    let used_pages = total_pages.saturating_sub(free);
    let mut out = Buf::new();
    out.udec(used_pages << 2)
        .str(b" KiB / ")
        .udec(total_pages >> 8)
        .str(b" MiB");
    out
}

/// Seconds since boot, humanised: `<h>h <m>m <s>s`, collapsing to `<s>s` under a
/// minute. The reading is monotonic across calls.
#[cfg(target_os = "none")]
fn uptime_str() -> Buf {
    let secs = sys::uptime();
    let (h, m, s) = (secs / 3600, (secs % 3600) / 60, secs % 60);
    let mut out = Buf::new();
    if h > 0 {
        out.udec(h).str(b"h ");
    }
    if h > 0 || m > 0 {
        out.udec(m).str(b"m ");
    }
    out.udec(s).str(b"s");
    out
}

/// SoC temperature in whole degrees Celsius, or `n/a` when unknown (0 -- virt's stub,
/// or a mailbox timeout on real hardware). The syscall reports milli-degrees. ASCII
/// `C` keeps every byte single-width on any console.
#[cfg(target_os = "none")]
fn temp_str() -> Buf {
    let mut out = Buf::new();
    let milli = sys::cpu_temp();
    if milli == 0 {
        out.str(b"n/a");
    } else {
        out.udec(milli / 1000).str(b" C");
    }
    out
}

/// ARM core clock in MHz, or `n/a` when unknown (0). The syscall reports Hz.
#[cfg(target_os = "none")]
fn freq_str() -> Buf {
    let mut out = Buf::new();
    let hz = sys::cpu_freq();
    if hz == 0 {
        out.str(b"n/a");
    } else {
        out.udec(hz / 1_000_000).str(b" MHz");
    }
    out
}

#[cfg(target_os = "none")]
entry!(main);

#[cfg(test)]
mod tests {
    use super::VERSION;

    /// Cargo supplies the package version from `[workspace.package]`. Pin the
    /// inherited value against that source so a manifest edit cannot silently
    /// ship a stale sysinfo row.
    #[test]
    fn the_printed_version_matches_the_workspace_manifest() {
        let manifest =
            std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../Cargo.toml"))
                .expect("workspace Cargo.toml is readable from the sysinfo package");
        let workspace_package = manifest
            .split_once("[workspace.package]")
            .map(|(_, tail)| tail)
            .expect("Cargo.toml declares [workspace.package]")
            .lines()
            .take_while(|line| !line.starts_with('['));
        let declared = workspace_package
            .filter_map(|line| line.trim().strip_prefix("version = \""))
            .find_map(|value| value.strip_suffix('"'))
            .expect("[workspace.package] declares version");
        assert_eq!(VERSION, declared);
    }
}
