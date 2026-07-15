//! FAT32 on-disk geometry, allocation, lookup, and directory mutation.
//!
//! This is the allocation-free pure storage layer. It knows the Microsoft
//! FAT32 BPB, FAT entries, FSInfo hints, and 8.3 directory records, but no VFS
//! or process state. All sector traffic goes through the runtime `BlockDev`
//! pointer in [`Mount`], which keeps the complete unit host-testable.

use crate::block_dev::BlockDev;
use core::cell::UnsafeCell;

pub const ATTR_READ_ONLY: u8 = 0x01;
pub const ATTR_HIDDEN: u8 = 0x02;
pub const ATTR_SYSTEM: u8 = 0x04;
pub const ATTR_VOLUME_ID: u8 = 0x08;
pub const ATTR_DIRECTORY: u8 = 0x10;
pub const ATTR_ARCHIVE: u8 = 0x20;
pub const ATTR_LONG_NAME: u8 = 0x0f;

pub const FAT_EOC: u32 = 0x0fff_ffff;
pub const FAT_FREE: u32 = 0;
pub const FAT_BAD: u32 = 0x0fff_fff7;
/// Every value at or above this threshold is an end-of-chain marker.
pub const FAT_EOC_MIN: u32 = 0x0fff_fff8;

pub const FSINFO_LEAD_SIG: u32 = 0x4161_5252;
pub const FSINFO_STRUC_SIG: u32 = 0x6141_7272;
pub const FSINFO_TRAIL_SIG: u32 = 0xaa55_0000;

pub type SectorBuf = [u8; 512];

/// Byte-exact FAT32 BPB prefix through `FilSysType` (offset 0x59 inclusive).
#[derive(Clone, Copy)]
#[repr(C)]
pub struct Bpb {
    pub raw: [u8; 90],
}

impl Bpb {
    pub const fn zeroed() -> Self {
        Self { raw: [0; 90] }
    }

    pub fn bytes_per_sector(&self) -> u16 {
        read_u16(&self.raw, 0x0b)
    }

    pub fn number_of_fats(&self) -> u8 {
        self.raw[0x10]
    }

    pub fn fat_size(&self) -> u32 {
        read_u32(&self.raw, 0x24)
    }

    pub fn root_cluster(&self) -> u32 {
        read_u32(&self.raw, 0x2c)
    }

    pub fn set_number_of_fats(&mut self, value: u8) {
        self.raw[0x10] = value;
    }

    pub fn set_root_cluster(&mut self, value: u32) {
        write_u32(&mut self.raw, 0x2c, value);
    }
}

const _: () = assert!(core::mem::size_of::<Bpb>() == 90);
const _: () = assert!(core::mem::align_of::<Bpb>() == 1);
const _: () = assert!(core::mem::offset_of!(Bpb, raw) == 0);

/// Byte-exact 32-byte FAT short-directory entry.
#[derive(Clone, Copy)]
#[repr(C)]
pub struct DirEntry {
    pub raw: [u8; 32],
}

impl DirEntry {
    pub const fn zeroed() -> Self {
        Self { raw: [0; 32] }
    }

    pub fn attr(&self) -> u8 {
        self.raw[0x0b]
    }

    pub fn file_size(&self) -> u32 {
        read_u32(&self.raw, 0x1c)
    }
}

const _: () = assert!(core::mem::size_of::<DirEntry>() == 32);
const _: () = assert!(core::mem::align_of::<DirEntry>() == 1);
const _: () = assert!(core::mem::offset_of!(DirEntry, raw) == 0);

/// Mounted volume geometry shared temporarily with the Flash VFS backend.
#[derive(Clone, Copy)]
#[repr(C)]
pub struct Mount {
    pub bpb: Bpb,
    pub partition_lba: u32,
    pub fat_lba: u32,
    pub data_lba: u32,
    pub sectors_per_cluster: u32,
    pub bytes_per_cluster: u32,
    pub fsinfo_lba: u32,
    pub total_clusters: u32,
    pub dev: *mut BlockDev,
}

const _: () = assert!(core::mem::size_of::<Mount>() == 128);
const _: () = assert!(core::mem::align_of::<Mount>() == 8);
const _: () = assert!(core::mem::offset_of!(Mount, partition_lba) == 92);
const _: () = assert!(core::mem::offset_of!(Mount, dev) == 120);

#[derive(Clone, Copy)]
#[repr(C)]
pub struct FoundEntry {
    pub entry: DirEntry,
    pub lba: u32,
    pub byte_offset: u16,
}

const _: () = assert!(core::mem::size_of::<FoundEntry>() == 40);
const _: () = assert!(core::mem::align_of::<FoundEntry>() == 4);
const _: () = assert!(core::mem::offset_of!(FoundEntry, lba) == 32);
const _: () = assert!(core::mem::offset_of!(FoundEntry, byte_offset) == 36);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct DirSlot {
    pub lba: u32,
    pub byte_offset: u16,
}

const _: () = assert!(core::mem::size_of::<DirSlot>() == 8);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct Rendered8_3 {
    pub buf: [u8; 12],
    pub len: usize,
}

const _: () = assert!(core::mem::size_of::<Rendered8_3>() == 24);
const _: () = assert!(core::mem::offset_of!(Rendered8_3, len) == 16);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MountError {
    BadBpb,
    NotFat32,
    BlockReadFailed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FatError {
    BlockReadFailed,
    BlockWriteFailed,
    InvalidCluster,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AllocError {
    NoSpace,
    BlockReadFailed,
    BlockWriteFailed,
    InvalidCluster,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LookupError {
    NotFound,
    BlockReadFailed,
    InvalidCluster,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PathError {
    NotFound,
    NotADirectory,
    BlockReadFailed,
    InvalidCluster,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DirSlotError {
    NoSpace,
    BlockReadFailed,
    BlockWriteFailed,
    InvalidCluster,
}

impl From<FatError> for AllocError {
    fn from(error: FatError) -> Self {
        match error {
            FatError::BlockReadFailed => Self::BlockReadFailed,
            FatError::BlockWriteFailed => Self::BlockWriteFailed,
            FatError::InvalidCluster => Self::InvalidCluster,
        }
    }
}

impl From<FatError> for DirSlotError {
    fn from(error: FatError) -> Self {
        match error {
            FatError::BlockReadFailed => Self::BlockReadFailed,
            FatError::BlockWriteFailed => Self::BlockWriteFailed,
            FatError::InvalidCluster => Self::InvalidCluster,
        }
    }
}

impl From<AllocError> for DirSlotError {
    fn from(error: AllocError) -> Self {
        match error {
            AllocError::NoSpace => Self::NoSpace,
            AllocError::BlockReadFailed => Self::BlockReadFailed,
            AllocError::BlockWriteFailed => Self::BlockWriteFailed,
            AllocError::InvalidCluster => Self::InvalidCluster,
        }
    }
}

struct SectorScratch(UnsafeCell<SectorBuf>);

// SAFETY: production VFS dispatch disables preemption around every FAT32 call,
// and kernel bring-up is single-core. Tests serialize access with TEST_LOCK.
unsafe impl Sync for SectorScratch {}

static DIR_SECTOR_SCRATCH: SectorScratch = SectorScratch(UnsafeCell::new([0; 512]));
static FAT_SECTOR_SCRATCH: SectorScratch = SectorScratch(UnsafeCell::new([0; 512]));

fn dir_scratch() -> &'static mut SectorBuf {
    // SAFETY: guarded by the single-operation invariant documented above.
    unsafe { &mut *DIR_SECTOR_SCRATCH.0.get() }
}

fn fat_scratch() -> &'static mut SectorBuf {
    // SAFETY: guarded by the single-operation invariant documented above.
    unsafe { &mut *FAT_SECTOR_SCRATCH.0.get() }
}

pub fn mount(dev: *mut BlockDev, partition_lba: u32) -> Result<Mount, MountError> {
    let mut sector = [0u8; 512];
    read_sector_raw(dev, partition_lba, &mut sector).map_err(|_| MountError::BlockReadFailed)?;
    if read_u16(&sector, 510) != 0xaa55 {
        return Err(MountError::BadBpb);
    }
    let bytes_per_sec = read_u16(&sector, 0x0b);
    let sec_per_clus = sector[0x0d];
    let rsvd_sec_cnt = read_u16(&sector, 0x0e);
    let num_fats = sector[0x10];
    let root_ent_cnt = read_u16(&sector, 0x11);
    let tot_sec_16 = read_u16(&sector, 0x13);
    let fat_sz_16 = read_u16(&sector, 0x16);
    let tot_sec_32 = read_u32(&sector, 0x20);
    let fat_sz_32 = read_u32(&sector, 0x24);
    let root_clus = read_u32(&sector, 0x2c);
    let fs_info = read_u16(&sector, 0x30);

    if bytes_per_sec != 512
        || sec_per_clus == 0
        || !sec_per_clus.is_power_of_two()
        || !(1..=2).contains(&num_fats)
    {
        return Err(MountError::BadBpb);
    }
    if fat_sz_32 == 0 || fat_sz_16 != 0 || root_ent_cnt != 0 || tot_sec_16 != 0 || root_clus < 2 {
        return Err(MountError::NotFat32);
    }

    let fat_lba = partition_lba
        .checked_add(u32::from(rsvd_sec_cnt))
        .ok_or(MountError::BadBpb)?;
    let fat_region = u64::from(num_fats) * u64::from(fat_sz_32);
    let data_lba_u64 = u64::from(fat_lba) + fat_region;
    if data_lba_u64 < u64::from(partition_lba)
        || data_lba_u64 - u64::from(partition_lba) > u64::from(tot_sec_32)
        || data_lba_u64 > u64::from(u32::MAX)
    {
        return Err(MountError::BadBpb);
    }
    let data_lba = data_lba_u64 as u32;
    let total_clusters = (tot_sec_32 - (data_lba - partition_lba)) / u32::from(sec_per_clus) + 2;
    let mut bpb = Bpb::zeroed();
    bpb.raw.copy_from_slice(&sector[..90]);

    Ok(Mount {
        bpb,
        partition_lba,
        fat_lba,
        data_lba,
        sectors_per_cluster: u32::from(sec_per_clus),
        bytes_per_cluster: u32::from(sec_per_clus) * u32::from(bytes_per_sec),
        fsinfo_lba: partition_lba.wrapping_add(u32::from(fs_info)),
        total_clusters,
        dev,
    })
}

pub fn cluster_lba(mount: &Mount, cluster: u32) -> Result<u32, FatError> {
    if cluster < 2 {
        return Err(FatError::InvalidCluster);
    }
    Ok(mount
        .data_lba
        .wrapping_add((cluster - 2).wrapping_mul(mount.sectors_per_cluster)))
}

pub fn read_fat_entry(mount: &Mount, cluster: u32) -> Result<u32, FatError> {
    if cluster < 2 || cluster >= mount.total_clusters {
        return Err(FatError::InvalidCluster);
    }
    let fat_offset = cluster * 4;
    let lba = mount.fat_lba + fat_offset / 512;
    let sector = fat_scratch();
    read_sector(mount, lba, sector)?;
    Ok(read_u32(sector, (fat_offset % 512) as usize) & 0x0fff_ffff)
}

pub fn write_fat_entry(mount: &mut Mount, cluster: u32, value: u32) -> Result<(), FatError> {
    if cluster < 2 || cluster >= mount.total_clusters {
        return Err(FatError::InvalidCluster);
    }
    let fat_offset = cluster * 4;
    let lba = mount.fat_lba + fat_offset / 512;
    let sector = fat_scratch();
    read_sector(mount, lba, sector)?;
    let offset = (fat_offset % 512) as usize;
    let old = read_u32(sector, offset);
    write_u32(sector, offset, (old & 0xf000_0000) | (value & 0x0fff_ffff));
    write_sector(mount, lba, sector)?;
    if mount.bpb.number_of_fats() >= 2 {
        write_sector(mount, lba + mount.bpb.fat_size(), sector)?;
    }
    Ok(())
}

pub fn alloc_cluster(mount: &mut Mount) -> Result<u32, AllocError> {
    let mut cluster = 2u32;
    while cluster < mount.total_clusters {
        if read_fat_entry(mount, cluster)? == FAT_FREE {
            write_fat_entry(mount, cluster, FAT_EOC)?;
            return Ok(cluster);
        }
        cluster += 1;
    }
    Err(AllocError::NoSpace)
}

pub fn fs_info_on_alloc(mount: &mut Mount, allocated_cluster: u32) -> Result<(), FatError> {
    update_fs_info(mount, allocated_cluster, false)
}

pub fn fs_info_on_free(mount: &mut Mount, freed_cluster: u32) -> Result<(), FatError> {
    update_fs_info(mount, freed_cluster, true)
}

fn update_fs_info(mount: &mut Mount, cluster: u32, freeing: bool) -> Result<(), FatError> {
    let sector = fat_scratch();
    read_sector(mount, mount.fsinfo_lba, sector)?;
    if read_u32(sector, 0) != FSINFO_LEAD_SIG || read_u32(sector, 0x1e4) != FSINFO_STRUC_SIG {
        return Ok(());
    }
    let mut free_count = read_u32(sector, 0x1e8);
    if free_count != u32::MAX {
        if freeing {
            free_count = free_count.wrapping_add(1);
        } else {
            free_count = free_count.saturating_sub(1);
        }
    }
    write_u32(sector, 0x1e8, free_count);
    write_u32(
        sector,
        0x1ec,
        if freeing {
            cluster
        } else {
            cluster.wrapping_add(1)
        },
    );
    write_sector(mount, mount.fsinfo_lba, sector)
}

pub fn lookup_in_root(mount: &Mount, name: [u8; 11]) -> Result<FoundEntry, LookupError> {
    lookup_in_dir(mount, mount.bpb.root_cluster(), name)
}

pub fn lookup_in_dir(
    mount: &Mount,
    start_cluster: u32,
    name: [u8; 11],
) -> Result<FoundEntry, LookupError> {
    let mut cluster = start_cluster;
    let mut hops = 0u32;
    let sector = dir_scratch();
    while (2..FAT_EOC_MIN).contains(&cluster) {
        let start_lba = cluster_lba(mount, cluster).map_err(|_| LookupError::InvalidCluster)?;
        let mut sector_index = 0u32;
        while sector_index < mount.sectors_per_cluster {
            let lba = start_lba + sector_index;
            read_sector(mount, lba, sector).map_err(|_| LookupError::BlockReadFailed)?;
            let mut slot = 0usize;
            while slot < 16 {
                let offset = slot * 32;
                let first = sector[offset];
                if first == 0 {
                    return Err(LookupError::NotFound);
                }
                let attr = sector[offset + 0x0b];
                if first != 0xe5
                    && attr & ATTR_LONG_NAME != ATTR_LONG_NAME
                    && sector[offset..offset + 11] == name
                {
                    return Ok(FoundEntry {
                        entry: decode_dir_entry(sector, offset),
                        lba,
                        byte_offset: offset as u16,
                    });
                }
                slot += 1;
            }
            sector_index += 1;
        }
        cluster = match read_fat_entry(mount, cluster) {
            Ok(next) => next,
            Err(FatError::InvalidCluster) => return Err(LookupError::InvalidCluster),
            Err(_) => return Err(LookupError::BlockReadFailed),
        };
        hops += 1;
        if hops > mount.total_clusters {
            return Err(LookupError::NotFound);
        }
    }
    Err(LookupError::NotFound)
}

pub fn first_cluster(entry: DirEntry) -> u32 {
    (u32::from(read_u16(&entry.raw, 0x14)) << 16) | u32::from(read_u16(&entry.raw, 0x1a))
}

pub fn lookup_path(mount: &Mount, relative: &[u8]) -> Result<FoundEntry, PathError> {
    let mut directory = mount.bpb.root_cluster();
    let mut found: Option<FoundEntry> = None;
    let mut cursor = 0usize;
    while cursor < relative.len() {
        while cursor < relative.len() && relative[cursor] == b'/' {
            cursor += 1;
        }
        if cursor >= relative.len() {
            break;
        }
        let start = cursor;
        while cursor < relative.len() && relative[cursor] != b'/' {
            cursor += 1;
        }
        if let Some(previous) = found {
            if previous.entry.attr() & ATTR_DIRECTORY == 0 {
                return Err(PathError::NotADirectory);
            }
            directory = first_cluster(previous.entry);
        }
        let name = encode_8_3(&relative[start..cursor]).ok_or(PathError::NotFound)?;
        found = Some(match lookup_in_dir(mount, directory, name) {
            Ok(entry) => entry,
            Err(LookupError::NotFound) => return Err(PathError::NotFound),
            Err(LookupError::BlockReadFailed) => return Err(PathError::BlockReadFailed),
            Err(LookupError::InvalidCluster) => return Err(PathError::InvalidCluster),
        });
    }
    found.ok_or(PathError::NotFound)
}

pub fn update_dir_entry_size(
    mount: &mut Mount,
    found: FoundEntry,
    new_size: u32,
) -> Result<(), FatError> {
    rewrite_dir_entry_field(mount, found, |sector, base| {
        write_u32(sector, base + 0x1c, new_size);
    })
}

pub fn update_dir_entry_first_cluster(
    mount: &mut Mount,
    found: FoundEntry,
    cluster: u32,
) -> Result<(), FatError> {
    rewrite_dir_entry_field(mount, found, |sector, base| {
        write_u16(sector, base + 0x14, (cluster >> 16) as u16);
        write_u16(sector, base + 0x1a, cluster as u16);
    })
}

fn rewrite_dir_entry_field(
    mount: &mut Mount,
    found: FoundEntry,
    update: impl FnOnce(&mut SectorBuf, usize),
) -> Result<(), FatError> {
    let sector = fat_scratch();
    read_sector(mount, found.lba, sector)?;
    update(sector, usize::from(found.byte_offset));
    write_sector(mount, found.lba, sector)
}

pub fn find_free_dir_slot(
    mount: &mut Mount,
    directory_cluster: u32,
) -> Result<DirSlot, DirSlotError> {
    let mut cluster = directory_cluster;
    let mut last_cluster = 0u32;
    let mut hops = 0u32;
    let sector = dir_scratch();
    while (2..FAT_EOC_MIN).contains(&cluster) {
        let start_lba = cluster_lba(mount, cluster).map_err(|_| DirSlotError::InvalidCluster)?;
        let mut sector_index = 0u32;
        while sector_index < mount.sectors_per_cluster {
            let lba = start_lba + sector_index;
            read_sector(mount, lba, sector).map_err(|_| DirSlotError::BlockReadFailed)?;
            let mut slot = 0usize;
            while slot < 16 {
                let offset = slot * 32;
                if sector[offset] == 0 || sector[offset] == 0xe5 {
                    return Ok(DirSlot {
                        lba,
                        byte_offset: offset as u16,
                    });
                }
                slot += 1;
            }
            sector_index += 1;
        }
        last_cluster = cluster;
        cluster = read_fat_entry(mount, cluster)?;
        hops += 1;
        if hops > mount.total_clusters {
            return Err(DirSlotError::NoSpace);
        }
    }
    extend_dir_chain(mount, last_cluster)
}

fn extend_dir_chain(mount: &mut Mount, last_cluster: u32) -> Result<DirSlot, DirSlotError> {
    if last_cluster < 2 {
        return Err(DirSlotError::NoSpace);
    }
    let new_cluster = alloc_cluster(mount)?;
    write_fat_entry(mount, last_cluster, new_cluster)?;
    fs_info_on_alloc(mount, new_cluster)?;
    zero_cluster(mount, new_cluster)?;
    Ok(DirSlot {
        lba: cluster_lba(mount, new_cluster)?,
        byte_offset: 0,
    })
}

fn zero_cluster(mount: &mut Mount, cluster: u32) -> Result<(), DirSlotError> {
    let start_lba = cluster_lba(mount, cluster)?;
    let sector = dir_scratch();
    sector.fill(0);
    let mut index = 0u32;
    while index < mount.sectors_per_cluster {
        write_sector(mount, start_lba + index, sector)?;
        index += 1;
    }
    Ok(())
}

pub fn write_dir_entry(
    mount: &mut Mount,
    lba: u32,
    byte_offset: u16,
    name: [u8; 11],
    attr: u8,
    first_cluster: u32,
    size: u32,
) -> Result<(), FatError> {
    let sector = dir_scratch();
    read_sector(mount, lba, sector)?;
    let base = usize::from(byte_offset);
    let mut index = 0usize;
    while index < 32 {
        sector[base + index] = 0;
        index += 1;
    }
    index = 0;
    while index < name.len() {
        sector[base + index] = name[index];
        index += 1;
    }
    sector[base + 0x0b] = attr;
    write_u16(sector, base + 0x14, (first_cluster >> 16) as u16);
    write_u16(sector, base + 0x1a, first_cluster as u16);
    write_u32(sector, base + 0x1c, size);
    write_sector(mount, lba, sector)
}

pub fn mark_deleted(mount: &mut Mount, lba: u32, byte_offset: u16) -> Result<(), FatError> {
    let sector = dir_scratch();
    read_sector(mount, lba, sector)?;
    sector[usize::from(byte_offset)] = 0xe5;
    write_sector(mount, lba, sector)
}

pub fn free_chain(mount: &mut Mount, first_cluster: u32) -> Result<(), FatError> {
    let mut cluster = first_cluster;
    let mut hops = 0u32;
    while (2..FAT_EOC_MIN).contains(&cluster) {
        let next = read_fat_entry(mount, cluster)?;
        write_fat_entry(mount, cluster, FAT_FREE)?;
        fs_info_on_free(mount, cluster)?;
        cluster = next;
        hops += 1;
        if hops > mount.total_clusters {
            return Err(FatError::InvalidCluster);
        }
    }
    Ok(())
}

pub fn encode_8_3(name: &[u8]) -> Option<[u8; 11]> {
    let dot = name
        .iter()
        .position(|&byte| byte == b'.')
        .unwrap_or(name.len());
    if dot > 8 || name.len().checked_sub(dot)? > 4 {
        return None;
    }
    let mut out = [b' '; 11];
    let mut index = 0usize;
    while index < dot && index < 8 {
        out[index] = name[index].to_ascii_uppercase();
        index += 1;
    }
    if dot < name.len() {
        let mut destination = 8usize;
        let mut source = dot + 1;
        while source < name.len() && destination < 11 {
            out[destination] = name[source].to_ascii_uppercase();
            source += 1;
            destination += 1;
        }
    }
    Some(out)
}

pub fn decode_8_3(raw: [u8; 11]) -> Rendered8_3 {
    let mut name_len = 8usize;
    while name_len > 0 && raw[name_len - 1] == b' ' {
        name_len -= 1;
    }
    let mut extension_len = 3usize;
    while extension_len > 0 && raw[8 + extension_len - 1] == b' ' {
        extension_len -= 1;
    }
    let mut rendered = Rendered8_3 {
        buf: [0; 12],
        len: 0,
    };
    let mut index = 0usize;
    while index < name_len {
        rendered.buf[rendered.len] = raw[index].to_ascii_lowercase();
        rendered.len += 1;
        index += 1;
    }
    if extension_len > 0 {
        rendered.buf[rendered.len] = b'.';
        rendered.len += 1;
        index = 0;
        while index < extension_len {
            rendered.buf[rendered.len] = raw[8 + index].to_ascii_lowercase();
            rendered.len += 1;
            index += 1;
        }
    }
    rendered
}

fn decode_dir_entry(sector: &SectorBuf, base: usize) -> DirEntry {
    let mut entry = DirEntry::zeroed();
    entry.raw.copy_from_slice(&sector[base..base + 32]);
    entry
}

fn read_sector(mount: &Mount, lba: u32, sector: &mut SectorBuf) -> Result<(), FatError> {
    read_sector_raw(mount.dev, lba, sector)
}

fn read_sector_raw(dev: *mut BlockDev, lba: u32, sector: &mut SectorBuf) -> Result<(), FatError> {
    if dev.is_null() {
        return Err(FatError::BlockReadFailed);
    }
    // SAFETY: Mount's contract keeps `dev` live; reading the callback does not
    // mutate the shared vtable.
    let callback = unsafe { (*dev).read_fn }.ok_or(FatError::BlockReadFailed)?;
    if callback(lba, sector) == 0 {
        Ok(())
    } else {
        Err(FatError::BlockReadFailed)
    }
}

fn write_sector(mount: &Mount, lba: u32, sector: &SectorBuf) -> Result<(), FatError> {
    if mount.dev.is_null() {
        return Err(FatError::BlockWriteFailed);
    }
    // SAFETY: same live-vtable contract as read_sector.
    let callback = unsafe { (*mount.dev).write_fn }.ok_or(FatError::BlockWriteFailed)?;
    if callback(lba, sector) == 0 {
        Ok(())
    } else {
        Err(FatError::BlockWriteFailed)
    }
}

fn read_u16(bytes: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([bytes[offset], bytes[offset + 1]])
}

fn read_u32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
    ])
}

fn write_u16(bytes: &mut [u8], offset: usize, value: u16) {
    bytes[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
}

fn write_u32(bytes: &mut [u8], offset: usize, value: u32) {
    bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    const FIXTURE_LEN: usize = 128 * 512;

    struct TestDisk(UnsafeCell<[u8; FIXTURE_LEN]>);

    // SAFETY: every FAT32 test takes TEST_LOCK before touching the fixture.
    unsafe impl Sync for TestDisk {}

    static HOST_DISK: TestDisk = TestDisk(UnsafeCell::new([0; FIXTURE_LEN]));
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn lock() -> MutexGuard<'static, ()> {
        TEST_LOCK
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    fn disk() -> &'static mut [u8; FIXTURE_LEN] {
        // SAFETY: caller holds TEST_LOCK for the whole test.
        unsafe { &mut *HOST_DISK.0.get() }
    }

    extern "C" fn fake_read(lba: u32, buffer: *mut [u8; 512]) -> i32 {
        let offset = lba as usize * 512;
        if offset + 512 > FIXTURE_LEN {
            return -1;
        }
        // SAFETY: tests hold TEST_LOCK; BlockDev promises a writable sector.
        unsafe {
            let source = &*HOST_DISK.0.get();
            (*buffer).copy_from_slice(&source[offset..offset + 512]);
        }
        0
    }

    extern "C" fn fake_write(lba: u32, buffer: *const [u8; 512]) -> i32 {
        let offset = lba as usize * 512;
        if offset + 512 > FIXTURE_LEN {
            return -1;
        }
        // SAFETY: tests hold TEST_LOCK; BlockDev promises a readable sector.
        unsafe {
            let destination = &mut *HOST_DISK.0.get();
            destination[offset..offset + 512].copy_from_slice(&*buffer);
        }
        0
    }

    fn fake_dev() -> BlockDev {
        BlockDev {
            read_fn: Some(fake_read),
            write_fn: Some(fake_write),
        }
    }

    fn setup_fixture() {
        let disk = disk();
        disk.fill(0);
        disk[0..3].copy_from_slice(&[0xeb, 0x58, 0x90]);
        disk[3..11].copy_from_slice(b"MSWIN4.1");
        write_u16(disk, 0x0b, 512);
        disk[0x0d] = 1;
        write_u16(disk, 0x0e, 2);
        disk[0x10] = 2;
        write_u16(disk, 0x11, 0);
        write_u16(disk, 0x13, 0);
        disk[0x15] = 0xf8;
        write_u16(disk, 0x16, 0);
        write_u32(disk, 0x20, 128);
        write_u32(disk, 0x24, 2);
        write_u32(disk, 0x2c, 2);
        write_u16(disk, 0x30, 1);
        write_u32(disk, 0x43, 12_345_678);
        disk[0x47..0x52].copy_from_slice(b"SCRATCH    ");
        disk[0x52..0x5a].copy_from_slice(b"FAT32   ");
        write_u16(disk, 510, 0xaa55);

        write_u32(disk, 512, FSINFO_LEAD_SIG);
        write_u32(disk, 512 + 0x1e4, FSINFO_STRUC_SIG);
        write_u32(disk, 512 + 0x1e8, 120);
        write_u32(disk, 512 + 0x1ec, 4);
        write_u32(disk, 512 + 0x1fc, FSINFO_TRAIL_SIG);

        for fat_base in [1024usize, 3072] {
            for (index, entry) in [0x0fff_fff8, 0x0fff_ffff, FAT_EOC, FAT_EOC]
                .into_iter()
                .enumerate()
            {
                write_u32(disk, fat_base + index * 4, entry);
            }
        }

        let root = 6 * 512;
        disk[root..root + 11].copy_from_slice(b"SCRATCH    ");
        disk[root + 0x0b] = ATTR_VOLUME_ID;
        disk[root + 32..root + 43].copy_from_slice(b"?DELETEDTXT");
        disk[root + 32] = 0xe5;
        disk[root + 32 + 0x0b] = ATTR_ARCHIVE;
        disk[root + 64..root + 75].copy_from_slice(b"HELLO   TXT");
        disk[root + 64 + 0x0b] = ATTR_ARCHIVE;
        write_u16(disk, root + 64 + 0x14, 0);
        write_u16(disk, root + 64 + 0x1a, 3);
        write_u32(disk, root + 64 + 0x1c, 11);
        disk[7 * 512..7 * 512 + 11].copy_from_slice(b"Hello World");
    }

    fn mounted(dev: &mut BlockDev) -> Mount {
        mount(dev, 0).unwrap()
    }

    fn entry_size(entry: DirEntry) -> u32 {
        entry.file_size()
    }

    #[test]
    fn mount_parses_bpb_and_computes_data_lba() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        let bytes_per_sec = mounted.bpb.bytes_per_sector();
        assert_eq!(bytes_per_sec, 512);
        assert_eq!(mounted.fat_lba, 2);
        assert_eq!(mounted.data_lba, 6);
        assert_eq!(mounted.total_clusters, 124);
    }

    #[test]
    fn mount_rejects_data_region_past_volume_end() {
        let _guard = lock();
        setup_fixture();
        write_u32(disk(), 0x24, 0x1000_0000);
        let mut dev = fake_dev();
        assert!(matches!(mount(&mut dev, 0), Err(MountError::BadBpb)));
    }

    #[test]
    fn lookup_in_root_finds_existing_entry() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        let found = lookup_in_root(&mounted, encode_8_3(b"HELLO.TXT").unwrap()).unwrap();
        assert_eq!(entry_size(found.entry), 11);
        assert_eq!(first_cluster(found.entry), 3);
    }

    #[test]
    fn lookup_terminates_on_self_looping_fat_chain() {
        let _guard = lock();
        setup_fixture();
        write_u32(disk(), 1024 + 8, 2);
        write_u32(disk(), 3072 + 8, 2);
        let root = &mut disk()[6 * 512..7 * 512];
        for slot in 0..16 {
            let offset = slot * 32;
            root[offset..offset + 11].copy_from_slice(b"OTHER   BIN");
            root[offset + 0x0b] = ATTR_ARCHIVE;
        }
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        assert!(matches!(
            lookup_in_root(&mounted, encode_8_3(b"MISSING.TXT").unwrap()),
            Err(LookupError::NotFound)
        ));
    }

    #[test]
    fn read_fat_entry_returns_eoc() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        assert_eq!(read_fat_entry(&mounted, 3), Ok(FAT_EOC));
    }

    #[test]
    fn alloc_cluster_finds_free_entry_and_marks_eoc() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        let cluster = alloc_cluster(&mut mounted).unwrap();
        assert_eq!(cluster, 4);
        assert_eq!(read_fat_entry(&mounted, cluster), Ok(FAT_EOC));
    }

    #[test]
    fn write_fat_entry_mirrors_to_second_fat() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        write_fat_entry(&mut mounted, 100, 0x12345).unwrap();
        assert_eq!(read_fat_entry(&mounted, 100), Ok(0x12345));
        assert_eq!(read_u32(disk(), 2048 + 100 * 4) & 0x0fff_ffff, 0x12345);
    }

    #[test]
    fn read_fat_entry_rejects_reserved_clusters() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        assert_eq!(read_fat_entry(&mounted, 0), Err(FatError::InvalidCluster));
        assert_eq!(read_fat_entry(&mounted, 1), Err(FatError::InvalidCluster));
    }

    #[test]
    fn write_fat_entry_rejects_reserved_clusters() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        assert_eq!(
            write_fat_entry(&mut mounted, 0, FAT_EOC),
            Err(FatError::InvalidCluster)
        );
        assert_eq!(
            write_fat_entry(&mut mounted, 1, FAT_EOC),
            Err(FatError::InvalidCluster)
        );
    }

    #[test]
    fn cluster_lba_rejects_reserved_clusters() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        assert_eq!(cluster_lba(&mounted, 0), Err(FatError::InvalidCluster));
        assert_eq!(cluster_lba(&mounted, 1), Err(FatError::InvalidCluster));
        assert_eq!(cluster_lba(&mounted, 2), Ok(mounted.data_lba));
    }

    #[test]
    fn fs_info_on_alloc_updates_count_and_hint() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        let before = read_u32(disk(), 512 + 0x1e8);
        fs_info_on_alloc(&mut mounted, 42).unwrap();
        assert_eq!(read_u32(disk(), 512 + 0x1e8), before - 1);
        assert_eq!(read_u32(disk(), 512 + 0x1ec), 43);
    }

    #[test]
    fn lookup_in_root_reports_missing_entry() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        assert!(matches!(
            lookup_in_root(&mounted, encode_8_3(b"MISSING.TXT").unwrap()),
            Err(LookupError::NotFound)
        ));
    }

    #[test]
    fn lookup_skips_deleted_entry_and_finds_later_match() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        let found = lookup_in_root(&mounted, encode_8_3(b"HELLO.TXT").unwrap()).unwrap();
        assert_eq!(found.byte_offset, 64);
    }

    #[test]
    fn update_dir_entry_size_round_trips() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        let name = encode_8_3(b"HELLO.TXT").unwrap();
        let found = lookup_in_root(&mounted, name).unwrap();
        update_dir_entry_size(&mut mounted, found, 0xdead_beef).unwrap();
        assert_eq!(
            entry_size(lookup_in_root(&mounted, name).unwrap().entry),
            0xdead_beef
        );
    }

    #[test]
    fn encode_uppercases_pads_and_accepts_dotless_name() {
        assert_eq!(encode_8_3(b"init").unwrap(), *b"INIT       ");
    }

    #[test]
    fn encode_splits_name_and_extension() {
        assert_eq!(encode_8_3(b"hello.txt").unwrap(), *b"HELLO   TXT");
    }

    #[test]
    fn encode_rejects_long_names() {
        assert_eq!(encode_8_3(b"verylongname.txt"), None);
    }

    #[test]
    fn decode_renders_lowercase_and_trims_padding() {
        let rendered = decode_8_3(*b"HELLO   TXT");
        assert_eq!(&rendered.buf[..rendered.len], b"hello.txt");
    }

    #[test]
    fn decode_drops_dot_for_empty_extension() {
        let rendered = decode_8_3(*b"INIT       ");
        assert_eq!(&rendered.buf[..rendered.len], b"init");
    }

    #[test]
    fn encode_decode_round_trip() {
        let rendered = decode_8_3(encode_8_3(b"readme.md").unwrap());
        assert_eq!(&rendered.buf[..rendered.len], b"readme.md");
    }

    fn put_entry(base: usize, name: &[u8; 11], attr: u8, first: u16, size: u32) {
        let disk = disk();
        disk[base..base + 11].copy_from_slice(name);
        disk[base + 0x0b] = attr;
        write_u16(disk, base + 0x14, 0);
        write_u16(disk, base + 0x1a, first);
        write_u32(disk, base + 0x1c, size);
    }

    fn seed_subtree() {
        put_entry(6 * 512 + 96, b"SUBDIR     ", ATTR_DIRECTORY, 4, 0);
        put_entry(8 * 512, b"DEEP    TXT", ATTR_ARCHIVE, 6, 7);
        put_entry(8 * 512 + 32, b"SUB2       ", ATTR_DIRECTORY, 5, 0);
        put_entry(9 * 512, b"NEST    TXT", ATTR_ARCHIVE, 7, 9);
        for fat_base in [1024usize, 3072] {
            write_u32(disk(), fat_base + 4 * 4, FAT_EOC);
            write_u32(disk(), fat_base + 5 * 4, FAT_EOC);
        }
    }

    #[test]
    fn lookup_path_descends_one_level() {
        let _guard = lock();
        setup_fixture();
        seed_subtree();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        let found = lookup_path(&mounted, b"subdir/deep.txt").unwrap();
        assert_eq!(entry_size(found.entry), 7);
        assert_eq!(first_cluster(found.entry), 6);
    }

    #[test]
    fn lookup_path_descends_two_levels() {
        let _guard = lock();
        setup_fixture();
        seed_subtree();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        let found = lookup_path(&mounted, b"subdir/sub2/nest.txt").unwrap();
        assert_eq!(entry_size(found.entry), 9);
        assert_eq!(first_cluster(found.entry), 7);
    }

    #[test]
    fn lookup_path_single_component_uses_root() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        let found = lookup_path(&mounted, b"hello.txt").unwrap();
        assert_eq!(entry_size(found.entry), 11);
        assert_eq!(first_cluster(found.entry), 3);
    }

    #[test]
    fn lookup_path_rejects_file_as_intermediate_directory() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        assert!(matches!(
            lookup_path(&mounted, b"hello.txt/deep.txt"),
            Err(PathError::NotADirectory)
        ));
    }

    #[test]
    fn lookup_path_reports_missing_intermediate_directory() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        assert!(matches!(
            lookup_path(&mounted, b"nope/deep.txt"),
            Err(PathError::NotFound)
        ));
    }

    #[test]
    fn lookup_path_reports_missing_leaf() {
        let _guard = lock();
        setup_fixture();
        seed_subtree();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        assert!(matches!(
            lookup_path(&mounted, b"subdir/missing.txt"),
            Err(PathError::NotFound)
        ));
    }

    #[test]
    fn lookup_path_tolerates_redundant_slashes() {
        let _guard = lock();
        setup_fixture();
        seed_subtree();
        let mut dev = fake_dev();
        let mounted = mounted(&mut dev);
        assert_eq!(
            first_cluster(lookup_path(&mounted, b"/subdir//deep.txt").unwrap().entry),
            6
        );
    }

    fn free_count(mount: &Mount) -> u32 {
        let mut sector = [0; 512];
        fake_read(mount.fsinfo_lba, &mut sector);
        read_u32(&sector, 0x1e8)
    }

    fn fill_root_cluster() {
        let root = &mut disk()[6 * 512..7 * 512];
        for slot in 0..16 {
            let offset = slot * 32;
            root[offset..offset + 11].copy_from_slice(b"FULL    BIN");
            root[offset + 0x0b] = ATTR_ARCHIVE;
        }
    }

    #[test]
    fn find_free_dir_slot_reuses_deleted_slot() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        let root = mounted.bpb.root_cluster();
        assert_eq!(
            find_free_dir_slot(&mut mounted, root).unwrap(),
            DirSlot {
                lba: 6,
                byte_offset: 32
            }
        );
    }

    #[test]
    fn find_free_dir_slot_returns_first_end_marker() {
        let _guard = lock();
        setup_fixture();
        seed_subtree();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        assert_eq!(
            find_free_dir_slot(&mut mounted, 4).unwrap(),
            DirSlot {
                lba: 8,
                byte_offset: 64
            }
        );
    }

    #[test]
    fn find_free_dir_slot_extends_full_directory() {
        let _guard = lock();
        setup_fixture();
        fill_root_cluster();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        let before = free_count(&mounted);
        let root = mounted.bpb.root_cluster();
        assert_eq!(
            find_free_dir_slot(&mut mounted, root).unwrap(),
            DirSlot {
                lba: 8,
                byte_offset: 0
            }
        );
        assert_eq!(read_fat_entry(&mounted, 2), Ok(4));
        assert_eq!(read_fat_entry(&mounted, 4), Ok(FAT_EOC));
        assert_eq!(free_count(&mounted), before - 1);
    }

    #[test]
    fn find_free_dir_slot_terminates_on_cycle() {
        let _guard = lock();
        setup_fixture();
        fill_root_cluster();
        write_u32(disk(), 1024 + 8, 2);
        write_u32(disk(), 3072 + 8, 2);
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        let root = mounted.bpb.root_cluster();
        assert_eq!(
            find_free_dir_slot(&mut mounted, root),
            Err(DirSlotError::NoSpace)
        );
    }

    #[test]
    fn write_dir_entry_stamps_findable_entry() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        let name = encode_8_3(b"new.fl").unwrap();
        let root = mounted.bpb.root_cluster();
        let slot = find_free_dir_slot(&mut mounted, root).unwrap();
        write_dir_entry(
            &mut mounted,
            slot.lba,
            slot.byte_offset,
            name,
            ATTR_ARCHIVE,
            0,
            0,
        )
        .unwrap();
        let found = lookup_in_root(&mounted, name).unwrap();
        assert_eq!(found.byte_offset, slot.byte_offset);
        assert_eq!(entry_size(found.entry), 0);
        assert_eq!(first_cluster(found.entry), 0);
    }

    #[test]
    fn write_dir_entry_rewrites_name_preserving_cluster_and_size() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        let old = encode_8_3(b"hello.txt").unwrap();
        let found = lookup_in_root(&mounted, old).unwrap();
        let new = encode_8_3(b"renamed.fl").unwrap();
        let attr = found.entry.attr();
        write_dir_entry(
            &mut mounted,
            found.lba,
            found.byte_offset,
            new,
            attr,
            first_cluster(found.entry),
            entry_size(found.entry),
        )
        .unwrap();
        let renamed = lookup_in_root(&mounted, new).unwrap();
        assert_eq!(entry_size(renamed.entry), 11);
        assert_eq!(first_cluster(renamed.entry), 3);
        assert!(matches!(
            lookup_in_root(&mounted, old),
            Err(LookupError::NotFound)
        ));
    }

    #[test]
    fn mark_deleted_and_free_chain_unlink_file() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        let name = encode_8_3(b"hello.txt").unwrap();
        let found = lookup_in_root(&mounted, name).unwrap();
        let cluster = first_cluster(found.entry);
        let before = free_count(&mounted);
        mark_deleted(&mut mounted, found.lba, found.byte_offset).unwrap();
        free_chain(&mut mounted, cluster).unwrap();
        assert!(matches!(
            lookup_in_root(&mounted, name),
            Err(LookupError::NotFound)
        ));
        assert_eq!(read_fat_entry(&mounted, cluster), Ok(FAT_FREE));
        assert_eq!(free_count(&mounted), before + 1);
    }

    #[test]
    fn free_chain_of_empty_file_is_noop() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        let before = free_count(&mounted);
        free_chain(&mut mounted, 0).unwrap();
        assert_eq!(free_count(&mounted), before);
    }

    #[test]
    fn free_count_round_trips_through_alloc_and_free() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        let before = free_count(&mounted);
        let cluster = alloc_cluster(&mut mounted).unwrap();
        fs_info_on_alloc(&mut mounted, cluster).unwrap();
        assert_eq!(free_count(&mounted), before - 1);
        free_chain(&mut mounted, cluster).unwrap();
        assert_eq!(free_count(&mounted), before);
    }

    #[test]
    fn free_chain_frees_every_link() {
        let _guard = lock();
        setup_fixture();
        let mut dev = fake_dev();
        let mut mounted = mounted(&mut dev);
        let first = alloc_cluster(&mut mounted).unwrap();
        let second = alloc_cluster(&mut mounted).unwrap();
        write_fat_entry(&mut mounted, first, second).unwrap();
        free_chain(&mut mounted, first).unwrap();
        assert_eq!(read_fat_entry(&mounted, first), Ok(FAT_FREE));
        assert_eq!(read_fat_entry(&mounted, second), Ok(FAT_FREE));
    }
}
