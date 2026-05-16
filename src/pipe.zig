// Anonymous pipes (v0.3.0).
//
// One get_free_page per `Pipe`. The header lives at the start of the
// page; the byte ring fills the rest (4 KiB - sizeof(Pipe)). `head`
// and `tail` are monotone u32 byte counters — indexing happens via
// modulo RING_CAP — so `is_full` vs. `is_empty` is trivially
// distinguishable without burning a slot. FIXME: the u32 counters
// wrap after 4 GiB of pipe traffic; widen to u64 or roll the
// counters modulo (2 * RING_CAP) before then.
//
// The page is **not** tracked in mm.user_pages / mm.kernel_pages — the
// Pipe.refs counter owns the page lifetime. do_wait_impl frees only
// the address-space resources, so the only path from refs==0 back to
// the page allocator is unref().
//
// Single-producer / single-consumer per pipe end. Multi-reader /
// multi-writer is deferred along with the rest of the POSIX
// read(2)/write(2)/close(2) ABI.

const builtin = @import("builtin");
// Named module — see wait_queue.zig for the rationale.
const layout = @import("task_layout");
const wq_mod = @import("wait_queue");

pub const WaitQueue = wq_mod.WaitQueue;
pub const TaskStruct = layout.TaskStruct;
pub const FD_TABLE_SIZE = layout.FD_TABLE_SIZE;

pub const PAGE_SIZE: u64 = 1 << 12;

extern fn get_free_page() u64;
extern fn free_page(p: u64) void;
extern fn preempt_disable() void;
extern fn preempt_enable() void;

// In the freestanding kernel build the page allocator hands out a
// physical address; the kernel reads/writes the page through its
// TTBR1 linear-map alias at `pa | LINEAR_MAP_BASE`. The host test
// build allocates from a static buffer (tests/host_stubs.zig) and
// returns a bare host VA — no alias, identity mapping. Branching at
// comptime keeps the kernel path zero-overhead.
const LINEAR_MAP_BASE: u64 = 0xffff000000000000;

inline fn pageKva(pa: u64) u64 {
    return if (builtin.target.os.tag == .freestanding) pa | LINEAR_MAP_BASE else pa;
}

pub const Pipe = extern struct {
    refs: u32 = 0,
    head: u32 = 0,
    tail: u32 = 0,
    _pad: u32 = 0,
    readers_wq: WaitQueue = .{},
    writers_wq: WaitQueue = .{},
    // Ring data follows in the same page; see ringBase().

    pub fn count(self: *const Pipe) u32 {
        return self.head -% self.tail;
    }
    pub fn isEmpty(self: *const Pipe) bool {
        return self.head == self.tail;
    }
    pub fn isFull(self: *const Pipe) bool {
        return self.count() == RING_CAP;
    }
};

pub const HEADER_SIZE: u64 = @sizeOf(Pipe);
pub const RING_CAP: u32 = @intCast(PAGE_SIZE - HEADER_SIZE);

inline fn ringBase(p: *Pipe) [*]u8 {
    const base: u64 = @intFromPtr(p) + HEADER_SIZE;
    return @ptrFromInt(base);
}

// Allocate + initialise. Caller bumps `refs` before installing the
// pipe in any fd slot. Returns null on allocator failure.
pub fn alloc() ?*Pipe {
    const pa = get_free_page();
    if (pa == 0) return null;
    const kva = pageKva(pa);
    const p: *Pipe = @ptrFromInt(kva);
    p.* = .{};
    return p;
}

pub fn ref(p: *Pipe) void {
    preempt_disable();
    p.refs += 1;
    preempt_enable();
}

// Decrement the reference count. On the last drop, wake everyone
// blocked on either end (they'll see the refs==0 short-circuit on
// re-entry) and return the page to the allocator.
pub fn unref(p: *Pipe) void {
    preempt_disable();
    p.refs -= 1;
    const last = p.refs == 0;
    preempt_enable();
    if (!last) return;
    // Wake-side runs without holding the page; the woken tasks observe
    // the (now zeroed) refs == 0 / closed state on their next read or
    // write iteration. No one can race us to free the page because
    // there are by construction no other refs.
    p.readers_wq.wake_all();
    p.writers_wq.wake_all();
    const kva: u64 = @intFromPtr(p);
    const pa: u64 = if (builtin.target.os.tag == .freestanding)
        kva & ~LINEAR_MAP_BASE
    else
        kva;
    free_page(pa);
}

// Block until at least one byte is available, then drain what is
// present (up to `len`). Returns 0 on EOF (refs == 1 && empty —
// caller holds the only fd, no writers can wake us). Negative is
// reserved for future short-read error paths.
pub fn read(p: *Pipe, buf: [*]u8, len: u64) i64 {
    var written: u64 = 0;
    while (written < len) {
        preempt_disable();
        if (p.isEmpty()) {
            // Last-writer-closed EOF: caller's fd is the only ref.
            if (p.refs <= 1) {
                preempt_enable();
                break;
            }
            preempt_enable();
            p.readers_wq.wait();
            continue;
        }
        const ring = ringBase(p);
        while (written < len and !p.isEmpty()) {
            buf[written] = ring[p.tail % RING_CAP];
            p.tail +%= 1;
            written += 1;
        }
        preempt_enable();
        p.writers_wq.wake_one();
        // Break after one drain: short-read is fine, matches
        // POSIX read(2) for pipes — caller loops if it needs more.
        break;
    }
    return @intCast(written);
}

// Push bytes until `len` are written or the pipe loses all readers.
// Returns the number of bytes pushed; negative is reserved.
pub fn write(p: *Pipe, buf: [*]const u8, len: u64) i64 {
    var pushed: u64 = 0;
    while (pushed < len) {
        preempt_disable();
        if (p.isFull()) {
            // Last-reader-closed: SIGPIPE territory in POSIX; for
            // now a short-write with the bytes pushed so far is
            // enough — signal path TBD.
            if (p.refs <= 1) {
                preempt_enable();
                break;
            }
            preempt_enable();
            p.writers_wq.wait();
            continue;
        }
        const ring = ringBase(p);
        while (pushed < len and !p.isFull()) {
            ring[p.head % RING_CAP] = buf[pushed];
            p.head +%= 1;
            pushed += 1;
        }
        preempt_enable();
        p.readers_wq.wake_one();
    }
    return @intCast(pushed);
}

// ---- fd-table helpers ----
//
// Live on pipe.zig (not sys.zig) so the dispatch layer stays a thin
// shim. The fd_table slot type is `?*anyopaque` — see task_layout.zig
// for why the layout module deliberately keeps Pipe-typedness out of
// TaskStruct.

pub fn fdAlloc(t: *TaskStruct, p: *Pipe) i32 {
    var i: usize = 0;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        if (t.fd_table[i] == null) {
            t.fd_table[i] = @ptrCast(p);
            return @intCast(i);
        }
    }
    return -1;
}

pub fn fdGet(t: *TaskStruct, fd: i32) ?*Pipe {
    if (fd < 0) return null;
    const idx: usize = @intCast(fd);
    if (idx >= FD_TABLE_SIZE) return null;
    const raw = t.fd_table[idx] orelse return null;
    return @ptrCast(@alignCast(raw));
}

pub fn fdClose(t: *TaskStruct, fd: i32) i32 {
    const p = fdGet(t, fd) orelse return -1;
    const idx: usize = @intCast(fd);
    t.fd_table[idx] = null;
    unref(p);
    return 0;
}

// Called from the fork-dup path (copy_process_impl) to bump the
// refcount on every inherited slot, and from the reap path
// (do_wait_impl) to drop refs for fds the zombie didn't close itself.
pub fn dupAll(src: *TaskStruct, dst: *TaskStruct) void {
    var i: usize = 0;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        if (src.fd_table[i]) |raw| {
            const p: *Pipe = @ptrCast(@alignCast(raw));
            ref(p);
            dst.fd_table[i] = raw;
        }
    }
}

pub fn closeAll(t: *TaskStruct) void {
    var i: usize = 0;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        if (t.fd_table[i]) |raw| {
            t.fd_table[i] = null;
            unref(@ptrCast(@alignCast(raw)));
        }
    }
}

// ---- Host tests ----

const std = @import("std");

test "empty pipe: isEmpty true, isFull false, count == 0" {
    const p = alloc() orelse return error.OutOfMemory;
    p.refs = 1;
    try std.testing.expect(p.isEmpty());
    try std.testing.expect(!p.isFull());
    try std.testing.expectEqual(@as(u32, 0), p.count());
    p.refs = 0;
    // Not calling unref — host stubs leak; bump-allocator doesn't recycle.
}

test "write then read round-trips bytes" {
    const p = alloc() orelse return error.OutOfMemory;
    p.refs = 2; // two fds installed
    const payload = "hello-pipe";
    const n_w = write(p, payload.ptr, payload.len);
    try std.testing.expectEqual(@as(i64, payload.len), n_w);
    try std.testing.expectEqual(@as(u32, payload.len), p.count());

    var buf: [16]u8 = undefined;
    const n_r = read(p, &buf, payload.len);
    try std.testing.expectEqual(@as(i64, payload.len), n_r);
    try std.testing.expectEqualSlices(u8, payload, buf[0..@intCast(n_r)]);
    try std.testing.expect(p.isEmpty());
}

test "head/tail wraparound preserves byte order" {
    const p = alloc() orelse return error.OutOfMemory;
    p.refs = 2;
    // Seed head/tail near wrap so the next write+read straddles modulo.
    p.head = RING_CAP - 4;
    p.tail = RING_CAP - 4;
    const payload = "ABCDEFGH"; // 8 bytes — last 4 wrap to ring[0..4]
    _ = write(p, payload.ptr, payload.len);
    try std.testing.expectEqual(@as(u32, 8), p.count());
    var buf: [8]u8 = undefined;
    _ = read(p, &buf, payload.len);
    try std.testing.expectEqualSlices(u8, payload, buf[0..]);
}

test "EOF: empty pipe with refs == 1 returns 0 instead of blocking" {
    const p = alloc() orelse return error.OutOfMemory;
    p.refs = 1; // caller holds only the read end
    var buf: [4]u8 = undefined;
    const n = read(p, &buf, buf.len);
    try std.testing.expectEqual(@as(i64, 0), n);
}

test "isFull vs isEmpty mutually exclusive at boundaries" {
    const p = alloc() orelse return error.OutOfMemory;
    p.refs = 2;
    // count == 0 → empty, not full.
    try std.testing.expect(p.isEmpty());
    try std.testing.expect(!p.isFull());
    // count == RING_CAP → full, not empty.
    p.head = RING_CAP;
    p.tail = 0;
    try std.testing.expect(p.isFull());
    try std.testing.expect(!p.isEmpty());
}

test "fdAlloc fills the first null slot; out-of-fds returns -1" {
    var t: TaskStruct = .{};
    const p = alloc() orelse return error.OutOfMemory;
    p.refs = 1;

    const a = fdAlloc(&t, p);
    try std.testing.expectEqual(@as(i32, 0), a);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(p)), t.fd_table[0]);

    // Fill the rest of the table.
    var i: usize = 1;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        _ = fdAlloc(&t, p);
    }
    try std.testing.expectEqual(@as(i32, -1), fdAlloc(&t, p));
}

test "fdClose clears the slot and decrements refs" {
    var t: TaskStruct = .{};
    const p = alloc() orelse return error.OutOfMemory;
    p.refs = 2;
    const fd = fdAlloc(&t, p);
    try std.testing.expectEqual(@as(i32, 0), fdClose(&t, fd));
    try std.testing.expectEqual(@as(?*anyopaque, null), t.fd_table[0]);
    try std.testing.expectEqual(@as(u32, 1), p.refs);
    // fdClose on an empty slot returns -1.
    try std.testing.expectEqual(@as(i32, -1), fdClose(&t, fd));
}

test "closeAll clears every slot and drops refs" {
    var t: TaskStruct = .{};
    const p = alloc() orelse return error.OutOfMemory;
    p.refs = 2;
    _ = fdAlloc(&t, p);
    _ = fdAlloc(&t, p);
    p.refs = 2; // override the fdAlloc-unaware refs we set above
    closeAll(&t);
    var i: usize = 0;
    while (i < FD_TABLE_SIZE) : (i += 1) {
        try std.testing.expectEqual(@as(?*anyopaque, null), t.fd_table[i]);
    }
}

test "dupAll bumps refs and copies every non-null slot" {
    var src: TaskStruct = .{};
    var dst: TaskStruct = .{};
    const p = alloc() orelse return error.OutOfMemory;
    p.refs = 2;
    _ = fdAlloc(&src, p);
    _ = fdAlloc(&src, p);

    dupAll(&src, &dst);
    try std.testing.expectEqual(src.fd_table[0], dst.fd_table[0]);
    try std.testing.expectEqual(src.fd_table[1], dst.fd_table[1]);
    try std.testing.expectEqual(@as(u32, 4), p.refs);
}
