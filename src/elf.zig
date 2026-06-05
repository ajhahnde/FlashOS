// elf: ELF64 header and program-header parser.
//
// Pure data structures — no externs, no allocation, no kernel state —
// so this module is host-testable. The ELF loader
// (sys_execve / kernel boot → prepare_move_to_user_elf in
// src/fork.zig) uses parseEhdr + iteratePhdrs to walk PT_LOAD
// segments before mapping them with map_page.
//
// Scope is deliberately narrow:
//   * ELF64, little-endian, AArch64, ET_EXEC only.
//   * Validation rejects ET_DYN — dynamic relocations / PIE land
//     later if at all.
//   * No section-header parsing. The loader does not need section
//     names; segments are enough.

const user_layout = @import("user_layout");

pub const ELF_MAGIC = [_]u8{ 0x7F, 'E', 'L', 'F' };
pub const ELFCLASS64: u8 = 2;
pub const ELFDATA2LSB: u8 = 1;
pub const EV_CURRENT: u32 = 1;
pub const ET_EXEC: u16 = 2;
pub const EM_AARCH64: u16 = 183;

pub const PT_LOAD: u32 = 1;

pub const PF_X: u32 = 1 << 0;
pub const PF_W: u32 = 1 << 1;
pub const PF_R: u32 = 1 << 2;

// Panic-bound on Phdr count. Real AArch64 ET_EXEC binaries from
// `zig build-exe` use 4-6 program headers; 16 is a generous ceiling
// that still bounds blast radius if the header is malicious.
pub const MAX_PHDRS: u16 = 16;

pub const Ehdr = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

pub const Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

comptime {
    if (@sizeOf(Ehdr) != 64) @compileError("ELF64 Ehdr must be 64 bytes");
    if (@sizeOf(Phdr) != 56) @compileError("ELF64 Phdr must be 56 bytes");
}

pub const ParseError = error{
    BadMagic,
    NotElf64,
    NotLittleEndian,
    NotExecutable,
    NotAarch64,
    BadVersion,
    BadEntry,
    EntryOutOfBounds,
    PhoffOutOfBounds,
    TooManyPhdrs,
    MemszOverflow,
    VaddrOutOfBounds,
};

pub fn parseEhdr(blob: []const u8) ParseError!Ehdr {
    if (blob.len < @sizeOf(Ehdr)) return error.BadMagic;
    var ehdr: Ehdr = undefined;
    const bytes: [*]u8 = @ptrCast(&ehdr);
    @memcpy(bytes[0..@sizeOf(Ehdr)], blob[0..@sizeOf(Ehdr)]);

    if (ehdr.e_ident[0] != ELF_MAGIC[0] or
        ehdr.e_ident[1] != ELF_MAGIC[1] or
        ehdr.e_ident[2] != ELF_MAGIC[2] or
        ehdr.e_ident[3] != ELF_MAGIC[3]) return error.BadMagic;
    if (ehdr.e_ident[4] != ELFCLASS64) return error.NotElf64;
    if (ehdr.e_ident[5] != ELFDATA2LSB) return error.NotLittleEndian;
    if (ehdr.e_type != ET_EXEC) return error.NotExecutable;
    if (ehdr.e_machine != EM_AARCH64) return error.NotAarch64;
    if (ehdr.e_version != EV_CURRENT) return error.BadVersion;

    if (ehdr.e_entry < user_layout.TEXT_BASE or ehdr.e_entry >= user_layout.DATA_BASE) {
        return error.EntryOutOfBounds;
    }

    if (ehdr.e_phnum > MAX_PHDRS) return error.TooManyPhdrs;

    // Bound the program-header table itself: e_phoff..e_phoff +
    // phentsize*phnum must fit. Per-Phdr file-data bounds are checked
    // lazily in PhdrIterator.next(); a malformed blob with one bad
    // Phdr should still let earlier valid ones through to the loader.
    // Overflow checked via wraparound: `ph_end < ehdr.e_phoff` iff
    // `phentsize *% phnum` overflowed u64, since wraparound makes the
    // sum smaller than the original `e_phoff` addend.
    const phnum: u64 = ehdr.e_phnum;
    const phentsize: u64 = ehdr.e_phentsize;
    const ph_end = ehdr.e_phoff +% phentsize *% phnum;
    if (ph_end < ehdr.e_phoff or ph_end > blob.len) return error.PhoffOutOfBounds;

    return ehdr;
}

pub const PhdrIterator = struct {
    blob: []const u8,
    cursor: u64,
    stride: u64,
    remaining: u16,

    pub fn next(self: *PhdrIterator) ParseError!?Phdr {
        if (self.remaining == 0) return null;
        if (self.cursor +% @sizeOf(Phdr) > self.blob.len) return error.PhoffOutOfBounds;

        var phdr: Phdr = undefined;
        const bytes: [*]u8 = @ptrCast(&phdr);
        @memcpy(bytes[0..@sizeOf(Phdr)], self.blob[self.cursor..][0..@sizeOf(Phdr)]);

        // PT_LOAD is the only segment the loader copies into a user
        // page; bound-check its file region so the loader never
        // memcpy's past blob end. Other segment types are skipped at
        // the loader level, so their offsets do not matter here.
        if (phdr.p_type == PT_LOAD) {
            const seg_end = phdr.p_offset +% phdr.p_filesz;
            if (seg_end < phdr.p_offset or seg_end > self.blob.len) {
                return error.PhoffOutOfBounds;
            }
            // Virtual range must not wrap u64. The loader
            // (prepare_move_to_user_elf in src/fork.zig) walks e_entry against
            // [p_vaddr, p_vaddr + p_memsz) and maps that span one page at a
            // time; a wrapped sum would corrupt both the entry-mapped test and
            // the page loop. p_vaddr is otherwise unconstrained here — unlike
            // e_entry, which parseEhdr pins to [TEXT_BASE, DATA_BASE).
            const mem_end = phdr.p_vaddr +% phdr.p_memsz;
            if (mem_end < phdr.p_vaddr) return error.MemszOverflow;
            // The mapped span must also land inside the user range the
            // loader can populate: [TEXT_BASE, STACK_LOW). A crafted
            // p_vaddr above it would otherwise be mapped page-by-page over
            // the stack (eagerly mapped at STACK_TOP) or its guard region.
            // This is the p_vaddr counterpart to parseEhdr's e_entry pin —
            // the two were asymmetric: e_entry was range-checked, p_vaddr
            // was not.
            if (phdr.p_vaddr < user_layout.TEXT_BASE or mem_end > user_layout.STACK_LOW) {
                return error.VaddrOutOfBounds;
            }
        }

        self.cursor += self.stride;
        self.remaining -= 1;
        return phdr;
    }
};

pub fn iteratePhdrs(blob: []const u8, ehdr: Ehdr) PhdrIterator {
    return .{
        .blob = blob,
        .cursor = ehdr.e_phoff,
        .stride = ehdr.e_phentsize,
        .remaining = ehdr.e_phnum,
    };
}

// ---- host tests ----------------------------------------------------

const std = @import("std");

const PHENTSIZE: u16 = @sizeOf(Phdr);
const EHSIZE: u16 = @sizeOf(Ehdr);

fn writeU16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @intCast(v & 0xFF);
    buf[off + 1] = @intCast((v >> 8) & 0xFF);
}

fn writeU32(buf: []u8, off: usize, v: u32) void {
    buf[off] = @intCast(v & 0xFF);
    buf[off + 1] = @intCast((v >> 8) & 0xFF);
    buf[off + 2] = @intCast((v >> 16) & 0xFF);
    buf[off + 3] = @intCast((v >> 24) & 0xFF);
}

fn writeU64(buf: []u8, off: usize, v: u64) void {
    var i: usize = 0;
    while (i < 8) : (i += 1) buf[off + i] = @intCast((v >> @intCast(i * 8)) & 0xFF);
}

/// Lay down a minimal valid Ehdr at offset 0 of `buf`. Caller controls
/// e_phoff / e_phnum / e_entry; the rest are pinned to a parseEhdr-
/// happy default.
fn writeEhdr(buf: []u8, e_entry: u64, e_phoff: u64, e_phnum: u16) void {
    @memset(buf[0..EHSIZE], 0);
    buf[0] = 0x7F;
    buf[1] = 'E';
    buf[2] = 'L';
    buf[3] = 'F';
    buf[4] = ELFCLASS64;
    buf[5] = ELFDATA2LSB;
    buf[6] = 1; // EI_VERSION
    writeU16(buf, 16, ET_EXEC);
    writeU16(buf, 18, EM_AARCH64);
    writeU32(buf, 20, EV_CURRENT);
    writeU64(buf, 24, e_entry);
    writeU64(buf, 32, e_phoff);
    writeU64(buf, 40, 0); // e_shoff
    writeU32(buf, 48, 0); // e_flags
    writeU16(buf, 52, EHSIZE);
    writeU16(buf, 54, PHENTSIZE);
    writeU16(buf, 56, e_phnum);
    writeU16(buf, 58, 0);
    writeU16(buf, 60, 0);
    writeU16(buf, 62, 0);
}

fn writePhdr(buf: []u8, off: usize, p_type: u32, p_flags: u32, p_offset: u64, p_filesz: u64, p_memsz: u64, p_vaddr: u64) void {
    @memset(buf[off..][0..PHENTSIZE], 0);
    writeU32(buf, off + 0, p_type);
    writeU32(buf, off + 4, p_flags);
    writeU64(buf, off + 8, p_offset);
    writeU64(buf, off + 16, p_vaddr);
    writeU64(buf, off + 24, p_vaddr); // p_paddr = p_vaddr
    writeU64(buf, off + 32, p_filesz);
    writeU64(buf, off + 40, p_memsz);
    writeU64(buf, off + 48, 0x1000); // p_align
}

test "parseEhdr accepts a minimal valid header" {
    var buf: [EHSIZE]u8 = undefined;
    writeEhdr(&buf, 0x1000, 0, 0);
    const ehdr = try parseEhdr(&buf);
    try std.testing.expectEqual(@as(u16, ET_EXEC), ehdr.e_type);
    try std.testing.expectEqual(@as(u16, EM_AARCH64), ehdr.e_machine);
    try std.testing.expectEqual(@as(u64, 0x1000), ehdr.e_entry);
}

test "parseEhdr: BadMagic on truncated blob" {
    var buf: [EHSIZE - 1]u8 = undefined;
    @memset(&buf, 0);
    try std.testing.expectError(error.BadMagic, parseEhdr(&buf));
}

test "parseEhdr: BadMagic on flipped magic byte" {
    var buf: [EHSIZE]u8 = undefined;
    writeEhdr(&buf, 0x1000, 0, 0);
    buf[1] = 'X';
    try std.testing.expectError(error.BadMagic, parseEhdr(&buf));
}

test "parseEhdr: NotElf64 on ELFCLASS32" {
    var buf: [EHSIZE]u8 = undefined;
    writeEhdr(&buf, 0x1000, 0, 0);
    buf[4] = 1; // ELFCLASS32
    try std.testing.expectError(error.NotElf64, parseEhdr(&buf));
}

test "parseEhdr: NotLittleEndian on ELFDATA2MSB" {
    var buf: [EHSIZE]u8 = undefined;
    writeEhdr(&buf, 0x1000, 0, 0);
    buf[5] = 2; // ELFDATA2MSB
    try std.testing.expectError(error.NotLittleEndian, parseEhdr(&buf));
}

test "parseEhdr: NotExecutable on ET_DYN" {
    var buf: [EHSIZE]u8 = undefined;
    writeEhdr(&buf, 0x1000, 0, 0);
    writeU16(&buf, 16, 3); // ET_DYN
    try std.testing.expectError(error.NotExecutable, parseEhdr(&buf));
}

test "parseEhdr: NotAarch64 on EM_X86_64" {
    var buf: [EHSIZE]u8 = undefined;
    writeEhdr(&buf, 0x1000, 0, 0);
    writeU16(&buf, 18, 62); // EM_X86_64
    try std.testing.expectError(error.NotAarch64, parseEhdr(&buf));
}

test "parseEhdr: BadVersion on e_version=0" {
    var buf: [EHSIZE]u8 = undefined;
    writeEhdr(&buf, 0x1000, 0, 0);
    writeU32(&buf, 20, 0);
    try std.testing.expectError(error.BadVersion, parseEhdr(&buf));
}

test "parseEhdr: EntryOutOfBounds on e_entry >= DATA_BASE" {
    var buf: [EHSIZE]u8 = undefined;
    writeEhdr(&buf, user_layout.DATA_BASE, 0, 0);
    try std.testing.expectError(error.EntryOutOfBounds, parseEhdr(&buf));
}

test "parseEhdr: TooManyPhdrs above MAX_PHDRS" {
    var buf: [EHSIZE]u8 = undefined;
    writeEhdr(&buf, 0x1000, 0, MAX_PHDRS + 1);
    try std.testing.expectError(error.TooManyPhdrs, parseEhdr(&buf));
}

test "parseEhdr: PhoffOutOfBounds when Phdr table overruns blob" {
    var buf: [EHSIZE]u8 = undefined;
    // Two Phdrs declared at offset EHSIZE, but blob is exactly EHSIZE
    // bytes — the table runs off the end.
    writeEhdr(&buf, 0x1000, EHSIZE, 2);
    try std.testing.expectError(error.PhoffOutOfBounds, parseEhdr(&buf));
}

test "iteratePhdrs decodes a 2-PT_LOAD fixture" {
    var buf: [EHSIZE + 2 * PHENTSIZE + 0x1000]u8 = undefined;
    @memset(&buf, 0);
    writeEhdr(&buf, 0x1000, EHSIZE, 2);
    // Text segment: small, RX, file-backed at offset EHSIZE+2*PHENTSIZE
    writePhdr(&buf, EHSIZE + 0 * PHENTSIZE, PT_LOAD, PF_R | PF_X, EHSIZE + 2 * PHENTSIZE, 0x100, 0x100, 0x0);
    // Data segment: BSS-larger-than-file, RW, file-backed right after
    writePhdr(&buf, EHSIZE + 1 * PHENTSIZE, PT_LOAD, PF_R | PF_W, EHSIZE + 2 * PHENTSIZE + 0x100, 0x80, 0x200, 0x10_0000);

    const ehdr = try parseEhdr(&buf);
    var it = iteratePhdrs(&buf, ehdr);

    const p0 = (try it.next()).?;
    try std.testing.expectEqual(@as(u32, PT_LOAD), p0.p_type);
    try std.testing.expectEqual(PF_R | PF_X, p0.p_flags);
    try std.testing.expectEqual(@as(u64, 0x100), p0.p_filesz);
    try std.testing.expectEqual(@as(u64, 0x0), p0.p_vaddr);

    const p1 = (try it.next()).?;
    try std.testing.expectEqual(@as(u32, PT_LOAD), p1.p_type);
    try std.testing.expectEqual(PF_R | PF_W, p1.p_flags);
    try std.testing.expectEqual(@as(u64, 0x80), p1.p_filesz);
    try std.testing.expectEqual(@as(u64, 0x200), p1.p_memsz);
    try std.testing.expectEqual(@as(u64, 0x10_0000), p1.p_vaddr);

    try std.testing.expectEqual(@as(?Phdr, null), try it.next());
}

test "iteratePhdrs: PhoffOutOfBounds when PT_LOAD file range overruns blob" {
    var buf: [EHSIZE + PHENTSIZE]u8 = undefined;
    @memset(&buf, 0);
    writeEhdr(&buf, 0x1000, EHSIZE, 1);
    // p_filesz pushes the end of the segment past blob.len
    writePhdr(&buf, EHSIZE, PT_LOAD, PF_R, EHSIZE + PHENTSIZE, 0x1000, 0x1000, 0x0);

    const ehdr = try parseEhdr(&buf);
    var it = iteratePhdrs(&buf, ehdr);
    try std.testing.expectError(error.PhoffOutOfBounds, it.next());
}

test "iteratePhdrs: non-PT_LOAD entries are not bounds-checked" {
    var buf: [EHSIZE + PHENTSIZE]u8 = undefined;
    @memset(&buf, 0);
    writeEhdr(&buf, 0x1000, EHSIZE, 1);
    // PT_NOTE (4) with bogus offsets — loader skips, parser must not
    // reject. Keeps blobs with stripped notes / interp segments
    // working without forcing the loader to filter pre-iteration.
    writePhdr(&buf, EHSIZE, 4, 0, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0x0);

    const ehdr = try parseEhdr(&buf);
    var it = iteratePhdrs(&buf, ehdr);
    const p = (try it.next()).?;
    try std.testing.expectEqual(@as(u32, 4), p.p_type);
}

test "iteratePhdrs: MemszOverflow when p_vaddr + p_memsz wraps u64" {
    var buf: [EHSIZE + PHENTSIZE]u8 = undefined;
    @memset(&buf, 0);
    writeEhdr(&buf, 0x1000, EHSIZE, 1);
    // Valid file range (filesz 0, offset in-bounds) so the seg_end check
    // passes and the virtual-range wrap is what trips. p_vaddr near the top
    // of the address space + a nonzero p_memsz wraps the u64 sum.
    writePhdr(&buf, EHSIZE, PT_LOAD, PF_R, EHSIZE, 0, 0x2000, 0xFFFF_FFFF_FFFF_F000);
    const ehdr = try parseEhdr(&buf);
    var it = iteratePhdrs(&buf, ehdr);
    try std.testing.expectError(error.MemszOverflow, it.next());
}

test "iteratePhdrs: VaddrOutOfBounds when a PT_LOAD maps above STACK_LOW" {
    var buf: [EHSIZE + PHENTSIZE]u8 = undefined;
    @memset(&buf, 0);
    writeEhdr(&buf, 0x1000, EHSIZE, 1);
    // File range valid (filesz 0, in-bounds offset) and the virtual sum
    // does not wrap u64, so neither PhoffOutOfBounds nor MemszOverflow
    // fires — the p_vaddr range check is what must trip. p_vaddr sits at
    // STACK_TOP, so the mapped span would collide with the stack region.
    writePhdr(&buf, EHSIZE, PT_LOAD, PF_R, EHSIZE, 0, 0x1000, user_layout.STACK_TOP);
    const ehdr = try parseEhdr(&buf);
    var it = iteratePhdrs(&buf, ehdr);
    try std.testing.expectError(error.VaddrOutOfBounds, it.next());
}
