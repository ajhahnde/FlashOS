//! Two-mount VFS dispatch and its fixed callback ABI.

use crate::file::File;
use core::cell::UnsafeCell;
use core::ffi::c_int;
use core::mem::{align_of, offset_of, size_of};

pub use flashos_abi::syscall::{Dirent, DT_DIR, DT_REG};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum FsType {
    Initramfs = 0,
    Fat32 = 1,
}

#[repr(C)]
pub struct SuperBlock {
    pub fs_type: u8,
    pub _pad: [u8; 7],
    pub private: u64,
    pub ops: *const VfsOps,
}

impl SuperBlock {
    pub const fn new(fs_type: FsType) -> Self {
        Self {
            fs_type: fs_type as u8,
            _pad: [0; 7],
            private: 0,
            ops: core::ptr::null(),
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct OpenResult {
    pub private: u64,
    pub size: u64,
    pub mode: u32,
    pub uid: u32,
    pub gid: u32,
    pub dirent_lba: u32,
    pub dirent_off: u32,
}

pub type OpenFn = extern "C" fn(*mut SuperBlock, *const u8, usize, *mut OpenResult) -> c_int;
pub type ReadFn = extern "C" fn(*mut SuperBlock, *mut File, *mut u8, u64) -> i64;
pub type SeekFn = extern "C" fn(*mut SuperBlock, *mut File, i64, i32) -> i64;
pub type CloseFn = extern "C" fn(*mut SuperBlock, *mut File);
pub type WriteFn = extern "C" fn(*mut SuperBlock, *mut File, *const u8, u64) -> i64;
pub type ReaddirFn = extern "C" fn(*mut SuperBlock, *const u8, usize, u64, *mut Dirent) -> c_int;
pub type CreateFn = extern "C" fn(*mut SuperBlock, *const u8, usize, *mut OpenResult) -> c_int;
pub type UnlinkFn = extern "C" fn(*mut SuperBlock, *const u8, usize) -> c_int;
pub type RenameFn = extern "C" fn(*mut SuperBlock, *const u8, usize, *const u8, usize) -> c_int;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct VfsOps {
    pub open: Option<OpenFn>,
    pub read: Option<ReadFn>,
    pub seek: Option<SeekFn>,
    pub close: Option<CloseFn>,
    pub write: Option<WriteFn>,
    pub readdir: Option<ReaddirFn>,
    pub create: Option<CreateFn>,
    pub unlink: Option<UnlinkFn>,
    pub rename: Option<RenameFn>,
}

impl VfsOps {
    pub const fn read_only(
        open: OpenFn,
        read: ReadFn,
        seek: SeekFn,
        close: CloseFn,
        write: WriteFn,
        readdir: ReaddirFn,
    ) -> Self {
        Self {
            open: Some(open),
            read: Some(read),
            seek: Some(seek),
            close: Some(close),
            write: Some(write),
            readdir: Some(readdir),
            create: Some(default_create),
            unlink: Some(default_unlink),
            rename: Some(default_rename),
        }
    }
}

extern "C" fn default_create(
    _: *mut SuperBlock,
    _: *const u8,
    _: usize,
    _: *mut OpenResult,
) -> c_int {
    -1
}

extern "C" fn default_unlink(_: *mut SuperBlock, _: *const u8, _: usize) -> c_int {
    -1
}

extern "C" fn default_rename(
    _: *mut SuperBlock,
    _: *const u8,
    _: usize,
    _: *const u8,
    _: usize,
) -> c_int {
    -1
}

const LINEAR_MAP_BASE: usize = 0xFFFF_0000_0000_0000;

/// Re-point every non-null callback to its TTBR1 high-half alias.
///
/// # Safety
/// `ops` points to a live writable vtable whose entries are linked kernel
/// functions. The caller invokes this only for the high-half production image.
pub unsafe fn relocate_ops(ops: *mut VfsOps) {
    macro_rules! relocate {
        ($field:ident, $ty:ty) => {
            // SAFETY: `ops` is live and writable by the function contract.
            if let Some(function) = unsafe { (*ops).$field } {
                let address = function as usize | LINEAR_MAP_BASE;
                // SAFETY: OR-ing the linear-map base preserves the linked code
                // offset and yields the callable TTBR1 alias.
                let high: $ty = unsafe { core::mem::transmute::<usize, $ty>(address) };
                unsafe { (*ops).$field = Some(high) };
            }
        };
    }
    relocate!(open, OpenFn);
    relocate!(read, ReadFn);
    relocate!(seek, SeekFn);
    relocate!(close, CloseFn);
    relocate!(write, WriteFn);
    relocate!(readdir, ReaddirFn);
    relocate!(create, CreateFn);
    relocate!(unlink, UnlinkFn);
    relocate!(rename, RenameFn);
}

pub struct MountTable {
    slots: [*mut SuperBlock; 2],
}

impl MountTable {
    pub const fn new() -> Self {
        Self {
            slots: [core::ptr::null_mut(); 2],
        }
    }

    /// Install the root superblock.
    ///
    /// # Safety
    /// `sb` must point to a live, writable superblock that remains valid while
    /// it is registered in this table.
    pub unsafe fn register_initramfs(&mut self, sb: *mut SuperBlock) {
        // SAFETY: registration requires a live writable superblock.
        unsafe { (*sb).fs_type = FsType::Initramfs as u8 };
        self.slots[0] = sb;
    }

    /// Install the `/mnt` superblock.
    ///
    /// # Safety
    /// `sb` must point to a live, writable superblock that remains valid while
    /// it is registered in this table.
    pub unsafe fn register_fat32(&mut self, sb: *mut SuperBlock) {
        // SAFETY: registration requires a live writable superblock.
        unsafe { (*sb).fs_type = FsType::Fat32 as u8 };
        self.slots[1] = sb;
    }

    pub fn resolve<'a>(&self, path: &'a [u8]) -> Option<Resolved<'a>> {
        const MNT_PREFIX: &[u8] = b"/mnt/";
        if path.starts_with(MNT_PREFIX) {
            let sb = self.slots[1];
            if sb.is_null() {
                return None;
            }
            return Some(Resolved {
                sb,
                sub_path: &path[MNT_PREFIX.len() - 1..],
            });
        }
        let sb = self.slots[0];
        if sb.is_null() {
            None
        } else {
            Some(Resolved { sb, sub_path: path })
        }
    }
}

impl Default for MountTable {
    fn default() -> Self {
        Self::new()
    }
}

pub struct Resolved<'a> {
    pub sb: *mut SuperBlock,
    pub sub_path: &'a [u8],
}

/// Audited mutable global for the boot-wired mount table. FlashOS is
/// uniprocessor; both slots are registered during bring-up before EL0 runs, and
/// later callers only read them under the existing preemption discipline.
struct Global<T>(UnsafeCell<T>);

// SAFETY: the invariant above serializes mutation and excludes concurrent
// access. `Global` is deliberately private to this module.
unsafe impl<T> Sync for Global<T> {}

static MOUNT_TABLE: Global<MountTable> = Global(UnsafeCell::new(MountTable::new()));

/// # Safety
/// `sb` is live for the lifetime of the kernel and registration occurs during
/// single-core bring-up.
pub unsafe fn register_initramfs(sb: *mut SuperBlock) {
    // SAFETY: guaranteed by the caller and the global invariant.
    unsafe { (*MOUNT_TABLE.0.get()).register_initramfs(sb) };
}

/// # Safety
/// Same contract as [`register_initramfs`].
pub unsafe fn register_fat32(sb: *mut SuperBlock) {
    // SAFETY: guaranteed by the caller and the global invariant.
    unsafe { (*MOUNT_TABLE.0.get()).register_fat32(sb) };
}

fn global_table() -> &'static MountTable {
    // SAFETY: mount mutations finish before EL0 dispatch starts; thereafter the
    // table is immutable for the lifetime of the kernel.
    unsafe { &*MOUNT_TABLE.0.get() }
}

/// Dispatch an open through the registered mount table.
///
/// # Safety
/// `out` must be writable for one [`OpenResult`]. Registered superblocks and
/// callback tables must satisfy the lifetime contract of registration.
pub unsafe fn open(path: &[u8], out: *mut OpenResult) -> *mut SuperBlock {
    open_in(global_table(), path, out)
}

pub fn open_in(table: &MountTable, path: &[u8], out: *mut OpenResult) -> *mut SuperBlock {
    let Some(resolved) = table.resolve(path) else {
        return core::ptr::null_mut();
    };
    // SAFETY: a registered superblock is live for the kernel lifetime.
    let ops = unsafe { (*resolved.sb).ops };
    if ops.is_null() {
        return core::ptr::null_mut();
    }
    // SAFETY: registered vtable is live and fixed-layout.
    let Some(callback) = (unsafe { (*ops).open }) else {
        return core::ptr::null_mut();
    };
    if callback(
        resolved.sb,
        resolved.sub_path.as_ptr(),
        resolved.sub_path.len(),
        out,
    ) < 0
    {
        core::ptr::null_mut()
    } else {
        resolved.sb
    }
}

/// Dispatch a file read.
///
/// # Safety
/// `sb` and `file` must be live records from a successful open, and `buffer`
/// must be writable for `len` bytes.
pub unsafe fn read(sb: *mut SuperBlock, file: *mut File, buffer: *mut u8, len: u64) -> i64 {
    let ops = unsafe { (*sb).ops };
    if ops.is_null() {
        return -1;
    }
    match unsafe { (*ops).read } {
        Some(callback) => callback(sb, file, buffer, len),
        None => -1,
    }
}

/// Dispatch a file seek.
///
/// # Safety
/// `sb` and `file` must be live records from a successful open.
pub unsafe fn seek(sb: *mut SuperBlock, file: *mut File, off: i64, whence: i32) -> i64 {
    let ops = unsafe { (*sb).ops };
    if ops.is_null() {
        return -1;
    }
    match unsafe { (*ops).seek } {
        Some(callback) => callback(sb, file, off, whence),
        None => -1,
    }
}

/// Dispatch a file close.
///
/// # Safety
/// `sb` and `file` must be live records from a successful open.
pub unsafe fn close(sb: *mut SuperBlock, file: *mut File) {
    let ops = unsafe { (*sb).ops };
    if !ops.is_null() {
        if let Some(callback) = unsafe { (*ops).close } {
            callback(sb, file);
        }
    }
}

/// Dispatch a file write.
///
/// # Safety
/// `sb` and `file` must be live records from a successful open, and `buffer`
/// must be readable for `len` bytes.
pub unsafe fn write(sb: *mut SuperBlock, file: *mut File, buffer: *const u8, len: u64) -> i64 {
    let ops = unsafe { (*sb).ops };
    if ops.is_null() {
        return -1;
    }
    match unsafe { (*ops).write } {
        Some(callback) => callback(sb, file, buffer, len),
        None => -1,
    }
}

/// Dispatch a directory read through the registered mount table.
///
/// # Safety
/// `out` must be writable for one [`Dirent`].
pub unsafe fn readdir(path: &[u8], index: u64, out: *mut Dirent) -> c_int {
    readdir_in(global_table(), path, index, out)
}

pub fn readdir_in(table: &MountTable, path: &[u8], index: u64, out: *mut Dirent) -> c_int {
    let Some(resolved) = table.resolve(path) else {
        return -1;
    };
    // SAFETY: registered records are live.
    let ops = unsafe { (*resolved.sb).ops };
    if ops.is_null() {
        return -1;
    }
    match unsafe { (*ops).readdir } {
        Some(callback) => callback(
            resolved.sb,
            resolved.sub_path.as_ptr(),
            resolved.sub_path.len(),
            index,
            out,
        ),
        None => -1,
    }
}

/// Dispatch a file create through the registered mount table.
///
/// # Safety
/// `out` must be writable for one [`OpenResult`].
pub unsafe fn create(path: &[u8], out: *mut OpenResult) -> *mut SuperBlock {
    create_in(global_table(), path, out)
}

pub fn create_in(table: &MountTable, path: &[u8], out: *mut OpenResult) -> *mut SuperBlock {
    let Some(resolved) = table.resolve(path) else {
        return core::ptr::null_mut();
    };
    // SAFETY: registered records are live.
    let ops = unsafe { (*resolved.sb).ops };
    if ops.is_null() {
        return core::ptr::null_mut();
    }
    let Some(callback) = (unsafe { (*ops).create }) else {
        return core::ptr::null_mut();
    };
    if callback(
        resolved.sb,
        resolved.sub_path.as_ptr(),
        resolved.sub_path.len(),
        out,
    ) < 0
    {
        core::ptr::null_mut()
    } else {
        resolved.sb
    }
}

/// Dispatch an unlink through the registered mount table.
///
/// # Safety
/// Registered superblocks and callback tables must satisfy the lifetime
/// contract of registration.
pub unsafe fn unlink(path: &[u8]) -> c_int {
    unlink_in(global_table(), path)
}

pub fn unlink_in(table: &MountTable, path: &[u8]) -> c_int {
    let Some(resolved) = table.resolve(path) else {
        return -1;
    };
    // SAFETY: registered records are live.
    let ops = unsafe { (*resolved.sb).ops };
    if ops.is_null() {
        return -1;
    }
    match unsafe { (*ops).unlink } {
        Some(callback) => callback(
            resolved.sb,
            resolved.sub_path.as_ptr(),
            resolved.sub_path.len(),
        ),
        None => -1,
    }
}

/// Dispatch a same-mount rename through the registered mount table.
///
/// # Safety
/// Registered superblocks and callback tables must satisfy the lifetime
/// contract of registration.
pub unsafe fn rename(old: &[u8], new: &[u8]) -> c_int {
    rename_in(global_table(), old, new)
}

pub fn rename_in(table: &MountTable, old: &[u8], new: &[u8]) -> c_int {
    let Some(old_resolved) = table.resolve(old) else {
        return -1;
    };
    let Some(new_resolved) = table.resolve(new) else {
        return -1;
    };
    if old_resolved.sb != new_resolved.sb {
        return -1;
    }
    // SAFETY: registered records are live.
    let ops = unsafe { (*old_resolved.sb).ops };
    if ops.is_null() {
        return -1;
    }
    match unsafe { (*ops).rename } {
        Some(callback) => callback(
            old_resolved.sb,
            old_resolved.sub_path.as_ptr(),
            old_resolved.sub_path.len(),
            new_resolved.sub_path.as_ptr(),
            new_resolved.sub_path.len(),
        ),
        None => -1,
    }
}

const _: () = {
    assert!(size_of::<SuperBlock>() == 24);
    assert!(align_of::<SuperBlock>() == 8);
    assert!(offset_of!(SuperBlock, fs_type) == 0);
    assert!(offset_of!(SuperBlock, private) == 8);
    assert!(offset_of!(SuperBlock, ops) == 16);
    assert!(size_of::<OpenResult>() == 40);
    assert!(align_of::<OpenResult>() == 8);
    assert!(offset_of!(OpenResult, private) == 0);
    assert!(offset_of!(OpenResult, size) == 8);
    assert!(offset_of!(OpenResult, mode) == 16);
    assert!(offset_of!(OpenResult, uid) == 20);
    assert!(offset_of!(OpenResult, gid) == 24);
    assert!(offset_of!(OpenResult, dirent_lba) == 28);
    assert!(offset_of!(OpenResult, dirent_off) == 32);
    assert!(size_of::<VfsOps>() == 72);
    assert!(align_of::<VfsOps>() == 8);
    assert!(offset_of!(VfsOps, open) == 0);
    assert!(offset_of!(VfsOps, read) == 8);
    assert!(offset_of!(VfsOps, seek) == 16);
    assert!(offset_of!(VfsOps, close) == 24);
    assert!(offset_of!(VfsOps, write) == 32);
    assert!(offset_of!(VfsOps, readdir) == 40);
    assert!(offset_of!(VfsOps, create) == 48);
    assert!(offset_of!(VfsOps, unlink) == 56);
    assert!(offset_of!(VfsOps, rename) == 64);
};

#[cfg(test)]
mod tests {
    use super::*;

    extern "C" fn fake_open(
        _: *mut SuperBlock,
        path: *const u8,
        len: usize,
        out: *mut OpenResult,
    ) -> c_int {
        // SAFETY: test dispatch supplies a live path and output.
        let path = unsafe { core::slice::from_raw_parts(path, len) };
        if path != b"/hit" {
            return -1;
        }
        // SAFETY: test dispatch supplies a live output.
        unsafe {
            out.write(OpenResult {
                private: 0xABCD,
                size: 7,
                mode: 0o100640,
                uid: 1,
                gid: 2,
                ..OpenResult::default()
            })
        };
        0
    }
    extern "C" fn fake_read(_: *mut SuperBlock, file: *mut File, _: *mut u8, _: u64) -> i64 {
        unsafe { (*file).private as i64 }
    }
    extern "C" fn fake_seek(_: *mut SuperBlock, _: *mut File, _: i64, _: i32) -> i64 {
        -1
    }
    extern "C" fn fake_close(_: *mut SuperBlock, _: *mut File) {}
    extern "C" fn fake_write(_: *mut SuperBlock, file: *mut File, _: *const u8, _: u64) -> i64 {
        unsafe { (*file).private as i64 }
    }
    extern "C" fn fake_readdir(
        _: *mut SuperBlock,
        path: *const u8,
        len: usize,
        index: u64,
        out: *mut Dirent,
    ) -> c_int {
        let path = unsafe { core::slice::from_raw_parts(path, len) };
        if path != b"/" || index != 0 {
            return -1;
        }
        let mut entry = Dirent::default();
        entry.name[..3].copy_from_slice(b"bin");
        entry.d_type = DT_DIR;
        unsafe { out.write(entry) };
        0
    }
    extern "C" fn fake_create(
        _: *mut SuperBlock,
        path: *const u8,
        len: usize,
        out: *mut OpenResult,
    ) -> c_int {
        let path = unsafe { core::slice::from_raw_parts(path, len) };
        if path != b"/new" {
            return -1;
        }
        unsafe {
            out.write(OpenResult {
                mode: 0o100644,
                uid: 3,
                gid: 4,
                dirent_lba: 6,
                dirent_off: 64,
                ..OpenResult::default()
            })
        };
        0
    }
    extern "C" fn fake_unlink(_: *mut SuperBlock, path: *const u8, len: usize) -> c_int {
        -i32::from(unsafe { core::slice::from_raw_parts(path, len) } != b"/gone")
    }
    extern "C" fn fake_rename(
        _: *mut SuperBlock,
        old: *const u8,
        old_len: usize,
        new: *const u8,
        new_len: usize,
    ) -> c_int {
        let old = unsafe { core::slice::from_raw_parts(old, old_len) };
        let new = unsafe { core::slice::from_raw_parts(new, new_len) };
        if old == b"/a" && new == b"/b" {
            0
        } else {
            -1
        }
    }

    static OPS: VfsOps = VfsOps {
        open: Some(fake_open),
        read: Some(fake_read),
        seek: Some(fake_seek),
        close: Some(fake_close),
        write: Some(fake_write),
        readdir: Some(fake_readdir),
        create: Some(fake_create),
        unlink: Some(fake_unlink),
        rename: Some(fake_rename),
    };
    static READONLY: VfsOps = VfsOps::read_only(
        fake_open,
        fake_read,
        fake_seek,
        fake_close,
        fake_write,
        fake_readdir,
    );

    fn table() -> (MountTable, SuperBlock, SuperBlock) {
        (
            MountTable::new(),
            SuperBlock::new(FsType::Initramfs),
            SuperBlock::new(FsType::Fat32),
        )
    }

    fn register_root(table: &mut MountTable, sb: &mut SuperBlock) {
        // SAFETY: every test keeps the stack-owned superblock alive while the
        // table is used.
        unsafe { table.register_initramfs(sb) };
    }

    fn register_mnt(table: &mut MountTable, sb: &mut SuperBlock) {
        // SAFETY: every test keeps the stack-owned superblock alive while the
        // table is used.
        unsafe { table.register_fat32(sb) };
    }

    #[test]
    fn resolve_mnt_prefix_to_slot_one_and_strip_it() {
        let (mut t, mut root, mut fat) = table();
        register_root(&mut t, &mut root);
        register_mnt(&mut t, &mut fat);
        let r = t.resolve(b"/mnt/foo").unwrap();
        assert_eq!(r.sb, &raw mut fat);
        assert_eq!(r.sub_path, b"/foo");
    }
    #[test]
    fn resolve_other_path_to_root() {
        let (mut t, mut root, mut fat) = table();
        register_root(&mut t, &mut root);
        register_mnt(&mut t, &mut fat);
        let r = t.resolve(b"/sbin/init").unwrap();
        assert_eq!(r.sb, &raw mut root);
        assert_eq!(r.sub_path, b"/sbin/init");
    }
    #[test]
    fn resolve_empty_target_slot_is_none() {
        let (mut t, _root, mut fat) = table();
        register_mnt(&mut t, &mut fat);
        assert!(t.resolve(b"/anything").is_none());
    }
    #[test]
    fn resolve_mnt_without_slash_as_root() {
        let (mut t, mut root, mut fat) = table();
        register_root(&mut t, &mut root);
        register_mnt(&mut t, &mut fat);
        assert_eq!(t.resolve(b"/mnt").unwrap().sb, &raw mut root);
    }
    #[test]
    fn resolve_mnt2_as_root() {
        let (mut t, mut root, mut fat) = table();
        register_root(&mut t, &mut root);
        register_mnt(&mut t, &mut fat);
        assert_eq!(t.resolve(b"/mnt2/foo").unwrap().sb, &raw mut root);
    }
    #[test]
    fn open_dispatches_and_threads_result() {
        let (mut t, mut root, _) = table();
        root.ops = &raw const OPS;
        register_root(&mut t, &mut root);
        let mut out = OpenResult::default();
        assert_eq!(open_in(&t, b"/hit", &raw mut out), &raw mut root);
        assert_eq!(
            (out.private, out.size, out.mode, out.uid, out.gid),
            (0xABCD, 7, 0o100640, 1, 2)
        );
        assert!(open_in(&t, b"/miss", &raw mut out).is_null());
    }
    #[test]
    fn open_without_vtable_is_null() {
        let (mut t, mut root, _) = table();
        register_root(&mut t, &mut root);
        let mut out = OpenResult::default();
        assert!(open_in(&t, b"/anything", &raw mut out).is_null());
    }
    #[test]
    fn read_threads_file_private() {
        let mut root = SuperBlock::new(FsType::Initramfs);
        root.ops = &raw const OPS;
        let mut file = File {
            private: 0x1234,
            ..File::default()
        };
        assert_eq!(
            unsafe { read(&raw mut root, &raw mut file, core::ptr::null_mut(), 0) },
            0x1234
        );
    }
    #[test]
    fn read_and_seek_without_vtable_fail() {
        let mut root = SuperBlock::new(FsType::Initramfs);
        let mut file = File::default();
        assert_eq!(
            unsafe { read(&raw mut root, &raw mut file, core::ptr::null_mut(), 0) },
            -1
        );
        assert_eq!(unsafe { seek(&raw mut root, &raw mut file, 0, 0) }, -1);
    }
    #[test]
    fn write_threads_file_private() {
        let mut root = SuperBlock::new(FsType::Initramfs);
        root.ops = &raw const OPS;
        let mut file = File {
            private: 0x5678,
            ..File::default()
        };
        assert_eq!(
            unsafe { write(&raw mut root, &raw mut file, core::ptr::null(), 0) },
            0x5678
        );
    }
    #[test]
    fn write_without_vtable_fails() {
        let mut root = SuperBlock::new(FsType::Initramfs);
        let mut file = File::default();
        assert_eq!(
            unsafe { write(&raw mut root, &raw mut file, core::ptr::null(), 0) },
            -1
        );
    }
    #[test]
    fn readdir_dispatches_and_fills_dirent() {
        let (mut t, mut root, _) = table();
        root.ops = &raw const OPS;
        register_root(&mut t, &mut root);
        let mut out = Dirent::default();
        assert_eq!(readdir_in(&t, b"/", 0, &raw mut out), 0);
        assert_eq!(&out.name[..3], b"bin");
        assert_eq!(out.d_type, DT_DIR);
        assert_eq!(readdir_in(&t, b"/", 1, &raw mut out), -1);
    }
    #[test]
    fn readdir_without_vtable_fails() {
        let (mut t, mut root, _) = table();
        register_root(&mut t, &mut root);
        let mut out = Dirent::default();
        assert_eq!(readdir_in(&t, b"/", 0, &raw mut out), -1);
    }
    #[test]
    fn create_dispatches_and_threads_result() {
        let (mut t, mut root, _) = table();
        root.ops = &raw const OPS;
        register_root(&mut t, &mut root);
        let mut out = OpenResult::default();
        assert_eq!(create_in(&t, b"/new", &raw mut out), &raw mut root);
        assert_eq!(
            (out.uid, out.gid, out.dirent_lba, out.dirent_off),
            (3, 4, 6, 64)
        );
        assert!(create_in(&t, b"/miss", &raw mut out).is_null());
    }
    #[test]
    fn create_without_vtable_is_null() {
        let (mut t, mut root, _) = table();
        register_root(&mut t, &mut root);
        let mut out = OpenResult::default();
        assert!(create_in(&t, b"/new", &raw mut out).is_null());
    }
    #[test]
    fn unlink_dispatches() {
        let (mut t, mut root, _) = table();
        root.ops = &raw const OPS;
        register_root(&mut t, &mut root);
        assert_eq!(unlink_in(&t, b"/gone"), 0);
        assert_eq!(unlink_in(&t, b"/still-here"), -1);
    }
    #[test]
    fn rename_dispatches_same_mount() {
        let (mut t, mut root, _) = table();
        root.ops = &raw const OPS;
        register_root(&mut t, &mut root);
        assert_eq!(rename_in(&t, b"/a", b"/b"), 0);
        assert_eq!(rename_in(&t, b"/a", b"/c"), -1);
    }
    #[test]
    fn rename_rejects_cross_mount() {
        let (mut t, mut root, mut fat) = table();
        root.ops = &raw const OPS;
        fat.ops = &raw const OPS;
        register_root(&mut t, &mut root);
        register_mnt(&mut t, &mut fat);
        assert_eq!(rename_in(&t, b"/a", b"/mnt/b"), -1);
    }
    #[test]
    fn readonly_write_side_defaults_fail_closed() {
        let (mut t, mut root, _) = table();
        root.ops = &raw const READONLY;
        register_root(&mut t, &mut root);
        let mut out = OpenResult::default();
        assert!(create_in(&t, b"/new", &raw mut out).is_null());
        assert_eq!(unlink_in(&t, b"/gone"), -1);
        assert_eq!(rename_in(&t, b"/a", b"/b"), -1);
    }
}
