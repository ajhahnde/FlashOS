# 8. Rust Userland and the Initramfs

FlashOS runs ordinary ELF64 programs at EL0. They are Rust `no_std` static
libraries linked with explicit user linker scripts and packaged into a
deterministic initramfs.

## Building the filesystem image

`xtask/src/build.rs` builds every program under `user/`, inspects the ELF,
strips it, and stages it under its runtime path. `xtask/src/initramfs.rs`
encodes the sorted staging tree as a deterministic newc CPIO archive.

Checked-in seed files come from `rootfs/`:

```text
rootfs/etc/passwd   → /etc/passwd
rootfs/fsh/fshrc    → /etc/fshrc
generated shadow    → /etc/shadow
user/pid1           → /sbin/init
user/fsh            → /bin/fsh
user/* tools        → /bin/* and /test/*
```

`rootfs/etc/perms.tab` is the third checked-in seed. It is deployed to the
FAT32 volume as `PERMS.TAB`, not embedded in the read-only initramfs.

Programs are staged as mode `0755`, public configuration as `0644`, and shadow
as `0600`, owned by root. The archive is embedded by `tools/initramfs.S` and
served read-only by `crates/kernel/src/initramfs_backend.rs`.

## The runtime boundary

The FlashSDK `flashsdk-rt` crate supplies the `_start`-side EL0 runtime, panic
path, memory intrinsics, and raw SVC transport. The loader enters a program with
a stack containing `argc`, the `argv` pointer array, and NUL-terminated argument
strings.

A teaching-sized entry shape looks like this:

```rust
#[no_mangle]
pub extern "C" fn main(argc: usize, argv: *const *const u8) -> i32 {
    // inspect arguments through bounded userland helpers
    0
}
```

The exact exported symbol and panic glue are supplied by each user crate and
the FlashSDK `flashsdk-rt` crate; inspect the real crate before treating a
simplified snippet as linkable code.

## `flibc`

`crates/flibc/` is the current Rust mini-libc. It provides:

- formatted and raw I/O;
- process and file syscall wrappers;
- a bump heap over `brk`/`sbrk`;
- readline, history, and completion;
- key decoding and TUI rendering;
- pager, gap-buffer, and grep-match cores.

It is part of the current in-repository implementation, not yet a stable
external SDK. The post-Rust-port FlashSDK work will define the narrow public
boundary and make the kernel consume that canonical ABI.

## Loading PID 1

The kernel finds `/sbin/init` through the VFS and maps its ELF segments with
permissions derived from their program headers. `user/pid1/src/lib.rs` runs
the optional boot-selftest harness, then replaces itself with `/bin/login`.

Four dedicated fixtures under `/test` exercise argument transfer, runtime I/O,
fork pressure, and stack failure paths without becoming user-facing commands.

> [!NOTE]
> The root `src/` directory does not contain the initramfs parser or user
> programs. Kernel filesystem code is under `crates/kernel/`; EL0 programs are
> under `user/`; static seeds are under `rootfs/`.

Next, we follow PID 1 through authentication and privilege dropping.
