//! Read-only VFS backend over the embedded initramfs archive.

use crate::file::File;
use crate::initramfs::{self, Iterator};
use crate::vfs::{self, FsType, OpenResult, SuperBlock, VfsOps};
use core::cell::UnsafeCell;
use core::ffi::c_int;

const READDIR_PREFIX_MAX: usize = 256;
#[cfg(target_os = "none")]
const LINEAR_MAP_BASE: usize = 0xFFFF_0000_0000_0000;

struct Global<T>(UnsafeCell<T>);

// SAFETY: these records are mutated once during single-core bring-up, before
// EL0 and interrupts can dispatch through them, and are immutable thereafter.
unsafe impl<T> Sync for Global<T> {}

static SUPERBLOCK: Global<SuperBlock> = Global(UnsafeCell::new(SuperBlock::new(FsType::Initramfs)));
static OPS: Global<VfsOps> = Global(UnsafeCell::new(VfsOps {
    open: Some(open_callback),
    read: Some(read_callback),
    seek: Some(seek_callback),
    close: Some(close_callback),
    write: Some(write_erofs),
    readdir: Some(readdir_callback),
    create: Some(create_erofs),
    unlink: Some(unlink_erofs),
    rename: Some(rename_erofs),
}));

#[cfg(target_os = "none")]
unsafe extern "C" {
    static __initramfs_start: u8;
    static __initramfs_end: u8;
}

#[cfg(target_os = "none")]
fn production_archive() -> &'static [u8] {
    let low_start = core::ptr::addr_of!(__initramfs_start) as usize;
    let low_end = core::ptr::addr_of!(__initramfs_end) as usize;
    let len = low_end - low_start;
    let high_start = (low_start | LINEAR_MAP_BASE) as *const u8;
    // SAFETY: linker bounds enclose the immutable `.initramfs` section, and the
    // TTBR1 alias maps the same physical bytes for the kernel lifetime.
    unsafe { core::slice::from_raw_parts(high_start, len) }
}

#[cfg(not(target_os = "none"))]
fn production_archive() -> &'static [u8] {
    &[]
}

/// Wire the Rust-owned initramfs vtable and root superblock.
///
/// # Safety
/// Called once during single-core kernel bring-up after TTBR1 is active.
pub unsafe fn init() {
    let ops = OPS.0.get();
    // SAFETY: one-time bring-up owns the mutable vtable.
    unsafe { vfs::relocate_ops(ops) };
    let superblock = SUPERBLOCK.0.get();
    // SAFETY: one-time bring-up owns the mutable superblock.
    unsafe { (*superblock).ops = ops };
    // SAFETY: both statics live for the kernel lifetime.
    unsafe { vfs::register_initramfs(superblock) };
}

pub fn locate_production(
    path: &[u8],
) -> Result<Option<initramfs::Entry<'static>>, initramfs::ParseError> {
    initramfs::locate(production_archive(), path)
}

pub fn production_archive_base() -> *const u8 {
    production_archive().as_ptr()
}

pub fn open_archive(archive: &[u8], path: &[u8], out: &mut OpenResult) -> c_int {
    let Ok(Some(entry)) = initramfs::locate(archive, path) else {
        return -1;
    };
    out.private = entry.data.as_ptr() as u64;
    out.size = entry.data.len() as u64;
    out.mode = entry.mode;
    out.uid = entry.uid;
    out.gid = entry.gid;
    0
}

extern "C" fn open_callback(
    _: *mut SuperBlock,
    path: *const u8,
    path_len: usize,
    out: *mut OpenResult,
) -> c_int {
    // SAFETY: VFS supplies a live path and output record for the call.
    let path = unsafe { core::slice::from_raw_parts(path, path_len) };
    // SAFETY: VFS supplies exclusive output storage.
    open_archive(production_archive(), path, unsafe { &mut *out })
}

extern "C" fn read_callback(_: *mut SuperBlock, file: *mut File, buffer: *mut u8, len: u64) -> i64 {
    // SAFETY: the VFS owns a live file and `len` writable output bytes.
    unsafe { read(file, buffer, len) }
}

/// # Safety
/// `file` is live and `buffer` points to `len` writable bytes.
pub unsafe fn read(file: *mut File, buffer: *mut u8, len: u64) -> i64 {
    let offset = unsafe { (*file).offset };
    let size = unsafe { (*file).size };
    if offset >= size {
        return 0;
    }
    let count = len.min(size - offset);
    let source = unsafe { (*file).private as *const u8 };
    let mut index = 0u64;
    while index < count {
        // SAFETY: bounds follow from the live File size/offset contract and the
        // caller-provided destination length.
        unsafe {
            buffer
                .add(index as usize)
                .write(source.add((offset + index) as usize).read())
        };
        index += 1;
    }
    unsafe { (*file).offset = offset + count };
    count as i64
}

extern "C" fn seek_callback(_: *mut SuperBlock, file: *mut File, off: i64, whence: i32) -> i64 {
    // SAFETY: VFS supplies a live file.
    unsafe { seek(file, off, whence) }
}

/// # Safety
/// `file` points to a live writable `File`.
pub unsafe fn seek(file: *mut File, off: i64, whence: i32) -> i64 {
    let current = unsafe { (*file).offset } as i64;
    let size = unsafe { (*file).size } as i64;
    let target = match whence {
        0 => Some(off),
        1 => current.checked_add(off),
        2 => size.checked_add(off),
        _ => None,
    };
    let Some(target) = target else { return -1 };
    if target < 0 || target > size {
        return -1;
    }
    unsafe { (*file).offset = target as u64 };
    target
}

extern "C" fn close_callback(_: *mut SuperBlock, _: *mut File) {}
extern "C" fn write_erofs(_: *mut SuperBlock, _: *mut File, _: *const u8, _: u64) -> i64 {
    -1
}
extern "C" fn create_erofs(
    _: *mut SuperBlock,
    _: *const u8,
    _: usize,
    _: *mut OpenResult,
) -> c_int {
    -1
}
extern "C" fn unlink_erofs(_: *mut SuperBlock, _: *const u8, _: usize) -> c_int {
    -1
}
extern "C" fn rename_erofs(
    _: *mut SuperBlock,
    _: *const u8,
    _: usize,
    _: *const u8,
    _: usize,
) -> c_int {
    -1
}

extern "C" fn readdir_callback(
    _: *mut SuperBlock,
    path: *const u8,
    path_len: usize,
    index: u64,
    out: *mut vfs::Dirent,
) -> c_int {
    // SAFETY: VFS supplies live input and output storage.
    let path = unsafe { core::slice::from_raw_parts(path, path_len) };
    // SAFETY: VFS supplies exclusive output storage.
    readdir_archive(production_archive(), path, index, unsafe { &mut *out })
}

pub fn readdir_archive(archive: &[u8], path: &[u8], index: u64, out: &mut vfs::Dirent) -> c_int {
    let mut prefix_buffer = [0u8; READDIR_PREFIX_MAX];
    let prefix = if path == b"/" {
        path
    } else {
        let Some(end) = path.len().checked_add(1) else {
            return -1;
        };
        if end > prefix_buffer.len() {
            return -1;
        }
        prefix_buffer[..path.len()].copy_from_slice(path);
        prefix_buffer[path.len()] = b'/';
        &prefix_buffer[..end]
    };

    let mut iterator = Iterator::new(archive);
    let mut emitted = 0u64;
    let mut last_child: &[u8] = &[];
    let mut have_last = false;
    loop {
        let entry = match iterator.next_entry() {
            Ok(Some(entry)) => entry,
            Ok(None) => break,
            Err(_) => return -1,
        };
        let Some(direct) = initramfs::direct_entry(entry.name, prefix) else {
            continue;
        };
        if have_last && direct.child == last_child {
            continue;
        }
        last_child = direct.child;
        have_last = true;
        if emitted == index {
            *out = vfs::Dirent::default();
            let count = direct.child.len().min(out.name.len() - 1);
            out.name[..count].copy_from_slice(&direct.child[..count]);
            out.d_type = if direct.is_dir {
                vfs::DT_DIR
            } else {
                vfs::DT_REG
            };
            return 0;
        }
        emitted += 1;
    }
    -1
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{format, vec::Vec};

    fn hex(out: &mut Vec<u8>, value: u32) {
        out.extend_from_slice(format!("{value:08X}").as_bytes());
    }
    fn entry(out: &mut Vec<u8>, name: &[u8], data: &[u8], mode: u32, uid: u32, gid: u32) {
        out.extend_from_slice(b"070701");
        hex(out, 1);
        hex(out, mode);
        hex(out, uid);
        hex(out, gid);
        hex(out, 1);
        hex(out, 0);
        hex(out, data.len() as u32);
        for _ in 0..4 {
            hex(out, 0);
        }
        hex(out, (name.len() + 1) as u32);
        hex(out, 0);
        out.extend_from_slice(name);
        out.push(0);
        while out.len() & 3 != 0 {
            out.push(0);
        }
        out.extend_from_slice(data);
        while out.len() & 3 != 0 {
            out.push(0);
        }
    }
    type FixtureEntry<'a> = (&'a [u8], &'a [u8], u32, u32, u32);

    fn fixture(entries: &[FixtureEntry<'_>]) -> Vec<u8> {
        let mut out = Vec::new();
        for (name, data, mode, uid, gid) in entries {
            entry(&mut out, name, data, *mode, *uid, *gid);
        }
        entry(&mut out, b"TRAILER!!!", b"", 0, 0, 0);
        out
    }

    #[test]
    fn open_read_and_seek_round_trip() {
        let archive = fixture(&[(b"hello", b"world", 0o100644, 1000, 1000)]);
        let mut result = OpenResult::default();
        assert_eq!(open_archive(&archive, b"hello", &mut result), 0);
        assert_eq!(
            (result.size, result.mode, result.uid, result.gid),
            (5, 0o100644, 1000, 1000)
        );
        let mut file = File {
            refs: 1,
            size: result.size,
            private: result.private,
            ..File::default()
        };
        let mut buffer = [0u8; 5];
        assert_eq!(unsafe { read(&raw mut file, buffer.as_mut_ptr(), 5) }, 5);
        assert_eq!(&buffer, b"world");
        assert_eq!(unsafe { seek(&raw mut file, 0, 0) }, 0);
        assert_eq!(unsafe { read(&raw mut file, buffer.as_mut_ptr(), 3) }, 3);
        assert_eq!(&buffer[..3], b"wor");
    }

    #[test]
    fn readdir_synthesizes_directories_and_collapses_adjacent_duplicates() {
        let archive = fixture(&[
            (b"/bin/cat", b"C", 0o100755, 0, 0),
            (b"/bin/echo", b"E", 0o100755, 0, 0),
            (b"/etc/fshrc", b"F", 0o100644, 0, 0),
            (b"/sbin/init", b"I", 0o100755, 0, 0),
        ]);
        let mut out = vfs::Dirent::default();
        assert_eq!(readdir_archive(&archive, b"/", 0, &mut out), 0);
        assert_eq!(&out.name[..3], b"bin");
        assert_eq!(out.d_type, vfs::DT_DIR);
        assert_eq!(readdir_archive(&archive, b"/", 1, &mut out), 0);
        assert_eq!(&out.name[..3], b"etc");
        assert_eq!(readdir_archive(&archive, b"/", 2, &mut out), 0);
        assert_eq!(&out.name[..4], b"sbin");
        assert_eq!(readdir_archive(&archive, b"/", 3, &mut out), -1);
        assert_eq!(readdir_archive(&archive, b"/bin", 0, &mut out), 0);
        assert_eq!(&out.name[..3], b"cat");
        assert_eq!(out.d_type, vfs::DT_REG);
        assert_eq!(readdir_archive(&archive, b"/bin", 1, &mut out), 0);
        assert_eq!(&out.name[..4], b"echo");
        assert_eq!(readdir_archive(&archive, b"/bin", 2, &mut out), -1);
    }
}
