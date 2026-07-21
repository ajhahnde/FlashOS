# 9. Login, Credentials, and Password Storage

After optional selftests, PID 1 execs `/bin/login`. The login program is an
EL0 Rust executable under `userland/auth/login/`; authentication primitives and access
checks are enforced by the kernel.

## Account formats

`/etc/passwd` contains public account records:

```text
name:uid:gid:home:shell
```

`/etc/shadow` contains password verifier records:

```text
name:iterations:salt_hex:hash_hex
```

`crates/pwfile/` shares passwd parsing where kernel and userland need the same
format. Kernel shadow parsing and PBKDF2-HMAC-SHA256 live under
`crates/kernel/`.

## Authentication stays in EL1

Userland passes credentials to the authentication syscall. The kernel locates
the account, derives the candidate hash, and compares it in constant time.
EL0 receives only success or failure; it does not receive the stored verifier.

The initramfs shadow file is an immutable recovery seed. If the FAT32 volume is
mounted, `/mnt/shadow` is the writable database. Password changes mint a new
kernel-generated salt and rewrite an equal-length record in place.

The checked-in seed uses fixed public salts and a modest work factor on
purpose: the complete production image remains reproducible and the QEMU TCG
boot test remains practical. The current entropy provider announces that it is
a timer-mixed fallback; an RNG200 driver is not implemented yet.

## Session creation

Once authentication succeeds, login:

1. forks a session child;
2. changes the child's effective UID and GID;
3. changes to the account home directory;
4. execs the configured shell;
5. remains the supervisor that can start a new login after session exit.

The default shell is currently `/bin/fsh`. Future FlashUI work will change the
post-login default only after FlashSDK and FlashShell integration; `/bin/fsh`
will remain a tested recovery path.

## Permission model

`crates/kernel/src/perm.rs` applies classic owner/group/other bits to open,
write, and exec. Effective UID 0 bypasses the check. There are no ACLs,
supplementary groups, setuid bits, `chmod`, or `chown` yet.

FAT32 has no Unix ownership metadata. `PERMS.TAB` overlays mode, UID, and GID by
basename. Missing entries default to `0666` root:root, while `SHADOW` is always
floored at `0600` root:root.

> [!IMPORTANT]
> Credentials are kernel-owned state inside `TaskStruct`. A future public SDK
> may expose syscall values, but never the private task layout itself.

Next, we explore the shell that login starts today.
