# Chapter 9: Login & Identity

Chapter 8 ended with a program that can read its own `argv` — the
mechanics of *running*. This chapter asks a different question: *as
whom*? Every FlashOS task carries a Unix-style identity, the console is
gated behind a password, and that identity follows a process across
`fork` and `execve` until something explicitly changes it. This chapter
walks that path from the credentials themselves to the login prompt that
mints them.

## Credentials on a task

Every `TaskStruct` carries four ids: `uid`, `gid`, `euid`, `egid`. They
are inherited across `fork` and preserved across `execve` — a process
never wakes up with a different identity than its parent handed it,
unless it calls one of the `SYS_SETUID`/`SYS_SETGID` family itself.
Effective uid 0 is root, and root bypasses every permission check the
kernel makes. The seeded accounts are `root` (uid 0) and `flash`
(uid 1000); the shell's prompt already reflects the split — `#` for
root, `$` for everyone else — a piece of state chapter 10 picks up.

## `/etc/passwd`: name to identity

The account list is a plain colon-delimited file, `user:uid:gid:home:shell`,
parsed by one shared reader used by every consumer that needs a name↔id
mapping — the kernel's `sys_passwd`, `/bin/login`, and fsh's `whoami`
built-in all import the same module rather than rolling their own parser:

```flash
pub const Entry = struct {
    user []u8,
    uid u32,
    gid u32,
    home []u8,
    shell []u8,
}

pub fn lookupByName(content []u8, name []u8) ?Entry {
    // …
}

pub fn lookupByUid(content []u8, uid u32) ?Entry {
    // …
}
```

*(excerpt from `src/pwfile.flash` — not standalone-compilable)*

`/etc/passwd` lives in the initramfs, so the account **list** is
build-time-immutable — new users are not created at runtime. Only
*passwords* are mutable state, held separately in the shadow database.

## Authentication: a KDF that never leaves the kernel

`SYS_AUTHENTICATE` (slot 45) is the one call `/bin/login` makes to check
a typed password. The kernel reads the shadow database itself, runs
PBKDF2-HMAC-SHA256 over the password with the record's stored salt and
iteration count, and constant-time-compares the result against the
stored verifier. Userland never sees a salt or a hash — only pass or
fail comes back across the syscall boundary, which is the whole point of
asking the kernel to do the check rather than handing login the
verifier to compare itself.

The authoritative shadow file is a writable FAT32 copy at `/mnt/shadow`;
the read-only initramfs `/etc/shadow` is the fallback whenever `/mnt` is
unmounted, absent, or corrupt. A bad write or a damaged SD card can
never lock the operator out — the baked-in seed credentials still
authenticate against the fallback.

## login: prompt, mask, verify, drop

`/bin/login` (`tools/login.flash`) is PID 1's hand-off target: instead
of calling `sys_exit` once the boot-time test harness finishes,
`init_main.flash` `execve`s `/bin/login` and falls through to
`sys_exit` only if that `execve` itself fails. From there login runs as
a session supervisor:

```flash
if flibc.sys.geteuid() != 0 {
    emit("login: must be root\n")
    flibc.exit()
}
// …
while true {
    _ = flibc.sys.set_console_mode(0)
    emit("login: ")
    ulen := switch flibc.readline(&user_buf) {
        .line => |l| l.len,
        .eof, .abandoned => 0,
    }
    // …
    emit("Password: ")
    plen := readMasked(&pass_buf)
    // …
    if flibc.sys.authenticate(&user_buf, ulen, &pass_buf, plen) != 0 {
        emit("Login incorrect\n")
        continue
    }
    // … look up uid/gid/shell in /etc/passwd, then runSession(...)
}
```

*(excerpt from `tools/login.flash` — not standalone-compilable)*

Two console-mode details are worth calling out. The username prompt
turns kernel echo *off* and echoes itself, byte by byte, through
flibc's line editor — that is what makes a typo correctable with
backspace instead of leaving an uncorrectable raw echo. The password
prompt reuses the same line-editor state machine but never echoes the
byte itself: it prints one `*` per accepted character and rubs it out
with `"\x08 \x08"` on backspace, so the secret never reaches the serial
console at all, correctable or not.

A blank username re-prompts silently — no password challenge, no error
— the same way a real getty absorbs a stray Enter.

## The privilege drop lives in the child

Once `sys_authenticate` passes, login forks. The **child** drops
privilege and execs the user's shell; the **parent** stays root, waits
for the child to exit, and loops back to `login:`:

```flash
fn runSession(uid u32, gid u32, shell_z cstr) bool {
    pid := flibc.fork()
    if pid == 0 {
        if flibc.sys.setgid(gid) != 0 || flibc.sys.setuid(uid) != 0 {
            emit("login: cannot drop privilege\n")
            flibc.exit()
        }
        sh_argv := [_:null]?cstr{ shell_z }
        _ = flibc.sys.exec_path(shell_z, &sh_argv)
        emit("login: exec failed\n")
        flibc.exit()
    }
    if pid < 0 {
        emit("login: fork failed\n")
        return false
    }
    _ = flibc.wait()
    return true
}
```

*(excerpt from `tools/login.flash` — not standalone-compilable)*

The order matters twice over. `setgid` runs before `setuid`, while the
child is still root — dropping uid first would make the group change
fail, since only root may call `setgid` for a group it does not already
hold. And the drop has to happen in the **child**, not login itself:
`setuid` is one-way for a non-root process, so a login that dropped its
own privilege could never authenticate a second session. The parent
staying root for the whole supervisor lifetime is what makes repeated
logins possible.

`exit` (or its alias `logout`) inside fsh is therefore not the end of
the boot — it is `wait()` in login returning, which sends the operator
straight back to `login:` for another round.

## Unattended CI: the same real path, no typist

The CI boot watchdog has no one to type a password, and it feeds the
console from `/dev/null` — a real `login:` prompt would hang it forever.
Rather than build a separate no-login test image, PID 1 console-injects
the test credentials (`flash`/`flash`) before the `execve`, but only
when the kernel is built with `-Dci-login-seed=true`. That flag defaults
to **false**: an ordinary build never auto-logs-in, and a watchdog that
forgets to set it fails loud — it times out sitting at `login:` — rather
than silently booting a password-free system. Either way, the
authentication call itself is the same `sys_authenticate` path a human
typist would exercise; injection only supplies the keystrokes.

## Changing a password

`/bin/passwd` re-hashes with a freshly kernel-minted salt and rewrites
the matching line in `/mnt/shadow`. Root may reset any record without
supplying the old password — the forgotten-password recovery path —
while every other caller may change only the record matching its own
uid, and only after proving the current password. The rewrite is
splice-safe by construction: the iteration count is kept and the salt
and hash are fixed-width hex, so the line never changes length and the
whole-file write can never resize the FAT32 directory entry underneath
it.

## What this model is not

The security model is deliberately lean, and says so plainly: no
`chmod`/`chown`, no directory permissions, no setuid bits, no
supplementary groups, no saved-uid. It is a single-core kernel with one
shared kernel address space — the boundary it actually defends is
*unprivileged EL0 process vs. privileged kernel and root*, not a
hardened multi-tenant isolation boundary. As a teaching model of the
classic Unix credential/authentication/permission triad, though, it is
complete end to end: this chapter's login flow, and chapter 11's file
permission checks, are the same mechanism applied to two different
resources.

## What's next

A session now exists with a concrete identity behind it — chapter 10
turns to what that identity actually *does* with the console: `fsh`,
its prompt, its line editor, and the builtins vs. `/bin` split that
every typed command resolves through.
