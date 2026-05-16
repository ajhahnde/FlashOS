// virt-board SD fallback — 64 MiB memory-backed scratch (v0.4.0).
//
// QEMU's `-M virt` does not ship an SDHCI peripheral on default
// invocation (passing `-drive if=sd,...` errors with "machine type
// does not support if=sd"), so the real BCM2711 EMMC2 driver from
// `src/board/rpi4b/emmc2.zig` cannot run here. The FAT32 backend
// talks to the SD card exclusively through the `block_dev.sd_dev`
// vtable, so a memory-backed fake satisfies the abstraction and
// lets [TEST] emmc2-block + [TEST] fs-roundtrip pass on virt
// without dragging in a QEMU SDHCI-on-PCI model.
//
// Future work (real virt storage) can swap the body for a
// `virtio-blk-device` driver if anyone actually needs persistent
// virt storage. The on-disk abstraction (`block_dev.BlockDev`) is
// stable enough that the swap is a one-file change.

const block_dev = @import("block_dev");

const SCRATCH_BLOCKS: u32 = 128 * 1024; // 64 MiB / 512 B per block

// `linksection(".sdscratch")`: keep this 64 MiB fake disk OUT of
// `.bss`. Before the FAT32 backend landed, nothing read
// `block_dev.sd_dev`, so LLVM dead-code-eliminated `scratch` and
// `.bss` stayed ~755 KiB —
// inside boot.S's `adr x1, bss_end` ±1 MiB PC-relative range. The
// FAT32 backend is the first real `sd_dev` reader; with `scratch`
// alive in `.bss`, `bss_end` lands 64 MiB out and the
// R_AARCH64_ADR_PREL_LO21 reloc overflows. Its own NOLOAD section
// (placed outside bss_begin..bss_end in src/board/virt/linker.ld)
// keeps bss_end reachable. init() @memsets the buffer itself, so it
// does not need boot.S's bss memzero — safe to exclude.
var scratch: [@as(usize, SCRATCH_BLOCKS) * 512]u8 linksection(".sdscratch") = undefined;

// Init signature mirrors the rpi4b counterpart's i32 return
// so kernel.zig can branch uniformly on failure. The virt fake has
// no failure paths — always returns 0 — but the caller still treats
// negative-return as a soft failure (log + continue) so the contract
// holds across boards.
pub fn init() i32 {
    @memset(&scratch, 0);
    block_dev.sd_dev = .{ .read_fn = read_block, .write_fn = write_block };
    return 0;
}

pub fn read_block(lba: u32, buf: *[512]u8) callconv(.c) i32 {
    if (lba >= SCRATCH_BLOCKS) return -1;
    const off: usize = @as(usize, lba) * 512;
    @memcpy(buf, scratch[off..][0..512]);
    return 0;
}

pub fn write_block(lba: u32, buf: *const [512]u8) callconv(.c) i32 {
    if (lba >= SCRATCH_BLOCKS) return -1;
    const off: usize = @as(usize, lba) * 512;
    @memcpy(scratch[off..][0..512], buf);
    return 0;
}
