# Chapter 11: Files — VFS & FAT32

Every `open` in the last three chapters — `/etc/passwd`, `/etc/shadow`,
a program's own ELF bytes — has quietly crossed a dispatch layer this
chapter finally opens up. FlashOS mounts two very different backing
stores under one path namespace: the initramfs chapter 8 already
covered, and a real FAT32 filesystem on the SD card. Neither backend
knows the other exists; a thin vtable-based shim in between is what
makes `open("/mnt/foo")` and `open("/bin/ls")` look like the same call
to everything above it.

## Two mounts, one prefix check

```text
| Path prefix     | Slot | Backend                                  |
| :--------------- | :--: | :---------------------------------------- |
| /mnt/…           |  1   | FAT32 — src/fat32_backend.flash            |
| everything else  |  0   | initramfs — src/initramfs_backend.flash    |
```

`src/vfs.zig` owns a fixed two-slot mount table and a single
`startsWith("/mnt/")` branch — nothing more elaborate. initramfs is
mounted at `/`; FAT32 mounts at `/mnt`, and the system still boots if
the SD card is missing or unreadable, since the root filesystem never
depends on it. The trailing slash in `/mnt/` is load-bearing: `/mnt2/foo`
resolves as an initramfs path, and `/mnt` with no trailing slash does
too. `sys_mount`, longest-prefix matching beyond this one split, and
path normalization (`..`, relative components) are all future work —
the shim is deliberately as small as the two-backend reality requires
today.

## The `VfsOps` vtable

Each backend exposes the same six-to-nine-entry function-pointer table,
declared once in `src/vfs.zig` (one of the handful of modules that stay
plain Zig rather than Flash — the project map calls out boot assembly
and a few low-level modules as the deliberate exceptions):

```text
pub const VfsOps = extern struct {
    open: *const fn (sb: *SuperBlock, path_ptr: [*]const u8, path_len: usize, out: *OpenResult) callconv(.c) c_int,
    read: *const fn (sb: *SuperBlock, f: *File, buf: [*]u8, len: u64) callconv(.c) i64,
    seek: *const fn (sb: *SuperBlock, f: *File, off: i64, whence: i32) callconv(.c) i64,
    close: *const fn (sb: *SuperBlock, f: *File) callconv(.c) void,
    write: *const fn (sb: *SuperBlock, f: *File, buf: [*]const u8, len: u64) callconv(.c) i64,
    readdir: *const fn (sb: *SuperBlock, path_ptr: [*]const u8, path_len: usize, index: u64, out: *Dirent) callconv(.c) c_int = defaultReaddir,
    create: *const fn (sb: *SuperBlock, path_ptr: [*]const u8, path_len: usize, out: *OpenResult) callconv(.c) c_int = defaultCreate,
    unlink: *const fn (sb: *SuperBlock, path_ptr: [*]const u8, path_len: usize) callconv(.c) c_int = defaultUnlink,
    rename: *const fn (sb: *SuperBlock, old_ptr: [*]const u8, old_len: usize, new_ptr: [*]const u8, new_len: usize) callconv(.c) c_int = defaultRename,
}
```

*(excerpt from `src/vfs.zig` — not standalone-compilable)*

`create`/`unlink`/`rename` default to an EROFS stub, so a read-only
backend like initramfs needs to implement nothing to stay safely
non-destructive — it simply never overrides them. `vfs_open` resolves a
path, dispatches through the matching backend's `open`, and stashes the
backing `SuperBlock` pointer on the `File` handle; `sys_read` /
`sys_write` / `sys_seek` / `sys_close` re-cast that pointer and call
back through the same vtable. The path crosses the boundary as a raw
`ptr + len` pair rather than a Flash/Zig slice, because `callconv(.c)`
functions have no guaranteed in-memory slice representation to agree
on across a function-pointer call — the same ABI discipline chapter 7
required at the syscall boundary applies again one layer up.

## FAT32: create, unlink, rename

`src/fat32_backend.flash` decodes the BPB, FAT, and root directory once
at `init()`, then walks and mutates the cluster chain for every
operation. Syscalls 53–55 (`SYS_CREATE`, `SYS_UNLINK`, `SYS_RENAME`)
round out the file-metadata surface beyond ordinary read/write — files
only, and rename is same-directory only:

```flash
fn create(_ *mut vfs.SuperBlock, path_ptr [*]u8, path_len usize, out *mut vfs.OpenResult) callconv(.c) c_int {
    const path = path_ptr[0..path_len]
    const rel = if (path.len > 0 && path[0] == '/') path[1..] else path
    const sp = splitBasename(rel)
    if (sp.base.len == 0) { return -1 } // trailing slash / empty name
    const parent_cluster = resolveParentCluster(sp.parent) orelse return -1
    const name8_3 = fat32.encode8_3(sp.base) orelse return -1
    if (probeExists(parent_cluster, name8_3) != 0) { return -1 }
    const slot = fat32.findFreeDirSlot(&mount_info, parent_cluster) catch return -1
    fat32.writeDirEntry(&mount_info, slot.lba, slot.byte_offset, name8_3, fat32.ATTR_ARCHIVE, 0, 0) catch return -1
    out.private = 0 // empty file: no first cluster until the first write
    // …
    return 0
}
```

*(excerpt from `src/fat32_backend.flash` — not standalone-compilable)*

`create` finds or extends a free 8.3 directory slot and stamps an empty
entry; `unlink` tombstones the entry (byte `0xE5`, the classic FAT
deleted-entry marker) and frees its cluster chain — writing the
tombstone *before* freeing the chain, so a crash between the two steps
leaks clusters (recoverable by an fsck-style scan) rather than leaving
a live directory entry pointing at freed storage; `rename` rewrites the
8.3 name in place with no data move, refusing a cross-directory target
(that is `mv`'s copy-plus-unlink job at the coreutil layer, not the
backend's). There is no long-filename support — on-device Flash source
files use a 3-character `.fl` extension rather than `.flash`, because
`.flash` does not fit an 8.3 short name and `fat32.encode8_3` rejects
anything that doesn't.

`create`/`unlink`/`rename` are validated on **real Pi-4 hardware only**:
QEMU's `-M raspi4b` machine does not model the BCM2711 EMMC2/Arasan
SDHCI controller well enough to complete the SD initialization sequence
(`CMD8`), so `fat32_backend.init()` never runs under either QEMU board,
and `/mnt` simply stays unmounted there. `zig build test` covers
`src/fat32.flash`'s pure decode units on the host, but the write path
itself only ever runs on the real board.

## Directory enumeration without a directory inode

`sys_readdir` (slot 37) is a stateless `(path, index, *Dirent)` walk —
no `opendir` handle, no per-fd cursor. Each call resolves `path` afresh
and returns the `index`-th entry, which costs nothing to allocate: the
caller just increments `index` and calls again until it gets `-1`. That
statelessness is a deliberate trade — a POSIX `opendir`/fd-cursor shape
would need either a synthetic directory `File` or a scratch page
allocation to free on close, and this walk introduces no new site for a
future OOM audit to track.

The two backends synthesize a listing very differently, because neither
one has a real directory inode to enumerate:

- **initramfs** is a flat cpio archive — there is no `/bin` entry, only
  `/bin/cat`, `/bin/echo`, and so on. `readdir` derives the listing from
  path prefixes: for a directory `path` it walks the archive, and for
  each entry takes the single path segment following `path`'s prefix —
  a direct child surfaces as `DT_REG`, a deeper entry contributes its
  first segment as a synthetic `DT_DIR`. The result is sorted, so
  duplicate synthetic subdirectories collapse with one de-dup pass.
- **FAT32** reuses the real root-directory walk — 16 entries per sector,
  skipping deleted (`0xE5`), long-name, and volume-label entries — and
  renders the surviving 8.3 name through `fat32.decode8_3`. Only the
  mount root enumerates in this release; a subdirectory listing would
  need a directory-cluster walk that has not been built yet, so a
  non-root FAT32 path lists empty rather than erroring.

`ls`, the first real consumer of `sys_readdir`, is a small coreutil
built entirely on this call: `readdir(path, i, &d)` from `i = 0` until
it returns `-1`, printing each basename with a `/` suffix on `DT_DIR`.
Run with no argument it lists the current `cwd`. `ls /mnt` is the
simplest end-to-end proof that a real FAT32 card mounted successfully —
it walks the exact root-directory decode path this section just
described, entry by entry, and there is no faster way to see whether
`/mnt` came up than reading its output.

## What's next

Reading and writing files is one half of "programs that do things
visibly" — chapter 12 covers the other half: taking over the whole
screen. `less` and `edit` are the first FlashOS programs that leave
line-at-a-time output behind for an alternate screen, raw keystrokes,
and — for `edit` — the first real exercise of the userland heap this
tour has seen.
