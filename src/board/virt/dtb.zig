// Minimal Flattened Device Tree (FDT v17) parser for QEMU virt /
// any UEFI host that hands off a DTB pointer in x0 at kernel entry.
//
// The DTB physical address is captured by src/boot.S `master` (via
// the per-board `save_dtb_pa` macro) into the .bss global `dtb_pa`
// declared in src/board/virt/boot_quirks.S. After the high-half
// linear map is up, this file reads the DTB at LINEAR_MAP_BASE +
// dtb_pa.
//
// Scope is intentionally tight: validate the FDT magic, walk the
// structure block, and answer two questions the virt drivers need:
//   * `findDeviceBase(compatible) ?u64`        — first `reg` base
//   * `findRegN(compatible, n)  ?u64`          — Nth `reg` base
//   * `findInterrupt(compatible) ?u32`         — first `interrupts`
//                                                 triplet → GIC INTID
//
// Conventions baked in (matching QEMU virt's DTB):
//   * #address-cells = 2, #size-cells = 2 at the root, so each
//     `reg` entry is 16 B (8 B address + 8 B size).
//   * `interrupts` triples are 12 B (3 × u32):
//       (type, irq, flags) where type 0 = SPI → INTID = irq + 32,
//       type 1 = PPI → INTID = irq + 16. Flags are ignored.
// Drivers fall back to their hard-coded constants when the lookup
// returns null, so a missing / malformed DTB doesn't break boot.
//
// All multi-byte FDT fields are big-endian; on AArch64 (LE) we
// decode via @byteSwap. The parser does no allocation.

const std = @import("std");

const LINEAR_MAP_BASE: u64 = 0xffff000000000000;

const FDT_MAGIC: u32 = 0xd00dfeed;
const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_NOP: u32 = 4;
const FDT_END: u32 = 9;

extern var dtb_pa: u64;

fn beU32(p: [*]const u8) u32 {
    var raw: u32 = undefined;
    @memcpy(std.mem.asBytes(&raw), p[0..4]);
    return @byteSwap(raw);
}

fn beU64(p: [*]const u8) u64 {
    var raw: u64 = undefined;
    @memcpy(std.mem.asBytes(&raw), p[0..8]);
    return @byteSwap(raw);
}

fn alignUp4(n: u32) u32 {
    return (n + 3) & ~@as(u32, 3);
}

pub const Dtb = struct {
    base: [*]const u8,
    total_size: u32,
    off_struct: u32,
    off_strings: u32,
    size_struct: u32,

    /// Build a Dtb view from the handoff pointer left in `dtb_pa`.
    /// Returns null if no DTB was handed off (Pi path or pre-handoff
    /// boot stage) or the magic doesn't match.
    pub fn fromHandoff() ?Dtb {
        if (dtb_pa == 0) return null;
        const base: [*]const u8 = @ptrFromInt(dtb_pa + LINEAR_MAP_BASE);
        if (beU32(base) != FDT_MAGIC) return null;
        return .{
            .base = base,
            .total_size = beU32(base + 4),
            .off_struct = beU32(base + 8),
            .off_strings = beU32(base + 16),
            .size_struct = beU32(base + 36),
        };
    }

    fn propName(self: *const Dtb, name_off: u32) []const u8 {
        const start = self.base + self.off_strings + name_off;
        var len: usize = 0;
        while (start[len] != 0) : (len += 1) {}
        return start[0..len];
    }

    /// Iterate the structure block looking for a node whose `compatible`
    /// property contains `compat` (NUL-separated string list per spec).
    /// Returns the byte offset within `base` of the first FDT token of
    /// the matching node's body (i.e., just past the BEGIN_NODE name).
    fn findNode(self: *const Dtb, compat: []const u8) ?u32 {
        var off: u32 = self.off_struct;
        const end: u32 = self.off_struct + self.size_struct;
        var current_body: u32 = 0;

        while (off + 4 <= end) {
            const tok = beU32(self.base + off);
            off += 4;
            switch (tok) {
                FDT_BEGIN_NODE => {
                    // Skip the NUL-terminated node name, padded to 4 B.
                    var name_len: u32 = 0;
                    while (self.base[off + name_len] != 0) : (name_len += 1) {}
                    off += alignUp4(name_len + 1);
                    current_body = off;
                },
                FDT_END_NODE => {},
                FDT_PROP => {
                    if (off + 8 > end) return null;
                    const plen = beU32(self.base + off);
                    const nameoff = beU32(self.base + off + 4);
                    off += 8;
                    const value = (self.base + off)[0..plen];
                    off += alignUp4(plen);

                    const name = self.propName(nameoff);
                    if (std.mem.eql(u8, name, "compatible")) {
                        // value is a NUL-separated list; check each entry.
                        var i: usize = 0;
                        while (i < value.len) {
                            var j = i;
                            while (j < value.len and value[j] != 0) : (j += 1) {}
                            if (std.mem.eql(u8, value[i..j], compat)) {
                                return current_body;
                            }
                            i = j + 1;
                        }
                    }
                },
                FDT_NOP => {},
                FDT_END => return null,
                else => return null,
            }
        }
        return null;
    }

    /// Read the named property of the node whose body starts at
    /// `node_body_off`. Stops at the first FDT_END_NODE that closes
    /// the node, so child-node properties are not visible.
    fn getProp(self: *const Dtb, node_body_off: u32, prop: []const u8) ?[]const u8 {
        var off: u32 = node_body_off;
        const end: u32 = self.off_struct + self.size_struct;
        var depth: i32 = 1;

        while (off + 4 <= end) {
            const tok = beU32(self.base + off);
            off += 4;
            switch (tok) {
                FDT_BEGIN_NODE => {
                    depth += 1;
                    var name_len: u32 = 0;
                    while (self.base[off + name_len] != 0) : (name_len += 1) {}
                    off += alignUp4(name_len + 1);
                },
                FDT_END_NODE => {
                    depth -= 1;
                    if (depth == 0) return null;
                },
                FDT_PROP => {
                    if (off + 8 > end) return null;
                    const plen = beU32(self.base + off);
                    const nameoff = beU32(self.base + off + 4);
                    off += 8;
                    const value = (self.base + off)[0..plen];
                    off += alignUp4(plen);

                    if (depth == 1 and std.mem.eql(u8, self.propName(nameoff), prop)) {
                        return value;
                    }
                },
                FDT_NOP => {},
                FDT_END => return null,
                else => return null,
            }
        }
        return null;
    }

    /// First reg entry's base (8 B address, big-endian). Assumes
    /// #address-cells = #size-cells = 2 at the root.
    pub fn findDeviceBase(self: *const Dtb, compatible: []const u8) ?u64 {
        return self.findRegN(compatible, 0);
    }

    /// Nth reg entry's base. Used for GIC's distributor (n=0) and
    /// redistributor (n=1) which share one node.
    pub fn findRegN(self: *const Dtb, compatible: []const u8, n: usize) ?u64 {
        const node = self.findNode(compatible) orelse return null;
        const reg = self.getProp(node, "reg") orelse return null;
        const stride: usize = 16; // (addr 8B, size 8B)
        if (reg.len < (n + 1) * stride) return null;
        return beU64(reg.ptr + n * stride);
    }

    /// First `interrupts` triplet decoded as a GIC INTID (PPI/SPI
    /// translated). Flags are ignored. Returns null if the prop is
    /// missing or shorter than one triplet.
    pub fn findInterrupt(self: *const Dtb, compatible: []const u8) ?u32 {
        const node = self.findNode(compatible) orelse return null;
        const ints = self.getProp(node, "interrupts") orelse return null;
        if (ints.len < 12) return null;
        const typ = beU32(ints.ptr);
        const irq = beU32(ints.ptr + 4);
        return switch (typ) {
            0 => irq + 32, // SPI
            1 => irq + 16, // PPI
            else => null,
        };
    }
};
