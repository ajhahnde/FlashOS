// fat32_backend: FAT32 VFS backend. Wraps src/fat32.zig's
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
const overlay = @import("overlay");

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
    .readdir = readdir,
};

// Start sector of the single FAT32 partition on the SD card. Matches
// scripts/format_sd.sh (MBR, one FAT32 at LBA 2048 = the 1 MiB
// alignment offset); make_test_disk.sh formats the QEMU image to the
// same offset.
const FAT32_PARTITION_LBA: u32 = 2048;

// ---- FAT32 permission overlay ----
//
// FAT32 has no native owner/mode concept, so /mnt files get their
// permission metadata from a root-level text file (PERMS.TAB) parsed once
// at mount time into this fixed table; open() consults it. Un-annotated
// paths keep the documented default (0666 root:root) — except the shadow
// basename, which floors at 0600 root:root so a missing or corrupt
// overlay can never expose the on-card password file (defense in depth
// behind the anti-brick fallback).

// Overlay file name in the FAT32 root (matched case-insensitively).
const OVERLAY_NAME: []const u8 = "perms.tab";
// The basename that floors at 0600 when the overlay carries no entry.
const SHADOW_NAME: []const u8 = "shadow";

// True when PERMS.TAB was found AND parsed cleanly at mount time.
// kernel.zig reads this after init() to emit the loud anti-brick
// announcement — this module has no console.
pub var overlay_ok: bool = false;
var overlay_count: usize = 0;
var overlay_entries: [overlay.MAX_ENTRIES]overlay.Entry = undefined;
// Static read buffer for the overlay file. The overlay is sub-KiB by
// design; an oversized file is treated as corrupt (rejected wholesale).
var overlay_buf: [1024]u8 = undefined;

// Kernel-stack relief: shared sector scratch for the
// vtable I/O entry points (read / write / readdir and the dir-walk
// helper). They never nest in each other and every dispatch runs under
// the sys.zig preempt_disable bracket, so one buffer serves all four.
// See src/fat32.zig's dir/fat_sector_scratch for the full rationale.
var io_sector_scratch: fat32.SectorBuf align(4) = undefined;

// Read + parse /PERMS.TAB from the freshly mounted volume. Any failure
// (absent, empty, oversized, unreadable, malformed) leaves overlay_ok
// false and the table empty — open() then applies the defaults + shadow
// floor. Called by init() right after register_fat32, so the table is
// ready before the first syscall-path open.
fn applyOverlay() void {
    overlay_ok = false;
    overlay_count = 0;

    const name = fat32.encode8_3(OVERLAY_NAME) orelse return;
    const found = fat32.lookupInRoot(&mount_info, name) catch return;
    if (found.entry.file_size == 0 or found.entry.file_size > overlay_buf.len) return;

    const first_clus = (@as(u32, found.entry.fst_clus_hi) << 16) | found.entry.fst_clus_lo;
    var f: File = .{
        .ftype = 0,
        .refs = 1,
        .offset = 0,
        .private = first_clus,
        .size = found.entry.file_size,
        .sb = &sb,
    };
    var got: u64 = 0;
    while (got < f.size) {
        const n = read(&sb, &f, overlay_buf[@intCast(got)..].ptr, f.size - got);
        if (n < 0) return;
        if (n == 0) break;
        got += @intCast(n);
    }

    overlay_count = overlay.parse(overlay_buf[0..@intCast(got)], &overlay_entries) orelse {
        overlay_count = 0;
        return;
    };
    overlay_ok = true;
}

// Kernel bring-up hook. Returns 0 on a mounted volume, -1 if
// fat32.mount fails (blank/bad disk, no BPB). On failure the mount
// table slot is left null — non-fatal: vfs.resolve returns null for
// /mnt/* and the caller treats it as ENOENT. kernel.zig logs the
// outcome (this module has no console). Allocates nothing (mount
// uses a stack sector buffer), so the free-page baseline holds.
pub fn init() i32 {
    vfs.relocateOps(&ops_vtable);
    // The block-device function pointers are link-time (low) addresses
    // wired by the board's emmc2 init. Like the vtable above, they are
    // invoked from syscall context (TTBR0 = user pgd), so they must be
    // re-pointed to their high-mem aliases before the first mount.
    block_dev.relocate();
    sb.ops = &ops_vtable;
    mount_info = fat32.mount(&block_dev.sd_dev, FAT32_PARTITION_LBA) catch return -1;
    sb.private = @intFromPtr(&mount_info);
    vfs.register_fat32(&sb);
    // Permission overlay: parse PERMS.TAB into the static table
    // while the mount is fresh. Failure is soft — overlay_ok stays false
    // and open() falls back to defaults + the shadow floor.
    applyOverlay();
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
    // Permission metadata: the mount-time overlay (PERMS.TAB)
    // supplies per-file mode/uid/gid. Annotated paths get their entry
    // (low 9 bits + the regular-file type the perm layer expects);
    // un-annotated paths keep the documented default — rw-rw-rw-
    // root:root, no exec bit (the historical /mnt contract) — except the
    // shadow basename, which floors at 0600 root:root so a missing or
    // corrupt overlay never exposes the on-card password file. An
    // explicit overlay entry can still override the floor (operator's
    // call).
    if (overlay.lookup(overlay_entries[0..overlay_count], rel)) |e| {
        out.mode = 0o100000 | (e.mode & 0o777);
        out.uid = e.uid;
        out.gid = e.gid;
    } else if (overlay.nameEql(rel, SHADOW_NAME)) {
        out.mode = 0o100600;
        out.uid = 0;
        out.gid = 0;
    } else {
        out.mode = 0o100666;
        out.uid = 0;
        out.gid = 0;
    }
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
    const sector_buf = &io_sector_scratch;
    while (copied < n) {
        const sector_in_cluster: u32 = @intCast(cluster_offset / 512);
        const byte_in_sector: u32 = @intCast(cluster_offset % 512);
        const lba = (fat32.clusterLba(&mount_info, cluster) catch return -1) + sector_in_cluster;
        const read_fn = block_dev.sd_dev.read_fn orelse return -1;
        if (read_fn(lba, sector_buf) != 0) return -1;
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
            // FSInfo free-count/next-free is an advisory hint; the FAT
            // chain and dir entry are already durable, so a failed
            // hint update only costs a slower future allocation scan,
            // never data — swallow it rather than fail the write.
            fat32.fsInfoOnAlloc(&mount_info, next) catch {};
        }
        cluster = next;
        cluster_offset -= mount_info.bytes_per_cluster;
    }

    // Step 2: sector read-modify-write loop.
    var copied: u64 = 0;
    const sector_buf = &io_sector_scratch;
    while (copied < len) {
        const sector_in_cluster: u32 = @intCast(cluster_offset / 512);
        const byte_in_sector: u32 = @intCast(cluster_offset % 512);
        const lba = (fat32.clusterLba(&mount_info, cluster) catch return -1) + sector_in_cluster;
        const read_fn = block_dev.sd_dev.read_fn orelse return -1;
        if (read_fn(lba, sector_buf) != 0) return -1;
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
        const write_fn = block_dev.sd_dev.write_fn orelse return -1;
        if (write_fn(lba, sector_buf) != 0) return -1;
        copied += take;
        cluster_offset += take;
        if (cluster_offset >= mount_info.bytes_per_cluster and copied < len) {
            var next = fat32.readFatEntry(&mount_info, cluster) catch return -1;
            if (next >= fat32.FAT_EOC_MIN) {
                next = fat32.allocCluster(&mount_info) catch return -1;
                fat32.writeFatEntry(&mount_info, cluster, next) catch return -1;
                // FSInfo free-count/next-free is an advisory hint; the
                // FAT chain and dir entry are already durable, so a
                // failed hint update only costs a slower future
                // allocation scan, never data — swallow it.
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
        // The small root dir makes the re-walk trivial; future
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
    const sector_buf = &io_sector_scratch;
    // Cycle guard: a valid chain visits at most total_clusters links;
    // exceeding that proves a self-loop in a corrupted FAT, so bail.
    var hops: u32 = 0;
    while (cluster >= 2 and cluster < fat32.FAT_EOC_MIN) {
        const start_lba = fat32.clusterLba(&mount_info, cluster) catch return null;
        var i: u32 = 0;
        while (i < mount_info.sectors_per_cluster) : (i += 1) {
            const lba = start_lba + i;
            const read_fn = block_dev.sd_dev.read_fn orelse return null;
            if (read_fn(lba, sector_buf) != 0) return null;
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
        hops += 1;
        if (hops > mount_info.total_clusters) return null;
    }
    return null;
}

// readdir — enumerate the FAT32 mount root, one entry per call. Stateless
// like the rest of the VFS surface: the caller passes a fresh `index`, the
// walk re-reads the root chain and emits the `index`-th survivor. Root-only
// — only the mount root ("/", i.e. `/mnt/`) enumerates; a subdirectory
// listing needs a directory-cluster walk keyed off the entry's first
// cluster (deferred, no nested dirs in the demo image), so a
// non-root path lists empty. Skips the same entries lookupInRoot does
// (0x00 end-of-dir, 0xE5 deleted, LFN) plus the volume-label entry, which
// is not an enumerable file. Renders 8.3 via fat32.decode8_3; d_type from
// ATTR_DIRECTORY. Allocates nothing (one stack sector buffer). Runtime
// Pi-only: FAT32 does not mount under QEMU, so vfs.resolve("/mnt/*")
// returns null and sys_readdir answers -1 before reaching here.
fn readdir(_: *vfs.SuperBlock, path_ptr: [*]const u8, path_len: usize, index: u64, out: *vfs.Dirent) callconv(.c) c_int {
    const path = path_ptr[0..path_len];
    if (!(path.len == 1 and path[0] == '/')) return -1; // root-only

    var cluster: u32 = mount_info.bpb.root_clus;
    const sector_buf = &io_sector_scratch;
    var emitted: u64 = 0;
    // Cycle guard: a valid chain visits at most total_clusters links;
    // exceeding that proves a self-loop in a corrupted FAT, so stop.
    var hops: u32 = 0;
    while (cluster >= 2 and cluster < fat32.FAT_EOC_MIN) {
        const start_lba = fat32.clusterLba(&mount_info, cluster) catch return -1;
        var i: u32 = 0;
        while (i < mount_info.sectors_per_cluster) : (i += 1) {
            const lba = start_lba + i;
            const read_fn = block_dev.sd_dev.read_fn orelse return -1;
            if (read_fn(lba, sector_buf) != 0) return -1;
            var j: u16 = 0;
            while (j < 16) : (j += 1) {
                const byte_off: u16 = j * 32;
                const first_byte = sector_buf[byte_off];
                if (first_byte == 0x00) return -1; // end-of-dir
                if (first_byte == 0xE5) continue; // deleted
                const attr = sector_buf[byte_off + 0x0B];
                if ((attr & fat32.ATTR_LONG_NAME) == fat32.ATTR_LONG_NAME) continue; // LFN
                if ((attr & fat32.ATTR_VOLUME_ID) != 0) continue; // volume label
                if (emitted == index) {
                    var raw: [11]u8 = undefined;
                    @memcpy(&raw, sector_buf[byte_off..][0..11]);
                    const dec = fat32.decode8_3(raw);
                    out.* = .{};
                    const n = @min(dec.len, out.name.len - 1);
                    @memcpy(out.name[0..n], dec.buf[0..n]);
                    out.d_type = if ((attr & fat32.ATTR_DIRECTORY) != 0) vfs.DT_DIR else vfs.DT_REG;
                    return 0;
                }
                emitted += 1;
            }
        }
        cluster = fat32.readFatEntry(&mount_info, cluster) catch return -1;
        hops += 1;
        if (hops > mount_info.total_clusters) return -1;
    }
    return -1;
}

// ---------------------------------------------------------------------
// FAT32 splice contract — sub-sector write at File.offset must land
// in the on-disk sector even when a hostile read_fn re-zeros
// sector_buf on the preceding read. The byte-loop splice at
// write():203-208 enforces this against the FAT32 splice reorder
// bug class (Zig 0.16 hoisted inlined @memcpy stores ABOVE the
// read_fn fn-pointer call on aarch64-elf freestanding under
// ReleaseSmall, so read_fn zeroed the splice).
//
// This host-test does NOT reproduce the reorder — the
// aarch64-darwin host LLVM pipeline keeps the splice below the call
// under both byte-loop AND inline-@memcpy variants (verified
// empirically against -Doptimize=ReleaseSmall, 2026-05-24). The
// real regression catcher is `[TEST] fs-roundtrip` on Pi-4 hardware.
// This block's job: (a) document the rationale inline so a future
// "cleanup" PR sees why the byte loop exists, (b) assert the splice
// contract so structural breakage of write() (wrong index, bleed)
// gets caught here.
// ---------------------------------------------------------------------

const testing = std.testing;

var antagonist_read_calls: u32 = 0;
noinline fn antagonistRead(_: u32, buf: *[512]u8) callconv(.c) i32 {
    antagonist_read_calls += 1;
    @memset(buf, 0);
    return 0;
}

var harvest_sector: [512]u8 align(4) = undefined;
var harvest_writes: u32 = 0;
noinline fn harvestWrite(_: u32, buf: *const [512]u8) callconv(.c) i32 {
    harvest_writes += 1;
    @memcpy(&harvest_sector, buf);
    return 0;
}

fn installAntagonist() void {
    antagonist_read_calls = 0;
    harvest_writes = 0;
    @memset(&harvest_sector, 0xCC);
    block_dev.sd_dev = .{ .read_fn = antagonistRead, .write_fn = harvestWrite };
}

fn installMountInfo() void {
    mount_info = .{
        .bpb = std.mem.zeroes(fat32.Bpb),
        .partition_lba = 0,
        .fat_lba = 2,
        .data_lba = 6,
        .sectors_per_cluster = 1,
        .bytes_per_cluster = 512,
        .fsinfo_lba = 1,
        .total_clusters = 124,
        .dev = &block_dev.sd_dev,
    };
}

test "splice contract: 1-byte sub-sector write lands at File.offset with no bleed" {
    installAntagonist();
    installMountInfo();

    var f: File = .{
        .ftype = 0,
        .refs = 1,
        .offset = 100,
        .private = 3,
        .size = 512,
        .sb = &sb,
    };
    const payload: [1]u8 = .{0xAA};

    const n = ops_vtable.write(&sb, &f, &payload, 1);

    try testing.expectEqual(@as(i64, 1), n);
    try testing.expectEqual(@as(u32, 1), antagonist_read_calls);
    try testing.expectEqual(@as(u32, 1), harvest_writes);
    try testing.expectEqual(@as(u8, 0xAA), harvest_sector[100]);
    try testing.expectEqual(@as(u8, 0), harvest_sector[99]);
    try testing.expectEqual(@as(u8, 0), harvest_sector[101]);
}

test "splice contract: 4-byte sub-sector write lands at File.offset with no bleed" {
    installAntagonist();
    installMountInfo();

    var f: File = .{
        .ftype = 0,
        .refs = 1,
        .offset = 200,
        .private = 3,
        .size = 512,
        .sb = &sb,
    };
    const payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    const n = ops_vtable.write(&sb, &f, &payload, 4);

    try testing.expectEqual(@as(i64, 4), n);
    try testing.expectEqualSlices(u8, &payload, harvest_sector[200..204]);
    try testing.expectEqual(@as(u8, 0), harvest_sector[199]);
    try testing.expectEqual(@as(u8, 0), harvest_sector[204]);
}

test "splice contract: whole-file same-length rewrite from offset 0 (shadow rewrite shape)" {
    // The sys_passwd write shape: the whole shadow file,
    // rewritten in place from offset 0 with byte-identical length.
    // Pins three contract points: (a) every byte lands exactly
    // (sub-sector splice through the byte loop), (b) no bleed past the
    // written length, (c) the same-length write never takes the
    // dir-entry resize branch — against this antagonist (no root
    // directory) that branch could only return -1, so a non-negative
    // return proves it was skipped.
    installAntagonist();
    installMountInfo();

    const content =
        "root:4096:" ++ ("aa" ** 16) ++ ":" ++ ("bb" ** 32) ++ "\n" ++
        "flash:4096:" ++ ("cc" ** 16) ++ ":" ++ ("dd" ** 32) ++ "\n";

    var f: File = .{
        .ftype = 0,
        .refs = 1,
        .offset = 0,
        .private = 3,
        .size = content.len, // same length -> no resize
        .sb = &sb,
    };

    const n = ops_vtable.write(&sb, &f, content, content.len);

    try testing.expectEqual(@as(i64, @intCast(content.len)), n);
    try testing.expectEqualSlices(u8, content, harvest_sector[0..content.len]);
    // No bleed past the written length (antagonist zeroed the rest).
    try testing.expectEqual(@as(u8, 0), harvest_sector[content.len]);
    // Offset advanced to exactly size; size untouched (no resize).
    try testing.expectEqual(@as(u64, content.len), f.offset);
    try testing.expectEqual(@as(u64, content.len), f.size);
}

// readdir fixture — a real root-dir cluster for the enumeration walk
// (the splice tests above use an antagonist with no directory). LBA 0..7
// of an in-memory disk: FAT @ LBA 2 terminates the root chain (cluster 2
// -> EOC), root dir @ LBA 6 (data_lba 6, sec_per_clus 1) carries a volume
// label (skipped), a deleted entry (skipped), a file, and a subdirectory.
var rd_disk: [8 * 512]u8 align(512) = undefined;

fn rdRead(lba: u32, buf: *[512]u8) callconv(.c) i32 {
    const off: usize = @as(usize, lba) * 512;
    if (off + 512 > rd_disk.len) return -1;
    @memcpy(buf, rd_disk[off..][0..512]);
    return 0;
}

fn setupReaddirFixture() void {
    @memset(&rd_disk, 0);
    // FAT @ LBA 2: cluster 2 (root) -> EOC so the chain walk stops after
    // the single root cluster (entry 2 is at fat byte offset 8).
    std.mem.writeInt(u32, rd_disk[2 * 512 + 8 ..][0..4], fat32.FAT_EOC, .little);
    // Root dir @ LBA 6 (cluster 2).
    const root = rd_disk[6 * 512 .. 7 * 512];
    @memcpy(root[0..11], "SCRATCH    "); // volume label — skipped
    root[0x0B] = fat32.ATTR_VOLUME_ID;
    @memcpy(root[32..][0..11], "?DELETEDBIN"); // deleted — skipped
    root[32] = 0xE5;
    @memcpy(root[64..][0..11], "HELLO   TXT"); // regular file
    root[64 + 0x0B] = fat32.ATTR_ARCHIVE;
    @memcpy(root[96..][0..11], "SUBDIR     "); // directory
    root[96 + 0x0B] = fat32.ATTR_DIRECTORY;
    // Entry 4 onward: first byte 0x00 (end-of-dir) — already zeroed.
}

fn installReaddirMount() void {
    block_dev.sd_dev = .{ .read_fn = rdRead, .write_fn = null };
    var bpb = std.mem.zeroes(fat32.Bpb);
    bpb.root_clus = 2;
    mount_info = .{
        .bpb = bpb,
        .partition_lba = 0,
        .fat_lba = 2,
        .data_lba = 6,
        .sectors_per_cluster = 1,
        .bytes_per_cluster = 512,
        .fsinfo_lba = 1,
        .total_clusters = 124,
        .dev = &block_dev.sd_dev,
    };
}

test "readdir lists root entries, skipping volume label and deleted" {
    setupReaddirFixture();
    installReaddirMount();

    var d: vfs.Dirent = .{};
    // index 0 -> first real survivor (volume + deleted skipped).
    try testing.expectEqual(@as(c_int, 0), ops_vtable.readdir(&sb, "/".ptr, 1, 0, &d));
    try testing.expectEqualStrings("hello.txt", std.mem.sliceTo(&d.name, 0));
    try testing.expectEqual(vfs.DT_REG, d.d_type);
    // index 1 -> the subdirectory, flagged DT_DIR.
    try testing.expectEqual(@as(c_int, 0), ops_vtable.readdir(&sb, "/".ptr, 1, 1, &d));
    try testing.expectEqualStrings("subdir", std.mem.sliceTo(&d.name, 0));
    try testing.expectEqual(vfs.DT_DIR, d.d_type);
    // index 2 -> past the last survivor: end sentinel.
    try testing.expectEqual(@as(c_int, -1), ops_vtable.readdir(&sb, "/".ptr, 1, 2, &d));
}

test "readdir on a non-root path lists empty (root-only walk)" {
    setupReaddirFixture();
    installReaddirMount();
    var d: vfs.Dirent = .{};
    try testing.expectEqual(@as(c_int, -1), ops_vtable.readdir(&sb, "/subdir".ptr, 7, 0, &d));
}

test "readdir terminates on self-looping FAT chain" {
    setupReaddirFixture();
    installReaddirMount();

    // Forge a 1-cluster cycle: the root cluster's FAT entry (cluster 2,
    // at fat byte 2*512 + 8) points back at itself instead of EOC.
    std.mem.writeInt(u32, rd_disk[2 * 512 + 8 ..][0..4], 2, .little);

    // Fill the root cluster (LBA 6) with valid, non-matching entries and
    // NO 0x00 end-of-dir marker, so the in-cluster scan never stops — the
    // walk must follow the self-loop and only the cycle guard can break
    // it. A hang here would be a cycle-guard regression.
    const root = rd_disk[6 * 512 .. 7 * 512];
    var j: usize = 0;
    while (j < 16) : (j += 1) {
        const off = j * 32;
        @memcpy(root[off .. off + 11], "OTHER   BIN");
        root[off + 0x0B] = fat32.ATTR_ARCHIVE;
    }

    var d: vfs.Dirent = .{};
    // A high index forces the walk to traverse every survivor and then
    // follow the chain; with the guard it terminates with the -1 sentinel
    // instead of spinning forever.
    try testing.expectEqual(@as(c_int, -1), ops_vtable.readdir(&sb, "/".ptr, 1, 9999, &d));
}

// Overlay fixture — a root dir carrying PERMS.TAB (with real text in a
// data cluster), SHADOW, and ROUNDTR.DAT, so applyOverlay() and the
// open() metadata selection run against a real lookup + read path.
// Reuses the readdir fixture's in-memory disk (rd_disk) + mount wiring.
const OVERLAY_TEXT = "PERMS.TAB 0600 0 0\nSHADOW 0640 0 0\n";

fn setupOverlayFixture() void {
    @memset(&rd_disk, 0);
    // FAT @ LBA 2: root chain (cluster 2) -> EOC; PERMS.TAB data
    // (cluster 3) -> EOC. FAT entry for cluster N sits at byte N*4.
    std.mem.writeInt(u32, rd_disk[2 * 512 + 8 ..][0..4], fat32.FAT_EOC, .little);
    std.mem.writeInt(u32, rd_disk[2 * 512 + 12 ..][0..4], fat32.FAT_EOC, .little);

    // Root dir @ LBA 6 (cluster 2, data_lba 6).
    const root = rd_disk[6 * 512 .. 7 * 512];
    // Entry 0: PERMS.TAB -> cluster 3, size = overlay text length.
    @memcpy(root[0..11], "PERMS   TAB");
    root[0x0B] = fat32.ATTR_ARCHIVE;
    std.mem.writeInt(u16, root[0x1A..][0..2], 3, .little);
    std.mem.writeInt(u32, root[0x1C..][0..4], OVERLAY_TEXT.len, .little);
    // Entry 1: SHADOW -> cluster 4 (no data needed for open()).
    @memcpy(root[32..][0..11], "SHADOW     ");
    root[32 + 0x0B] = fat32.ATTR_ARCHIVE;
    std.mem.writeInt(u16, root[32 + 0x1A ..][0..2], 4, .little);
    std.mem.writeInt(u32, root[32 + 0x1C ..][0..4], 100, .little);
    // Entry 2: ROUNDTR.DAT -> cluster 5.
    @memcpy(root[64..][0..11], "ROUNDTR DAT");
    root[64 + 0x0B] = fat32.ATTR_ARCHIVE;
    std.mem.writeInt(u16, root[64 + 0x1A ..][0..2], 5, .little);
    std.mem.writeInt(u32, root[64 + 0x1C ..][0..4], 4096, .little);

    // PERMS.TAB data @ LBA 7 (cluster 3 = data_lba + (3-2)*1).
    @memcpy(rd_disk[7 * 512 ..][0..OVERLAY_TEXT.len], OVERLAY_TEXT);
}

test "overlay: annotated entries, the shadow floor override, and defaults" {
    setupOverlayFixture();
    installReaddirMount();

    applyOverlay();
    try testing.expect(overlay_ok);
    try testing.expectEqual(@as(usize, 2), overlay_count);

    var out: vfs.OpenResult = .{};
    // SHADOW carries an explicit overlay entry (0640) — it overrides the
    // floor (operator's call).
    try testing.expectEqual(@as(c_int, 0), ops_vtable.open(&sb, "/shadow".ptr, 7, &out));
    try testing.expectEqual(@as(u32, 0o100640), out.mode);
    try testing.expectEqual(@as(u32, 0), out.uid);
    try testing.expectEqual(@as(u32, 0), out.gid);
    // PERMS.TAB protects itself through its self-entry.
    try testing.expectEqual(@as(c_int, 0), ops_vtable.open(&sb, "/perms.tab".ptr, 10, &out));
    try testing.expectEqual(@as(u32, 0o100600), out.mode);
    // ROUNDTR.DAT is un-annotated -> documented default.
    try testing.expectEqual(@as(c_int, 0), ops_vtable.open(&sb, "/roundtr.dat".ptr, 12, &out));
    try testing.expectEqual(@as(u32, 0o100666), out.mode);
}

test "overlay: absent PERMS.TAB floors shadow at 0600 and keeps defaults elsewhere" {
    setupOverlayFixture();
    installReaddirMount();

    // Delete the PERMS.TAB dir entry, then re-apply: the overlay is gone.
    rd_disk[6 * 512] = 0xE5;
    applyOverlay();
    try testing.expect(!overlay_ok);
    try testing.expectEqual(@as(usize, 0), overlay_count);

    var out: vfs.OpenResult = .{};
    // The shadow basename floors at 0600 root:root — a lost overlay
    // never exposes the on-card password file.
    try testing.expectEqual(@as(c_int, 0), ops_vtable.open(&sb, "/shadow".ptr, 7, &out));
    try testing.expectEqual(@as(u32, 0o100600), out.mode);
    try testing.expectEqual(@as(u32, 0), out.uid);
    try testing.expectEqual(@as(u32, 0), out.gid);
    // Everything else keeps the documented default.
    try testing.expectEqual(@as(c_int, 0), ops_vtable.open(&sb, "/roundtr.dat".ptr, 12, &out));
    try testing.expectEqual(@as(u32, 0o100666), out.mode);
}

test "overlay: corrupt PERMS.TAB content is rejected wholesale (floor applies)" {
    setupOverlayFixture();
    installReaddirMount();

    // Corrupt the mode field in the data cluster: "PERMS.TAB 0600 ..."
    // -> "PERMS.TAB x600 ..." — overlay.parse rejects the whole file.
    rd_disk[7 * 512 + 10] = 'x';
    applyOverlay();
    try testing.expect(!overlay_ok);
    try testing.expectEqual(@as(usize, 0), overlay_count);

    var out: vfs.OpenResult = .{};
    // With the table empty, the floor still protects the shadow file.
    try testing.expectEqual(@as(c_int, 0), ops_vtable.open(&sb, "/shadow".ptr, 7, &out));
    try testing.expectEqual(@as(u32, 0o100600), out.mode);
}
