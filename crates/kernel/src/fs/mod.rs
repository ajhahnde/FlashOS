//! The filesystem stack: the VFS and path resolver, the open-file and
//! descriptor tables, pipes, permission checks, the overlay, and the
//! initramfs and FAT32 backends.
pub mod fat32;
pub mod fat32_backend;
pub mod fdtable;
pub mod file;
pub mod initramfs;
pub mod initramfs_backend;
pub mod overlay;
pub mod path;
pub mod perm;
pub mod pipe;
pub mod vfs;
