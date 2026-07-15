// Transitional adapter for Rust-owned open-file lifetime helpers.

const layout = @import("task_layout");

pub const TaskStruct = layout.TaskStruct;
pub const File = layout.File;
pub const FD_TABLE_SIZE = layout.FD_TABLE_SIZE;

pub const FType = enum(u8) {
    INITRAMFS_FILE = 0,
    _,
};

extern fn fos_file_alloc() ?*File;
extern fn fos_file_unref(file: *File) void;
extern fn fos_file_ref(file: *File) void;

pub fn alloc() ?*File {
    return fos_file_alloc();
}

pub fn unref(file: *File) void {
    fos_file_unref(file);
}

pub fn ref(file: *File) void {
    fos_file_ref(file);
}
