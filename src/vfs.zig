// Transitional adapter for the Rust-owned VFS dispatch layer.

const builtin = @import("builtin");
const file_mod = @import("file");
const defs = @import("syscall_defs");

pub const File = file_mod.File;
pub const Dirent = defs.Dirent;
pub const DT_REG = defs.DT_REG;
pub const DT_DIR = defs.DT_DIR;

pub const FsType = enum(u8) {
    INITRAMFS = 0,
    FAT32 = 1,
    _,
};

pub const SuperBlock = extern struct {
    fs_type: u8,
    _pad: [7]u8 = .{0} ** 7,
    private: u64 = 0,
    ops: ?*const VfsOps = null,
};

pub const OpenResult = extern struct {
    private: u64 = 0,
    size: u64 = 0,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    dirent_lba: u32 = 0,
    dirent_off: u32 = 0,
};

pub const VfsOps = extern struct {
    open: *const fn (*SuperBlock, [*]const u8, usize, *OpenResult) callconv(.c) c_int,
    read: *const fn (*SuperBlock, *File, [*]u8, u64) callconv(.c) i64,
    seek: *const fn (*SuperBlock, *File, i64, i32) callconv(.c) i64,
    close: *const fn (*SuperBlock, *File) callconv(.c) void,
    write: *const fn (*SuperBlock, *File, [*]const u8, u64) callconv(.c) i64,
    readdir: *const fn (*SuperBlock, [*]const u8, usize, u64, *Dirent) callconv(.c) c_int,
    create: *const fn (*SuperBlock, [*]const u8, usize, *OpenResult) callconv(.c) c_int,
    unlink: *const fn (*SuperBlock, [*]const u8, usize) callconv(.c) c_int,
    rename: *const fn (*SuperBlock, [*]const u8, usize, [*]const u8, usize) callconv(.c) c_int,
};

comptime {
    if (@offsetOf(SuperBlock, "fs_type") != 0 or
        @offsetOf(SuperBlock, "private") != 8 or
        @offsetOf(SuperBlock, "ops") != 16 or
        @sizeOf(SuperBlock) != 24)
    {
        @compileError("SuperBlock layout drifted from Rust");
    }
    if (@offsetOf(OpenResult, "private") != 0 or
        @offsetOf(OpenResult, "size") != 8 or
        @offsetOf(OpenResult, "mode") != 16 or
        @offsetOf(OpenResult, "uid") != 20 or
        @offsetOf(OpenResult, "gid") != 24 or
        @offsetOf(OpenResult, "dirent_lba") != 28 or
        @offsetOf(OpenResult, "dirent_off") != 32 or
        @sizeOf(OpenResult) != 40)
    {
        @compileError("OpenResult layout drifted from Rust");
    }
    if (@offsetOf(VfsOps, "open") != 0 or
        @offsetOf(VfsOps, "read") != 8 or
        @offsetOf(VfsOps, "seek") != 16 or
        @offsetOf(VfsOps, "close") != 24 or
        @offsetOf(VfsOps, "write") != 32 or
        @offsetOf(VfsOps, "readdir") != 40 or
        @offsetOf(VfsOps, "create") != 48 or
        @offsetOf(VfsOps, "unlink") != 56 or
        @offsetOf(VfsOps, "rename") != 64 or
        @sizeOf(VfsOps) != 72)
    {
        @compileError("VfsOps layout drifted from Rust");
    }
}

extern fn fos_vfs_relocate_ops(ops: *VfsOps) void;
extern fn fos_vfs_register_fat32(sb: *SuperBlock) void;
extern fn fos_vfs_open([*]const u8, usize, *OpenResult) ?*SuperBlock;
extern fn fos_vfs_read(*SuperBlock, *File, [*]u8, u64) i64;
extern fn fos_vfs_seek(*SuperBlock, *File, i64, i32) i64;
extern fn fos_vfs_close(*SuperBlock, *File) void;
extern fn fos_vfs_write(*SuperBlock, *File, [*]const u8, u64) i64;
extern fn fos_vfs_readdir([*]const u8, usize, u64, *Dirent) c_int;
extern fn fos_vfs_create([*]const u8, usize, *OpenResult) ?*SuperBlock;
extern fn fos_vfs_unlink([*]const u8, usize) c_int;
extern fn fos_vfs_rename([*]const u8, usize, [*]const u8, usize) c_int;

pub fn relocateOps(ops: *VfsOps) void {
    if (builtin.target.os.tag != .freestanding) return;
    fos_vfs_relocate_ops(ops);
}

pub fn register_fat32(sb: *SuperBlock) void {
    fos_vfs_register_fat32(sb);
}

pub fn vfs_open(path: []const u8, out: *OpenResult) ?*SuperBlock {
    return fos_vfs_open(path.ptr, path.len, out);
}

pub fn vfs_read(sb: *SuperBlock, file: *File, buffer: [*]u8, len: u64) i64 {
    return fos_vfs_read(sb, file, buffer, len);
}

pub fn vfs_seek(sb: *SuperBlock, file: *File, off: i64, whence: i32) i64 {
    return fos_vfs_seek(sb, file, off, whence);
}

pub fn vfs_close(sb: *SuperBlock, file: *File) void {
    fos_vfs_close(sb, file);
}

pub fn vfs_write(sb: *SuperBlock, file: *File, buffer: [*]const u8, len: u64) i64 {
    return fos_vfs_write(sb, file, buffer, len);
}

pub fn vfs_readdir(path: []const u8, index: u64, out: *Dirent) c_int {
    return fos_vfs_readdir(path.ptr, path.len, index, out);
}

pub fn vfs_create(path: []const u8, out: *OpenResult) ?*SuperBlock {
    return fos_vfs_create(path.ptr, path.len, out);
}

pub fn vfs_unlink(path: []const u8) c_int {
    return fos_vfs_unlink(path.ptr, path.len);
}

pub fn vfs_rename(old: []const u8, new: []const u8) c_int {
    return fos_vfs_rename(old.ptr, old.len, new.ptr, new.len);
}
