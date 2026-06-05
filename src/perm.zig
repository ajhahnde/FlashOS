// perm: Unix discretionary access check.
//
// Pure, allocation-free, no externs. The single decision function the
// syscall layer calls before handing a file to userland: sys_openFile
// (read intent), the sys_write file arm (write intent), and execve
// (exec intent) all funnel through checkAccess with the caller's
// effective ids and the file's mode/owner reported by the VFS backend.
//
// Model (deliberately lean):
//   * Root bypass — euid 0 is allowed everything, including exec of a
//     file with no x bit set (real Unix wants at least one x bit for
//     root exec; this layer grants it unconditionally — documented
//     simplification, revisit if setuid binaries ever land).
//   * First-match triad — owner if euid matches, else group if egid
//     matches, else other. The matching triad alone decides: an owner
//     denied by the owner bits stays denied even if the group or other
//     bits would allow (classic System V semantics, no fall-through).
//   * Only the low 9 permission bits participate; the file-type bits of
//     a full mode word (0o100644-style cpio modes) are masked off.
//
// Kernel-internal VFS opens (sys_authenticate reading /etc/shadow, the
// execve ELF streamer) never call this — they are the privileged door.
// Enforcement lives at the syscall boundary only.

pub const Access = enum(u8) { read, write, exec };

// Decide whether a caller with effective ids (euid, egid) may perform
// `want` on a file owned by (file_uid, file_gid) with permission word
// `mode`. Pure bit selection — no side effects, no globals.
pub fn checkAccess(
    mode: u32,
    file_uid: u32,
    file_gid: u32,
    euid: u32,
    egid: u32,
    want: Access,
) bool {
    // Root bypasses the bit check entirely.
    if (euid == 0) return true;

    // File-type bits (S_IFREG etc.) never participate in the decision.
    const bits = mode & 0o777;

    // Pick the triad: owner, else group, else other — first match wins
    // and is authoritative.
    const shift: u5 = if (euid == file_uid)
        6
    else if (egid == file_gid)
        3
    else
        0;

    const bit: u32 = switch (want) {
        .read => 0o4,
        .write => 0o2,
        .exec => 0o1,
    };

    return (bits >> shift) & bit != 0;
}

// ---- Host tests ----
//
// The truth table below is the gate for the permission layer: no
// enforcement site ships until every row passes. Rows mirror the
// roadmap acceptance line (/etc/shadow 0600: non-root denied, root ok)
// plus the selection rules that are easy to get silently wrong.
const std = @import("std");
const expect = std.testing.expect;

test "checkAccess: root bypasses every want regardless of mode" {
    // mode 0 grants nothing, yet euid 0 passes all three intents —
    // even on a file owned by somebody else.
    try expect(checkAccess(0, 0, 0, 0, 0, .read));
    try expect(checkAccess(0, 0, 0, 0, 0, .write));
    try expect(checkAccess(0, 0, 0, 0, 0, .exec));
    try expect(checkAccess(0, 1000, 1000, 0, 0, .read));
    try expect(checkAccess(0, 1000, 1000, 0, 1000, .write));
}

test "checkAccess: owner read honours the owner read bit" {
    try expect(checkAccess(0o600, 1000, 1000, 1000, 1000, .read));
    try expect(checkAccess(0o600, 1000, 1000, 1000, 1000, .write));
    try expect(!checkAccess(0o600, 1000, 1000, 1000, 1000, .exec));
}

test "checkAccess: owner triad wins even when it denies and group would allow" {
    // 0o060: owner has nothing, group has rw. A caller who is both the
    // owner and in the group is still denied — the owner triad is
    // authoritative, there is no fall-through to friendlier triads.
    try expect(!checkAccess(0o060, 1000, 1000, 1000, 1000, .read));
    try expect(!checkAccess(0o060, 1000, 1000, 1000, 1000, .write));
}

test "checkAccess: group triad when egid matches and euid does not" {
    try expect(checkAccess(0o640, 0, 1000, 1000, 1000, .read));
    try expect(!checkAccess(0o640, 0, 1000, 1000, 1000, .write));
    try expect(!checkAccess(0o640, 0, 1000, 1000, 1000, .exec));
}

test "checkAccess: other triad when neither uid nor gid matches" {
    try expect(checkAccess(0o644, 0, 0, 1000, 1000, .read));
    try expect(!checkAccess(0o644, 0, 0, 1000, 1000, .write));
    try expect(!checkAccess(0o644, 0, 0, 1000, 1000, .exec));
}

test "checkAccess: exec bit gates exec independently of read" {
    try expect(!checkAccess(0o644, 0, 0, 1000, 1000, .exec));
    try expect(checkAccess(0o755, 0, 0, 1000, 1000, .exec));
    // Write stays denied on 0o755 for non-owners even though exec is
    // granted — the bits are independent.
    try expect(!checkAccess(0o755, 0, 0, 1000, 1000, .write));
}

test "checkAccess: shadow 0600 denies a non-owner non-root reader" {
    // The acceptance line of the permission layer: /etc/shadow is
    // 0o600 root:root — uid 1000 read denied, root read allowed.
    try expect(!checkAccess(0o600, 0, 0, 1000, 1000, .read));
    try expect(!checkAccess(0o600, 0, 0, 1000, 1000, .write));
    try expect(checkAccess(0o600, 0, 0, 0, 0, .read));
}

test "checkAccess: passwd 0644 allows any reader but denies non-owner write" {
    try expect(checkAccess(0o644, 0, 0, 1000, 1000, .read));
    try expect(!checkAccess(0o644, 0, 0, 1000, 1000, .write));
    // A non-root owner writes through the owner bit (no bypass needed).
    try expect(checkAccess(0o644, 1000, 1000, 1000, 1000, .write));
}

test "checkAccess: file-type bits above 0o777 are ignored" {
    // Full cpio modes (0o100644-style) behave exactly like their low
    // 9 bits in every triad.
    try expect(checkAccess(0o100600, 1000, 1000, 1000, 1000, .read));
    try expect(!checkAccess(0o100600, 0, 0, 1000, 1000, .read));
    try expect(checkAccess(0o100755, 0, 0, 1000, 1000, .exec));
    try expect(!checkAccess(0o100644, 0, 0, 1000, 1000, .exec));
}
