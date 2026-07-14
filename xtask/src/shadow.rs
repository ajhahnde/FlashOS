//! Build-time `/etc/shadow` generator.
//!
//! Emits a deterministic `/etc/shadow` by running the SAME PBKDF2-HMAC-SHA256 the
//! kernel verifies with (`crates/kernel`) over fixed, in-repo test credentials.
//! Reusing the kernel's KDF guarantees the baked verifier matches what
//! `sys_authenticate` recomputes at login — eliminating the stable-but-wrong-hash
//! failure the sha256 module's header warns about.
//!
//! The salts are fixed, public 16-byte literals and the iteration count is modest
//! (4096, well below modern OWASP guidance for PBKDF2-HMAC-SHA256): this is a
//! hobby-OS demonstration of the auth flow, not a production secret store
//! (documented as such). Output is a pure function of the constants below, so two
//! clean builds are byte-identical — required for the Pi kernel-image hash
//! baseline.
//!
//! Keep `ACCOUNTS` in lockstep with `user_space/etc/passwd`, the PID-1
//! boot-injection credentials, and the `[TEST] authenticate` scenario.

use std::fmt::Write as _;
use std::fs;
use std::path::Path;

use flashos_kernel::sha256;

struct Account {
    user: &'static str,
    password: &'static [u8],
    /// 16 fixed, public bytes
    salt: &'static [u8],
    iterations: u32,
}

const ACCOUNTS: [Account; 2] = [
    Account {
        user: "root",
        password: b"root",
        salt: b"FlashOS-rootSalt",
        iterations: 4096,
    },
    Account {
        user: "flash",
        password: b"flash",
        salt: b"FlashOS-userSalt",
        iterations: 4096,
    },
];

/// Write the shadow file to `out_path`.
pub fn run(out_path: &Path) -> Result<(), String> {
    let mut text = String::new();
    for acc in ACCOUNTS.iter() {
        let mut dk = [0u8; 32];
        sha256::pbkdf2_hmac_sha256(acc.password, acc.salt, acc.iterations, &mut dk);
        text.push_str(acc.user);
        text.push(':');
        let _ = write!(text, "{}", acc.iterations);
        text.push(':');
        push_hex(&mut text, acc.salt);
        text.push(':');
        push_hex(&mut text, &dk);
        text.push('\n');
    }
    fs::write(out_path, text).map_err(|e| format!("write {}: {e}", out_path.display()))
}

/// Lowercase hex, the encoding `src/shadow.flash` parses back.
fn push_hex(out: &mut String, bytes: &[u8]) {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    for b in bytes {
        out.push(DIGITS[(b >> 4) as usize] as char);
        out.push(DIGITS[(b & 0x0F) as usize] as char);
    }
}
