// Raw SVC wrappers for the FlashOS kernel ABI — the lowest layer of
// flibc. Each fn loads the syscall ID into x8 (per the EL0→EL1 contract
// established in src/entry.S:el0_svc), then `svc #0` to trap. Argument /
// return wiring follows AAPCS64: x0..x5 inputs, x0 return.
//
// Syscall IDs come from lib/syscall_defs.zig — the same constants the
// kernel-side dispatch table in src/sys.zig uses to populate
// sys_call_table. A renumbering there propagates here automatically.
//
// No `linksection` attributes: flibc consumers are ELF-loaded programs
// (the sys_execve path), not the in-blob user_init.o that PID 1 still
// uses. The kernel's loader places these wrappers wherever the ELF's
// PT_LOAD segments dictate, not in the .text.user blob region.

const defs = @import("syscall_defs");

pub fn fork() i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_FORK),
        : .{ .memory = true });
}

pub fn exit() noreturn {
    asm volatile ("svc #0"
        :
        : [nr] "{x8}" (defs.SYS_EXIT),
        : .{ .memory = true });
    unreachable;
}

// Reset the machine (SYS_REBOOT). The kernel performs a board-specific
// reset and never returns control to userland, so this wrapper is
// noreturn like exit().
pub fn reboot() noreturn {
    asm volatile ("svc #0"
        :
        : [nr] "{x8}" (defs.SYS_REBOOT),
        : .{ .memory = true });
    unreachable;
}

pub fn wait() i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_WAIT),
        : .{ .memory = true });
}

pub fn dump_free() u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [nr] "{x8}" (defs.SYS_DUMP_FREE),
        : .{ .memory = true });
}

/// exec_path(path, argv) — path-resolved ELF exec on slot 31. `path` is
/// a NUL-terminated UVA; `argv` points at a NULL-terminated array of
/// `[*:0]u8`. The kernel (src/execve.zig:execveKernel) streams PT_LOAD
/// segments from the resolved VFS file and lays an argv block on the
/// new user stack, then erets with `x0 = argc`, `x1 = argv`. Returns
/// only on failure (-1); on success the caller's image is replaced.
pub fn exec_path(path: [*:0]const u8, argv: [*]const ?[*:0]const u8) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_EXECVE),
          [path] "{x0}" (path),
          [argv] "{x1}" (argv),
        : .{ .memory = true });
}

pub fn kill(pid: i32) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_KILL),
          [pid] "{x0}" (pid),
        : .{ .memory = true });
}

/// brk(addr) — set the heap break to `addr` (rounded up to PAGE_SIZE by
/// the kernel). Returns the new break, or the current break if addr==0.
/// Negative on out-of-range (below HEAP_BASE, or above
/// STACK_TOP - STACK_BUDGET). i64 because the heap range covers UVAs
/// that don't fit in i32.
pub fn brk(addr: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_BRK),
          [addr] "{x0}" (addr),
        : .{ .memory = true });
}

/// sbrk(delta) — bump the break by `delta` bytes (kernel rounds the
/// resulting target up to PAGE_SIZE). Returns the *previous* break (the
/// start of the freshly-allocated region on grow) or -1 on
/// overflow / out-of-range. Negative `delta` shrinks; the kernel frees
/// released pages and flushes the TLB.
pub fn sbrk(delta: i64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_SBRK),
          [delta] "{x0}" (delta),
        : .{ .memory = true });
}

// ---- Unified fd-table ABI (slots 32..35) ----
//
// Slots 32..35 (read/write/close/dup2) dispatch on the fd's kind tag in
// the unified `fds` table (console / pipe / file); slot 18 is the pipe
// constructor; slot 36 is the working-directory store. The kernel-side
// handlers live in src/sys.zig (sys_read/write/close/dup2/sys_chdir)
// and src/fdtable.zig (the lookup + close/dup2 mechanics). These
// wrappers are the userland surface; the harness keeps using the raw
// `sys_*` wrappers in user_space/kernel_tests.zig so PID 1 stays
// blob-loaded for now.

/// read(fd, buf, len) — drain up to `len` bytes from `fd` into `buf`.
/// Returns the byte count, 0 on clean EOF (no peer for a pipe), or -1
/// on an invalid fd / wild UVA. Backend-aware: console blocks on the
/// RX ring, pipe blocks on the SPSC ring, file copies from the open
/// VFS file.
pub fn read(fd: i32, buf: [*]u8, len: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_READ),
          [fd] "{x0}" (fd),
          [buf] "{x1}" (buf),
          [len] "{x2}" (len),
        : .{ .memory = true });
}

/// write_fd(fd, buf, len) — emit `len` bytes from `buf` to `fd`. Returns
/// the byte count or -1. Carries an explicit length and routes through
/// the unified fd table by fd kind (console / pipe / file).
pub fn write_fd(fd: i32, buf: [*]const u8, len: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_WRITE),
          [fd] "{x0}" (fd),
          [buf] "{x1}" (buf),
          [len] "{x2}" (len),
        : .{ .memory = true });
}

/// close(fd) — release `fd` from the calling task's table. File fds run
/// the backend's vfs_close flush before the slot clears; pipe fds drop
/// the page-refcount (last close frees the pipe page); console is
/// refcount-exempt. Returns 0 on success, -1 on bad fd.
pub fn close(fd: i32) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_CLOSE),
          [fd] "{x0}" (fd),
        : .{ .memory = true });
}

/// dup2(old, new) — redirect `new` to point at `old`'s backend, closing
/// whatever `new` previously held. Returns `new` on success, -1 on bad
/// old fd / out-of-range new. The mechanic that powers `fsh`'s pipe
/// wiring (dup2 the pipe end onto fd 0/1 before `exec_path`).
pub fn dup2(oldfd: i32, newfd: i32) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_DUP2),
          [old] "{x0}" (oldfd),
          [new] "{x1}" (newfd),
        : .{ .memory = true });
}

/// pipe() — allocate a pipe page and install two fds (read end + write
/// end) into the calling task's table. Returns both fds packed into a
/// single i64: low 32 bits = read fd, high 32 bits = write fd. Negative
/// on failure (no free fd pair / out-of-pages). Single-register return
/// matches src/sys.zig:sys_pipe — avoids any copy_to_user dance.
pub fn pipe() i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_PIPE),
        : .{ .memory = true });
}

/// chdir(path) — replace the calling task's `cwd` with the joined +
/// `.`/`..`-collapsed version of `path`. Relative paths are joined
/// against the current `cwd`; absolute paths are collapsed in place.
/// No backend existence check this release;
/// the open/execve boundary trusts the stored value. Returns 0 on
/// success, -1 on wild user pointer / un-NUL-terminated input /
/// oversize composition past CWD_SIZE (256).
pub fn chdir(path: [*:0]const u8) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_CHDIR),
          [path] "{x0}" (path),
        : .{ .memory = true });
}

/// open(path) — resolve `path` through VFS and install a file fd in the
/// calling task's unified table (slot 7, SYS_OPEN_FILE). `path` is a
/// NUL-terminated UVA; relative paths are joined against the task's
/// `cwd` at the syscall boundary (the same resolver `execve` / `chdir`
/// use). Returns the new fd (>= 0), or -1 on resolve failure / no free
/// fd / out-of-file-objects.
///
/// This is the lone surviving member of the legacy file ABI (slots
/// 7..11): the read / write / close shims at 8/9/11 are DEPRECATED in
/// favour of the unified `read` (slot 32) / `write_fd` (33) / `close`
/// (34) handlers, which dispatch the file-kind fd this returns. There is
/// no unified "open" — slot 7 stays canonical. fsh uses it to slurp
/// `/etc/fshrc` at startup (open → read → close).
pub fn open(path: [*:0]const u8) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_OPEN_FILE),
          [path] "{x0}" (path),
        : .{ .memory = true });
}

/// readdir(path, index, out) — fill `out` with the `index`-th entry of
/// the directory at `path` (slot 37, SYS_READDIR). `path` is a NUL-
/// terminated UVA; relative paths join against the task's `cwd` at the
/// boundary, like `open` / `chdir`. Stateless — pass a fresh `index` each
/// call; there is no opendir handle. Returns 0 on a hit (`out` filled), -1
/// at end-of-directory / bad path / wild pointer. The kernel
/// copy_to_user's the whole Dirent on a hit, so `out` must point at a
/// writable 40-byte object. `ls` loops `index` 0.. until -1.
pub fn readdir(path: [*:0]const u8, index: u64, out: *defs.Dirent) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_READDIR),
          [path] "{x0}" (path),
          [index] "{x1}" (index),
          [out] "{x2}" (out),
        : .{ .memory = true });
}

/// klog_read(buf, len) — snapshot the most-recent min(len, retained) bytes
/// of the kernel log ring (slot 38, SYS_KLOG_READ) into `buf`, oldest
/// first. Returns the byte count (0 when the ring is empty), or -1 on a
/// wild buffer UVA. Consume-free — the ring is unchanged, so repeated
/// reads re-see the live log. `/bin/dmesg` sizes `buf` to KLOG_SIZE to
/// capture the whole retained log in one call.
pub fn klog_read(buf: [*]u8, len: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_KLOG_READ),
          [buf] "{x0}" (buf),
          [len] "{x1}" (len),
        : .{ .memory = true });
}

// ---- Process credentials (slots 39..44) ----
//
// Identity for the login/auth flow. Getters report the
// calling task's real / effective uid / gid; setuid / setgid mutate them
// under a root-gated policy (euid 0 sets any id; a dropped process may
// only reset to an id it already holds, else -1). `/bin/login` uses
// setgid + setuid to drop privilege after authenticating, then execs the
// user's shell. i64 returns mirror the kernel handlers' -1 sentinel.

pub fn getuid() i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_GETUID),
        : .{ .memory = true });
}

pub fn geteuid() i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_GETEUID),
        : .{ .memory = true });
}

pub fn getgid() i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_GETGID),
        : .{ .memory = true });
}

pub fn getegid() i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_GETEGID),
        : .{ .memory = true });
}

pub fn setuid(uid: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_SETUID),
          [uid] "{x0}" (uid),
        : .{ .memory = true });
}

pub fn setgid(gid: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_SETGID),
          [gid] "{x0}" (gid),
        : .{ .memory = true });
}

// authenticate(user, user_len, pass, pass_len) — kernel-side credential
// verify against the active shadow database (slot 45). Returns 0 on a
// match, -1 otherwise. The KDF lives in the kernel; the caller passes a
// plaintext password once and never sees a salt or hash. /bin/login is
// the sole consumer.
pub fn authenticate(user: [*]const u8, user_len: u64, pass: [*]const u8, pass_len: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_AUTHENTICATE),
          [u] "{x0}" (user),
          [ul] "{x1}" (user_len),
          [p] "{x2}" (pass),
          [pl] "{x3}" (pass_len),
        : .{ .memory = true });
}

// passwd(user, user_len, old, old_len, new, new_len) — kernel-side
// password change (slot 46). The kernel re-hashes with a fresh salt and
// rewrites `user`'s record in the writable FAT32 shadow. Root may reset
// any record without the old password; everyone else only their own
// record with the correct old password (-EACCES otherwise). Returns 0 on
// success, -1 when no writable shadow exists (QEMU virt / fresh card) or
// the input is malformed. /bin/passwd is the interactive consumer.
pub fn passwd(user: [*]const u8, user_len: u64, old: [*]const u8, old_len: u64, new: [*]const u8, new_len: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_PASSWD),
          [u] "{x0}" (user),
          [ul] "{x1}" (user_len),
          [o] "{x2}" (old),
          [ol] "{x3}" (old_len),
          [n] "{x4}" (new),
          [nl] "{x5}" (new_len),
        : .{ .memory = true });
}

// set_console_mode(mode) — toggle the kernel console echo flag (slot 25).
// CONSOLE_MODE_ECHO on => the kernel echoes typed printable bytes; off
// suppresses echo (used around /bin/login's password prompt). Returns 0.
pub fn set_console_mode(mode: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_SET_CONSOLE_MODE),
          [m] "{x0}" (mode),
        : .{ .memory = true });
}
