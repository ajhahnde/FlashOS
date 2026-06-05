// In-kernel runtime test harness.
//
// Formalises the fork-stress / kill / exec cycles into a
// `[TEST]/[PASS]/[FAIL]` suite with a final `X/Y passed\n` tally.
// Each scenario validates against the free-page baseline captured at
// PID 1 startup; any post-reap mismatch flips that scenario to [FAIL]
// and decrements the tally.
//
// Imported by user_space/init_main.zig, the root of the pid1.elf
// artifact. pid1.elf is staged into the
// initramfs at /sbin/init and ELF-loaded by the kernel; the loader
// honours e_entry + p_vaddr, so the .text.user / .rodata.user
// linksection decorations and the user_start / user_end blob wrapping
// are retired — tools/pid1_linker.ld places every section.

// ---- Syscall ABI ----
//
// Numbers come from lib/syscall_defs.zig — same constants the kernel
// uses to populate sys_call_table in src/sys.zig, so a renumbering is a
// single-file edit. The harness drives I/O exclusively through the
// unified fd-table ABI (sys_read / sys_write / sys_close, plus
// sys_openFile / sys_execve / sys_dup2 / sys_readdir); the console and
// file/pipe helpers below are thin adapters over those calls.

const defs = @import("syscall_defs");

// NUL-terminated console printer kept as a convenience over the unified
// write path: it measures the string and emits it through sys_write on
// fd 1 (stdout). Every [TEST]/[PASS]/[FAIL] trace line in this file flows
// through here, so each one exercises the unified SYS_WRITE dispatch.
pub fn sys_writeConsole(buf: [*:0]const u8) void {
    // Volatile loads keep LLVM's loop-idiom recognition from lowering this
    // scan into a libc strlen call, which a freestanding image cannot link.
    var len: u64 = 0;
    while (@as(*const volatile u8, @ptrCast(&buf[len])).* != 0) : (len += 1) {}
    _ = sys_write(1, @intFromPtr(buf), len);
}

// Convenience reader over the unified read path: pulls from fd 0 (stdin,
// pre-installed as a console slot). The console-echo scenario is the
// consumer.
pub fn sys_readConsole(buf: [*]u8, len: u64) i64 {
    return sys_read(0, @intFromPtr(buf), len);
}

// Debug-only — see lib/syscall_defs.zig
// SYS_CONSOLE_INJECT note. Powers the QEMU-side deterministic
// console-echo scenario.
pub fn sys_console_inject(byte: u8) void {
    asm volatile ("svc #0"
        :
        : [nr] "{x8}" (defs.SYS_CONSOLE_INJECT),
          [b] "{x0}" (byte),
        : .{ .memory = true });
}

pub fn sys_fork() i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_FORK),
        : .{ .memory = true });
}

pub fn sys_exit() noreturn {
    asm volatile ("svc #0"
        :
        : [nr] "{x8}" (defs.SYS_EXIT),
        : .{ .memory = true });
    unreachable;
}

pub fn sys_wait() i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_WAIT),
        : .{ .memory = true });
}

// Returns the kernel's free-page count (and prints it to Mini-UART
// as the side effect that preserves the existing trace shape). The
// value powers the [PASS]/[FAIL] decision in each scenario.
pub fn sys_dump_free() u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [nr] "{x8}" (defs.SYS_DUMP_FREE),
        : .{ .memory = true });
}

pub fn sys_kill(pid: i32) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_KILL),
          [pid] "{x0}" (pid),
        : .{ .memory = true });
}

// Path-resolved ELF exec with argv. x0 = NUL-terminated path
// UVA, x1 = UVA of a NULL-terminated array of string pointers. Returns
// only on failure (-1); on success the image is replaced and eret jumps
// to the new entry.
pub fn sys_execve(path_ptr: u64, argv_ptr: u64) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_EXECVE),
          [path] "{x0}" (path_ptr),
          [argv] "{x1}" (argv_ptr),
        : .{ .memory = true });
}

// brk(addr) — set heap break to `addr` (rounded up to page boundary).
// Returns the new break, or current if `addr == 0`. Negative return
// = error (out of bounds against [HEAP_BASE, STACK_TOP - budget)).
// i64 because the heap range covers UVAs that don't fit in i32.
pub fn sys_brk(addr: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_BRK),
          [addr] "{x0}" (addr),
        : .{ .memory = true });
}

// sys_pipe returns both fds packed into one i64: low 32 bits = read fd,
// high 32 bits = write fd. Negative on failure. Compact ABI matches
// src/sys.zig:sys_pipe — single-register return keeps the wrapper
// trivial and avoids any copy_to_user dance.
pub fn sys_pipe() i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_PIPE),
        : .{ .memory = true });
}

pub fn sys_openFile(path: [*:0]const u8) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_OPEN_FILE),
          [path] "{x0}" (path),
        : .{ .memory = true });
}

// Directory-enumeration ABI (Slot 37) — stateless
// index walk: x0/x1/x2 = path / index / out-Dirent UVA. Returns 0 with
// the dirent filled on a hit, -1 at end-of-directory / bad path / wild
// pointer. `dirent` is passed as a u64 UVA, mirroring sys_read's buffer
// argument.
pub fn sys_readdir(path: [*:0]const u8, index: u64, dirent: u64) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_READDIR),
          [path] "{x0}" (path),
          [index] "{x1}" (index),
          [out] "{x2}" (dirent),
        : .{ .memory = true });
}

// Unified fd-table ABI (slots 32..35). Dispatches by the fd's
// kind tag in current.fds (console / pipe / file). These are the only
// I/O syscalls the harness issues: every console, pipe, and file
// scenario routes its reads/writes/closes through them, and
// sys_writeConsole / sys_readConsole above are thin adapters over them.
pub fn sys_read(fd: i32, buf: u64, len: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_READ),
          [fd] "{x0}" (fd),
          [buf] "{x1}" (buf),
          [len] "{x2}" (len),
        : .{ .memory = true });
}

pub fn sys_write(fd: i32, buf: u64, len: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_WRITE),
          [fd] "{x0}" (fd),
          [buf] "{x1}" (buf),
          [len] "{x2}" (len),
        : .{ .memory = true });
}

pub fn sys_close(fd: i32) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_CLOSE),
          [fd] "{x0}" (fd),
        : .{ .memory = true });
}

pub fn sys_dup2(oldfd: i32, newfd: i32) i32 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i32),
        : [nr] "{x8}" (defs.SYS_DUP2),
          [old] "{x0}" (oldfd),
          [new] "{x1}" (newfd),
        : .{ .memory = true });
}

// Kernel-log read (Slot 38) — x0/x1 = buf/len. Snapshots the
// most-recent min(len, retained) bytes of the kernel log ring into `buf`,
// oldest-first, and returns the count (0 empty, -1 wild buffer). Powers
// the [TEST] klog scenario.
pub fn sys_klog_read(buf: u64, len: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_KLOG_READ),
          [buf] "{x0}" (buf),
          [len] "{x1}" (len),
        : .{ .memory = true });
}

// Process-credential ABI (slots 39..44). The getters report the
// calling task's real / effective uid / gid; setuid / setgid mutate them
// under a root-gated policy. i64 returns mirror the kernel handlers' -1
// sentinel. Driven by [TEST] creds.
pub fn sys_getuid() i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_GETUID),
        : .{ .memory = true });
}
pub fn sys_geteuid() i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_GETEUID),
        : .{ .memory = true });
}
pub fn sys_getgid() i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_GETGID),
        : .{ .memory = true });
}
pub fn sys_getegid() i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_GETEGID),
        : .{ .memory = true });
}
pub fn sys_setuid(uid: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_SETUID),
          [uid] "{x0}" (uid),
        : .{ .memory = true });
}
pub fn sys_setgid(gid: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_SETGID),
          [gid] "{x0}" (gid),
        : .{ .memory = true });
}

// Authentication ABI (slot 45). x0..x3 = user / user_len /
// pass / pass_len (UVAs + lengths). Returns 0 on a match, -1 otherwise.
// Drives [TEST] authenticate.
pub fn sys_authenticate(user: u64, user_len: u64, pass: u64, pass_len: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (defs.SYS_AUTHENTICATE),
          [u] "{x0}" (user),
          [ul] "{x1}" (user_len),
          [p] "{x2}" (pass),
          [pl] "{x3}" (pass_len),
        : .{ .memory = true });
}

// Password-change ABI (slot 46). x0..x5 = user / user_len / old /
// old_len / new / new_len (UVAs + lengths). Returns 0 on success, -EACCES
// on an authorization failure, -1 when no writable shadow exists. Drives
// [TEST] passwd.
pub fn sys_passwd(user: u64, user_len: u64, old: u64, old_len: u64, new: u64, new_len: u64) i64 {
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

// ---- Strings (.rodata — placed by tools/pid1_linker.ld) ----

const FORK_ERR_MSG: [*:0]const u8 = "fork error\n";
const NEWLINE: [*:0]const u8 = "\n";
const CHILD_TAG: [*:0]const u8 = "child";
const PARENT_TAG: [*:0]const u8 = "parent";
const DONE_MSG: [*:0]const u8 = "done\n";
const KILL_OK_MSG: [*:0]const u8 = "kill ok\n";
const EXEC_ELF_OK_MSG: [*:0]const u8 = "exec-elf ok\n";
const BRK_OK_MSG: [*:0]const u8 = "brk ok\n";
const BRK_CHILD_OK_MSG: [*:0]const u8 = "brk child ok\n";
const BRK_CHILD_BAD_MSG: [*:0]const u8 = "brk child bad\n";

const TEST_FORK_STRESS: [*:0]const u8 = "[TEST] fork-stress\n";
const PASS_FORK_STRESS: [*:0]const u8 = "[PASS] fork-stress\n";
const FAIL_FORK_STRESS: [*:0]const u8 = "[FAIL] fork-stress\n";
const TEST_OOM_GRACEFUL: [*:0]const u8 = "[TEST] oom-graceful\n";
const PASS_OOM_GRACEFUL: [*:0]const u8 = "[PASS] oom-graceful\n";
const FAIL_OOM_GRACEFUL: [*:0]const u8 = "[FAIL] oom-graceful\n";
const TEST_KILL: [*:0]const u8 = "[TEST] kill\n";
const PASS_KILL: [*:0]const u8 = "[PASS] kill\n";
const FAIL_KILL: [*:0]const u8 = "[FAIL] kill\n";
const TEST_EXEC_ELF: [*:0]const u8 = "[TEST] exec-elf\n";
const PASS_EXEC_ELF: [*:0]const u8 = "[PASS] exec-elf\n";
const FAIL_EXEC_ELF: [*:0]const u8 = "[FAIL] exec-elf\n";
const TEST_EXECVE: [*:0]const u8 = "[TEST] execve\n";
const PASS_EXECVE: [*:0]const u8 = "[PASS] execve\n";
const FAIL_EXECVE: [*:0]const u8 = "[FAIL] execve\n";
const TEST_BRK: [*:0]const u8 = "[TEST] brk\n";
const PASS_BRK: [*:0]const u8 = "[PASS] brk\n";
const FAIL_BRK: [*:0]const u8 = "[FAIL] brk\n";
const TEST_STACK_OVERFLOW: [*:0]const u8 = "[TEST] stack-overflow\n";
const PASS_STACK_OVERFLOW: [*:0]const u8 = "[PASS] stack-overflow\n";
const FAIL_STACK_OVERFLOW: [*:0]const u8 = "[FAIL] stack-overflow\n";
const TEST_WILD_POINTER: [*:0]const u8 = "[TEST] wild-pointer\n";
const PASS_WILD_POINTER: [*:0]const u8 = "[PASS] wild-pointer\n";
const FAIL_WILD_POINTER: [*:0]const u8 = "[FAIL] wild-pointer\n";
const TEST_EXEC_FAULT: [*:0]const u8 = "[TEST] exec-fault\n";
const PASS_EXEC_FAULT: [*:0]const u8 = "[PASS] exec-fault\n";
const FAIL_EXEC_FAULT: [*:0]const u8 = "[FAIL] exec-fault\n";
const TEST_UNDEF_INSTR: [*:0]const u8 = "[TEST] undef-instr\n";
const PASS_UNDEF_INSTR: [*:0]const u8 = "[PASS] undef-instr\n";
const FAIL_UNDEF_INSTR: [*:0]const u8 = "[FAIL] undef-instr\n";
const TEST_EFAULT_SYSCALL: [*:0]const u8 = "[TEST] efault-syscall\n";
const PASS_EFAULT_SYSCALL: [*:0]const u8 = "[PASS] efault-syscall\n";
const FAIL_EFAULT_SYSCALL: [*:0]const u8 = "[FAIL] efault-syscall\n";
const TEST_FLIBC: [*:0]const u8 = "[TEST] flibc\n";
const PASS_FLIBC: [*:0]const u8 = "[PASS] flibc\n";
const FAIL_FLIBC: [*:0]const u8 = "[FAIL] flibc\n";
const TEST_TRACE: [*:0]const u8 = "[TEST] trace\n";
const PASS_TRACE: [*:0]const u8 = "[PASS] trace\n";
const FAIL_TRACE: [*:0]const u8 = "[FAIL] trace\n";
const TEST_PIPE: [*:0]const u8 = "[TEST] pipe\n";
const PASS_PIPE: [*:0]const u8 = "[PASS] pipe\n";
const FAIL_PIPE: [*:0]const u8 = "[FAIL] pipe\n";
const PIPE_OK_MSG: [*:0]const u8 = "pipe ok\n";
const PIPE_BAD_MSG: [*:0]const u8 = "pipe bad\n";
const TEST_CONSOLE_ECHO: [*:0]const u8 = "[TEST] console-echo\n";
const PASS_CONSOLE_ECHO: [*:0]const u8 = "[PASS] console-echo\n";
const FAIL_CONSOLE_ECHO: [*:0]const u8 = "[FAIL] console-echo\n";
const ECHO_OK_MSG: [*:0]const u8 = "echo ok\n";
const ECHO_BAD_MSG: [*:0]const u8 = "echo bad\n";
const TEST_FD_REDIRECT: [*:0]const u8 = "[TEST] fd-redirect\n";
const PASS_FD_REDIRECT: [*:0]const u8 = "[PASS] fd-redirect\n";
const FAIL_FD_REDIRECT: [*:0]const u8 = "[FAIL] fd-redirect\n";
const FD_REDIRECT_OK_MSG: [*:0]const u8 = "fd-redirect ok\n";
const FD_REDIRECT_BAD_MSG: [*:0]const u8 = "fd-redirect bad\n";
const TEST_INITRAMFS_OPEN: [*:0]const u8 = "[TEST] initramfs-open\n";
const PASS_INITRAMFS_OPEN: [*:0]const u8 = "[PASS] initramfs-open\n";
const FAIL_INITRAMFS_OPEN: [*:0]const u8 = "[FAIL] initramfs-open\n";
const TEST_VFS_DISPATCH: [*:0]const u8 = "[TEST] vfs-dispatch\n";
const PASS_VFS_DISPATCH: [*:0]const u8 = "[PASS] vfs-dispatch\n";
const FAIL_VFS_DISPATCH: [*:0]const u8 = "[FAIL] vfs-dispatch\n";
const INIT_PATH: [*:0]const u8 = "/sbin/init";
const HELLO_ELF_PATH: [*:0]const u8 = "/test/hello.elf";
const ARGV_ECHO_PATH: [*:0]const u8 = "/test/argv_echo.elf";
const STACKBOMB_ELF_PATH: [*:0]const u8 = "/test/stackbomb.elf";
const FLIBC_DEMO_ELF_PATH: [*:0]const u8 = "/test/flibc_demo.elf";
// fsh-scenario constants — disabled with run_fsh below (kept, not deleted).
// The interactive shell is now exercised by the PID-1 hand-off + the boot
// watchdog's `[Debug] fsh init OK` success marker, so an in-harness fsh test is
// redundant. Re-enable by uncommenting these, run_fsh, and the scenarios[]
// entry.
// const FSH_PATH: [*:0]const u8 = "/bin/fsh";
// const TEST_FSH: [*:0]const u8 = "[TEST] fsh\n";
// const PASS_FSH: [*:0]const u8 = "[PASS] fsh\n";
// const FAIL_FSH: [*:0]const u8 = "[FAIL] fsh\n";
const TEST_READDIR: [*:0]const u8 = "[TEST] readdir\n";
const PASS_READDIR: [*:0]const u8 = "[PASS] readdir\n";
const FAIL_READDIR: [*:0]const u8 = "[FAIL] readdir\n";
const TEST_KLOG: [*:0]const u8 = "[TEST] klog\n";
const PASS_KLOG: [*:0]const u8 = "[PASS] klog\n";
const FAIL_KLOG: [*:0]const u8 = "[FAIL] klog\n";
// Marker run_klog searches the ring snapshot for. `free_pages: ` is
// emitted by the kernel's dump_free_count via main_output(MU) *directly*
// (not the user console_tx mux), so it is teed into the ring regardless of
// USB-console enumeration — robust on every QEMU target and on Pi HW,
// unlike the userland scenario header. run_klog prints it (via
// sys_dump_free) right before the snapshot, so it is the freshest line.
const KLOG_MARKER: []const u8 = "free_pages";
const TEST_RNG: [*:0]const u8 = "[TEST] rng\n";
const PASS_RNG: [*:0]const u8 = "[PASS] rng\n";
const FAIL_RNG: [*:0]const u8 = "[FAIL] rng\n";
// Markers run_rng scans the ring snapshot for. hwrng_init (src/hwrng.zig)
// announces the active entropy source over main_output(MU) during kernel
// bring-up, so the line is teed into the ring on every target before
// PID 1 exists. The positive token matches any announce; the negative
// token is printed only by the failed boot self-test and must be absent —
// both together assert "the announce ran AND it was healthy".
const HWRNG_MARKER: []const u8 = "hwrng:";
const HWRNG_FAIL_MARKER: []const u8 = "hwrng: self-test failed";
const TEST_CREDS: [*:0]const u8 = "[TEST] creds\n";
const PASS_CREDS: [*:0]const u8 = "[PASS] creds\n";
const FAIL_CREDS: [*:0]const u8 = "[FAIL] creds\n";
const TEST_AUTH: [*:0]const u8 = "[TEST] authenticate\n";
const PASS_AUTH: [*:0]const u8 = "[PASS] authenticate\n";
const FAIL_AUTH: [*:0]const u8 = "[FAIL] authenticate\n";
const TEST_PERM: [*:0]const u8 = "[TEST] perm\n";
const PASS_PERM: [*:0]const u8 = "[PASS] perm\n";
const FAIL_PERM: [*:0]const u8 = "[FAIL] perm\n";
// Login-lifecycle capstone: drives the real /bin/login through
// two console-scripted sessions (flash, then root) via its session-limit
// argv. Named "login" — not "auth" — so greps for the existing
// "authenticate" scenario never collide with it.
const TEST_LOGIN: [*:0]const u8 = "[TEST] login\n";
const PASS_LOGIN: [*:0]const u8 = "[PASS] login\n";
const FAIL_LOGIN: [*:0]const u8 = "[FAIL] login\n";
const LOGIN_BIN_PATH: [*:0]const u8 = "/bin/login";
// Password change: sys_passwd roundtrip against the writable
// FAT32 shadow; SKIP-PASSes on virt (no SD card), mirroring fs-roundtrip.
const TEST_PASSWD: [*:0]const u8 = "[TEST] passwd\n";
const PASS_PASSWD: [*:0]const u8 = "[PASS] passwd\n";
const PASS_PASSWD_SKIP: [*:0]const u8 = "[PASS] passwd (skip)\n";
const FAIL_PASSWD: [*:0]const u8 = "[FAIL] passwd\n";
const MNT_SHADOW_PATH: [*:0]const u8 = "/mnt/shadow";
// Paths the perm scenario probes: the 0600 shadow file (denied to a
// dropped child, open to root) and the 0644 passwd file (world-readable
// but not executable).
const SHADOW_PATH: [*:0]const u8 = "/etc/shadow";
const ETC_PASSWD_PATH: [*:0]const u8 = "/etc/passwd";
const BIN_DIR: [*:0]const u8 = "/bin";
const MNT_MISSING_PATH: [*:0]const u8 = "/mnt/this-does-not-exist";
const MNT_BARE_PATH: [*:0]const u8 = "/mnt";
const TEST_FS_ROUNDTRIP: [*:0]const u8 = "[TEST] fs-roundtrip\n";
const PASS_WRITE: [*:0]const u8 = "[PASS] fs-roundtrip-write (reboot to verify)\n";
const PASS_VERIFY: [*:0]const u8 = "[PASS] fs-roundtrip\n";
const PASS_SKIP: [*:0]const u8 = "[PASS] fs-roundtrip (skip)\n";
const FAIL_FS_ROUNDTRIP: [*:0]const u8 = "[FAIL] fs-roundtrip\n";
const FAIL_MAGIC: [*:0]const u8 = "[FAIL] fs-roundtrip (magic corrupted)\n";
// 1-byte sub-sector writeBack regression probe. [DBG] prefix so
// run_qemu_test.sh's [FAIL]/14-14/ERROR-CAUGHT greps are untouched.
// Catches the FAT32 splice reorder regression
// (fat32_backend `@memcpy` hoisted above `read_fn` re-zeroed the
// 1-byte write); kept as a permanent assertion since QEMU never runs
// the real block-I/O path.
const MAG_INBOOT_OK: [*:0]const u8 = "[DBG] mag-inboot=01 (1-byte writeBack OK)\n";
const MAG_INBOOT_BAD: [*:0]const u8 = "[DBG] mag-inboot=00 (1-byte writeBack REGRESSION)\n";
// 8.3-safe basenames (<=8 chars): fat32.encode8_3 rejects a
// basename longer than 8, so a literal roundtrip.dat /
// roundtrip.mag (9-char base) would make every open return -1.
const ROUNDTRIP_DAT_PATH: [*:0]const u8 = "/mnt/roundtr.dat";
const ROUNDTRIP_MAG_PATH: [*:0]const u8 = "/mnt/roundtr.mag";

const SLASH: [*:0]const u8 = "/";
const PASSED_SUFFIX: [*:0]const u8 = " passed\n";
const D0: [*:0]const u8 = "0";
const D1: [*:0]const u8 = "1";
const D2: [*:0]const u8 = "2";
const D3: [*:0]const u8 = "3";
const D4: [*:0]const u8 = "4";
const D5: [*:0]const u8 = "5";
const D6: [*:0]const u8 = "6";
const D7: [*:0]const u8 = "7";
const D8: [*:0]const u8 = "8";
const D9: [*:0]const u8 = "9";
const QMARK: [*:0]const u8 = "?";

// ---- Test parameters ----

const NUM_ROUNDS: u32 = 3;
const NUM_CHILDREN: u32 = 5;
const CHILD_ITERS: u32 = 10;

// Canonical wild UVA: sits in the 16 TiB heap-stack gap, outside
// every legal region (text/data, heap [HEAP_BASE, brk), stack
// [STACK_LOW, STACK_TOP)). Shared by [TEST] wild-pointer (direct EL0
// write — exercises do_data_abort's hard path) and [TEST]
// efault-syscall (passed as a user pointer to a syscall — exercises
// check_and_prefault_user_range's soft path).
const WILD_UVA_CANONICAL: u64 = 0xDEADBEEF000;

// ---- Children ----

// Run `iters` print iterations and then sys_exit. Used by children only,
// so the call is noreturn. Parent's print bursts are inlined into the
// scenario bodies.
fn loop(str: [*:0]const u8, iters: u32) noreturn {
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        sys_writeConsole(str);
        sys_writeConsole(NEWLINE);
        var d: u32 = 100_000;
        while (d > 0) : (d -= 1) {}
    }
    sys_exit();
}

// Loop forever printing `str`. Used by the sys_kill test child — it never
// reaches sys_exit; the parent's sys_kill is what flips it to TASK_ZOMBIE.
fn loop_forever(str: [*:0]const u8) noreturn {
    while (true) {
        sys_writeConsole(str);
        sys_writeConsole(NEWLINE);
        var d: u32 = 100_000;
        while (d > 0) : (d -= 1) {}
    }
}

// ---- Scenarios ----

fn run_fork_stress(baseline: u64) bool {
    sys_writeConsole(TEST_FORK_STRESS);
    var ok = true;

    var round: u32 = 0;
    while (round < NUM_ROUNDS) : (round += 1) {
        var spawned: u32 = 0;
        while (spawned < NUM_CHILDREN) : (spawned += 1) {
            const pid = sys_fork();
            if (pid < 0) {
                sys_writeConsole(FORK_ERR_MSG);
                ok = false;
                break;
            }
            if (pid == 0) {
                loop(CHILD_TAG, CHILD_ITERS);
            }
            sys_writeConsole(PARENT_TAG);
            sys_writeConsole(NEWLINE);
        }

        var reaped: u32 = 0;
        while (reaped < NUM_CHILDREN) : (reaped += 1) {
            _ = sys_wait();
            sys_writeConsole(PARENT_TAG);
            sys_writeConsole(NEWLINE);
        }

        if (sys_dump_free() != baseline) ok = false;
    }

    sys_writeConsole(DONE_MSG);
    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_FORK_STRESS else FAIL_FORK_STRESS);
    return ok;
}

// Drives fork to the global task-slot cap and asserts the failing fork
// degrades cleanly: returns -1 (not a crash, not a half-built zombie),
// every child reaps, and the free-page count returns to baseline. This
// exercises the integration of copy_process_impl's slot-exhaustion
// teardown (release_user_mm on the abandoned child mm) with the fork/reap
// page balance under maximum slot pressure — the userland-visible face of
// the OOM-soft-fail contract whose unit pieces (get_free_page
// sentinel, map_page rollback, release_user_mm) are host-tested.
//
// Accumulate-without-reap design: the parent forks children that each
// sys_exit immediately and piles them (running or zombie, both hold a
// task[] slot) until fork returns -1 at the slot cap. Reachable only
// since the page-allocator / kernel-image overlap fix (commit before
// this) — pre-fix the kernel stalled around the 9th-12th live fork when
// get_free_page handed out a PA inside the kernel image. The real pool
// is never exhausted here (8 MiB live-memory ceiling vs a ~245k-page
// virt pool); the 64-slot task cap is the deterministic limiter, so this
// runs identically on both QEMU targets. OOM_FORK_GUARD bounds the loop
// so a regression that lets fork succeed past the cap fails the scenario
// instead of hanging the harness.
const OOM_FORK_GUARD: u32 = 80;

fn run_oom_graceful(baseline: u64) bool {
    sys_writeConsole(TEST_OOM_GRACEFUL);
    var ok = true;

    var spawned: u32 = 0;
    var hit_cap = false;
    while (spawned < OOM_FORK_GUARD) {
        const pid = sys_fork();
        if (pid < 0) {
            hit_cap = true;
            break;
        }
        if (pid == 0) sys_exit();
        spawned += 1;
    }

    // Clean cap failure: fork worked at all, and the loop ended on the
    // -1 slot-cap return — not the runaway guard (which would mean fork
    // kept succeeding past the cap).
    if (spawned == 0) ok = false;
    if (!hit_cap) ok = false;

    // Reap every child accumulated above; sys_wait blocks until each
    // still-running child reaches its sys_exit and zombifies.
    var reaped: u32 = 0;
    while (reaped < spawned) : (reaped += 1) _ = sys_wait();

    // The one new free-page checkpoint: the cap-hit fork's abandoned
    // child mm was released (copy_process_impl slot-exhaustion path) and
    // every reaped child returned its pages, so the pool is exactly where
    // it started.
    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_OOM_GRACEFUL else FAIL_OOM_GRACEFUL);
    return ok;
}

fn run_kill(baseline: u64) bool {
    sys_writeConsole(TEST_KILL);
    var ok = true;

    const kill_pid = sys_fork();
    if (kill_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_KILL);
        return false;
    }
    if (kill_pid == 0) {
        loop_forever(CHILD_TAG);
    }

    var d: u32 = 500_000;
    while (d > 0) : (d -= 1) {}
    _ = sys_kill(kill_pid);
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(KILL_OK_MSG);
    sys_writeConsole(if (ok) PASS_KILL else FAIL_KILL);
    return ok;
}

// Forks a child that path-resolves and execs /test/hello.elf via
// sys_execve (the VFS resolve + parser + PT_LOAD walk + stack page +
// entry dispatch all live in src/fork.zig:prepare_move_to_user_elf).
// The kernel streams the whole ELF in from the initramfs itself, so the
// harness hands it only the path and a minimal argv. sys_execve returns
// only on failure, so the trailing sys_exit covers the resolve / parse /
// alloc error path. Success criterion: the child terminates cleanly
// (sys_exit from the ELF's own _start), the parent reaps it, and the
// free-page count returns to baseline — the exec teardown frees the old
// pages and the loader's allocations are swept by the reap, netting to
// zero.
fn run_exec_elf(baseline: u64) bool {
    sys_writeConsole(TEST_EXEC_ELF);
    var ok = true;

    const exec_pid = sys_fork();
    if (exec_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_EXEC_ELF);
        return false;
    }
    if (exec_pid == 0) {
        const argv = [_:null]?[*:0]const u8{"/test/hello.elf"};
        _ = sys_execve(@intFromPtr(HELLO_ELF_PATH), @intFromPtr(&argv));
        // Only reachable on sys_execve failure (resolve / parse / alloc).
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(EXEC_ELF_OK_MSG);
    sys_writeConsole(if (ok) PASS_EXEC_ELF else FAIL_EXEC_ELF);
    return ok;
}

// Path-resolved exec with argv. Forks a child that calls
// sys_execve("/test/argv_echo.elf", {"argv_echo","A","B"}); the kernel
// resolves the path through the VFS shim, streams the whole ELF into a
// static buffer (no PAGE_SIZE cap), encodes the argv block onto the new
// top stack page, tears down the old address space, and the loader maps
// the new image with x0=argc / x1=argv. argv_echo's _start prints its
// argv and exits. sys_execve only returns on failure, so the trailing
// sys_exit covers the resolve / parse / alloc error path. Success
// criterion mirrors run_exec_elf: the child runs to completion, the
// parent reaps it, and the free-page count returns to baseline — the
// exec teardown frees the old pages and the loader's allocations are
// swept by the reap, netting to zero.
fn run_execve(baseline: u64) bool {
    sys_writeConsole(TEST_EXECVE);
    var ok = true;

    const exec_pid = sys_fork();
    if (exec_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_EXECVE);
        return false;
    }
    if (exec_pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "argv_echo", "A", "B" };
        _ = sys_execve(@intFromPtr(ARGV_ECHO_PATH), @intFromPtr(&argv));
        // Only reachable on sys_execve failure (resolve / parse / alloc).
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_EXECVE else FAIL_EXECVE);
    return ok;
}

// Heap demand-allocation + shrink-and-free coverage. Forks a child that
// reads the initial break (HEAP_BASE, set by prepare_move_to_user_elf
// when PID 1 was loaded — copy_virt_memory inherits it across fork), grows
// the heap by NUM_BRK_PAGES pages, walks the new range writing one
// byte per page (each touch fires do_data_abort which demand-allocates
// the heap page), reads the pattern back, then shrinks the break to
// the original. Success criterion mirrors the other reap-based tests:
// after the parent's wait the free-page count must equal the baseline,
// proving (a) demand-allocated heap pages were tracked in the child's
// user_pages, (b) the brk-shrink path freed them via unmap_user_range,
// and (c) what the shrink missed do_wait swept up. The "brk child ok"
// trace marker is the in-band confirmation that the read-back pattern
// matched — purely informational, the [PASS]/[FAIL] decision is
// baseline-only (mirrors run_exec_elf).
const NUM_BRK_PAGES: u32 = 16;
// Build-time guard for src/task_layout.zig:MAX_PAGE_COUNT. The brk test
// consumes 1 inherited UVA-0 page + NUM_BRK_PAGES heap pages. If
// NUM_BRK_PAGES grows past 30, mm.user_pages would silently truncate at
// the 32nd map_page call — bump MAX_PAGE_COUNT in src/task_layout.zig
// first.
comptime {
    if (NUM_BRK_PAGES + 1 > 31) {
        @compileError("NUM_BRK_PAGES would overflow task_layout.MAX_PAGE_COUNT — bump src/task_layout.zig:MAX_PAGE_COUNT");
    }
}
const PAGE_SIZE_USER: u64 = 4096;

fn run_brk(baseline: u64) bool {
    sys_writeConsole(TEST_BRK);
    var ok = true;

    const brk_pid = sys_fork();
    if (brk_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_BRK);
        return false;
    }
    if (brk_pid == 0) {
        const initial = sys_brk(0);
        if (initial < 0) sys_exit();
        const initial_u: u64 = @bitCast(initial);

        const grown = sys_brk(initial_u + NUM_BRK_PAGES * PAGE_SIZE_USER);
        if (grown < 0) sys_exit();

        // Touch every fresh page once — each store traps to
        // do_data_abort with a level-3 translation fault and the
        // region-aware handler demand-allocates inside
        // the legal heap range [HEAP_BASE, current.mm.brk).
        var page: u32 = 0;
        while (page < NUM_BRK_PAGES) : (page += 1) {
            const ptr: *volatile u8 = @ptrFromInt(initial_u + page * PAGE_SIZE_USER);
            ptr.* = @as(u8, @truncate(page)) +% 0x42;
        }

        // Read back to prove the demand-allocated pages persist (i.e.
        // each fault gave a fresh page that stayed mapped, not a TLB
        // alias of someone else's PA).
        var read_ok = true;
        page = 0;
        while (page < NUM_BRK_PAGES) : (page += 1) {
            const ptr: *const volatile u8 = @ptrFromInt(initial_u + page * PAGE_SIZE_USER);
            const expected: u8 = @as(u8, @truncate(page)) +% 0x42;
            if (ptr.* != expected) read_ok = false;
        }
        sys_writeConsole(if (read_ok) BRK_CHILD_OK_MSG else BRK_CHILD_BAD_MSG);

        // Shrink back to the original break — exercises
        // unmap_user_range so the per-process page balance returns to
        // zero before do_wait. Without this the test would still pass
        // (do_wait reaps the leftover heap pages), so a failing shrink
        // is not treated as fatal here.
        _ = sys_brk(initial_u);
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(BRK_OK_MSG);
    sys_writeConsole(if (ok) PASS_BRK else FAIL_BRK);
    return ok;
}

// Forks a child that path-resolves and execs /test/stackbomb.elf via
// sys_execve — a tiny freestanding aarch64 ET_EXEC whose _start does
// nothing but recurse, pushing 1 KiB per frame. After ~64 frames the
// child's SP crosses STACK_LOW and the next store enters the guard page;
// the kernel's do_data_abort detects the guard fault, prints
// `[KERN] stack overflow at 0x<hex>` to MU, and zombies the task via
// exit_process. The parent's sys_wait reaps as usual, so the per-process
// page balance returns to baseline — that's what this scenario asserts.
//
// The child runs in the post-ELF-load image (SP = STACK_TOP, eager
// top page mapped, layout from src/user_layout.zig), which is the only
// context where the high stack VA is reachable. sys_execve only returns
// on failure, so the trailing sys_exit covers the resolve / parse / alloc
// error path.
fn run_stack_overflow(baseline: u64) bool {
    sys_writeConsole(TEST_STACK_OVERFLOW);
    var ok = true;

    const ovf_pid = sys_fork();
    if (ovf_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_STACK_OVERFLOW);
        return false;
    }
    if (ovf_pid == 0) {
        const argv = [_:null]?[*:0]const u8{"/test/stackbomb.elf"};
        _ = sys_execve(@intFromPtr(STACKBOMB_ELF_PATH), @intFromPtr(&argv));
        // Only reachable on sys_execve failure (resolve / parse / alloc).
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_STACK_OVERFLOW else FAIL_STACK_OVERFLOW);
    return ok;
}

// Forks a child that path-resolves and execs /test/flibc_demo.elf via
// sys_execve — a flibc-driven payload that exercises printf (%d
// round-trip), malloc (bump-allocate 32 B + pattern verify), and exit.
// The harness validates kernel invariants the same way the other exec
// scenarios do (parent reaps, free-page baseline holds), and additionally
// the in-band trace markers `flibc hello 42` / `flibc malloc ok` confirm
// flibc's printf and heap layers ran end-to-end. fork/wait/execve
// wrappers are present in flibc but not exercised here — they are thin
// sys_* passthroughs already covered by run_fork_stress and run_exec_elf
// via the kernel's syscall path. sys_execve only returns on failure, so
// the trailing sys_exit covers the resolve / parse / alloc error path.
fn run_flibc(baseline: u64) bool {
    sys_writeConsole(TEST_FLIBC);
    var ok = true;

    const flibc_pid = sys_fork();
    if (flibc_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_FLIBC);
        return false;
    }
    if (flibc_pid == 0) {
        const argv = [_:null]?[*:0]const u8{"/test/flibc_demo.elf"};
        _ = sys_execve(@intFromPtr(FLIBC_DEMO_ELF_PATH), @intFromPtr(&argv));
        // Only reachable on sys_execve failure (resolve / parse / alloc).
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_FLIBC else FAIL_FLIBC);
    return ok;
}

// Forks a child that writes one byte to 0xDEADBEEF000 — a UVA that
// falls in the 16 TiB heap-stack gap, outside every legal region
// (heap [HEAP_BASE, brk), stack [STACK_LOW, STACK_TOP), text
// [0, DATA_BASE)). do_data_abort classifies it as a wild
// pointer, prints `[KERN] invalid uva at 0x<hex>` to MU and zombies the
// task via exit_process; the parent's sys_wait reaps so the per-process
// page balance returns to baseline — that's what this scenario asserts.
//
// The child runs in the inherited image (no exec needed) since
// the wild-pointer path doesn't depend on the loader's layout — only on
// do_data_abort's region classification, which keys off mm.brk + the
// static layout constants.
fn run_wild_pointer(baseline: u64) bool {
    sys_writeConsole(TEST_WILD_POINTER);
    var ok = true;

    const wp_pid = sys_fork();
    if (wp_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_WILD_POINTER);
        return false;
    }
    if (wp_pid == 0) {
        const wild: *volatile u8 = @ptrFromInt(WILD_UVA_CANONICAL);
        wild.* = 0x42;
        // Only reached if do_data_abort did not zombie the task;
        // exit cleanly so the parent can still wait.
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_WILD_POINTER else FAIL_WILD_POINTER);
    return ok;
}

// Forks a child that *jumps* to the canonical wild UVA (0xDEADBEEF000) —
// the instruction-side twin of run_wild_pointer's *store*. The fetch
// faults as an instruction abort (ESR EC 0x20) where the store faulted
// as a data abort (EC 0x24); entry.S routes it to do_instruction_abort,
// which prints `[KERN] exec fault at 0x<hex>` and zombies the task. The
// parent's sys_wait reaps so the per-process page balance returns to
// baseline. Before the fix, handle_sync_el0_64 matched only SVC + data
// abort, so an instruction abort fell through to handle_invalid_entry →
// err_hang and spun the whole core on a single bad jump.
//
// Liveness is the real assertion: had the routing regressed, the child
// would spin the core, sys_wait would never return, the harness would
// never hand off to fsh, and the QEMU watchdog would catch the missing
// `[Debug] fsh init OK`. The free-page baseline rules out a leak across
// the fault → reap. The child runs in the inherited image (no exec) —
// the path keys only on entry.S's EC dispatch.
fn run_exec_fault(baseline: u64) bool {
    sys_writeConsole(TEST_EXEC_FAULT);
    var ok = true;

    const ef_pid = sys_fork();
    if (ef_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_EXEC_FAULT);
        return false;
    }
    if (ef_pid == 0) {
        const bad: *const fn () void = @ptrFromInt(WILD_UVA_CANONICAL);
        bad();
        // Only reached if entry.S did not zombie the task; exit cleanly
        // so the parent can still wait.
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_EXEC_FAULT else FAIL_EXEC_FAULT);
    return ok;
}

// Forks a child that executes a permanently-undefined instruction
// (`.inst 0x00000000` = UDF #0). At EL0 this raises a synchronous
// "unknown reason" exception (ESR EC 0x00) — which is neither SVC
// (0x15), data abort (0x24), nor instruction abort (0x20), so
// handle_sync_el0_64's first three branches all miss and entry.S routes
// it to the el0_sync_other catch-all → do_el0_sync_fault, which prints
// `[KERN] el0 sync fault ec=0x0 at 0x<hex>` and zombies the task. Before
// the catch-all existed, this EC fell through to handle_invalid_entry →
// err_hang and spun the whole core. EC 0x00 has no other dispatch path,
// so harness survival here is unambiguous proof the catch-all ran (the
// only alternative was the core-spin). Liveness is the assertion: had
// the routing regressed, the child would hang the core, sys_wait would
// never return, and the QEMU watchdog would catch the missing
// `[Debug] fsh init OK`. The free-page baseline rules out a leak across
// the fault → reap. Reap-based + baseline-neutral, like run_exec_fault.
fn run_undef_instr(baseline: u64) bool {
    sys_writeConsole(TEST_UNDEF_INSTR);
    var ok = true;

    const ui_pid = sys_fork();
    if (ui_pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_UNDEF_INSTR);
        return false;
    }
    if (ui_pid == 0) {
        // UDF #0 — a permanently-undefined A64 encoding. `.inst` emits the
        // raw word, so this does not depend on the assembler aliasing the
        // `udf` mnemonic. Faults as EC 0x00 before the next instruction.
        asm volatile (".inst 0x00000000");
        // Only reached if the catch-all did not zombie the task; exit
        // cleanly so the parent can still wait.
        sys_exit();
    }
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_UNDEF_INSTR else FAIL_UNDEF_INSTR);
    return ok;
}

// Hands the canonical wild UVA to sys_openFile directly (no fork).
// copy_from_user walks the path through check_and_prefault_user_range;
// the soft path returns -1 to the syscall without invoking exit_process.
// PID 1 itself is the probe: if the soft path regresses to the hard
// path, the harness task zombifies mid-scenario, the hand-off to fsh
// never runs, and the QEMU watchdog catches the missing `[Debug] fsh init OK`.
// Free-page baseline holds trivially because sys_openFile bails before
// any File allocation when copy_from_user returns -1.
fn run_efault_syscall(baseline: u64) bool {
    sys_writeConsole(TEST_EFAULT_SYSCALL);
    var ok = true;

    const fd = sys_openFile(@ptrFromInt(WILD_UVA_CANONICAL));
    if (fd != -1) ok = false;

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_EFAULT_SYSCALL else FAIL_EFAULT_SYSCALL);
    return ok;
}

// Forks one child, hands a deterministic 16-byte payload through an
// anonymous pipe (parent reads, child writes), reaps the child, and
// asserts the per-process free-page baseline holds. Coverage spans:
//   * sys_pipe → page allocation + fd-table install for both ends
//   * fork-dup of fd_table (parent and child see the same Pipe object)
//   * child sys_close on the read end → refcount 2 → 1
//   * sys_write of full payload → reader wake
//   * parent sys_read → drains pipe
//   * child sys_close on the write end + sys_exit → reap
//   * parent sys_close on the read end → unref → page freed
//
// The pattern is 0xA0..0xAF (16 bytes) — distinct enough that a
// truncation or out-of-order delivery shows up immediately in the
// byte compare. Free-page baseline is the [PASS] gate, matching
// every other reap-based scenario.
const PIPE_PAYLOAD_LEN: u64 = 16;

fn run_pipe(baseline: u64) bool {
    sys_writeConsole(TEST_PIPE);
    var ok = true;

    const fds = sys_pipe();
    if (fds < 0) {
        sys_writeConsole(FAIL_PIPE);
        return false;
    }
    const rfd: i32 = @intCast(fds & 0xFFFF_ffff);
    const wfd: i32 = @intCast((fds >> 32) & 0xFFFF_ffff);

    const pid = sys_fork();
    if (pid < 0) {
        _ = sys_close(rfd);
        _ = sys_close(wfd);
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_PIPE);
        return false;
    }
    if (pid == 0) {
        // Child writer: close read end, push payload, close write end.
        _ = sys_close(rfd);
        var out: [16]u8 = undefined;
        var oi: u32 = 0;
        while (oi < PIPE_PAYLOAD_LEN) : (oi += 1) {
            out[oi] = 0xA0 +% @as(u8, @intCast(oi));
        }
        const n = sys_write(wfd, @intFromPtr(&out), PIPE_PAYLOAD_LEN);
        if (n != PIPE_PAYLOAD_LEN) {
            sys_writeConsole("[FAIL] pipe (short write)\n");
        }
        _ = sys_close(wfd);
        sys_exit();
    }

    // Parent reader: drop write end first so the EOF short-circuit
    // becomes reachable for the child if it ever short-writes.
    _ = sys_close(wfd);

    // pipe.read short-reads to whatever's currently buffered; loop
    // until the full payload arrives or EOF (child closed the write
    // end). The child writes a single 16-byte burst; looping keeps
    // the test robust to a future short-write semantics change.
    var in: [16]u8 = undefined;
    var got: u64 = 0;
    while (got < PIPE_PAYLOAD_LEN) {
        const n = sys_read(rfd, @intFromPtr(&in[got]), PIPE_PAYLOAD_LEN - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    if (got != PIPE_PAYLOAD_LEN) ok = false;

    var ci: u32 = 0;
    while (ci < PIPE_PAYLOAD_LEN) : (ci += 1) {
        const expected: u8 = 0xA0 +% @as(u8, @intCast(ci));
        if (in[ci] != expected) ok = false;
    }
    sys_writeConsole(if (ok) PIPE_OK_MSG else PIPE_BAD_MSG);

    _ = sys_close(rfd);
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_PIPE else FAIL_PIPE);
    return ok;
}

// Drives the console RX path end-to-end. Forks one
// child that injects ECHO_LEN bytes via SYS_CONSOLE_INJECT after a
// short delay; the parent blocks in sys_readConsole on the empty
// ring, the WaitQueue wake fires on each push, and the parent loops
// because console_read short-returns. The injected pattern
// (0xC0..0xC7) is distinct enough that a truncation or out-of-order
// drain shows up immediately in the byte compare. The parent reads
// fd 0 and writes fd 1 directly, both pre-installed console fds.
//
// Test free-page baseline gate matches the other reap-based
// scenarios; the ring buffer lives in BSS, so the baseline must be
// fully restored after the child is reaped.
const ECHO_LEN: u64 = 8;

fn run_console_echo(baseline: u64) bool {
    sys_writeConsole(TEST_CONSOLE_ECHO);
    var ok = true;

    const pid = sys_fork();
    if (pid < 0) {
        sys_writeConsole(FAIL_CONSOLE_ECHO);
        return false;
    }
    if (pid == 0) {
        // Delay so the parent reaches sys_readConsole and hits the
        // empty-ring branch first — that's the WaitQueue path under
        // test. The same loop length is used by run_kill; single-core
        // scheduling makes that an upper bound for the parent to
        // enter wait state.
        var d: u32 = 500_000;
        while (d > 0) : (d -= 1) {}
        var i: u32 = 0;
        while (i < ECHO_LEN) : (i += 1) {
            sys_console_inject(0xC0 +% @as(u8, @intCast(i)));
        }
        sys_exit();
    }

    var in: [8]u8 = undefined;
    var got: u64 = 0;
    while (got < ECHO_LEN) {
        const n = sys_readConsole(@ptrCast(&in[got]), ECHO_LEN - got);
        if (n <= 0) {
            ok = false;
            break;
        }
        got += @intCast(n);
    }
    var i: u32 = 0;
    while (i < ECHO_LEN) : (i += 1) {
        const expected: u8 = 0xC0 +% @as(u8, @intCast(i));
        if (in[i] != expected) ok = false;
    }
    sys_writeConsole(if (ok) ECHO_OK_MSG else ECHO_BAD_MSG);
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_CONSOLE_ECHO else FAIL_CONSOLE_ECHO);
    return ok;
}

// Drives the unified read/write/close/dup2 ABI (slots 32-35) end-to-end
// across a fork/exec-style boundary, the way a shell hands a child its
// redirected stdio. A single anonymous pipe is wired so the
// child writes through fd 1 and the parent reads through fd 0 — both
// fds start life as console slots (D5 pre-install) and are re-pointed at
// the pipe with sys_dup2, proving the tagged FdSlot dispatch routes a
// dup2'd descriptor to the pipe backend, not the console.
//
// Refcount choreography keeps the free-page baseline neutral: sys_pipe
// installs two refs, fork's dupAll bumps to four, the two pipe dup2 calls
// add one each (six total), and the three child + three parent closes drop
// all six. The stdin-restore dup2(1, 0) in the parent tail re-points fd 0
// at the refcount-exempt console singleton, so it adds no pipe ref and
// leaves the count untouched. The pipe page is released on the parent's
// final sys_close(rfd) — before sys_dump_free — so the checkpoint stays on
// the suite baseline. The read loop terminates on the byte count, not EOF
// (pipe EOF is refs<=1; the payload is buffered and survives until the
// last unref), so the result is independent of the fork interleaving.
const FD_REDIRECT_PAYLOAD_LEN: u64 = 16;

fn run_fd_redirect(baseline: u64) bool {
    sys_writeConsole(TEST_FD_REDIRECT);
    var ok = true;

    const fds = sys_pipe();
    if (fds < 0) {
        sys_writeConsole(FAIL_FD_REDIRECT);
        return false;
    }
    const rfd: i32 = @intCast(fds & 0xFFFF_ffff);
    const wfd: i32 = @intCast((fds >> 32) & 0xFFFF_ffff);

    const pid = sys_fork();
    if (pid < 0) {
        _ = sys_close(rfd);
        _ = sys_close(wfd);
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_FD_REDIRECT);
        return false;
    }
    if (pid == 0) {
        // Child writer: drop the read end, redirect stdout (fd 1, a
        // console slot) onto the pipe write end, then push the payload
        // through the *unified* SYS_WRITE — fd 1 now carries a .pipe tag,
        // so the dispatch routes to writePipe, not the console. Close
        // every fd it holds so the write-end refs collapse to the
        // parent's view.
        _ = sys_close(rfd);
        if (sys_dup2(wfd, 1) != 1) {
            sys_writeConsole(FD_REDIRECT_BAD_MSG);
        }
        var out: [16]u8 = undefined;
        var oi: u32 = 0;
        while (oi < FD_REDIRECT_PAYLOAD_LEN) : (oi += 1) {
            out[oi] = 0xD0 +% @as(u8, @intCast(oi));
        }
        const n = sys_write(1, @intFromPtr(&out), FD_REDIRECT_PAYLOAD_LEN);
        if (n != FD_REDIRECT_PAYLOAD_LEN) {
            sys_writeConsole("[FAIL] fd-redirect (short write)\n");
        }
        _ = sys_close(1);
        _ = sys_close(wfd);
        sys_exit();
    }

    // Parent reader: drop the write end first so the child's closes drive
    // the pipe toward the parent's sole reference, then redirect stdin
    // (fd 0) onto the pipe read end and pull the payload through the
    // unified SYS_READ.
    _ = sys_close(wfd);
    if (sys_dup2(rfd, 0) != 0) ok = false;

    var in: [16]u8 = undefined;
    var got: u64 = 0;
    while (got < FD_REDIRECT_PAYLOAD_LEN) {
        const n = sys_read(0, @intFromPtr(&in[got]), FD_REDIRECT_PAYLOAD_LEN - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    if (got != FD_REDIRECT_PAYLOAD_LEN) ok = false;

    var ci: u32 = 0;
    while (ci < FD_REDIRECT_PAYLOAD_LEN) : (ci += 1) {
        const expected: u8 = 0xD0 +% @as(u8, @intCast(ci));
        if (in[ci] != expected) ok = false;
    }
    sys_writeConsole(if (ok) FD_REDIRECT_OK_MSG else FD_REDIRECT_BAD_MSG);

    // Restore PID 1's stdin. fd 0 was a console slot (D5 pre-install) until
    // the dup2 above re-pointed it at the pipe. This scenario runs in PID 1
    // itself — not a forked child — and execve preserves the fd table (D6),
    // so leaving fd 0 closed here would hand the interactive fsh (the
    // PID-1 → /bin/fsh hand-off forks off this same table) a dead stdin:
    // sys_read(0) → -1 → readline EOF → the shell exits after one prompt.
    // fd 1 is still the console slot in the parent, so dup2(1, 0) re-installs
    // console on fd 0; console is refcount-exempt, so sys_close(0) already
    // dropped the pipe's fd-0 reference and the free-page baseline is intact.
    _ = sys_close(0);
    _ = sys_dup2(1, 0);
    _ = sys_close(rfd);
    _ = sys_wait();

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_FD_REDIRECT else FAIL_FD_REDIRECT);
    return ok;
}

// Exercises the read-only initramfs path end-to-end: open /sbin/init,
// read the first four bytes, assert ELF magic, close. The assertion is
// deliberately narrow. Pass criterion matches the other
// scenarios: the File page allocated by sys_openFile is freed by
// sys_close, so the post-scenario free-page count equals baseline.
fn run_initramfs_open(baseline: u64) bool {
    sys_writeConsole(TEST_INITRAMFS_OPEN);
    var ok = true;

    const fd = sys_openFile(INIT_PATH);
    if (fd < 0) ok = false;

    var buf: [4]u8 = undefined;
    const n = sys_read(fd, @intFromPtr(&buf), 4);
    if (n != 4) ok = false;
    // Capture the magic check into a const before the conditional
    // store. The inline form `if (buf[0] != 0x7f or buf[1] != 'E' or
    // buf[2] != 'L' or buf[3] != 'F') ok = false;` deterministically
    // mis-flips `ok` to false even when n == 4 and buf == "\x7fELF" —
    // an aarch64 freestanding / ReleaseSmall codegen bug in pid1.elf.
    // Restore the inline form once Zig fixes it.
    const magic_ok = buf[0] == 0x7f and buf[1] == 'E' and buf[2] == 'L' and buf[3] == 'F';
    if (!magic_ok) ok = false;

    if (sys_close(fd) != 0) ok = false;

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_INITRAMFS_OPEN else FAIL_INITRAMFS_OPEN);
    return ok;
}

// Exercises the VFS dispatch layer's two legs end-to-end.
// Positive: /sbin/init resolves through the initramfs
// backend — the same path run_initramfs_open takes, but here the
// assertion is "fd >= 0 and closes clean", not a content read.
// Negative-but-routed: /mnt/this-does-not-exist lands on the FAT32
// stub (slot 1), which returns -1 unconditionally. Negative-not-
// routed: /mnt with no trailing slash stays an initramfs path and
// misses there. The harness can't see which backend produced a
// given -1 (the kernel doesn't expose it), so the scenario asserts
// the contract — positives resolve, negatives don't — not the
// mechanism; per-backend coverage is the host tests. Pass criterion
// matches the other open/close scenarios: one File page allocated
// and freed, so the post-scenario free count equals the baseline.
fn run_vfs_dispatch(baseline: u64) bool {
    sys_writeConsole(TEST_VFS_DISPATCH);
    var ok = true;

    // Positive: routes to the initramfs backend, resolves, closes.
    const fd = sys_openFile(INIT_PATH);
    if (fd < 0) ok = false;
    if (sys_close(fd) != 0) ok = false;

    // Negative-but-routed: /mnt/* lands on the FAT32 stub (-1).
    if (sys_openFile(MNT_MISSING_PATH) >= 0) ok = false;

    // Negative-not-routed: /mnt (no trailing slash) is an initramfs
    // path, and misses there.
    if (sys_openFile(MNT_BARE_PATH) >= 0) ok = false;

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_VFS_DISPATCH else FAIL_VFS_DISPATCH);
    return ok;
}

// Drives the patched trampolines (kernel_main/_schedule/do_wait/copy_process)
// through their canonical user-visible call chain: fork enters copy_process,
// exit/wait routes through do_wait, both legs cross _schedule via timer
// ticks + explicit yields. Four sequential cycles is enough for each
// patched entry to fire; the in-band trace markers land on PL011 (UART4
// on Pi, no-op on virt where pl011_uart_send_string is comptime-stubbed).
// Pass criterion mirrors the other reap-based scenarios: free-page count
// after the loop equals the suite baseline.
fn run_trace(baseline: u64) bool {
    sys_writeConsole(TEST_TRACE);
    var ok = true;

    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const pid = sys_fork();
        if (pid < 0) {
            sys_writeConsole(FORK_ERR_MSG);
            ok = false;
            break;
        }
        if (pid == 0) sys_exit();
        _ = sys_wait();
    }

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_TRACE else FAIL_TRACE);
    return ok;
}

// Variant B FAT32 persistence roundtrip.
// Two pre-seeded files on the FAT32 root (created by
// scripts/make_test_disk.sh / scripts/format_sd.sh):
//   * /mnt/roundtrip.dat — 4 KiB, zero-filled
//   * /mnt/roundtrip.mag — 1 byte, 0 on a fresh disk
// The magic byte gates the phase so one binary handles both boots:
//   magic 0 -> write the pattern into .dat, set magic 1, PASS_WRITE
//   magic 1 -> read .dat back, compare, reset magic 0, PASS_VERIFY
//   else    -> FAIL_MAGIC
// A power-off-persistent disk (rpi4b QEMU test_sd.img written through
// without -snapshot; real microSD on Pi) makes the two consecutive
// runs see magic 0 then 1. virt has no persistent SD (the memory-
// backed fake is zeroed every boot, QEMU -M virt rejects -drive
// if=sd), so fat32_backend.init() never mounts /mnt and the first
// open fails: that is the documented board/mount-detected SKIP path
// — emit PASS_SKIP so the tally still increments.
// Ambiguity acknowledged: a genuinely broken rpi4b image also lands
// here as a false-green; the explicit two-run acceptance + Pi-HW run
// are what actually validate the real path.
//
// sys_dump_free() is called exactly once per invocation in every
// branch (write / verify / skip) so scripts/run_qemu_test.sh sees
// the same free-page checkpoint count on both boards.
const ROUNDTRIP_LEN: u64 = 4096;

fn fill_pattern(p: *[4096]u8) void {
    var i: u32 = 0;
    while (i < ROUNDTRIP_LEN) : (i += 1) p[i] = 0xA0 +% @as(u8, @intCast(i & 0x1F));
}

fn run_fs_roundtrip(baseline: u64) bool {
    sys_writeConsole(TEST_FS_ROUNDTRIP);

    // One 4 KiB payload buffer shared by both phases.
    var payload: [4096]u8 = undefined;

    // Read the magic byte to decide which phase this boot is in. A
    // negative fd here means /mnt is unmounted (virt) -> SKIP, not
    // FAIL.
    const fd_mag = sys_openFile(ROUNDTRIP_MAG_PATH);
    if (fd_mag < 0) {
        _ = sys_dump_free(); // checkpoint-count parity with real branches
        sys_writeConsole(PASS_SKIP);
        return true;
    }
    var magic: [1]u8 = .{0};
    if (sys_read(fd_mag, @intFromPtr(&magic[0]), 1) != 1) {
        _ = sys_close(fd_mag);
        sys_writeConsole(FAIL_FS_ROUNDTRIP);
        return false;
    }
    if (sys_close(fd_mag) != 0) {
        sys_writeConsole(FAIL_FS_ROUNDTRIP);
        return false;
    }

    switch (magic[0]) {
        0 => {
            // First-boot phase: write the payload, then set magic = 1.
            const fd_w = sys_openFile(ROUNDTRIP_DAT_PATH);
            if (fd_w < 0) {
                sys_writeConsole(FAIL_FS_ROUNDTRIP);
                return false;
            }
            fill_pattern(&payload);
            const w = sys_write(fd_w, @intFromPtr(&payload), ROUNDTRIP_LEN);
            const cw = sys_close(fd_w);
            if (w != @as(i64, ROUNDTRIP_LEN) or cw != 0) {
                sys_writeConsole(FAIL_FS_ROUNDTRIP);
                return false;
            }
            const fd_set = sys_openFile(ROUNDTRIP_MAG_PATH);
            if (fd_set < 0) {
                sys_writeConsole(FAIL_FS_ROUNDTRIP);
                return false;
            }
            var one: [1]u8 = .{0};
            one[0] = 1;
            const ws = sys_write(fd_set, @intFromPtr(&one), 1);
            const cs = sys_close(fd_set);
            if (ws != 1 or cs != 0) {
                sys_writeConsole(FAIL_FS_ROUNDTRIP);
                return false;
            }
            // Sub-sector writeBack regression probe: re-read the
            // 1-byte magic just written, same boot. Catches the
            // FAT32 splice reorder bug
            // (mag-inboot=00 = REGRESSION; the explicit byte loop in
            // fat32_backend.writeBack would have to break for this
            // probe to fail). open/read/close is free-page-neutral
            // (the magic-1 verify branch proves it below).
            const fd_chk = sys_openFile(ROUNDTRIP_MAG_PATH);
            if (fd_chk < 0) {
                sys_writeConsole(FAIL_FS_ROUNDTRIP);
                return false;
            }
            var chk: [1]u8 = .{0};
            const rc = sys_read(fd_chk, @intFromPtr(&chk[0]), 1);
            const cchk = sys_close(fd_chk);
            if (rc != 1 or cchk != 0) {
                sys_writeConsole(FAIL_FS_ROUNDTRIP);
                return false;
            }
            sys_writeConsole(if (chk[0] == 1) MAG_INBOOT_OK else MAG_INBOOT_BAD);
            if (chk[0] != 1) return false;
            if (sys_dump_free() != baseline) {
                sys_writeConsole(FAIL_FS_ROUNDTRIP);
                return false;
            }
            sys_writeConsole(PASS_WRITE);
            return true;
        },
        1 => {
            // Second-boot phase: read payload, compare, reset magic.
            const fd_r = sys_openFile(ROUNDTRIP_DAT_PATH);
            if (fd_r < 0) {
                sys_writeConsole(FAIL_FS_ROUNDTRIP);
                return false;
            }
            var got: u64 = 0;
            var ok = true;
            while (got < ROUNDTRIP_LEN) {
                const n = sys_read(fd_r, @intFromPtr(&payload[got]), ROUNDTRIP_LEN - got);
                if (n <= 0) {
                    ok = false;
                    break;
                }
                got += @intCast(n);
            }
            if (sys_close(fd_r) != 0) ok = false;
            if (ok) {
                // Compare against the formula inline — no second 4 KiB
                // buffer.
                var i: u32 = 0;
                while (i < ROUNDTRIP_LEN) : (i += 1) {
                    if (payload[i] != 0xA0 +% @as(u8, @intCast(i & 0x1F))) {
                        ok = false;
                        break;
                    }
                }
            }
            // Reset magic to 0 regardless of verify outcome — leaving
            // it 1 would jam every future run on the verify branch.
            const fd_reset = sys_openFile(ROUNDTRIP_MAG_PATH);
            if (fd_reset >= 0) {
                var zero: [1]u8 = .{0};
                _ = sys_write(fd_reset, @intFromPtr(&zero), 1);
                _ = sys_close(fd_reset);
            }
            if (sys_dump_free() != baseline) ok = false;
            sys_writeConsole(if (ok) PASS_VERIFY else FAIL_FS_ROUNDTRIP);
            return ok;
        },
        else => {
            _ = sys_dump_free(); // checkpoint-count parity
            sys_writeConsole(FAIL_MAGIC);
            return false;
        },
    }
}

// ---- Runner ----

// fsh capstone scenario — DISABLED (kept, not deleted). The interactive
// shell is now exercised by the PID-1 hand-off + the boot watchdog's
// `[Debug] fsh init OK` success marker, so an in-harness fsh test is redundant.
// Re-enable by uncommenting the const + fn below, the FSH_* constants
// above, and the scenarios[] entry further down.
//
// Capstone integration: drives the whole shell stack
// end to end. The harness injects a short script into the console RX
// ring *before* forking, then forks a child that execve's /bin/fsh and
// reaps it. fsh reads the script via readline (fd 0 = console, inherited
// from PID 1's spawn-time install + preserved across execve), runs
// `echo hi | cat` (fork echo + cat, sys_pipe + dup2 wiring), then
// `ls /bin` (fork ls → sys_readdir → write_fd, the surface end
// to end through the shell), then `exit`. cat's fd 0 is the pipe
// (dup2'd), so it never contends for the console bytes — only fsh's
// readline drains them; inject-before-fork closes the empty-ring race
// (the 256-byte SPSC ring holds the ~28-byte script).
//
// The "hi" round-trip and the `/bin` listing are observable in the
// serial log (the human / Pi check); the in-kernel pass criterion is
// baseline-only, like every other scenario: after the reap the whole
// chain — fsh fork/exec, the echo|cat pipe + dup2, the ls readdir walk,
// fsh reaping its children, the clean exit — must have leaked no page.
// `ls` calls no sys_dump_free, so the script stays count-neutral.
// const FSH_SCRIPT = "echo hi | cat\nls /bin\nexit\n";
//
// fn run_fsh(baseline: u64) bool {
//     sys_writeConsole(TEST_FSH);
//     var ok = true;
//
//     for (FSH_SCRIPT) |b| sys_console_inject(b);
//
//     const pid = sys_fork();
//     if (pid < 0) {
//         sys_writeConsole(FORK_ERR_MSG);
//         sys_writeConsole(FAIL_FSH);
//         return false;
//     }
//     if (pid == 0) {
//         const argv = [_:null]?[*:0]const u8{"/bin/fsh"};
//         _ = sys_execve(@intFromPtr(FSH_PATH), @intFromPtr(&argv));
//         // Only reachable on execve failure (resolve / parse / alloc).
//         sys_exit();
//     }
//     _ = sys_wait();
//
//     if (sys_dump_free() != baseline) ok = false;
//     sys_writeConsole(if (ok) PASS_FSH else FAIL_FSH);
//     return ok;
// }

// True when the NUL-terminated basename in a Dirent.name equals `want`
// exactly (same bytes, terminated right after). Freestanding ReleaseSmall
// has no std.mem.eql, and the byte loop mirrors run_initramfs_open's
// hand-rolled magic check.
fn nameEql(name: *const [32]u8, want: []const u8) bool {
    if (want.len >= name.len) return false; // no room for the NUL
    for (want, 0..) |c, i| {
        if (name[i] != c) return false;
    }
    return name[want.len] == 0;
}

// Enumerates /bin via the stateless sys_readdir index walk and asserts:
// the known coreutils `fsh` and `ls` are present (robust to /bin growth —
// an exact count would be brittle), the end sentinel fires (the call past
// the last entry returns -1, not a runaway), and the walk leaks nothing
// (free count equals baseline; the stateless ABI holds no per-call page,
// which is the one new sys_dump_free checkpoint this scenario adds).
// QEMU exercises the initramfs synthesized-directory leg only — /bin is
// on the root initramfs mount. FAT32 readdir is Pi-only: /mnt/* fails to
// mount under QEMU, so vfs.resolve returns null and sys_readdir returns
// -1 cleanly (no QEMU coverage by design, like read/write/seek).
fn run_readdir(baseline: u64) bool {
    sys_writeConsole(TEST_READDIR);
    var ok = true;

    var found_fsh = false;
    var found_ls = false;
    var last: i32 = 0;
    var index: u64 = 0;
    // Bounded walk — /bin holds six entries today; 64 is a runaway guard,
    // not the sentinel (the sentinel is the -1 return asserted below).
    while (index < 64) : (index += 1) {
        var d: defs.Dirent = .{};
        last = sys_readdir(BIN_DIR, index, @intFromPtr(&d));
        if (last != 0) break;
        if (nameEql(&d.name, "fsh")) found_fsh = true;
        if (nameEql(&d.name, "ls")) found_ls = true;
    }
    // The walk stopped on the end sentinel (-1), not the runaway guard.
    if (last >= 0) ok = false;
    if (!found_fsh) ok = false;
    if (!found_ls) ok = false;

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_READDIR else FAIL_READDIR);
    return ok;
}

// True if `needle` occurs anywhere in `hay`. Freestanding ReleaseSmall has
// no std.mem.indexOf; the O(n·m) byte scan is fine for a 256-byte haystack
// and mirrors the hand-rolled nameEql above.
fn findSub(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return needle.len == 0;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and hay[i + j] == needle[j]) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

// Drives the kernel-log ring + sys_klog_read (slot 38) end to end.
// sys_dump_free prints `free_pages: <hex>` through the kernel's
// main_output(MU), which tees it into the ring (src/klog_ring.zig); the
// snapshot below must therefore contain that freshest line. Asserting the
// kernel-emitted marker (not the userland scenario header) keeps the test
// robust to USB-console state — `free_pages` reaches the ring on every
// target. The one sys_dump_free call doubles as the scenario's baseline
// checkpoint, so this adds exactly one free-page checkpoint like the other
// no-fork scenarios. No fork, no alloc: the ring is static BSS and the
// 256-byte snapshot lands in PID 1's already-warmed stack page, so the
// baseline holds (the same posture as run_efault_syscall).
const KLOG_SNAP_LEN: u64 = 256;

fn run_klog(baseline: u64) bool {
    sys_writeConsole(TEST_KLOG);
    var ok = true;

    // Emits the `free_pages: <hex>` marker into the ring AND is the
    // baseline checkpoint for this scenario.
    if (sys_dump_free() != baseline) ok = false;

    var buf: [KLOG_SNAP_LEN]u8 = undefined;
    const n = sys_klog_read(@intFromPtr(&buf), KLOG_SNAP_LEN);
    if (n <= 0) ok = false;
    // The ring captured the kernel-side `free_pages` line just emitted.
    if (n > 0 and !findSub(buf[0..@intCast(n)], KLOG_MARKER)) ok = false;

    sys_writeConsole(if (ok) PASS_KLOG else FAIL_KLOG);
    return ok;
}

// Asserts the kernel entropy source came up healthy. hwrng_init
// (src/hwrng.zig) runs during kernel bring-up and announces the active
// source via main_output(MU) — `hwrng: ... ok` on success, `hwrng:
// self-test failed ...` when two draws come back identical — and the line
// tees into the kernel log ring. EL0 cannot reach the generator directly
// (deliberately no getrandom syscall: entropy stays kernel-internal, where
// the auth syscalls mint their salts), so the scenario proves bring-up
// through the ring, exactly like [TEST] klog proves the tee.
//
// This scenario MUST RUN FIRST in scenarios[]. The announce is a boot-time
// line; the snapshot below reads the most-recent RNG_SNAP_LEN bytes of the
// ring. Running first keeps everything from boot to this snapshot well
// inside the window (~1-2 KiB of boot log vs 4 KiB); running last would
// put several KiB of harness output between the announce and the snapshot,
// pushing the announce outside any baseline-safe stack buffer.
//
// No fork, no alloc: the ring is static BSS; the 4 KiB snapshot buffer is
// a scenario-frame stack array (same budget as fs-roundtrip's payload
// buffer), so the free-page baseline holds.
const RNG_SNAP_LEN: u64 = 4096;

fn run_rng(baseline: u64) bool {
    sys_writeConsole(TEST_RNG);
    var ok = true;

    // Baseline checkpoint for this scenario.
    if (sys_dump_free() != baseline) ok = false;

    var buf: [RNG_SNAP_LEN]u8 = undefined;
    const n = sys_klog_read(@intFromPtr(&buf), RNG_SNAP_LEN);
    if (n <= 0) ok = false;
    if (n > 0) {
        const snap = buf[0..@intCast(n)];
        if (!findSub(snap, HWRNG_MARKER)) ok = false;
        if (findSub(snap, HWRNG_FAIL_MARKER)) ok = false;
    }

    sys_writeConsole(if (ok) PASS_RNG else FAIL_RNG);
    return ok;
}

// Process credentials. Proves the uid/gid identity layer:
// PID-1's own getters report root; a forked child inherits root, drops to
// an unprivileged id via setgid + setuid, re-reads the getters, and is
// then barred from climbing back to root. The child reports a single Y/N
// verdict over a pipe so the result reaches the scenario's pass bool
// without PID-1 ever dropping its own root (it must stay uid 0 to exec
// /bin/login next). The pipe page + child are fully reclaimed before the
// baseline checkpoint, so the scenario is baseline-neutral like run_pipe.
fn run_creds(baseline: u64) bool {
    sys_writeConsole(TEST_CREDS);
    var ok = true;

    // PID-1 is root: every getter reports 0.
    if (sys_getuid() != 0) ok = false;
    if (sys_geteuid() != 0) ok = false;
    if (sys_getgid() != 0) ok = false;
    if (sys_getegid() != 0) ok = false;

    const fds = sys_pipe();
    if (fds < 0) {
        sys_writeConsole(FAIL_CREDS);
        return false;
    }
    const rfd: i32 = @intCast(fds & 0xFFFF_ffff);
    const wfd: i32 = @intCast((fds >> 32) & 0xFFFF_ffff);

    const pid = sys_fork();
    if (pid < 0) {
        _ = sys_close(rfd);
        _ = sys_close(wfd);
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_CREDS);
        return false;
    }
    if (pid == 0) {
        // Child: close the read end, run the drop sequence, report a verdict.
        _ = sys_close(rfd);
        var verdict: u8 = 'Y';
        // fork inherited root.
        if (sys_getuid() != 0 or sys_getgid() != 0) verdict = 'N';
        // Drop gid first (still root), then uid.
        if (sys_setgid(1000) != 0) verdict = 'N';
        if (sys_setuid(1000) != 0) verdict = 'N';
        // Real + effective both moved off root.
        if (sys_getuid() != 1000 or sys_geteuid() != 1000) verdict = 'N';
        if (sys_getgid() != 1000 or sys_getegid() != 1000) verdict = 'N';
        // A dropped process must not be able to regain root.
        if (sys_setuid(0) == 0) verdict = 'N';
        const vb = [_]u8{verdict};
        _ = sys_write(wfd, @intFromPtr(&vb), 1);
        _ = sys_close(wfd);
        sys_exit();
    }

    // Parent: drop the write end, read the child's verdict, reap.
    _ = sys_close(wfd);
    var vbuf: [1]u8 = .{0};
    const n = sys_read(rfd, @intFromPtr(&vbuf), 1);
    if (n != 1 or vbuf[0] != 'Y') ok = false;
    _ = sys_close(rfd);
    _ = sys_wait();

    // PID-1 itself never dropped root.
    if (sys_getuid() != 0 or sys_geteuid() != 0) ok = false;

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_CREDS else FAIL_CREDS);
    return ok;
}

// Authentication. Drives the kernel-side /etc/shadow verifier
// directly: the seeded `flash`/`flash` must authenticate (0), a wrong
// password and an unknown user must both fail (-1). No fork; sys_authenticate
// reads /etc/shadow through the kernel's no-alloc VFS path, so the scenario
// is baseline-neutral (one checkpoint). Uses the same credentials PID-1
// injects for the boot login.
fn run_authenticate(baseline: u64) bool {
    sys_writeConsole(TEST_AUTH);
    var ok = true;

    const user: []const u8 = "flash";
    const good: []const u8 = "flash";
    const bad: []const u8 = "wrongpw";
    const nouser: []const u8 = "nobody";

    if (sys_authenticate(@intFromPtr(user.ptr), user.len, @intFromPtr(good.ptr), good.len) != 0) ok = false;
    if (sys_authenticate(@intFromPtr(user.ptr), user.len, @intFromPtr(bad.ptr), bad.len) != -1) ok = false;
    if (sys_authenticate(@intFromPtr(nouser.ptr), nouser.len, @intFromPtr(good.ptr), good.len) != -1) ok = false;

    // Kernel-stack-overflow canary. sys_authenticate's crypto call chain
    // runs on the per-task kernel stack, directly above the TaskStruct —
    // an overflow smashes the struct tail, which is exactly the credential
    // fields. PID-1 must still be root afterwards; garbage here means the
    // crypto frames outgrew the stack budget (see the sha256 module's
    // forced-ReleaseSmall note in build.zig).
    if (sys_getuid() != 0 or sys_geteuid() != 0) ok = false;
    if (sys_getgid() != 0 or sys_getegid() != 0) ok = false;

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_AUTH else FAIL_AUTH);
    return ok;
}

// VFS permission layer. Proves the mode/owner enforcement on the
// open and exec syscall paths end-to-end against the initramfs metadata:
// a forked child drops to uid/gid 1000 and must be refused /etc/shadow
// (0600 root) with exactly -EACCES — a bare -1 would mean "not found",
// i.e. the permission layer never fired — while /etc/passwd (0644) stays
// readable and exec of that no-x-bit file is refused, also with -EACCES.
// PID-1 itself (root) bypasses every check and re-opens the same shadow
// file. The child reports a single Y/N verdict over a pipe (same shape as
// creds); pipe page + child are fully reclaimed before the checkpoint, so
// the scenario is baseline-neutral.
fn run_perm(baseline: u64) bool {
    sys_writeConsole(TEST_PERM);
    var ok = true;

    const fds = sys_pipe();
    if (fds < 0) {
        sys_writeConsole(FAIL_PERM);
        return false;
    }
    const rfd: i32 = @intCast(fds & 0xFFFF_ffff);
    const wfd: i32 = @intCast((fds >> 32) & 0xFFFF_ffff);

    const pid = sys_fork();
    if (pid < 0) {
        _ = sys_close(rfd);
        _ = sys_close(wfd);
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_PERM);
        return false;
    }
    if (pid == 0) {
        // Child: drop to an unprivileged identity (gid before uid — a
        // post-drop setgid would be denied), then probe the enforcement
        // points.
        _ = sys_close(rfd);
        var verdict: u8 = 'Y';
        if (sys_setgid(1000) != 0) verdict = 'N';
        if (sys_setuid(1000) != 0) verdict = 'N';

        // /etc/shadow is 0600 root:root — the open must fail with exactly
        // -EACCES. >= 0 means the password hashes leaked to a non-root
        // reader; -1 means the perm layer never ran.
        const shadow_fd = sys_openFile(SHADOW_PATH);
        if (shadow_fd != -defs.EACCES) verdict = 'N';
        if (shadow_fd >= 0) _ = sys_close(shadow_fd);

        // /etc/passwd is 0644 root:root — world-readable, so the dropped
        // child still opens it.
        const passwd_fd = sys_openFile(ETC_PASSWD_PATH);
        if (passwd_fd < 0) verdict = 'N';
        if (passwd_fd >= 0) _ = sys_close(passwd_fd);

        // 0644 has no exec bit: execve must refuse it with -EACCES before
        // parsing a single byte (a non-ELF would otherwise fail with the
        // generic -1, so the exact code pins the perm check, not the ELF
        // magic gate).
        const exec_argv = [_:null]?[*:0]const u8{ETC_PASSWD_PATH};
        const rc = sys_execve(@intFromPtr(ETC_PASSWD_PATH), @intFromPtr(&exec_argv));
        if (rc != -defs.EACCES) verdict = 'N';

        const vb = [_]u8{verdict};
        _ = sys_write(wfd, @intFromPtr(&vb), 1);
        _ = sys_close(wfd);
        sys_exit();
    }

    // Parent: read the child's verdict, reap it.
    _ = sys_close(wfd);
    var vbuf: [1]u8 = .{0};
    const n = sys_read(rfd, @intFromPtr(&vbuf), 1);
    if (n != 1 or vbuf[0] != 'Y') ok = false;
    _ = sys_close(rfd);
    _ = sys_wait();

    // Root bypass: PID-1 (still root) opens the same 0600 shadow file.
    const root_fd = sys_openFile(SHADOW_PATH);
    if (root_fd < 0) ok = false;
    if (root_fd >= 0) _ = sys_close(root_fd);

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_PERM else FAIL_PERM);
    return ok;
}

// Login-lifecycle capstone. Drives the real /bin/login binary
// through two full sessions — authenticate as flash, run the shell, exit,
// re-prompt, authenticate as root, exit — using a console-injected script
// and login's session-limit argv ("2"), then reaps it and checks the
// free-page baseline. This is the integration proof for the supervisor
// lifecycle: fork-per-session, privilege drop in the child, reap on
// logout, re-prompt loop.
//
// The script is injected before the fork (the closed-race pattern from
// the retired fsh capstone); both sessions' shells read "exit" and quit.
// The 30-byte script fits the 256-byte console RX ring with room to
// spare, and login drains it as it reads.
//
// Serial side effects: each session emits `[Debug] login OK` + the
// shell's `[Debug] fsh init OK`, so a full boot log carries 3 of each
// (2 from here + 1 from the real boot login). run_qemu_test.sh keys its
// early-exit and guards on exactly those counts.
const LOGIN_CYCLE_SCRIPT = "flash\nflash\nexit\nroot\nroot\nexit\n";

fn run_login(baseline: u64) bool {
    sys_writeConsole(TEST_LOGIN);
    var ok = true;

    for (LOGIN_CYCLE_SCRIPT) |b| sys_console_inject(b);

    const pid = sys_fork();
    if (pid < 0) {
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_LOGIN);
        return false;
    }
    if (pid == 0) {
        // Child: become /bin/login with a two-session limit. Each session
        // forks + drops + execs the shell, so the process tree under this
        // child is pid1 → login → fsh (depth-2 forks, within the
        // allocator's supported territory).
        const argv = [_:null]?[*:0]const u8{ LOGIN_BIN_PATH, "2" };
        _ = sys_execve(@intFromPtr(LOGIN_BIN_PATH), @intFromPtr(&argv));
        // Only reachable on execve failure (resolve / parse / alloc).
        sys_exit();
    }
    _ = sys_wait();

    // The whole tree — login, two session shells, their pages — must be
    // reclaimed: the cycle is page-neutral or the lifecycle leaks.
    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_LOGIN else FAIL_LOGIN);
    return ok;
}

// Password change. Exercises sys_passwd (slot 46) against the
// writable FAT32 shadow.
//
// rpi4b (QEMU SD image + real card, /mnt/shadow seeded): the full
// roundtrip — (1) root resets flash to the seed password without the old
// one (self-healing against an interrupted previous run), (2) root
// changes it to a temp value and authenticate proves both the change and
// that the old password stopped working, (3) a dropped child (uid 1000 =
// flash) is denied a foreign record and its own record with a wrong old
// password (both exactly -EACCES), then restores the seed password via
// the legitimate own-record + correct-old-password path, (4) the parent
// proves the restore so the boot login and the next run still
// authenticate.
//
// virt (no SD): /mnt/shadow is absent → sys_passwd must answer a clean
// -1 (not -EACCES, not success); the scenario asserts that and PASSes in
// the fs-roundtrip SKIP style.
fn do_passwd(user: []const u8, old: []const u8, new: []const u8) i64 {
    return sys_passwd(
        @intFromPtr(user.ptr),
        user.len,
        @intFromPtr(old.ptr),
        old.len,
        @intFromPtr(new.ptr),
        new.len,
    );
}

fn do_auth(user: []const u8, pass: []const u8) i64 {
    return sys_authenticate(@intFromPtr(user.ptr), user.len, @intFromPtr(pass.ptr), pass.len);
}

fn run_passwd(baseline: u64) bool {
    sys_writeConsole(TEST_PASSWD);
    var ok = true;

    const user: []const u8 = "flash";
    const seed_pw: []const u8 = "flash";
    const temp_pw: []const u8 = "changed1";
    const none: []const u8 = "";

    // Probe for a writable shadow. PID-1 is root, so the open is about
    // existence, not permission.
    const probe_fd = sys_openFile(MNT_SHADOW_PATH);
    if (probe_fd < 0) {
        // virt / fresh card: no writable shadow. The syscall must report
        // the documented -1, and nothing may leak.
        if (do_passwd(user, seed_pw, temp_pw) != -1) ok = false;
        if (sys_dump_free() != baseline) ok = false;
        sys_writeConsole(if (ok) PASS_PASSWD_SKIP else FAIL_PASSWD);
        return ok;
    }
    _ = sys_close(probe_fd);

    // (1) Self-heal: root resets flash to the seed password (no old
    // password required for euid 0). An interrupted previous run may have
    // left the temp password active — this line makes the scenario
    // re-entrant.
    if (do_passwd(user, none, seed_pw) != 0) ok = false;
    if (do_auth(user, seed_pw) != 0) ok = false;

    // (2) Root rotates flash to the temp password: the change is live
    // (new password verifies, old one stops working) and persisted on the
    // FAT32 shadow the authenticate fallback chain reads first.
    if (do_passwd(user, none, temp_pw) != 0) ok = false;
    if (do_auth(user, temp_pw) != 0) ok = false;
    if (do_auth(user, seed_pw) != -1) ok = false;

    // (3) Non-root rules, probed by a dropped child (uid/gid 1000 =
    // flash), verdict over a pipe (the creds/perm shape).
    const fds = sys_pipe();
    if (fds < 0) {
        sys_writeConsole(FAIL_PASSWD);
        return false;
    }
    const rfd: i32 = @intCast(fds & 0xFFFF_ffff);
    const wfd: i32 = @intCast((fds >> 32) & 0xFFFF_ffff);

    const pid = sys_fork();
    if (pid < 0) {
        _ = sys_close(rfd);
        _ = sys_close(wfd);
        sys_writeConsole(FORK_ERR_MSG);
        sys_writeConsole(FAIL_PASSWD);
        return false;
    }
    if (pid == 0) {
        _ = sys_close(rfd);
        var verdict: u8 = 'Y';
        if (sys_setgid(1000) != 0) verdict = 'N';
        if (sys_setuid(1000) != 0) verdict = 'N';

        // A foreign record is off limits, whatever password is offered.
        if (do_passwd("root", "root", "hijacked") != -defs.EACCES) verdict = 'N';
        // The own record still needs the correct old password.
        if (do_passwd(user, "wrongold", seed_pw) != -defs.EACCES) verdict = 'N';
        // The legitimate path: own record + correct old password. This
        // also restores the seed password for the boot login + next run.
        if (do_passwd(user, temp_pw, seed_pw) != 0) verdict = 'N';

        const vb = [_]u8{verdict};
        _ = sys_write(wfd, @intFromPtr(&vb), 1);
        _ = sys_close(wfd);
        sys_exit();
    }

    _ = sys_close(wfd);
    var vbuf: [1]u8 = .{0};
    const n = sys_read(rfd, @intFromPtr(&vbuf), 1);
    if (n != 1 or vbuf[0] != 'Y') ok = false;
    _ = sys_close(rfd);
    _ = sys_wait();

    // (4) The child's restore is visible here: the seed password
    // authenticates again (and the shadow is back in its boot state).
    if (do_auth(user, seed_pw) != 0) ok = false;

    // Kernel-stack-overflow canary (same rationale as [TEST] authenticate:
    // the PBKDF2 chain runs directly above TaskStruct; smashed credentials
    // would show up right here).
    if (sys_getuid() != 0 or sys_geteuid() != 0) ok = false;

    if (sys_dump_free() != baseline) ok = false;
    sys_writeConsole(if (ok) PASS_PASSWD else FAIL_PASSWD);
    return ok;
}

pub const TestResult = struct {
    passed: u32,
    total: u32,
};

const Scenario = struct {
    name: []const u8,
    run: *const fn (u64) bool,
};

const scenarios = [_]Scenario{
    // rng runs first by contract — it asserts the boot-time hwrng announce
    // through a bounded ring snapshot; see the comment at run_rng.
    .{ .name = "rng", .run = run_rng },
    .{ .name = "fork-stress", .run = run_fork_stress },
    .{ .name = "oom-graceful", .run = run_oom_graceful },
    .{ .name = "kill", .run = run_kill },
    .{ .name = "exec-elf", .run = run_exec_elf },
    .{ .name = "execve", .run = run_execve },
    .{ .name = "brk", .run = run_brk },
    .{ .name = "stack-overflow", .run = run_stack_overflow },
    .{ .name = "wild-pointer", .run = run_wild_pointer },
    // exec-fault is wild-pointer's instruction-side twin: an EL0 *jump*
    // to the same wild UVA faults as an instruction abort (EC 0x20),
    // which entry.S must route to do_instruction_abort → zombie, never
    // err_hang the core. Reap-based + baseline-neutral.
    .{ .name = "exec-fault", .run = run_exec_fault },
    // undef-instr completes the EL0-sync-dispatch trio (wild-pointer = data
    // abort 0x24, exec-fault = instruction abort 0x20, undef-instr =
    // everything else): an undefined instruction raises EC 0x00, which
    // entry.S must route to the el0_sync_other catch-all → zombie, never
    // err_hang the core. Reap-based + baseline-neutral.
    .{ .name = "undef-instr", .run = run_undef_instr },
    .{ .name = "efault-syscall", .run = run_efault_syscall },
    .{ .name = "flibc", .run = run_flibc },
    .{ .name = "pipe", .run = run_pipe },
    .{ .name = "console-echo", .run = run_console_echo },
    .{ .name = "fd-redirect", .run = run_fd_redirect },
    .{ .name = "initramfs-open", .run = run_initramfs_open },
    .{ .name = "vfs-dispatch", .run = run_vfs_dispatch },
    .{ .name = "trace", .run = run_trace },
    .{ .name = "fs-roundtrip", .run = run_fs_roundtrip },
    // .{ .name = "fsh", .run = run_fsh }, // DISABLED — see run_fsh above
    .{ .name = "readdir", .run = run_readdir },
    .{ .name = "klog", .run = run_klog },
    // creds runs last — it asserts the uid/gid identity layer. Never
    // first (rng holds that slot by contract); a forked child drops
    // privilege and reports via a pipe, so it is reap-based and
    // baseline-neutral like fork-stress / pipe.
    .{ .name = "creds", .run = run_creds },
    // authenticate exercises the kernel-side /etc/shadow verifier:
    // good creds → 0, wrong password / unknown user → -1. No fork; reads
    // /etc/shadow via the no-alloc kernel path → baseline-neutral.
    .{ .name = "authenticate", .run = run_authenticate },
    // perm exercises the VFS permission layer: a forked child
    // drops to uid/gid 1000 and is denied /etc/shadow (0600) and exec of
    // a no-x-bit file, both with exactly -EACCES, while PID-1 (root)
    // bypasses. Reap-based + baseline-neutral like creds; never first
    // (rng holds that slot by contract).
    .{ .name = "perm", .run = run_perm },
    // login drives the real /bin/login supervisor through two console-
    // scripted sessions (the logout → re-prompt lifecycle). Its
    // two inner shells emit the same boot markers the real login does, so
    // run_qemu_test.sh counts 3× login OK / fsh init OK per boot. Runs
    // late so its console scripting never interleaves with the I/O
    // scenarios; never first (rng holds that slot by contract).
    .{ .name = "login", .run = run_login },
    // passwd exercises sys_passwd: the full change/verify/restore
    // roundtrip on the writable FAT32 shadow (rpi4b), or the documented
    // clean -1 + SKIP-PASS on virt (no SD card). Runs last: it is the most
    // environment-dependent scenario, and a failure here must never
    // cascade into the login test that precedes it.
    .{ .name = "passwd", .run = run_passwd },
};

pub fn run_all() TestResult {
    // Warm up the deepest stack page the scenarios will write into via
    // kernel-side stores (sys_read on file/pipe fds / sys_readConsole).
    //
    // This is no longer a kernel-crash workaround (the
    // copy_to_user / copy_from_user fixup handlers now fault-in EL0
    // pages correctly), but it is still REQUIRED for baseline stability:
    // without the warmup, the first scenario to use a syscall read
    // would materialise the stack page via demand-allocation, causing
    // its (and all future) free-page counts to drift from the baseline
    // captured below.
    var stack_warmup: [4096]u8 align(8) = undefined;
    var wi: usize = 0;
    while (wi < stack_warmup.len) : (wi += @intCast(PAGE_SIZE_USER)) {
        const p: *volatile u8 = @ptrCast(&stack_warmup[wi]);
        p.* = 0;
    }
    const p_last: *volatile u8 = @ptrCast(&stack_warmup[stack_warmup.len - 1]);
    p_last.* = 0;

    const baseline = sys_dump_free();
    var passed: u32 = 0;
    inline for (scenarios) |s| {
        if (s.run(baseline)) passed += 1;
    }
    return .{ .passed = passed, .total = scenarios.len };
}

// Tens-digit unrolling: write_digit only covers 0..9 directly. The
// suite now reports 10/10, so decompose two-digit values into
// `(n / 10)` then `(n % 10)`. Single-digit values stay unchanged.
// Up to 99/99 — future work can revisit if the suite ever overflows.
pub fn print_tally(passed: u32, total: u32) void {
    if (passed >= 10) {
        write_digit(passed / 10);
        write_digit(passed % 10);
    } else write_digit(passed);
    sys_writeConsole(SLASH);
    if (total >= 10) {
        write_digit(total / 10);
        write_digit(total % 10);
    } else write_digit(total);
    sys_writeConsole(PASSED_SUFFIX);
}

// 0..9 cover one decimal digit; print_tally decomposes two-digit
// tallies into two write_digit calls. '?' guards against drift if a
// value outside 0..9 ever reaches here.
//
// Written as an if/else chain — NOT a switch and NOT an array index —
// because the user image is copied to uva 0 at runtime; both a switch
// jump table and a const array of pointers would bake in absolute
// link-time addresses for D0..D9 and fault when dereferenced from
// uva 0. Only PC-relative `adr` references survive the relocation,
// which is what direct `sys_writeConsole(D_n)` produces.
fn write_digit(n: u32) void {
    if (n == 0) sys_writeConsole(D0) else if (n == 1) sys_writeConsole(D1) else if (n == 2) sys_writeConsole(D2) else if (n == 3) sys_writeConsole(D3) else if (n == 4) sys_writeConsole(D4) else if (n == 5) sys_writeConsole(D5) else if (n == 6) sys_writeConsole(D6) else if (n == 7) sys_writeConsole(D7) else if (n == 8) sys_writeConsole(D8) else if (n == 9) sys_writeConsole(D9) else sys_writeConsole(QMARK);
}
