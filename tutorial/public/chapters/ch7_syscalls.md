# 7. Syscalls and Exception Entry

An EL0 program cannot call a kernel Rust function directly. It places the
syscall number in `x8`, arguments in `x0` through `x5`, and executes `svc #0`.

The raw wrappers live in `crates/user-rt/src/syscall.rs`. Exception entry lives
in `arch/aarch64/entry.S`; handler logic and the relocated dispatch table live
in `crates/kernel/src/sys.rs`.

## Entry frame

The vector saves a 272-byte `KeRegs` frame on the current task's dedicated
kernel stack. It validates that `x8 < 56`, looks up the relocated function
pointer, invokes the handler, places the return value back in the saved frame,
and restores state for `eret`.

```text
EL0 wrapper
  → svc #0
  → vector saves KeRegs
  → bounds check x8
  → Rust handler table
  → result in x0
  → eret to EL0
```

## ABI ownership

`crates/abi/src/syscall.rs` defines syscall IDs and shared value types such as
`Dirent`. It is an internal repository ABI today. It also contains some
assembly-visible and kernel-adjacent data that must not automatically become a
future public contract.

The planned FlashSDK will extract a narrow public syscall/userspace ABI,
runtime, base library, and target-and-link contract only after the Rust-port
release. Private task records, saved frames, VFS objects, and descriptor
internals stay private.

## Current syscall groups

| Slots | Purpose |
| :---- | :------ |
| 1–13 | process lifecycle, open/seek, heap, diagnostics |
| 18 | anonymous pipe |
| 25–26, 30 | console mode and test input seam |
| 31 | path-resolved ELF `execve` |
| 32–35 | unified `read`, `write`, `close`, `dup2` |
| 36–38, 48 | CWD, `readdir`, kernel log, `getcwd` |
| 39–47 | credentials, auth, password change, reboot |
| 49–52 | memory, uptime, CPU temperature/frequency |
| 53–55 | FAT32 create, unlink, rename |

Retired slots return an error rather than silently changing meaning. Reserved
slots remain stubs.

## User pointers are data, not references

Handlers use bounded copy helpers to validate and prefault complete user
ranges. An invalid pointer produces an error such as `EFAULT`; it must not be
converted into a trusted Rust reference or allowed to fault deep inside the
kernel.

Synchronous aborts decode ESR and the fault address. Legal heap and stack
translation faults can be recovered; terminal invalid entries print
`ERROR CAUGHT`, a hard watchdog failure.

> [!CAUTION]
> The kernel stack is only one 4 KiB page, with the saved frame at its top.
> Large syscall-local values are a correctness risk; substantial scratch data
> belongs in bounded dedicated storage.

Next, we inspect what the ELF loader hands to a Rust user program.
