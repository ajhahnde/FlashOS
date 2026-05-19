// fat32_backend: FAT32 VFS backend (v0.4.0). Wraps src/fat32.zig's
// on-disk decode in the VfsOps vtable.
//
// open / read / seek / close / write do live cluster-chain I/O
// against block_dev.sd_dev. write (writeBack) extends-or-overwrites
// an existing file: chain-extend via allocCluster + writeFatEntry,
// sector read-modify-write loop, dir-entry file_size update by
// re-walking the root by first cluster, FSInfo decrement per alloc.
// No create-if-missing and no sparse-write past EOF — both are
// future scope (see writeBack header).
//
// init() MUST run after board.emmc2.init() has wired
// block_dev.sd_dev — fat32.mount issues block reads through that
// vtable. kernel.zig calls init() inside the emmc2-init-OK branch
// for exactly that reason; calling it before sd_dev is wired would
// dereference an undefined function pointer.

const std = @import("std");
const fat32 = @import("fat32");
const vfs = @import("vfs");
const file_mod = @import("file");
const block_dev = @import("block_dev");

const File = file_mod.File;

// Single static superblock for the /mnt mount (slot 1). fs_type is
// re-stamped by vfs.register_fat32.
pub var sb: vfs.SuperBlock = .{ .fs_type = @intFromEnum(vfs.FsType.FAT32) };

// Volume descriptor, populated by init()'s fat32.mount. sb.private
// carries its address (per the vfs.zig SuperBlock contract); the
// vtable bodies reach it directly through this module global.
var mount_info: fat32.Mount = undefined;

// `var`, not `const`: init() relocates these entries to their
// high-mem aliases in place via vfs.relocateOps (mirrors the earlier
// stub's pattern). Slot names match real src/vfs.zig VfsOps.
var ops_vtable: vfs.VfsOps = .{
    .open = open,
    .read = read,
    .seek = seek,
    .close = close,
    .write = write,
};

// Start sector of the single FAT32 partition on the SD card. Matches
// scripts/format_sd.sh (MBR, one FAT32 at LBA 2048 = the 1 MiB
// alignment offset); make_test_disk.sh formats the QEMU image to the
// same offset.
const FAT32_PARTITION_LBA: u32 = 2048;

// Kernel bring-up hook. Returns 0 on a mounted volume, -1 if
// fat32.mount fails (blank/bad disk, no BPB). On failure the mount
// table slot is left null — non-fatal: vfs.resolve returns null for
// /mnt/* and the caller treats it as ENOENT. kernel.zig logs the
// outcome (this module has no console). Allocates nothing (mount
// uses a stack sector buffer), so the free-page baseline holds.
pub fn init() i32 {
    vfs.relocateOps(&ops_vtable);
    sb.ops = &ops_vtable;
    mount_info = fat32.mount(&block_dev.sd_dev, FAT32_PARTITION_LBA) catch return -1;
    sb.private = @intFromPtr(&mount_info);
    vfs.register_fat32(&sb);
    return 0;
}

// path crosses as ptr+len (callconv(.c) forbids slices). The /mnt
// prefix is already stripped by vfs.resolve, leaving a leading '/'.
// out.private carries the file's first cluster in the low 32 bits
// (high bits 0 — read re-walks the chain; no cluster_count cached
// until fd state grows). out.size carries the dir-entry
// file_size.
fn open(_: *vfs.SuperBlock, path_ptr: [*]const u8, path_len: usize, out: *vfs.OpenResult) callconv(.c) c_int {
    const path = path_ptr[0..path_len];
    const rel = if (path.len > 0 and path[0] == '/') path[1..] else path;
    const name = fat32.encode8_3(rel) orelse return -1;
    const found = fat32.lookupInRoot(&mount_info, name) catch return -1;
    const first_clus = (@as(u32, found.entry.fst_clus_hi) << 16) | found.entry.fst_clus_lo;
    out.private = first_clus;
    out.size = found.entry.file_size;
    return 0;
}

fn read(_: *vfs.SuperBlock, f: *File, buf: [*]u8, len: u64) callconv(.c) i64 {
    if (f.offset >= f.size) return 0;
    const remaining = f.size - f.offset;
    const n: u64 = if (len > remaining) remaining else len;

    // Walk the FAT chain to the cluster covering f.offset.
    var cluster: u32 = @intCast(f.private & 0xFFFF_FFFF);
    var cluster_offset: u64 = f.offset;
    while (cluster_offset >= mount_info.bytes_per_cluster) {
        cluster = fat32.readFatEntry(&mount_info, cluster) catch return -1;
        if (cluster >= fat32.FAT_EOC_MIN) return -1;
        cluster_offset -= mount_info.bytes_per_cluster;
    }

    var copied: u64 = 0;
    var sector_buf: fat32.SectorBuf align(4) = undefined;
    while (copied < n) {
        const sector_in_cluster: u32 = @intCast(cluster_offset / 512);
        const byte_in_sector: u32 = @intCast(cluster_offset % 512);
        const lba = fat32.clusterLba(&mount_info, cluster) + sector_in_cluster;
        if (block_dev.sd_dev.read_fn(lba, &sector_buf) != 0) return -1;
        const take: u64 = @min(n - copied, 512 - byte_in_sector);
        // Symmetric to write()'s splice — explicit byte loop so the
        // read_fn(&sector_buf) -> copy-out dependency is preserved
        // for the sub-sector (take<512) case (see write() comment).
        {
            var si: usize = 0;
            while (si < take) : (si += 1) {
                buf[@as(usize, @intCast(copied)) + si] = sector_buf[@as(usize, byte_in_sector) + si];
            }
        }
        copied += take;
        cluster_offset += take;
        if (cluster_offset >= mount_info.bytes_per_cluster) {
            cluster = fat32.readFatEntry(&mount_info, cluster) catch return -1;
            if (cluster >= fat32.FAT_EOC_MIN) break;
            cluster_offset = 0;
        }
    }
    f.offset += copied;
    return @bitCast(copied);
}

fn seek(_: *vfs.SuperBlock, f: *File, off: i64, whence: i32) callconv(.c) i64 {
    const cur_signed: i64 = @bitCast(f.offset);
    const sz_signed: i64 = @bitCast(f.size);
    const target: i64 = switch (whence) {
        0 => off, // SEEK_SET
        1 => cur_signed + off, // SEEK_CUR
        2 => sz_signed + off, // SEEK_END
        else => return -1,
    };
    if (target < 0 or target > sz_signed) return -1;
    f.offset = @bitCast(target);
    return target;
}

fn close(_: *vfs.SuperBlock, _: *File) callconv(.c) void {
    // No per-handle state — every read is sector-fetched inline and
    // the File page lifetime is file.zig's refcount's job. Step 4's
    // write path stays sector-flushed too, so close stays a no-op
    // until a future buffer cache adds a real fsync here.
}

// write (writeBack) — extends or overwrites an existing file.
// No create-if-missing yet, no sparse write past EOF + len
// (offset > size treated as -1). Sequence:
//   1. Walk the chain from first_cluster to the cluster covering
//      f.offset; if the chain ends before that, allocCluster + link.
//   2. Sector read-modify-write loop: read the target sector, splice
//      `take` bytes, write it back. Cross cluster boundaries via the
//      same alloc-or-follow path.
//   3. If f.offset + copied > f.size, update the in-RAM f.size and
//      the on-disk dir entry's file_size (re-walk root by first
//      cluster, then updateDirEntrySize).
//   4. fsInfoOnAlloc once per allocCluster.
//
// Not crash-safe (FAT1/FAT2, dir-entry, FSInfo writes are three
// non-atomic RMW points). Single-shot acceptance run never power-
// cycles mid-write; a future journal closes the gap.
fn write(_: *vfs.SuperBlock, f: *File, buf: [*]const u8, len: u64) callconv(.c) i64 {
    if (len == 0) return 0;
    // No sparse write: a hole between f.size and f.offset is -1.
    if (f.offset > f.size) return -1;

    var cluster: u32 = @intCast(f.private & 0xFFFF_FFFF);
    var cluster_offset: u64 = f.offset;

    // Step 1: walk to the cluster covering f.offset, extending the
    // chain via allocCluster when the walk hits end-of-chain.
    while (cluster_offset >= mount_info.bytes_per_cluster) {
        var next = fat32.readFatEntry(&mount_info, cluster) catch return -1;
        if (next >= fat32.FAT_EOC_MIN) {
            next = fat32.allocCluster(&mount_info) catch return -1;
            fat32.writeFatEntry(&mount_info, cluster, next) catch return -1;
            fat32.fsInfoOnAlloc(&mount_info, next) catch {};
        }
        cluster = next;
        cluster_offset -= mount_info.bytes_per_cluster;
    }

    // Step 2: sector read-modify-write loop.
    var copied: u64 = 0;
    var sector_buf: fat32.SectorBuf align(4) = undefined;
    while (copied < len) {
        const sector_in_cluster: u32 = @intCast(cluster_offset / 512);
        const byte_in_sector: u32 = @intCast(cluster_offset % 512);
        const lba = fat32.clusterLba(&mount_info, cluster) + sector_in_cluster;
        if (block_dev.sd_dev.read_fn(lba, &sector_buf) != 0) return -1;
        const take: u64 = @min(len - copied, 512 - byte_in_sector);
        // Explicit byte loop, NOT @memcpy: the sub-sector (take<512)
        // splice as `@memcpy(sector_buf[bis..][0..take], buf[..])`
        // lowered to an inlined store that the optimizer hoisted
        // ABOVE the preceding `read_fn(&sector_buf)` fn-pointer call,
        // so read_fn re-zeroed sector_buf[bis] after the splice — the
        // 1-byte ROUNDTR.MAG write read back 0x00 every boot while the
        // take=512 DAT path (lowered to an opaque memcpy call, not
        // reordered) worked. Indexing through the buffer keeps the
        // read_fn -> splice dependency the compiler must honour.
        {
            var si: usize = 0;
            while (si < take) : (si += 1) {
                sector_buf[@as(usize, byte_in_sector) + si] = buf[@as(usize, @intCast(copied)) + si];
            }
        }
        if (block_dev.sd_dev.write_fn(lba, &sector_buf) != 0) return -1;
        copied += take;
        cluster_offset += take;
        if (cluster_offset >= mount_info.bytes_per_cluster and copied < len) {
            var next = fat32.readFatEntry(&mount_info, cluster) catch return -1;
            if (next >= fat32.FAT_EOC_MIN) {
                next = fat32.allocCluster(&mount_info) catch return -1;
                fat32.writeFatEntry(&mount_info, cluster, next) catch return -1;
                fat32.fsInfoOnAlloc(&mount_info, next) catch {};
            }
            cluster = next;
            cluster_offset = 0;
        }
    }

    // Step 3: grow file_size on disk if the write went past EOF.
    const new_offset = f.offset + copied;
    if (new_offset > f.size) {
        // Can't reconstruct the encoded 8.3 name from File state
        // (not stashed on open — needs 11 bytes, the private word is
        // 8). Re-walk root for the entry whose first cluster matches.
        // v0.4.0's small root dir makes the re-walk trivial; future
        // work caches FoundEntry on open.
        const first_clus_u32: u32 = @intCast(f.private & 0xFFFF_FFFF);
        if (findEntryByFirstCluster(first_clus_u32)) |found| {
            fat32.updateDirEntrySize(&mount_info, found, @intCast(new_offset)) catch return -1;
        } else {
            return -1; // entry vanished mid-write — should be impossible
        }
        f.size = new_offset;
    }

    f.offset = new_offset;
    return @bitCast(copied);
}

// Scan the root dir for the entry whose (fst_clus_hi<<16 |
// fst_clus_lo) equals `first_cluster`. Returns null on miss. Used by
// write() when growing file_size — avoids stashing the encoded 8.3
// name in File.private (11 bytes won't fit the 8-byte private word).
fn findEntryByFirstCluster(first_cluster: u32) ?fat32.FoundEntry {
    var cluster: u32 = mount_info.bpb.root_clus;
    var sector_buf: fat32.SectorBuf align(4) = undefined;
    while (cluster >= 2 and cluster < fat32.FAT_EOC_MIN) {
        const start_lba = fat32.clusterLba(&mount_info, cluster);
        var i: u32 = 0;
        while (i < mount_info.sectors_per_cluster) : (i += 1) {
            const lba = start_lba + i;
            if (block_dev.sd_dev.read_fn(lba, &sector_buf) != 0) return null;
            var j: u16 = 0;
            while (j < 16) : (j += 1) {
                const byte_off: u16 = j * 32;
                const first_byte = sector_buf[byte_off];
                if (first_byte == 0x00) return null; // end-of-dir
                if (first_byte == 0xE5) continue; // deleted
                const attr = sector_buf[byte_off + 0x0B];
                if ((attr & fat32.ATTR_LONG_NAME) == fat32.ATTR_LONG_NAME) continue;
                const fc_hi = std.mem.readInt(u16, sector_buf[byte_off + 0x14 ..][0..2], .little);
                const fc_lo = std.mem.readInt(u16, sector_buf[byte_off + 0x1A ..][0..2], .little);
                const fc: u32 = (@as(u32, fc_hi) << 16) | fc_lo;
                if (fc == first_cluster) {
                    var e: fat32.DirEntry = undefined;
                    e.fst_clus_hi = fc_hi;
                    e.fst_clus_lo = fc_lo;
                    e.attr = attr;
                    e.file_size = std.mem.readInt(u32, sector_buf[byte_off + 0x1C ..][0..4], .little);
                    return .{ .entry = e, .lba = lba, .byte_offset = byte_off };
                }
            }
        }
        cluster = fat32.readFatEntry(&mount_info, cluster) catch return null;
    }
    return null;
}
