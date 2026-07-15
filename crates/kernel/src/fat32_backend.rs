//! Writable FAT32 VFS backend over the board-provided block-device callbacks.
//!
//! The backend is allocation free. A single mounted volume, superblock,
//! callback table, overlay table, and I/O sector buffer live for the kernel
//! lifetime. FlashOS is single-core, and every VFS dispatch is bracketed by
//! the existing preemption exclusion, so the shared mutable records cannot be
//! entered concurrently.

use crate::block_dev::BlockDev;
use crate::fat32::{self, FoundEntry, Mount, SectorBuf};
use crate::file::File;
use crate::overlay::{self, Entry};
use crate::vfs::{self, FsType, OpenResult, SuperBlock, VfsOps};
use core::cell::UnsafeCell;
use core::ffi::c_int;
use core::mem::MaybeUninit;

const FAT32_PARTITION_LBA: u32 = 2048;
const OVERLAY_NAME: &[u8] = b"perms.tab";
const SHADOW_NAME: &[u8] = b"shadow";
const OVERLAY_BUFFER_LEN: usize = 1024;

struct Global<T>(UnsafeCell<T>);

// SAFETY: all mutation occurs during single-core bring-up or under the VFS
// preemption bracket described in the module documentation.
unsafe impl<T> Sync for Global<T> {}

static SUPERBLOCK: Global<SuperBlock> = Global(UnsafeCell::new(SuperBlock::new(FsType::Fat32)));
static OPS: Global<VfsOps> = Global(UnsafeCell::new(VfsOps {
    open: Some(open_callback),
    read: Some(read_callback),
    seek: Some(seek_callback),
    close: Some(close_callback),
    write: Some(write_callback),
    readdir: Some(readdir_callback),
    create: Some(create_callback),
    unlink: Some(unlink_callback),
    rename: Some(rename_callback),
}));
static MOUNT: Global<MaybeUninit<Mount>> = Global(UnsafeCell::new(MaybeUninit::uninit()));
static OVERLAY_OK: Global<bool> = Global(UnsafeCell::new(false));
static OVERLAY_COUNT: Global<usize> = Global(UnsafeCell::new(0));
const EMPTY_OVERLAY_ENTRY: Entry = Entry {
    name_buf: [0; overlay::MAX_NAME],
    name_len: 0,
    mode: 0,
    uid: 0,
    gid: 0,
};
static OVERLAY_ENTRIES: Global<[Entry; overlay::MAX_ENTRIES]> =
    Global(UnsafeCell::new([EMPTY_OVERLAY_ENTRY; overlay::MAX_ENTRIES]));
static OVERLAY_BUFFER: Global<[u8; OVERLAY_BUFFER_LEN]> =
    Global(UnsafeCell::new([0; OVERLAY_BUFFER_LEN]));
static IO_SECTOR: Global<SectorBuf> = Global(UnsafeCell::new([0; 512]));

fn mount_ptr() -> *mut Mount {
    MOUNT.0.get().cast::<Mount>()
}

fn superblock_ptr() -> *mut SuperBlock {
    SUPERBLOCK.0.get()
}

fn io_sector() -> &'static mut SectorBuf {
    // SAFETY: VFS dispatch serialization excludes concurrent use, and no
    // backend callback nests another backend callback.
    unsafe { &mut *IO_SECTOR.0.get() }
}

fn mounted() -> &'static Mount {
    // SAFETY: callbacks become reachable only after `init` writes MOUNT and
    // registers the superblock. Tests install a mount before calling helpers.
    unsafe { &*mount_ptr() }
}

fn mounted_mut() -> &'static mut Mount {
    // SAFETY: the VFS preemption bracket gives each callback exclusive access
    // to the mount record. Bring-up and tests are single-thread serialized.
    unsafe { &mut *mount_ptr() }
}

fn read_sector(lba: u32, sector: &mut SectorBuf) -> Result<(), ()> {
    let dev = mounted().dev;
    if dev.is_null() {
        return Err(());
    }
    // SAFETY: the mounted-volume contract keeps the callback record live.
    let callback = unsafe { (*dev).read_fn }.ok_or(())?;
    if callback(lba, sector) == 0 {
        Ok(())
    } else {
        Err(())
    }
}

fn write_sector(lba: u32, sector: &SectorBuf) -> Result<(), ()> {
    let dev = mounted().dev;
    if dev.is_null() {
        return Err(());
    }
    // SAFETY: the mounted-volume contract keeps the callback record live.
    let callback = unsafe { (*dev).write_fn }.ok_or(())?;
    if callback(lba, sector) == 0 {
        Ok(())
    } else {
        Err(())
    }
}

/// Mount the board-provided SD device and register `/mnt`.
///
/// # Safety
/// Called once during single-core bring-up after the board has initialized
/// `dev`; the record and its callbacks remain live for the kernel lifetime.
pub unsafe fn init(dev: *mut BlockDev) -> i32 {
    if dev.is_null() {
        return -1;
    }
    #[cfg(target_os = "none")]
    {
        // SAFETY: one-time bring-up owns the live board callback record.
        unsafe { crate::block_dev::relocate(dev) };
    }
    let Ok(mount) = fat32::mount(dev, FAT32_PARTITION_LBA) else {
        return -1;
    };
    // SAFETY: this is the sole initialization before callback registration.
    unsafe { MOUNT.0.get().write(MaybeUninit::new(mount)) };

    let ops = OPS.0.get();
    #[cfg(target_os = "none")]
    {
        // SAFETY: one-time bring-up owns the writable callback table.
        unsafe { vfs::relocate_ops(ops) };
    }
    let superblock = superblock_ptr();
    // SAFETY: both records are one-time initialized and kernel-lifetime.
    unsafe {
        (*superblock).private = mount_ptr() as u64;
        (*superblock).ops = ops;
        vfs::register_fat32(superblock);
    }
    apply_overlay();
    0
}

/// Whether `/PERMS.TAB` was present and parsed completely at mount time.
pub fn overlay_ok() -> bool {
    // SAFETY: initialized during bring-up, then only read.
    unsafe { *OVERLAY_OK.0.get() }
}

fn apply_overlay() {
    // SAFETY: bring-up or serialized test setup owns the overlay state.
    unsafe {
        *OVERLAY_OK.0.get() = false;
        *OVERLAY_COUNT.0.get() = 0;
    }
    let Some(name) = fat32::encode_8_3(OVERLAY_NAME) else {
        return;
    };
    let Ok(found) = fat32::lookup_in_root(mounted(), name) else {
        return;
    };
    let overlay_size = found.entry.file_size();
    if overlay_size == 0 || overlay_size as usize > OVERLAY_BUFFER_LEN {
        return;
    }

    let mut file = File {
        refs: 1,
        private: u64::from(fat32::first_cluster(found.entry)),
        size: u64::from(overlay_size),
        sb: superblock_ptr().cast(),
        ..File::default()
    };
    let buffer = OVERLAY_BUFFER.0.get();
    let mut got = 0u64;
    while got < file.size {
        // SAFETY: `buffer` has 1024 bytes and overlay_size was bounded above.
        let destination = unsafe { (*buffer).as_mut_ptr().add(got as usize) };
        // SAFETY: live local file and bounded writable destination.
        let count = unsafe { read(&raw mut file, destination, file.size - got) };
        if count <= 0 {
            return;
        }
        got += count as u64;
    }

    // SAFETY: bring-up owns both static buffers; `got` is bounded above.
    let content = unsafe { core::slice::from_raw_parts((*buffer).as_ptr(), got as usize) };
    // SAFETY: the overlay table is exclusively initialized here.
    let entries = unsafe { &mut *OVERLAY_ENTRIES.0.get() };
    let Some(count) = overlay::parse(content, entries) else {
        return;
    };
    // SAFETY: publication happens after the table is fully populated.
    unsafe {
        *OVERLAY_COUNT.0.get() = count;
        *OVERLAY_OK.0.get() = true;
    }
}

fn relative(path: &[u8]) -> &[u8] {
    path.strip_prefix(b"/").unwrap_or(path)
}

fn open_path(path: &[u8], out: &mut OpenResult) -> c_int {
    let rel = relative(path);
    let Ok(found) = fat32::lookup_path(mounted(), rel) else {
        return -1;
    };
    out.private = u64::from(fat32::first_cluster(found.entry));
    out.size = u64::from(found.entry.file_size());
    out.dirent_lba = found.lba;
    out.dirent_off = u32::from(found.byte_offset);

    // SAFETY: overlay state is immutable after bring-up and callbacks are
    // serialized with any test fixture mutation.
    let count = unsafe { *OVERLAY_COUNT.0.get() };
    // SAFETY: count came from parsing this fixed table and is in bounds.
    let entries = unsafe { &(&*OVERLAY_ENTRIES.0.get())[..count] };
    if let Some(entry) = overlay::lookup(entries, rel) {
        out.mode = 0o100000 | (entry.mode & 0o777);
        out.uid = entry.uid;
        out.gid = entry.gid;
    } else if overlay::name_eql(rel, SHADOW_NAME) {
        out.mode = 0o100600;
        out.uid = 0;
        out.gid = 0;
    } else {
        out.mode = 0o100666;
        out.uid = 0;
        out.gid = 0;
    }
    0
}

extern "C" fn open_callback(
    _: *mut SuperBlock,
    path: *const u8,
    path_len: usize,
    out: *mut OpenResult,
) -> c_int {
    // SAFETY: VFS supplies a readable path and exclusive output record.
    let path = unsafe { core::slice::from_raw_parts(path, path_len) };
    // SAFETY: VFS supplies writable storage for one OpenResult.
    open_path(path, unsafe { &mut *out })
}

extern "C" fn read_callback(_: *mut SuperBlock, file: *mut File, buffer: *mut u8, len: u64) -> i64 {
    // SAFETY: VFS supplies a live file and `len` writable bytes.
    unsafe { read(file, buffer, len) }
}

/// Read from a FAT cluster chain.
///
/// # Safety
/// `file` is live and writable; `buffer` points to `len` writable bytes.
pub unsafe fn read(file: *mut File, buffer: *mut u8, len: u64) -> i64 {
    let offset = unsafe { (*file).offset };
    let size = unsafe { (*file).size };
    if offset >= size {
        return 0;
    }
    let count = len.min(size - offset);
    let mut cluster = unsafe { (*file).private as u32 };
    let mut cluster_offset = offset;
    while cluster_offset >= u64::from(mounted().bytes_per_cluster) {
        let Ok(next) = fat32::read_fat_entry(mounted(), cluster) else {
            return -1;
        };
        if next >= fat32::FAT_EOC_MIN {
            return -1;
        }
        cluster = next;
        cluster_offset -= u64::from(mounted().bytes_per_cluster);
    }

    let mut copied = 0u64;
    let sector = io_sector();
    while copied < count {
        let sector_in_cluster = (cluster_offset / 512) as u32;
        let byte_in_sector = (cluster_offset % 512) as usize;
        let Ok(start_lba) = fat32::cluster_lba(mounted(), cluster) else {
            return -1;
        };
        if read_sector(start_lba + sector_in_cluster, sector).is_err() {
            return -1;
        }
        let take = (count - copied).min((512 - byte_in_sector) as u64);
        // Keep the runtime-length copy as an explicit byte loop. This is the
        // read-side structural twin of the release-codegen-sensitive write
        // splice below.
        let mut index = 0usize;
        while index < take as usize {
            // SAFETY: caller provides `len` bytes and `take` is bounded by the
            // remaining count; the sector index is bounded by 512.
            unsafe {
                buffer
                    .add(copied as usize + index)
                    .write(sector[byte_in_sector + index])
            };
            index += 1;
        }
        copied += take;
        cluster_offset += take;
        if cluster_offset >= u64::from(mounted().bytes_per_cluster) {
            let Ok(next) = fat32::read_fat_entry(mounted(), cluster) else {
                return -1;
            };
            if next >= fat32::FAT_EOC_MIN {
                break;
            }
            cluster = next;
            cluster_offset = 0;
        }
    }
    unsafe { (*file).offset = offset + copied };
    copied as i64
}

extern "C" fn seek_callback(_: *mut SuperBlock, file: *mut File, off: i64, whence: i32) -> i64 {
    // SAFETY: VFS supplies a live file record.
    unsafe { seek(file, off, whence) }
}

/// # Safety
/// `file` points to a live writable File.
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

extern "C" fn write_callback(
    _: *mut SuperBlock,
    file: *mut File,
    buffer: *const u8,
    len: u64,
) -> i64 {
    // SAFETY: VFS supplies a live file and `len` readable bytes.
    unsafe { write(file, buffer, len) }
}

fn extend_after(cluster: u32) -> Result<u32, ()> {
    let next = fat32::alloc_cluster(mounted_mut()).map_err(|_| ())?;
    fat32::write_fat_entry(mounted_mut(), cluster, next).map_err(|_| ())?;
    let _ = fat32::fs_info_on_alloc(mounted_mut(), next);
    Ok(next)
}

/// Extend or overwrite a FAT file without sparse holes.
///
/// # Safety
/// `file` is live and writable; `buffer` points to `len` readable bytes.
pub unsafe fn write(file: *mut File, buffer: *const u8, len: u64) -> i64 {
    if len == 0 {
        return 0;
    }
    let offset = unsafe { (*file).offset };
    let size = unsafe { (*file).size };
    if offset > size {
        return -1;
    }
    let dirent = FoundEntry {
        entry: fat32::DirEntry::zeroed(),
        lba: unsafe { (*file).dirent_lba },
        byte_offset: unsafe { (*file).dirent_off as u16 },
    };
    let mut cluster = unsafe { (*file).private as u32 };
    let mut cluster_offset = offset;
    if cluster == 0 {
        let Ok(first) = fat32::alloc_cluster(mounted_mut()) else {
            return -1;
        };
        let _ = fat32::fs_info_on_alloc(mounted_mut(), first);
        if fat32::update_dir_entry_first_cluster(mounted_mut(), dirent, first).is_err() {
            return -1;
        }
        unsafe { (*file).private = u64::from(first) };
        cluster = first;
    }

    while cluster_offset >= u64::from(mounted().bytes_per_cluster) {
        let Ok(mut next) = fat32::read_fat_entry(mounted(), cluster) else {
            return -1;
        };
        if next >= fat32::FAT_EOC_MIN {
            let Ok(extended) = extend_after(cluster) else {
                return -1;
            };
            next = extended;
        }
        cluster = next;
        cluster_offset -= u64::from(mounted().bytes_per_cluster);
    }

    let mut copied = 0u64;
    let sector = io_sector();
    while copied < len {
        let sector_in_cluster = (cluster_offset / 512) as u32;
        let byte_in_sector = (cluster_offset % 512) as usize;
        let Ok(start_lba) = fat32::cluster_lba(mounted(), cluster) else {
            return -1;
        };
        let lba = start_lba + sector_in_cluster;
        if read_sector(lba, sector).is_err() {
            return -1;
        }
        let take = (len - copied).min((512 - byte_in_sector) as u64);
        // This must remain an explicit runtime-length byte loop. A broad copy
        // at this splice was reordered above the callback read by freestanding
        // release codegen and lost sub-sector writes on real hardware.
        let mut index = 0usize;
        while index < take as usize {
            // SAFETY: caller provides `len` bytes; both indices are bounded by
            // the remaining input and the 512-byte sector.
            sector[byte_in_sector + index] = unsafe { buffer.add(copied as usize + index).read() };
            index += 1;
        }
        if write_sector(lba, sector).is_err() {
            return -1;
        }
        copied += take;
        cluster_offset += take;
        if cluster_offset >= u64::from(mounted().bytes_per_cluster) && copied < len {
            let Ok(mut next) = fat32::read_fat_entry(mounted(), cluster) else {
                return -1;
            };
            if next >= fat32::FAT_EOC_MIN {
                let Ok(extended) = extend_after(cluster) else {
                    return -1;
                };
                next = extended;
            }
            cluster = next;
            cluster_offset = 0;
        }
    }

    let new_offset = offset + copied;
    if new_offset > size {
        if fat32::update_dir_entry_size(mounted_mut(), dirent, new_offset as u32).is_err() {
            return -1;
        }
        unsafe { (*file).size = new_offset };
    }
    unsafe { (*file).offset = new_offset };
    copied as i64
}

extern "C" fn readdir_callback(
    _: *mut SuperBlock,
    path: *const u8,
    path_len: usize,
    index: u64,
    out: *mut vfs::Dirent,
) -> c_int {
    // SAFETY: VFS supplies a live path and output record.
    let path = unsafe { core::slice::from_raw_parts(path, path_len) };
    // SAFETY: VFS supplies exclusive output storage.
    readdir(path, index, unsafe { &mut *out })
}

fn readdir(path: &[u8], index: u64, out: &mut vfs::Dirent) -> c_int {
    if path != b"/" {
        return -1;
    }
    let mut cluster = mounted().bpb.root_cluster();
    let mut emitted = 0u64;
    let mut hops = 0u32;
    let sector = io_sector();
    while (2..fat32::FAT_EOC_MIN).contains(&cluster) {
        let Ok(start_lba) = fat32::cluster_lba(mounted(), cluster) else {
            return -1;
        };
        let mut sector_index = 0u32;
        while sector_index < mounted().sectors_per_cluster {
            if read_sector(start_lba + sector_index, sector).is_err() {
                return -1;
            }
            let mut slot = 0usize;
            while slot < 16 {
                let offset = slot * 32;
                let first = sector[offset];
                if first == 0 {
                    return -1;
                }
                let attr = sector[offset + 0x0b];
                if first != 0xe5
                    && attr & fat32::ATTR_LONG_NAME != fat32::ATTR_LONG_NAME
                    && attr & fat32::ATTR_VOLUME_ID == 0
                {
                    if emitted == index {
                        let mut raw = [0u8; 11];
                        raw.copy_from_slice(&sector[offset..offset + 11]);
                        let rendered = fat32::decode_8_3(raw);
                        *out = vfs::Dirent::default();
                        let count = rendered.len.min(out.name.len() - 1);
                        out.name[..count].copy_from_slice(&rendered.buf[..count]);
                        out.d_type = if attr & fat32::ATTR_DIRECTORY != 0 {
                            vfs::DT_DIR
                        } else {
                            vfs::DT_REG
                        };
                        return 0;
                    }
                    emitted += 1;
                }
                slot += 1;
            }
            sector_index += 1;
        }
        let Ok(next) = fat32::read_fat_entry(mounted(), cluster) else {
            return -1;
        };
        cluster = next;
        hops += 1;
        if hops > mounted().total_clusters {
            return -1;
        }
    }
    -1
}

struct PathSplit<'a> {
    parent: &'a [u8],
    base: &'a [u8],
}

fn split_basename(path: &[u8]) -> PathSplit<'_> {
    if let Some(index) = path.iter().rposition(|&byte| byte == b'/') {
        PathSplit {
            parent: &path[..index],
            base: &path[index + 1..],
        }
    } else {
        PathSplit {
            parent: &path[..0],
            base: path,
        }
    }
}

fn resolve_parent_cluster(parent: &[u8]) -> Option<u32> {
    if parent.is_empty() {
        return Some(mounted().bpb.root_cluster());
    }
    let found = fat32::lookup_path(mounted(), parent).ok()?;
    if found.entry.attr() & fat32::ATTR_DIRECTORY == 0 {
        return None;
    }
    Some(fat32::first_cluster(found.entry))
}

fn probe_exists(directory: u32, name: [u8; 11]) -> i32 {
    match fat32::lookup_in_dir(mounted(), directory, name) {
        Ok(_) => 1,
        Err(fat32::LookupError::NotFound) => 0,
        Err(_) => -1,
    }
}

extern "C" fn create_callback(
    _: *mut SuperBlock,
    path: *const u8,
    path_len: usize,
    out: *mut OpenResult,
) -> c_int {
    // SAFETY: VFS supplies live path and output storage.
    let path = unsafe { core::slice::from_raw_parts(path, path_len) };
    // SAFETY: VFS supplies exclusive output storage.
    create(relative(path), unsafe { &mut *out })
}

fn create(path: &[u8], out: &mut OpenResult) -> c_int {
    let split = split_basename(path);
    if split.base.is_empty() {
        return -1;
    }
    let Some(parent) = resolve_parent_cluster(split.parent) else {
        return -1;
    };
    let Some(name) = fat32::encode_8_3(split.base) else {
        return -1;
    };
    if probe_exists(parent, name) != 0 {
        return -1;
    }
    let Ok(slot) = fat32::find_free_dir_slot(mounted_mut(), parent) else {
        return -1;
    };
    if fat32::write_dir_entry(
        mounted_mut(),
        slot.lba,
        slot.byte_offset,
        name,
        fat32::ATTR_ARCHIVE,
        0,
        0,
    )
    .is_err()
    {
        return -1;
    }
    *out = OpenResult {
        mode: 0o100644,
        dirent_lba: slot.lba,
        dirent_off: u32::from(slot.byte_offset),
        ..OpenResult::default()
    };
    0
}

extern "C" fn unlink_callback(_: *mut SuperBlock, path: *const u8, path_len: usize) -> c_int {
    // SAFETY: VFS supplies a live path.
    let path = unsafe { core::slice::from_raw_parts(path, path_len) };
    unlink(relative(path))
}

fn unlink(path: &[u8]) -> c_int {
    let Ok(found) = fat32::lookup_path(mounted(), path) else {
        return -1;
    };
    if found.entry.attr() & fat32::ATTR_DIRECTORY != 0 {
        return -1;
    }
    let first = fat32::first_cluster(found.entry);
    if fat32::mark_deleted(mounted_mut(), found.lba, found.byte_offset).is_err() {
        return -1;
    }
    if fat32::free_chain(mounted_mut(), first).is_err() {
        return -1;
    }
    0
}

extern "C" fn rename_callback(
    _: *mut SuperBlock,
    old: *const u8,
    old_len: usize,
    new: *const u8,
    new_len: usize,
) -> c_int {
    // SAFETY: VFS supplies both live paths.
    let old = unsafe { core::slice::from_raw_parts(old, old_len) };
    let new = unsafe { core::slice::from_raw_parts(new, new_len) };
    rename(relative(old), relative(new))
}

fn rename(old: &[u8], new: &[u8]) -> c_int {
    let Ok(found) = fat32::lookup_path(mounted(), old) else {
        return -1;
    };
    let old_split = split_basename(old);
    let new_split = split_basename(new);
    if old_split.parent != new_split.parent || new_split.base.is_empty() {
        return -1;
    }
    let Some(parent) = resolve_parent_cluster(new_split.parent) else {
        return -1;
    };
    let Some(new_name) = fat32::encode_8_3(new_split.base) else {
        return -1;
    };
    let Some(old_name) = fat32::encode_8_3(old_split.base) else {
        return -1;
    };
    if old_name != new_name && probe_exists(parent, new_name) != 0 {
        return -1;
    }
    if fat32::write_dir_entry(
        mounted_mut(),
        found.lba,
        found.byte_offset,
        new_name,
        found.entry.attr(),
        fat32::first_cluster(found.entry),
        found.entry.file_size(),
    )
    .is_err()
    {
        return -1;
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    static ANTAGONIST_READ_CALLS: Global<u32> = Global(UnsafeCell::new(0));
    static HARVEST_WRITES: Global<u32> = Global(UnsafeCell::new(0));
    static HARVEST_SECTOR: Global<SectorBuf> = Global(UnsafeCell::new([0; 512]));
    static READ_DISK: Global<[u8; 8 * 512]> = Global(UnsafeCell::new([0; 8 * 512]));
    static RW_DISK: Global<[u8; 8 * 512]> = Global(UnsafeCell::new([0; 8 * 512]));

    extern "C" fn antagonist_read(_: u32, buffer: *mut [u8; 512]) -> i32 {
        // SAFETY: tests hold the shared FAT/backend lock and pass a live sector.
        unsafe {
            *ANTAGONIST_READ_CALLS.0.get() += 1;
            (*buffer).fill(0);
        }
        0
    }

    extern "C" fn harvest_write(_: u32, buffer: *const [u8; 512]) -> i32 {
        // SAFETY: tests hold the lock and both sectors are live for the call.
        unsafe {
            *HARVEST_WRITES.0.get() += 1;
            (*HARVEST_SECTOR.0.get()).copy_from_slice(&*buffer);
        }
        0
    }

    fn base_mount(dev: *mut BlockDev) -> Mount {
        Mount {
            bpb: fat32::Bpb::zeroed(),
            partition_lba: 0,
            fat_lba: 2,
            data_lba: 6,
            sectors_per_cluster: 1,
            bytes_per_cluster: 512,
            fsinfo_lba: 1,
            total_clusters: 124,
            dev,
        }
    }

    fn install_mount(mount: Mount) {
        // SAFETY: every test holds fat32::test_lock(), serializing all globals.
        unsafe {
            MOUNT.0.get().write(MaybeUninit::new(mount));
            (*SUPERBLOCK.0.get()).ops = OPS.0.get();
            *OVERLAY_OK.0.get() = false;
            *OVERLAY_COUNT.0.get() = 0;
        }
    }

    fn install_antagonist(dev: &mut BlockDev) {
        *dev = BlockDev {
            read_fn: Some(antagonist_read),
            write_fn: Some(harvest_write),
        };
        // SAFETY: test lock serializes the shared counters and sector.
        unsafe {
            *ANTAGONIST_READ_CALLS.0.get() = 0;
            *HARVEST_WRITES.0.get() = 0;
            (*HARVEST_SECTOR.0.get()).fill(0xcc);
        }
        install_mount(base_mount(dev));
    }

    fn file(offset: u64, private: u64, size: u64) -> File {
        File {
            refs: 1,
            offset,
            private,
            size,
            sb: superblock_ptr().cast(),
            ..File::default()
        }
    }

    #[test]
    fn splice_contract_one_byte_subsector_write_lands_at_file_offset_with_no_bleed() {
        let _guard = fat32::test_lock();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_antagonist(&mut dev);
        let mut handle = file(100, 3, 512);
        let payload = [0xaa];
        assert_eq!(unsafe { write(&raw mut handle, payload.as_ptr(), 1) }, 1);
        // SAFETY: the test lock serializes these globals.
        unsafe {
            assert_eq!(*ANTAGONIST_READ_CALLS.0.get(), 1);
            assert_eq!(*HARVEST_WRITES.0.get(), 1);
            assert_eq!((*HARVEST_SECTOR.0.get())[99], 0);
            assert_eq!((*HARVEST_SECTOR.0.get())[100], 0xaa);
            assert_eq!((*HARVEST_SECTOR.0.get())[101], 0);
        }
    }

    #[test]
    fn splice_contract_four_byte_subsector_write_lands_at_file_offset_with_no_bleed() {
        let _guard = fat32::test_lock();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_antagonist(&mut dev);
        let mut handle = file(200, 3, 512);
        let payload = [0xde, 0xad, 0xbe, 0xef];
        assert_eq!(unsafe { write(&raw mut handle, payload.as_ptr(), 4) }, 4);
        // SAFETY: the test lock serializes the harvest sector.
        unsafe {
            assert_eq!(&(&*HARVEST_SECTOR.0.get())[200..204], &payload);
            assert_eq!((*HARVEST_SECTOR.0.get())[199], 0);
            assert_eq!((*HARVEST_SECTOR.0.get())[204], 0);
        }
    }

    #[test]
    fn splice_contract_whole_file_same_length_rewrite_from_offset_zero() {
        let _guard = fat32::test_lock();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_antagonist(&mut dev);
        let content = concat!(
            "root:4096:",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:",
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
            "flash:4096:",
            "cccccccccccccccccccccccccccccccc:",
            "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\n"
        )
        .as_bytes();
        let mut handle = file(0, 3, content.len() as u64);
        assert_eq!(
            unsafe { write(&raw mut handle, content.as_ptr(), content.len() as u64) },
            content.len() as i64
        );
        // SAFETY: the test lock serializes the harvest sector.
        unsafe {
            assert_eq!(&(&*HARVEST_SECTOR.0.get())[..content.len()], content);
            assert_eq!((*HARVEST_SECTOR.0.get())[content.len()], 0);
        }
        assert_eq!(handle.offset, content.len() as u64);
        assert_eq!(handle.size, content.len() as u64);
    }

    #[test]
    fn read_splice_contract_one_byte_subsector_read_follows_hostile_callback() {
        let _guard = fat32::test_lock();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_antagonist(&mut dev);
        let mut handle = file(100, 3, 512);
        let mut out = [0xcc; 3];
        assert_eq!(
            unsafe { read(&raw mut handle, out[1..].as_mut_ptr(), 1) },
            1
        );
        assert_eq!(out, [0xcc, 0, 0xcc]);
        assert_eq!(handle.offset, 101);
        // SAFETY: the test lock serializes the counter.
        assert_eq!(unsafe { *ANTAGONIST_READ_CALLS.0.get() }, 1);
    }

    #[test]
    fn read_splice_contract_runtime_length_copy_has_no_destination_bleed() {
        let _guard = fat32::test_lock();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_antagonist(&mut dev);
        let mut handle = file(200, 3, 512);
        let mut out = [0xcc; 6];
        assert_eq!(
            unsafe { read(&raw mut handle, out[1..].as_mut_ptr(), 4) },
            4
        );
        assert_eq!(out, [0xcc, 0, 0, 0, 0, 0xcc]);
        assert_eq!(handle.offset, 204);
        // SAFETY: the test lock serializes the counter.
        assert_eq!(unsafe { *ANTAGONIST_READ_CALLS.0.get() }, 1);
    }

    fn read_disk() -> &'static mut [u8; 8 * 512] {
        // SAFETY: all backend and FAT fixtures share the same test lock.
        unsafe { &mut *READ_DISK.0.get() }
    }

    extern "C" fn read_disk_sector(lba: u32, buffer: *mut [u8; 512]) -> i32 {
        let offset = lba as usize * 512;
        if offset + 512 > 8 * 512 {
            return -1;
        }
        // SAFETY: test lock serializes the disk; bounds were checked.
        unsafe { (*buffer).copy_from_slice(&(&*READ_DISK.0.get())[offset..offset + 512]) };
        0
    }

    fn setup_readdir_fixture() {
        let disk = read_disk();
        disk.fill(0);
        disk[2 * 512 + 8..2 * 512 + 12].copy_from_slice(&fat32::FAT_EOC.to_le_bytes());
        let root = &mut disk[6 * 512..7 * 512];
        root[..11].copy_from_slice(b"SCRATCH    ");
        root[0x0b] = fat32::ATTR_VOLUME_ID;
        root[32..43].copy_from_slice(b"?DELETEDBIN");
        root[32] = 0xe5;
        root[64..75].copy_from_slice(b"HELLO   TXT");
        root[64 + 0x0b] = fat32::ATTR_ARCHIVE;
        root[96..107].copy_from_slice(b"SUBDIR     ");
        root[96 + 0x0b] = fat32::ATTR_DIRECTORY;
    }

    fn install_read_mount(dev: &mut BlockDev) {
        *dev = BlockDev {
            read_fn: Some(read_disk_sector),
            write_fn: None,
        };
        let mut mount = base_mount(dev);
        mount.bpb.set_root_cluster(2);
        install_mount(mount);
    }

    #[test]
    fn readdir_lists_root_entries_skipping_volume_label_and_deleted() {
        let _guard = fat32::test_lock();
        setup_readdir_fixture();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_read_mount(&mut dev);
        let mut out = vfs::Dirent::default();
        assert_eq!(readdir(b"/", 0, &mut out), 0);
        assert_eq!(&out.name[..9], b"hello.txt");
        assert_eq!(out.d_type, vfs::DT_REG);
        assert_eq!(readdir(b"/", 1, &mut out), 0);
        assert_eq!(&out.name[..6], b"subdir");
        assert_eq!(out.d_type, vfs::DT_DIR);
        assert_eq!(readdir(b"/", 2, &mut out), -1);
    }

    #[test]
    fn readdir_on_non_root_path_lists_empty() {
        let _guard = fat32::test_lock();
        setup_readdir_fixture();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_read_mount(&mut dev);
        let mut out = vfs::Dirent::default();
        assert_eq!(readdir(b"/subdir", 0, &mut out), -1);
    }

    #[test]
    fn readdir_terminates_on_self_looping_fat_chain() {
        let _guard = fat32::test_lock();
        setup_readdir_fixture();
        read_disk()[2 * 512 + 8..2 * 512 + 12].copy_from_slice(&2u32.to_le_bytes());
        let root = &mut read_disk()[6 * 512..7 * 512];
        for slot in 0..16 {
            let offset = slot * 32;
            root[offset..offset + 11].copy_from_slice(b"OTHER   BIN");
            root[offset + 0x0b] = fat32::ATTR_ARCHIVE;
        }
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_read_mount(&mut dev);
        let mut out = vfs::Dirent::default();
        assert_eq!(readdir(b"/", 9999, &mut out), -1);
    }

    const OVERLAY_TEXT: &[u8] = b"PERMS.TAB 0600 0 0\nSHADOW 0640 0 0\n";

    fn setup_overlay_fixture() {
        let disk = read_disk();
        disk.fill(0);
        disk[2 * 512 + 8..2 * 512 + 12].copy_from_slice(&fat32::FAT_EOC.to_le_bytes());
        disk[2 * 512 + 12..2 * 512 + 16].copy_from_slice(&fat32::FAT_EOC.to_le_bytes());
        let root = &mut disk[6 * 512..7 * 512];
        root[..11].copy_from_slice(b"PERMS   TAB");
        root[0x0b] = fat32::ATTR_ARCHIVE;
        root[0x1a..0x1c].copy_from_slice(&3u16.to_le_bytes());
        root[0x1c..0x20].copy_from_slice(&(OVERLAY_TEXT.len() as u32).to_le_bytes());
        root[32..43].copy_from_slice(b"SHADOW     ");
        root[32 + 0x0b] = fat32::ATTR_ARCHIVE;
        root[32 + 0x1a..32 + 0x1c].copy_from_slice(&4u16.to_le_bytes());
        root[32 + 0x1c..32 + 0x20].copy_from_slice(&100u32.to_le_bytes());
        root[64..75].copy_from_slice(b"ROUNDTR DAT");
        root[64 + 0x0b] = fat32::ATTR_ARCHIVE;
        root[64 + 0x1a..64 + 0x1c].copy_from_slice(&5u16.to_le_bytes());
        root[64 + 0x1c..64 + 0x20].copy_from_slice(&4096u32.to_le_bytes());
        disk[7 * 512..7 * 512 + OVERLAY_TEXT.len()].copy_from_slice(OVERLAY_TEXT);
    }

    #[test]
    fn overlay_annotated_entries_shadow_override_and_defaults() {
        let _guard = fat32::test_lock();
        setup_overlay_fixture();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_read_mount(&mut dev);
        apply_overlay();
        assert!(overlay_ok());
        let mut out = OpenResult::default();
        assert_eq!(open_path(b"/shadow", &mut out), 0);
        assert_eq!((out.mode, out.uid, out.gid), (0o100640, 0, 0));
        assert_eq!(open_path(b"/perms.tab", &mut out), 0);
        assert_eq!(out.mode, 0o100600);
        assert_eq!(open_path(b"/roundtr.dat", &mut out), 0);
        assert_eq!(out.mode, 0o100666);
    }

    #[test]
    fn overlay_absent_file_floors_shadow_and_keeps_defaults_elsewhere() {
        let _guard = fat32::test_lock();
        setup_overlay_fixture();
        read_disk()[6 * 512] = 0xe5;
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_read_mount(&mut dev);
        apply_overlay();
        assert!(!overlay_ok());
        let mut out = OpenResult::default();
        assert_eq!(open_path(b"/shadow", &mut out), 0);
        assert_eq!((out.mode, out.uid, out.gid), (0o100600, 0, 0));
        assert_eq!(open_path(b"/roundtr.dat", &mut out), 0);
        assert_eq!(out.mode, 0o100666);
    }

    #[test]
    fn overlay_corrupt_content_is_rejected_wholesale() {
        let _guard = fat32::test_lock();
        setup_overlay_fixture();
        read_disk()[7 * 512 + 10] = b'x';
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_read_mount(&mut dev);
        apply_overlay();
        assert!(!overlay_ok());
        let mut out = OpenResult::default();
        assert_eq!(open_path(b"/shadow", &mut out), 0);
        assert_eq!(out.mode, 0o100600);
    }

    fn rw_disk() -> &'static mut [u8; 8 * 512] {
        // SAFETY: all backend and FAT fixtures share the same test lock.
        unsafe { &mut *RW_DISK.0.get() }
    }

    extern "C" fn rw_read(lba: u32, buffer: *mut [u8; 512]) -> i32 {
        let offset = lba as usize * 512;
        if offset + 512 > 8 * 512 {
            return -1;
        }
        // SAFETY: test lock serializes the disk; bounds were checked.
        unsafe { (*buffer).copy_from_slice(&(&*RW_DISK.0.get())[offset..offset + 512]) };
        0
    }

    extern "C" fn rw_write(lba: u32, buffer: *const [u8; 512]) -> i32 {
        let offset = lba as usize * 512;
        if offset + 512 > 8 * 512 {
            return -1;
        }
        // SAFETY: test lock serializes the disk; bounds were checked.
        unsafe { (&mut *RW_DISK.0.get())[offset..offset + 512].copy_from_slice(&*buffer) };
        0
    }

    fn setup_empty_file_fixture() {
        let disk = rw_disk();
        disk.fill(0);
        disk[2 * 512 + 8..2 * 512 + 12].copy_from_slice(&fat32::FAT_EOC.to_le_bytes());
        let root = &mut disk[6 * 512..7 * 512];
        root[..11].copy_from_slice(b"EMPTY   TXT");
        root[0x0b] = fat32::ATTR_ARCHIVE;
    }

    fn install_rw_mount(dev: &mut BlockDev) {
        *dev = BlockDev {
            read_fn: Some(rw_read),
            write_fn: Some(rw_write),
        };
        let mut mount = base_mount(dev);
        mount.bpb.set_root_cluster(2);
        mount.bpb.set_number_of_fats(1);
        install_mount(mount);
    }

    fn seed_empty_with_chain() {
        let disk = rw_disk();
        let root = &mut disk[6 * 512..7 * 512];
        root[0x1a..0x1c].copy_from_slice(&3u16.to_le_bytes());
        root[0x1c..0x20].copy_from_slice(&4u32.to_le_bytes());
        disk[2 * 512 + 12..2 * 512 + 16].copy_from_slice(&fat32::FAT_EOC.to_le_bytes());
    }

    #[test]
    fn write_to_empty_file_allocates_first_cluster_and_records_dir_entry() {
        let _guard = fat32::test_lock();
        setup_empty_file_fixture();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_rw_mount(&mut dev);
        let mut out = OpenResult::default();
        assert_eq!(open_path(b"/empty.txt", &mut out), 0);
        assert_eq!((out.private, out.dirent_lba, out.dirent_off), (0, 6, 0));
        let mut handle = File {
            refs: 1,
            private: out.private,
            size: out.size,
            sb: superblock_ptr().cast(),
            dirent_lba: out.dirent_lba,
            dirent_off: out.dirent_off,
            ..File::default()
        };
        let payload = [0xde, 0xad, 0xbe, 0xef];
        assert_eq!(unsafe { write(&raw mut handle, payload.as_ptr(), 4) }, 4);
        assert_eq!(fat32::read_fat_entry(mounted(), 3), Ok(fat32::FAT_EOC));
        let root = &rw_disk()[6 * 512..7 * 512];
        assert_eq!(u16::from_le_bytes([root[0x1a], root[0x1b]]), 3);
        assert_eq!(u32::from_le_bytes(root[0x1c..0x20].try_into().unwrap()), 4);
        assert_eq!(&rw_disk()[7 * 512..7 * 512 + 4], &payload);
        assert_eq!((handle.private, handle.size), (3, 4));
    }

    #[test]
    fn write_past_eof_grows_size_via_stashed_dirent_location() {
        let _guard = fat32::test_lock();
        setup_empty_file_fixture();
        seed_empty_with_chain();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_rw_mount(&mut dev);
        let mut handle = File {
            refs: 1,
            offset: 4,
            private: 3,
            size: 4,
            sb: superblock_ptr().cast(),
            dirent_lba: 6,
            ..File::default()
        };
        let payload = [0x11, 0x22];
        assert_eq!(unsafe { write(&raw mut handle, payload.as_ptr(), 2) }, 2);
        let root = &rw_disk()[6 * 512..7 * 512];
        assert_eq!(u32::from_le_bytes(root[0x1c..0x20].try_into().unwrap()), 6);
        assert_eq!(&rw_disk()[7 * 512 + 4..7 * 512 + 6], &payload);
        assert_eq!(handle.size, 6);
    }

    #[test]
    fn create_stamps_new_entry_that_open_resolves() {
        let _guard = fat32::test_lock();
        setup_empty_file_fixture();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_rw_mount(&mut dev);
        let mut out = OpenResult::default();
        assert_eq!(create(b"new.fl", &mut out), 0);
        assert_eq!((out.private, out.size, out.mode), (0, 0, 0o100644));
        assert_eq!((out.dirent_lba, out.dirent_off), (6, 32));
        assert_eq!(open_path(b"/new.fl", &mut out), 0);
    }

    #[test]
    fn create_rejects_existing_name() {
        let _guard = fat32::test_lock();
        setup_empty_file_fixture();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_rw_mount(&mut dev);
        assert_eq!(create(b"empty.txt", &mut OpenResult::default()), -1);
    }

    #[test]
    fn create_rejects_name_that_does_not_fit_8_3() {
        let _guard = fat32::test_lock();
        setup_empty_file_fixture();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_rw_mount(&mut dev);
        assert_eq!(create(b"toolongname.flash", &mut OpenResult::default()), -1);
    }

    #[test]
    fn unlink_removes_file_and_frees_cluster_chain() {
        let _guard = fat32::test_lock();
        setup_empty_file_fixture();
        seed_empty_with_chain();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_rw_mount(&mut dev);
        assert_eq!(unlink(b"empty.txt"), 0);
        assert_eq!(open_path(b"/empty.txt", &mut OpenResult::default()), -1);
        assert_eq!(fat32::read_fat_entry(mounted(), 3), Ok(fat32::FAT_FREE));
    }

    #[test]
    fn rename_rewrites_name_in_place_preserving_cluster_and_size() {
        let _guard = fat32::test_lock();
        setup_empty_file_fixture();
        seed_empty_with_chain();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_rw_mount(&mut dev);
        assert_eq!(rename(b"empty.txt", b"renamed.fl"), 0);
        let mut out = OpenResult::default();
        assert_eq!(open_path(b"/renamed.fl", &mut out), 0);
        assert_eq!((out.private, out.size), (3, 4));
        assert_eq!(open_path(b"/empty.txt", &mut out), -1);
    }

    #[test]
    fn rename_rejects_cross_directory_move() {
        let _guard = fat32::test_lock();
        setup_empty_file_fixture();
        let mut dev = BlockDev {
            read_fn: None,
            write_fn: None,
        };
        install_rw_mount(&mut dev);
        assert_eq!(rename(b"empty.txt", b"sub/empty.txt"), -1);
    }
}
