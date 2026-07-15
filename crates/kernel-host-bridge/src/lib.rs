//! Host-linkable storage ABI for the remaining Flash FAT32 backend tests.
//!
//! The production kernel uses `crates/klib`. This smaller native staticlib
//! exists only so the Flash backend's regression suite can call the same
//! Rust-owned FAT32 and overlay logic before that backend moves to Rust.

#![deny(unsafe_op_in_unsafe_fn)]
// This crate is a private C-ABI link shim, not a Rust-callable API. The
// production exports in `flashos-klib` document each identical pointer
// contract; repeating 27 copies here would make the short-lived mirror harder
// to audit against that source of truth.
#![allow(clippy::missing_safety_doc)]

use flashos_kernel::{block_dev, fat32, overlay};

const NONE: usize = usize::MAX;

fn fat_code(error: fat32::FatError) -> i32 {
    match error {
        fat32::FatError::BlockReadFailed => 1,
        fat32::FatError::BlockWriteFailed => 2,
        fat32::FatError::InvalidCluster => 3,
    }
}

fn alloc_code(error: fat32::AllocError) -> i32 {
    match error {
        fat32::AllocError::BlockReadFailed => 1,
        fat32::AllocError::BlockWriteFailed => 2,
        fat32::AllocError::InvalidCluster => 3,
        fat32::AllocError::NoSpace => 4,
    }
}

fn lookup_code(error: fat32::LookupError) -> i32 {
    match error {
        fat32::LookupError::BlockReadFailed => 1,
        fat32::LookupError::InvalidCluster => 3,
        fat32::LookupError::NotFound => 5,
    }
}

fn path_code(error: fat32::PathError) -> i32 {
    match error {
        fat32::PathError::BlockReadFailed => 1,
        fat32::PathError::InvalidCluster => 3,
        fat32::PathError::NotFound => 5,
        fat32::PathError::NotADirectory => 6,
    }
}

fn slot_code(error: fat32::DirSlotError) -> i32 {
    match error {
        fat32::DirSlotError::BlockReadFailed => 1,
        fat32::DirSlotError::BlockWriteFailed => 2,
        fat32::DirSlotError::InvalidCluster => 3,
        fat32::DirSlotError::NoSpace => 4,
    }
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_mount(
    dev: *mut block_dev::BlockDev,
    lba: u32,
    out: *mut fat32::Mount,
) -> i32 {
    match fat32::mount(dev, lba) {
        Ok(value) => {
            unsafe { out.write(value) };
            0
        }
        Err(fat32::MountError::BadBpb) => 1,
        Err(fat32::MountError::NotFat32) => 2,
        Err(fat32::MountError::BlockReadFailed) => 3,
    }
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_cluster_lba(
    m: *const fat32::Mount,
    cluster: u32,
    out: *mut u32,
) -> i32 {
    match fat32::cluster_lba(unsafe { &*m }, cluster) {
        Ok(value) => {
            unsafe { out.write(value) };
            0
        }
        Err(error) => fat_code(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_read_fat_entry(
    m: *const fat32::Mount,
    cluster: u32,
    out: *mut u32,
) -> i32 {
    match fat32::read_fat_entry(unsafe { &*m }, cluster) {
        Ok(value) => {
            unsafe { out.write(value) };
            0
        }
        Err(error) => fat_code(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_write_fat_entry(
    m: *mut fat32::Mount,
    cluster: u32,
    value: u32,
) -> i32 {
    unsafe { fat32::write_fat_entry(&mut *m, cluster, value) }.map_or_else(fat_code, |()| 0)
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_alloc_cluster(m: *mut fat32::Mount, out: *mut u32) -> i32 {
    match unsafe { fat32::alloc_cluster(&mut *m) } {
        Ok(value) => {
            unsafe { out.write(value) };
            0
        }
        Err(error) => alloc_code(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_fs_info_on_alloc(m: *mut fat32::Mount, cluster: u32) -> i32 {
    unsafe { fat32::fs_info_on_alloc(&mut *m, cluster) }.map_or_else(fat_code, |()| 0)
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_lookup_in_root(
    m: *const fat32::Mount,
    name: *const [u8; 11],
    out: *mut fat32::FoundEntry,
) -> i32 {
    match fat32::lookup_in_root(unsafe { &*m }, unsafe { *name }) {
        Ok(value) => {
            unsafe { out.write(value) };
            0
        }
        Err(error) => lookup_code(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_lookup_in_dir(
    m: *const fat32::Mount,
    start: u32,
    name: *const [u8; 11],
    out: *mut fat32::FoundEntry,
) -> i32 {
    match fat32::lookup_in_dir(unsafe { &*m }, start, unsafe { *name }) {
        Ok(value) => {
            unsafe { out.write(value) };
            0
        }
        Err(error) => lookup_code(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_first_cluster(entry: *const fat32::DirEntry) -> u32 {
    fat32::first_cluster(unsafe { *entry })
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_bpb_root_cluster(bpb: *const fat32::Bpb) -> u32 {
    unsafe { &*bpb }.root_cluster()
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_bpb_set_root_cluster(bpb: *mut fat32::Bpb, value: u32) {
    unsafe { &mut *bpb }.set_root_cluster(value);
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_bpb_set_num_fats(bpb: *mut fat32::Bpb, value: u8) {
    unsafe { &mut *bpb }.set_number_of_fats(value);
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_dir_entry_attr(entry: *const fat32::DirEntry) -> u8 {
    unsafe { &*entry }.attr()
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_dir_entry_file_size(entry: *const fat32::DirEntry) -> u32 {
    unsafe { &*entry }.file_size()
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_lookup_path(
    m: *const fat32::Mount,
    path: *const u8,
    len: usize,
    out: *mut fat32::FoundEntry,
) -> i32 {
    let path = unsafe { core::slice::from_raw_parts(path, len) };
    match fat32::lookup_path(unsafe { &*m }, path) {
        Ok(value) => {
            unsafe { out.write(value) };
            0
        }
        Err(error) => path_code(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_update_dir_entry_size(
    m: *mut fat32::Mount,
    found: *const fat32::FoundEntry,
    size: u32,
) -> i32 {
    unsafe { fat32::update_dir_entry_size(&mut *m, *found, size) }.map_or_else(fat_code, |()| 0)
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_update_dir_entry_first_cluster(
    m: *mut fat32::Mount,
    found: *const fat32::FoundEntry,
    cluster: u32,
) -> i32 {
    unsafe { fat32::update_dir_entry_first_cluster(&mut *m, *found, cluster) }
        .map_or_else(fat_code, |()| 0)
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_find_free_dir_slot(
    m: *mut fat32::Mount,
    cluster: u32,
    out: *mut fat32::DirSlot,
) -> i32 {
    match unsafe { fat32::find_free_dir_slot(&mut *m, cluster) } {
        Ok(value) => {
            unsafe { out.write(value) };
            0
        }
        Err(error) => slot_code(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_write_dir_entry(
    m: *mut fat32::Mount,
    lba: u32,
    offset: u16,
    name: *const [u8; 11],
    attr: u8,
    cluster: u32,
    size: u32,
) -> i32 {
    unsafe { fat32::write_dir_entry(&mut *m, lba, offset, *name, attr, cluster, size) }
        .map_or_else(fat_code, |()| 0)
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_mark_deleted(
    m: *mut fat32::Mount,
    lba: u32,
    offset: u16,
) -> i32 {
    unsafe { fat32::mark_deleted(&mut *m, lba, offset) }.map_or_else(fat_code, |()| 0)
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_free_chain(m: *mut fat32::Mount, cluster: u32) -> i32 {
    unsafe { fat32::free_chain(&mut *m, cluster) }.map_or_else(fat_code, |()| 0)
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_fs_info_on_free(m: *mut fat32::Mount, cluster: u32) -> i32 {
    unsafe { fat32::fs_info_on_free(&mut *m, cluster) }.map_or_else(fat_code, |()| 0)
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_encode_8_3(
    name: *const u8,
    len: usize,
    out: *mut [u8; 11],
) -> u8 {
    let Some(value) = fat32::encode_8_3(unsafe { core::slice::from_raw_parts(name, len) }) else {
        return 0;
    };
    unsafe { out.write(value) };
    1
}

#[no_mangle]
pub unsafe extern "C" fn fos_fat32_decode_8_3(raw: *const [u8; 11], out: *mut fat32::Rendered8_3) {
    unsafe { out.write(fat32::decode_8_3(*raw)) };
}

#[no_mangle]
pub unsafe extern "C" fn fos_overlay_parse(
    content: *const u8,
    len: usize,
    out: *mut overlay::Entry,
    cap: usize,
) -> usize {
    overlay::parse(
        unsafe { core::slice::from_raw_parts(content, len) },
        unsafe { core::slice::from_raw_parts_mut(out, cap) },
    )
    .unwrap_or(NONE)
}

#[no_mangle]
pub unsafe extern "C" fn fos_overlay_lookup(
    entries: *const overlay::Entry,
    count: usize,
    name: *const u8,
    len: usize,
    out: *mut overlay::Entry,
) -> u8 {
    let Some(value) = overlay::lookup(
        unsafe { core::slice::from_raw_parts(entries, count) },
        unsafe { core::slice::from_raw_parts(name, len) },
    ) else {
        return 0;
    };
    unsafe { out.write(value) };
    1
}

#[no_mangle]
pub unsafe extern "C" fn fos_overlay_name_eql(
    a: *const u8,
    a_len: usize,
    b: *const u8,
    b_len: usize,
) -> u8 {
    u8::from(overlay::name_eql(
        unsafe { core::slice::from_raw_parts(a, a_len) },
        unsafe { core::slice::from_raw_parts(b, b_len) },
    ))
}
