// FAT32 — single source of truth for on-disk layout (v0.4.0).
//
// All field offsets / sizes follow Microsoft's "FAT: General Overview
// of On-Disk Format" v1.03. Implements:
//   * BPB parse (only the fields we need: BytsPerSec, SecPerClus,
//     RsvdSecCnt, NumFATs, FATSz32, RootClus, FSInfo)
//   * FAT table read/write (cluster -> next cluster, allocate fresh)
//   * Directory entry decode (8.3 only, no VFAT/LFN)
//   * Cluster allocate (linear scan, mark EOC, update FSInfo hints)
//   * FSInfo update (free_count decrement + next_free hint advance)
//
// Out of scope: LFN, attributes-as-permissions, sub-second
// timestamps, file deletion (sys_unlink is future work).
//
// Block I/O is the caller's responsibility — every helper takes a
// `*const Mount` (or `*Mount` for write paths) holding the
// `*const block_dev.BlockDev` runtime pointer. That keeps fat32.zig
// host-testable against an in-memory fake without a freestanding
// dependency.
//
// Layout decision: `packed struct` for the two on-disk types we
// actually access by field (Bpb + DirEntry). Zig's `extern struct`
// follows the C ABI and inserts alignment padding (u16 @ 0x0B
// bumps to 0x0C), which silently breaks every @offsetOf assumption
// against the FAT32 spec. Packed structs preserve bit-exact layout
// for known integer types; comptime asserts pin the spec offsets.
//
// FSInfo is decoded/encoded via std.mem.readInt / writeInt against
// the 512-byte sector buffer — a packed struct would need a u3712
// gap field that pushes some Zig versions over an internal size
// limit, and the only three fields we touch (lead/struc/free_count
// + next_free) are easier read byte-wise.

const std = @import("std");
const block_dev = @import("block_dev");

pub const Bpb = packed struct {
    jmp_boot: u24, // 0x00 (3 bytes)
    oem_name: u64, // 0x03 (8 bytes — opaque)
    bytes_per_sec: u16, // 0x0B
    sec_per_clus: u8, // 0x0D
    rsvd_sec_cnt: u16, // 0x0E
    num_fats: u8, // 0x10
    root_ent_cnt: u16, // 0x11 — must be 0 on FAT32
    tot_sec_16: u16, // 0x13 — must be 0 on FAT32
    media: u8, // 0x15
    fat_sz_16: u16, // 0x16 — must be 0 on FAT32
    sec_per_trk: u16, // 0x18
    num_heads: u16, // 0x1A
    hidd_sec: u32, // 0x1C
    tot_sec_32: u32, // 0x20
    fat_sz_32: u32, // 0x24
    ext_flags: u16, // 0x28
    fs_ver: u16, // 0x2A
    root_clus: u32, // 0x2C
    fs_info: u16, // 0x30
    bk_boot_sec: u16, // 0x32
    reserved: u96, // 0x34 (12 bytes)
    drv_num: u8, // 0x40
    reserved1: u8, // 0x41
    boot_sig: u8, // 0x42
    vol_id: u32, // 0x43
    vol_lab_lo: u64, // 0x47 (8 of 11)
    vol_lab_hi: u24, // 0x4F (3 of 11)
    fil_sys_type: u64, // 0x52 (8 bytes)
};
comptime {
    if (@bitOffsetOf(Bpb, "fat_sz_32") / 8 != 0x24) @compileError("BPB fat_sz_32 offset");
    if (@bitOffsetOf(Bpb, "root_clus") / 8 != 0x2C) @compileError("BPB root_clus offset");
    if (@bitOffsetOf(Bpb, "fs_info") / 8 != 0x30) @compileError("BPB fs_info offset");
}

pub const DirEntry = packed struct {
    name_lo: u64, // 0x00 (8 of 11 — 8.3 first half)
    name_hi: u24, // 0x08 (3 of 11 — 8.3 extension)
    attr: u8, // 0x0B
    nt_res: u8, // 0x0C
    crt_time_tenth: u8, // 0x0D
    crt_time: u16, // 0x0E
    crt_date: u16, // 0x10
    lst_acc_date: u16, // 0x12
    fst_clus_hi: u16, // 0x14
    wrt_time: u16, // 0x16
    wrt_date: u16, // 0x18
    fst_clus_lo: u16, // 0x1A
    file_size: u32, // 0x1C
};
comptime {
    if (@sizeOf(DirEntry) != 32) @compileError("DirEntry size");
    if (@bitOffsetOf(DirEntry, "attr") / 8 != 0x0B) @compileError("DirEntry attr offset");
    if (@bitOffsetOf(DirEntry, "file_size") / 8 != 0x1C) @compileError("DirEntry file_size offset");
}

pub const ATTR_READ_ONLY: u8 = 0x01;
pub const ATTR_HIDDEN: u8 = 0x02;
pub const ATTR_SYSTEM: u8 = 0x04;
pub const ATTR_VOLUME_ID: u8 = 0x08;
pub const ATTR_DIRECTORY: u8 = 0x10;
pub const ATTR_ARCHIVE: u8 = 0x20;
pub const ATTR_LONG_NAME: u8 = 0x0F;

pub const FAT_EOC: u32 = 0x0FFFFFFF;
pub const FAT_FREE: u32 = 0;
pub const FAT_BAD: u32 = 0x0FFFFFF7;
// End-of-chain test threshold. The FAT32 spec marks end-of-chain as
// ANY value >= 0x0FFFFFF8 (mkfs/mformat write 0x0FFFFFF8 or
// 0x0FFFFFFF interchangeably). Chain walkers must test
// `>= FAT_EOC_MIN`, not `== FAT_EOC` / `>= FAT_EOC` — otherwise a
// 0x0FFFFFF8 terminator reads as a (bogus) next cluster. allocCluster
// keeps writing FAT_EOC (0x0FFFFFFF), which is inside this range, so
// freshly-extended chains terminate correctly under the same test.
pub const FAT_EOC_MIN: u32 = 0x0FFFFFF8;

pub const FSINFO_LEAD_SIG: u32 = 0x41615252;
pub const FSINFO_STRUC_SIG: u32 = 0x61417272;
pub const FSINFO_TRAIL_SIG: u32 = 0xAA550000;

pub const Mount = struct {
    bpb: Bpb,
    partition_lba: u32,
    fat_lba: u32,
    data_lba: u32,
    sectors_per_cluster: u32,
    bytes_per_cluster: u32,
    fsinfo_lba: u32,
    total_clusters: u32,
    dev: *const block_dev.BlockDev,
};

pub const SectorBuf = [512]u8;

pub const MountError = error{ BadBpb, NotFat32, BlockReadFailed };

pub fn mount(dev: *const block_dev.BlockDev, partition_lba: u32) MountError!Mount {
    var sector: SectorBuf align(4) = undefined;
    if (dev.read_fn(partition_lba, &sector) != 0) return error.BlockReadFailed;
    if (std.mem.readInt(u16, sector[510..512], .little) != 0xAA55) return error.BadBpb;
    const bytes_per_sec = std.mem.readInt(u16, sector[0x0B..0x0D], .little);
    const sec_per_clus = sector[0x0D];
    const rsvd_sec_cnt = std.mem.readInt(u16, sector[0x0E..0x10], .little);
    const num_fats = sector[0x10];
    const root_ent_cnt = std.mem.readInt(u16, sector[0x11..0x13], .little);
    const tot_sec_16 = std.mem.readInt(u16, sector[0x13..0x15], .little);
    const fat_sz_16 = std.mem.readInt(u16, sector[0x16..0x18], .little);
    const tot_sec_32 = std.mem.readInt(u32, sector[0x20..0x24], .little);
    const fat_sz_32 = std.mem.readInt(u32, sector[0x24..0x28], .little);
    const root_clus = std.mem.readInt(u32, sector[0x2C..0x30], .little);
    const fs_info = std.mem.readInt(u16, sector[0x30..0x32], .little);

    if (bytes_per_sec != 512) return error.BadBpb;
    if (sec_per_clus == 0 or (sec_per_clus & (sec_per_clus - 1)) != 0) return error.BadBpb;
    if (num_fats < 1 or num_fats > 2) return error.BadBpb;
    if (fat_sz_32 == 0 or fat_sz_16 != 0) return error.NotFat32;
    if (root_ent_cnt != 0 or tot_sec_16 != 0) return error.NotFat32;
    if (root_clus < 2) return error.NotFat32;

    var bpb: Bpb = undefined;
    bpb.bytes_per_sec = bytes_per_sec;
    bpb.sec_per_clus = sec_per_clus;
    bpb.rsvd_sec_cnt = rsvd_sec_cnt;
    bpb.num_fats = num_fats;
    bpb.tot_sec_32 = tot_sec_32;
    bpb.fat_sz_32 = fat_sz_32;
    bpb.root_clus = root_clus;
    bpb.fs_info = fs_info;

    const fat_lba = partition_lba + rsvd_sec_cnt;
    const data_lba = fat_lba + @as(u32, num_fats) * fat_sz_32;
    const total_clusters = (tot_sec_32 - (data_lba - partition_lba)) / sec_per_clus + 2;

    return .{
        .bpb = bpb,
        .partition_lba = partition_lba,
        .fat_lba = fat_lba,
        .data_lba = data_lba,
        .sectors_per_cluster = sec_per_clus,
        .bytes_per_cluster = @as(u32, sec_per_clus) * bytes_per_sec,
        .fsinfo_lba = partition_lba + fs_info,
        .total_clusters = total_clusters,
        .dev = dev,
    };
}

pub fn clusterLba(m: *const Mount, cluster: u32) u32 {
    return m.data_lba + (cluster - 2) * m.sectors_per_cluster;
}

pub const FatError = error{ BlockReadFailed, BlockWriteFailed, InvalidCluster };

pub fn readFatEntry(m: *const Mount, cluster: u32) FatError!u32 {
    if (cluster < 2 or cluster >= m.total_clusters) return error.InvalidCluster;
    const fat_offset: u32 = cluster * 4;
    const lba = m.fat_lba + fat_offset / 512;
    var sector: SectorBuf align(4) = undefined;
    if (m.dev.read_fn(lba, &sector) != 0) return error.BlockReadFailed;
    const idx_byte = fat_offset % 512;
    return std.mem.readInt(u32, sector[idx_byte..][0..4], .little) & 0x0FFFFFFF;
}

pub fn writeFatEntry(m: *Mount, cluster: u32, value: u32) FatError!void {
    if (cluster < 2 or cluster >= m.total_clusters) return error.InvalidCluster;
    const fat_offset: u32 = cluster * 4;
    const lba = m.fat_lba + fat_offset / 512;
    var sector: SectorBuf align(4) = undefined;
    if (m.dev.read_fn(lba, &sector) != 0) return error.BlockReadFailed;
    const idx_byte = fat_offset % 512;
    const old = std.mem.readInt(u32, sector[idx_byte..][0..4], .little);
    const new = (old & 0xF0000000) | (value & 0x0FFFFFFF);
    std.mem.writeInt(u32, sector[idx_byte..][0..4], new, .little);
    if (m.dev.write_fn(lba, &sector) != 0) return error.BlockWriteFailed;
    if (m.bpb.num_fats >= 2) {
        const lba2 = lba + m.bpb.fat_sz_32;
        if (m.dev.write_fn(lba2, &sector) != 0) return error.BlockWriteFailed;
    }
}

pub const AllocError = error{ NoSpace, BlockReadFailed, BlockWriteFailed, InvalidCluster };

pub fn allocCluster(m: *Mount) AllocError!u32 {
    // Linear scan from cluster 2 upward. Future work replaces with
    // the FSInfo next_free hint when contention shows up;
    // single-writer + small disks for v0.4.0 makes the scan fast
    // enough.
    var cluster: u32 = 2;
    while (cluster < m.total_clusters) : (cluster += 1) {
        const entry = try readFatEntry(m, cluster);
        if (entry == FAT_FREE) {
            try writeFatEntry(m, cluster, FAT_EOC);
            return cluster;
        }
    }
    return error.NoSpace;
}

pub fn fsInfoOnAlloc(m: *Mount, allocated_cluster: u32) FatError!void {
    var sector: SectorBuf align(4) = undefined;
    if (m.dev.read_fn(m.fsinfo_lba, &sector) != 0) return error.BlockReadFailed;
    const lead = std.mem.readInt(u32, sector[0x000..0x004], .little);
    const struc = std.mem.readInt(u32, sector[0x1E4..0x1E8], .little);
    if (lead != FSINFO_LEAD_SIG or struc != FSINFO_STRUC_SIG) {
        // Corrupted FSInfo — bail without touching it. A future
        // fsck recomputes; trying to "fix" it here risks compounding
        // the damage.
        return;
    }
    var free_count = std.mem.readInt(u32, sector[0x1E8..0x1EC], .little);
    if (free_count != 0xFFFFFFFF and free_count > 0) free_count -= 1;
    std.mem.writeInt(u32, sector[0x1E8..0x1EC], free_count, .little);
    std.mem.writeInt(u32, sector[0x1EC..0x1F0], allocated_cluster + 1, .little);
    if (m.dev.write_fn(m.fsinfo_lba, &sector) != 0) return error.BlockWriteFailed;
}

pub const FoundEntry = struct {
    entry: DirEntry,
    lba: u32,
    byte_offset: u16,
};

pub const LookupError = error{ NotFound, BlockReadFailed, InvalidCluster };

pub fn lookupInRoot(m: *const Mount, name8_3: [11]u8) LookupError!FoundEntry {
    var cluster: u32 = m.bpb.root_clus;
    var sector_buf: SectorBuf align(4) = undefined;
    while (cluster >= 2 and cluster < FAT_EOC) {
        const start_lba = clusterLba(m, cluster);
        var i: u32 = 0;
        while (i < m.sectors_per_cluster) : (i += 1) {
            const lba = start_lba + i;
            if (m.dev.read_fn(lba, &sector_buf) != 0) return error.BlockReadFailed;
            var j: u16 = 0;
            while (j < 16) : (j += 1) {
                const byte_off: u16 = j * 32;
                const first_byte = sector_buf[byte_off];
                if (first_byte == 0x00) return error.NotFound; // end-of-dir
                if (first_byte == 0xE5) continue; // deleted
                const attr = sector_buf[byte_off + 0x0B];
                if ((attr & ATTR_LONG_NAME) == ATTR_LONG_NAME) continue;
                if (std.mem.eql(u8, sector_buf[byte_off..][0..11], &name8_3)) {
                    var e: DirEntry = undefined;
                    e.name_lo = std.mem.readInt(u64, sector_buf[byte_off..][0..8], .little);
                    e.name_hi = std.mem.readInt(u24, sector_buf[byte_off + 8 ..][0..3], .little);
                    e.attr = attr;
                    e.fst_clus_hi = std.mem.readInt(u16, sector_buf[byte_off + 0x14 ..][0..2], .little);
                    e.fst_clus_lo = std.mem.readInt(u16, sector_buf[byte_off + 0x1A ..][0..2], .little);
                    e.file_size = std.mem.readInt(u32, sector_buf[byte_off + 0x1C ..][0..4], .little);
                    return .{ .entry = e, .lba = lba, .byte_offset = byte_off };
                }
            }
        }
        cluster = readFatEntry(m, cluster) catch |err| return switch (err) {
            error.InvalidCluster => error.InvalidCluster,
            error.BlockReadFailed, error.BlockWriteFailed => error.BlockReadFailed,
        };
    }
    return error.NotFound;
}

pub fn updateDirEntrySize(m: *Mount, found: FoundEntry, new_size: u32) FatError!void {
    var sector_buf: SectorBuf align(4) = undefined;
    if (m.dev.read_fn(found.lba, &sector_buf) != 0) return error.BlockReadFailed;
    std.mem.writeInt(u32, sector_buf[found.byte_offset + 0x1C ..][0..4], new_size, .little);
    if (m.dev.write_fn(found.lba, &sector_buf) != 0) return error.BlockWriteFailed;
}

pub fn encode8_3(name: []const u8) ?[11]u8 {
    var out: [11]u8 = .{' '} ** 11;
    var dot: usize = name.len;
    for (name, 0..) |c, i| {
        if (c == '.') {
            dot = i;
            break;
        }
    }
    if (dot > 8 or (name.len - dot) > 4) return null;
    var i: usize = 0;
    while (i < dot and i < 8) : (i += 1) {
        const c = name[i];
        if (c >= 'a' and c <= 'z') out[i] = c - 0x20 else out[i] = c;
    }
    if (dot < name.len) {
        var k: usize = 0;
        var src = dot + 1;
        while (src < name.len and k < 3) : ({
            src += 1;
            k += 1;
        }) {
            const c = name[src];
            if (c >= 'a' and c <= 'z') out[8 + k] = c - 0x20 else out[8 + k] = c;
        }
    }
    return out;
}

// ---- Host tests ----
//
// The fixture is a minimal-but-real FAT32 volume built into a
// 64 KiB BSS buffer at test time (not comptime — Zig's comptime
// budget can't carry a full image, and an external fixture file
// would need a named-module hop). Geometry:
//
//   bytes_per_sec   = 512
//   sec_per_clus    = 1
//   rsvd_sec_cnt    = 2     (LBA 0 = BPB, LBA 1 = FSInfo)
//   num_fats        = 2
//   fat_sz_32       = 2     (256 entries per FAT)
//   root_clus       = 2     (root dir at cluster 2 = LBA 6)
//   tot_sec_32      = 128
//   total_clusters  = 124   (entries 2..125 valid)
//
// Root cluster (LBA 6) carries: VOLUME_ID entry + a 0xE5 deleted
// entry + HELLO.TXT + a 0x00 end-of-dir marker. HELLO.TXT lives at
// cluster 3 (LBA 7), one cluster, FAT entry EOC.

const testing = std.testing;

const FIXTURE_LEN: usize = 128 * 512;

var host_disk: [FIXTURE_LEN]u8 align(512) = undefined;

fn setupFixture() void {
    @memset(&host_disk, 0);

    // ---- LBA 0: BPB ----
    const bpb_sector = host_disk[0..512];
    bpb_sector[0] = 0xEB;
    bpb_sector[1] = 0x58;
    bpb_sector[2] = 0x90;
    @memcpy(bpb_sector[3..11], "MSWIN4.1");
    std.mem.writeInt(u16, bpb_sector[0x0B..0x0D], 512, .little); // bytes_per_sec
    bpb_sector[0x0D] = 1; // sec_per_clus
    std.mem.writeInt(u16, bpb_sector[0x0E..0x10], 2, .little); // rsvd_sec_cnt
    bpb_sector[0x10] = 2; // num_fats
    std.mem.writeInt(u16, bpb_sector[0x11..0x13], 0, .little); // root_ent_cnt
    std.mem.writeInt(u16, bpb_sector[0x13..0x15], 0, .little); // tot_sec_16
    bpb_sector[0x15] = 0xF8; // media
    std.mem.writeInt(u16, bpb_sector[0x16..0x18], 0, .little); // fat_sz_16
    std.mem.writeInt(u32, bpb_sector[0x20..0x24], 128, .little); // tot_sec_32
    std.mem.writeInt(u32, bpb_sector[0x24..0x28], 2, .little); // fat_sz_32
    std.mem.writeInt(u32, bpb_sector[0x2C..0x30], 2, .little); // root_clus
    std.mem.writeInt(u16, bpb_sector[0x30..0x32], 1, .little); // fs_info
    std.mem.writeInt(u32, bpb_sector[0x43..0x47], 12345678, .little); // vol_id
    @memcpy(bpb_sector[0x47..0x52], "SCRATCH    ");
    @memcpy(bpb_sector[0x52..0x5A], "FAT32   ");
    std.mem.writeInt(u16, bpb_sector[510..512], 0xAA55, .little);

    // ---- LBA 1: FSInfo ----
    const fsi_sector = host_disk[512..1024];
    std.mem.writeInt(u32, fsi_sector[0x000..0x004], FSINFO_LEAD_SIG, .little);
    std.mem.writeInt(u32, fsi_sector[0x1E4..0x1E8], FSINFO_STRUC_SIG, .little);
    std.mem.writeInt(u32, fsi_sector[0x1E8..0x1EC], 120, .little); // free_count
    std.mem.writeInt(u32, fsi_sector[0x1EC..0x1F0], 4, .little); // next_free
    std.mem.writeInt(u32, fsi_sector[0x1FC..0x200], FSINFO_TRAIL_SIG, .little);

    // ---- LBA 2..3 : FAT1 ; LBA 4..5: FAT2 (mirror) ----
    // Cluster 0 = media + reserved bits, cluster 1 = clean, cluster 2
    // (root) = EOC, cluster 3 (HELLO.TXT) = EOC.
    const fat_entries = [_]u32{
        0x0FFFFFF8, // 0
        0x0FFFFFFF, // 1
        FAT_EOC, // 2 root dir
        FAT_EOC, // 3 HELLO.TXT
    };
    inline for (.{ 1024, 3072 }) |fat_base| { // FAT1 @ LBA 2 (1024) + FAT2 @ LBA 4 (3072)
        for (fat_entries, 0..) |entry, idx| {
            const off = fat_base + idx * 4;
            std.mem.writeInt(u32, host_disk[off..][0..4], entry, .little);
        }
    }

    // ---- LBA 6: root dir cluster (cluster 2) ----
    const root_sector = host_disk[6 * 512 .. 7 * 512];

    // Entry 0: VOLUME_ID
    @memcpy(root_sector[0..11], "SCRATCH    ");
    root_sector[0x0B] = ATTR_VOLUME_ID;

    // Entry 1: deleted (0xE5 first byte)
    @memcpy(root_sector[32 .. 32 + 11], "?DELETEDTXT");
    root_sector[32] = 0xE5;
    root_sector[32 + 0x0B] = ATTR_ARCHIVE;

    // Entry 2: HELLO.TXT, first cluster 3, file_size 11
    @memcpy(root_sector[64 .. 64 + 11], "HELLO   TXT");
    root_sector[64 + 0x0B] = ATTR_ARCHIVE;
    std.mem.writeInt(u16, root_sector[64 + 0x14 ..][0..2], 0, .little); // fst_clus_hi
    std.mem.writeInt(u16, root_sector[64 + 0x1A ..][0..2], 3, .little); // fst_clus_lo
    std.mem.writeInt(u32, root_sector[64 + 0x1C ..][0..4], 11, .little); // file_size

    // Entry 3 onwards: first byte 0x00 (end-of-directory). @memset
    // above already zeroed the rest of the sector, so nothing to do.

    // ---- LBA 7: HELLO.TXT data (cluster 3) ----
    @memcpy(host_disk[7 * 512 ..][0..11], "Hello World");
}

fn fakeRead(lba: u32, buf: *[512]u8) callconv(.c) i32 {
    const off: usize = @as(usize, lba) * 512;
    if (off + 512 > host_disk.len) return -1;
    @memcpy(buf, host_disk[off..][0..512]);
    return 0;
}
fn fakeWrite(lba: u32, buf: *const [512]u8) callconv(.c) i32 {
    const off: usize = @as(usize, lba) * 512;
    if (off + 512 > host_disk.len) return -1;
    @memcpy(host_disk[off..][0..512], buf);
    return 0;
}
const fake_dev: block_dev.BlockDev = .{ .read_fn = fakeRead, .write_fn = fakeWrite };

test "mount parses BPB and computes data_lba" {
    setupFixture();
    const m = try mount(&fake_dev, 0);
    try testing.expectEqual(@as(u32, 512), @as(u32, m.bpb.bytes_per_sec));
    try testing.expectEqual(@as(u32, 2), m.fat_lba);
    try testing.expectEqual(@as(u32, 6), m.data_lba);
    try testing.expectEqual(@as(u32, 124), m.total_clusters);
}

test "lookupInRoot finds an existing 8.3 entry" {
    setupFixture();
    const m = try mount(&fake_dev, 0);
    const name = encode8_3("HELLO.TXT") orelse return error.EncodeFail;
    const found = try lookupInRoot(&m, name);
    try testing.expectEqual(@as(u32, 11), found.entry.file_size);
    const first_clus = (@as(u32, found.entry.fst_clus_hi) << 16) | found.entry.fst_clus_lo;
    try testing.expectEqual(@as(u32, 3), first_clus);
}

test "readFatEntry returns EOC for end-of-chain" {
    setupFixture();
    const m = try mount(&fake_dev, 0);
    const next = try readFatEntry(&m, 3); // HELLO.TXT's only cluster
    try testing.expectEqual(FAT_EOC, next);
}

test "allocCluster finds a free entry and marks EOC" {
    setupFixture();
    var m = try mount(&fake_dev, 0);
    const c = try allocCluster(&m);
    try testing.expectEqual(@as(u32, 4), c); // clusters 2+3 used; 4 is first free
    const after = try readFatEntry(&m, c);
    try testing.expectEqual(FAT_EOC, after);
}

test "writeFatEntry mirrors to FAT2 when NumFATs >= 2" {
    setupFixture();
    var m = try mount(&fake_dev, 0);
    try writeFatEntry(&m, 100, 0x12345);
    const reread = try readFatEntry(&m, 100);
    try testing.expectEqual(@as(u32, 0x12345), reread);
    // Read the FAT2 mirror directly via the same offset arithmetic
    // readFatEntry uses, but against (fat_lba + fat_sz_32).
    var sector: [512]u8 align(4) = undefined;
    const fat2_lba = m.fat_lba + m.bpb.fat_sz_32;
    _ = fake_dev.read_fn(fat2_lba + (100 * 4) / 512, &sector);
    const mirror = std.mem.readInt(u32, sector[(100 * 4) % 512 ..][0..4], .little) & 0x0FFFFFFF;
    try testing.expectEqual(@as(u32, 0x12345), mirror);
}

test "readFatEntry rejects cluster < 2" {
    setupFixture();
    const m = try mount(&fake_dev, 0);
    try testing.expectError(error.InvalidCluster, readFatEntry(&m, 0));
    try testing.expectError(error.InvalidCluster, readFatEntry(&m, 1));
}

test "writeFatEntry rejects cluster < 2" {
    setupFixture();
    var m = try mount(&fake_dev, 0);
    try testing.expectError(error.InvalidCluster, writeFatEntry(&m, 0, FAT_EOC));
    try testing.expectError(error.InvalidCluster, writeFatEntry(&m, 1, FAT_EOC));
}

test "fsInfoOnAlloc decrements free_count and advances next_free" {
    setupFixture();
    var m = try mount(&fake_dev, 0);
    var pre_sector: [512]u8 align(4) = undefined;
    _ = fake_dev.read_fn(m.fsinfo_lba, &pre_sector);
    const free_before = std.mem.readInt(u32, pre_sector[0x1E8..0x1EC], .little);
    try fsInfoOnAlloc(&m, 42);
    var post_sector: [512]u8 align(4) = undefined;
    _ = fake_dev.read_fn(m.fsinfo_lba, &post_sector);
    const free_after = std.mem.readInt(u32, post_sector[0x1E8..0x1EC], .little);
    const next_after = std.mem.readInt(u32, post_sector[0x1EC..0x1F0], .little);
    try testing.expectEqual(free_before - 1, free_after);
    try testing.expectEqual(@as(u32, 43), next_after);
}

test "lookupInRoot returns NotFound for missing entry" {
    setupFixture();
    const m = try mount(&fake_dev, 0);
    const name = encode8_3("MISSING.TXT") orelse return error.EncodeFail;
    try testing.expectError(error.NotFound, lookupInRoot(&m, name));
}

test "lookupInRoot skips 0xE5 deleted entries and still finds HELLO.TXT after" {
    setupFixture();
    const m = try mount(&fake_dev, 0);
    const name = encode8_3("HELLO.TXT") orelse return error.EncodeFail;
    const found = try lookupInRoot(&m, name);
    // The fixture stamps the deleted entry at offset 32 and HELLO.TXT
    // at offset 64; if the skip-branch were broken the walker would
    // either match the deleted name or short-circuit on 0xE5.
    try testing.expectEqual(@as(u16, 64), found.byte_offset);
}

test "updateDirEntrySize round-trips through the sector" {
    setupFixture();
    var m = try mount(&fake_dev, 0);
    const name = encode8_3("HELLO.TXT") orelse return error.EncodeFail;
    const found = try lookupInRoot(&m, name);
    try updateDirEntrySize(&m, found, 0xDEADBEEF);
    const re = try lookupInRoot(&m, name);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), re.entry.file_size);
}

test "encode8_3 uppercase + space-pad + dotless name" {
    const o = encode8_3("init") orelse return error.EncodeFail;
    try testing.expectEqualStrings("INIT       ", &o);
}

test "encode8_3 splits name and ext, uppercases both" {
    const o = encode8_3("hello.txt") orelse return error.EncodeFail;
    try testing.expectEqualStrings("HELLO   TXT", &o);
}

test "encode8_3 rejects long names" {
    try testing.expectEqual(@as(?[11]u8, null), encode8_3("verylongname.txt"));
}
