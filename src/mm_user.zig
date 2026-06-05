// mm_user: user-page mapping and page-table walk.
// Layouts come from src/task_layout.zig.

const layout = @import("task_layout");
const TaskStruct = layout.TaskStruct;
const MAX_PAGE_COUNT = layout.MAX_PAGE_COUNT;

const builtin = @import("builtin");

// User VA regions + per-region permission bags. The ELF loader
// (prepare_move_to_user_elf) chooses flags per PT_LOAD region.
const user_layout = @import("user_layout");

const PAGE_SHIFT: u6 = 12;
const TABLE_SHIFT: u6 = 9;
const PAGE_SIZE: u64 = 1 << PAGE_SHIFT;
const PAGE_MASK: u64 = 0xFFFFFFFFFFFFF000;
const PGD_SHIFT: u6 = PAGE_SHIFT + 3 * TABLE_SHIFT;
const PUD_SHIFT: u6 = PAGE_SHIFT + 2 * TABLE_SHIFT;
const PMD_SHIFT: u6 = PAGE_SHIFT + TABLE_SHIFT;
const ENTRIES_PER_TABLE: u64 = 512;

const LINEAR_MAP_BASE: u64 = 0xFFFF000000000000;

// MMU descriptor flags (user). Page-table internals only — the
// per-leaf permission bag now lives in src/user_layout.zig
// (TD_USER_PAGE_FLAGS_DEFAULT) so the ELF loader and the
// demand-allocation page-fault path can share it.
const TD_VALID: u64 = 1 << 0;
const TD_TABLE: u64 = 1 << 1;
const TD_USER_TABLE_FLAGS: u64 = TD_TABLE | TD_VALID;

fn paToKva(pa: u64) u64 {
    if (builtin.target.os.tag == .freestanding) {
        return pa + LINEAR_MAP_BASE;
    } else {
        return pa;
    }
}

extern fn get_free_page() u64;
extern fn free_page(p: u64) void;
extern fn memcpy(dst: *anyopaque, src: *const anyopaque, bytes: u64) *anyopaque;
extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn main_output_u64(interface: i32, in: u64) void;
extern fn exit_process() void;
extern var current: ?*TaskStruct;

const MU: i32 = 0;

// Used by C code that links against KERNEL_PA_BASE.
export var KERNEL_PA_BASE: u64 = 0;

/// Number of populated kernel-page slots in this task.
export fn task_kp_count(t: *TaskStruct) i32 {
    var i: usize = 0;
    while (i < MAX_PAGE_COUNT) : (i += 1) {
        if (t.mm.kernel_pages[i] == 0) return @intCast(i);
    }
    return @intCast(MAX_PAGE_COUNT);
}

/// Number of populated user-page slots in this task.
export fn task_up_count(t: *TaskStruct) i32 {
    var i: usize = 0;
    while (i < MAX_PAGE_COUNT) : (i += 1) {
        if (t.mm.user_pages[i].pa == 0) return @intCast(i);
    }
    return @intCast(MAX_PAGE_COUNT);
}

/// Look up or allocate the next-level table for `uva` at `shift` in `table`.
/// Returns the physical address of that level. `new_table` is set to 1 iff
/// a new page was allocated (so the caller can register it for cleanup).
export fn map_table(table: [*]u64, shift: u64, uva: u64, new_table: *i32) u64 {
    const sh: u6 = @intCast(shift);
    var index: u64 = uva >> sh;
    index = index & (ENTRIES_PER_TABLE - 1);
    if (table[index] == 0) {
        const next_level: u64 = get_free_page();
        // OOM: return the 0 sentinel WITHOUT mutating the table. Writing
        // `0 | flags` here would leave a valid-looking descriptor mapping
        // PA 0 — a catastrophe the caller could not detect.
        if (next_level == 0) {
            new_table.* = 0;
            return 0;
        }
        new_table.* = 1;
        const entry: u64 = next_level | TD_USER_TABLE_FLAGS;
        table[index] = entry;
        return next_level;
    }
    new_table.* = 0;
    return table[index] & PAGE_MASK;
}

export fn map_table_entry(pte: [*]u64, uva: u64, phys_page: u64, flags: u64) void {
    var index: u64 = uva >> PAGE_SHIFT;
    index = index & (ENTRIES_PER_TABLE - 1);
    pte[index] = phys_page | flags;
}

/// Undo the page-table allocations this `map_page` call made on a failure
/// path: free and zero `kernel_pages[kp0..)` and, if the pgd itself was
/// created in this call, reset it. Tables that already existed (shared
/// with other mappings) were never added to `kernel_pages` this call, so
/// they are left intact. `kp0` is the kernel-page count captured at entry.
fn rollback_map_tables(t: *TaskStruct, kp0: i32, pgd_was_fresh: bool) void {
    var i: i32 = task_kp_count(t) - 1;
    while (i >= kp0) : (i -= 1) {
        free_page(t.mm.kernel_pages[@intCast(i)]);
        t.mm.kernel_pages[@intCast(i)] = 0;
    }
    if (pgd_was_fresh) t.mm.pgd = 0;
}

/// Map `phys_page` to user-virtual `uva` in `task` with permission `flags`,
/// allocating PUD/PMD/PTE pages as needed. Returns 0 on success, -1 if the
/// task ran out of slots OR the allocator is out of memory — in the latter
/// case any tables allocated mid-walk are rolled back so the call is
/// baseline-neutral. Pass `user_layout.TD_USER_PAGE_FLAGS_DEFAULT` for the
/// historical combined-permission bag; the ELF loader will choose
/// per-region values (text vs data/heap/stack).
export fn map_page(t: *TaskStruct, uva: u64, phys_page: u64, flags: u64) i32 {
    // Snapshot for rollback: pages registered at index >= kp0 belong to
    // this call, and the pgd is ours to reset only if it did not exist yet.
    const kp0 = task_kp_count(t);
    const pgd_was_fresh = (t.mm.pgd == 0);

    if (t.mm.pgd == 0) {
        const kp_count = task_kp_count(t);
        if (kp_count == @as(i32, @intCast(MAX_PAGE_COUNT))) return -1;
        const new_pgd = get_free_page();
        if (new_pgd == 0) return -1; // nothing registered yet — clean bail
        t.mm.pgd = new_pgd;
        t.mm.kernel_pages[@intCast(kp_count)] = new_pgd;
    }
    const pgd: u64 = t.mm.pgd;
    var new_table: i32 = 0;

    const pud = map_table(@ptrFromInt(paToKva(pgd)), PGD_SHIFT, uva, &new_table);
    if (pud == 0) {
        rollback_map_tables(t, kp0, pgd_was_fresh);
        return -1;
    }
    if (new_table != 0) {
        const kp_count = task_kp_count(t);
        if (kp_count == @as(i32, @intCast(MAX_PAGE_COUNT))) {
            free_page(pud);
            rollback_map_tables(t, kp0, pgd_was_fresh);
            return -1;
        }
        t.mm.kernel_pages[@intCast(kp_count)] = pud;
    }

    const pmd = map_table(@ptrFromInt(paToKva(pud)), PUD_SHIFT, uva, &new_table);
    if (pmd == 0) {
        rollback_map_tables(t, kp0, pgd_was_fresh);
        return -1;
    }
    if (new_table != 0) {
        const kp_count = task_kp_count(t);
        if (kp_count == @as(i32, @intCast(MAX_PAGE_COUNT))) {
            free_page(pmd);
            rollback_map_tables(t, kp0, pgd_was_fresh);
            return -1;
        }
        t.mm.kernel_pages[@intCast(kp_count)] = pmd;
    }

    const pte = map_table(@ptrFromInt(paToKva(pmd)), PMD_SHIFT, uva, &new_table);
    if (pte == 0) {
        rollback_map_tables(t, kp0, pgd_was_fresh);
        return -1;
    }
    if (new_table != 0) {
        const kp_count = task_kp_count(t);
        if (kp_count == @as(i32, @intCast(MAX_PAGE_COUNT))) {
            free_page(pte);
            rollback_map_tables(t, kp0, pgd_was_fresh);
            return -1;
        }
        t.mm.kernel_pages[@intCast(kp_count)] = pte;
    }

    map_table_entry(@ptrFromInt(paToKva(pte)), uva, phys_page, flags);

    const up_count = task_up_count(t);
    if (up_count == @as(i32, @intCast(MAX_PAGE_COUNT))) return -1;
    t.mm.user_pages[@intCast(up_count)] = .{ .pa = phys_page, .uva = uva, .flags = flags };
    return 0;
}

/// Allocate a fresh physical page and map it at `uva` in `task` with
/// permission `flags`. Returns the kernel-virtual address of the page
/// (linear map), or 0 on failure.
export fn allocate_user_page(t: *TaskStruct, uva: u64, flags: u64) u64 {
    const phys_page = get_free_page();
    if (phys_page == 0) return 0;
    if (map_page(t, uva, phys_page, flags) < 0) {
        // Map failed (OOM mid-walk or slot exhaustion); free the orphaned
        // user page so this call leaves the pool baseline-neutral.
        free_page(phys_page);
        return 0;
    }
    return paToKva(phys_page);
}

/// Clone current's user-mapped pages into `dst`. Per-page region
/// flags are stashed on `mm.user_pages` so fork preserves
/// per-region permissions (text RX, data/heap/stack RW+UXN).
///
/// `mm.brk` is inherited from the parent so a child that grew its
/// heap pre-fork keeps a coherent break. Page contents come via the
/// user_pages copy above; a post-grow, pre-touch page is not yet in
/// user_pages and demand-allocates on first touch in the child.
export fn copy_virt_memory(dst: *TaskStruct) i32 {
    var i: usize = 0;
    while (i < MAX_PAGE_COUNT) : (i += 1) {
        const up = current.?.mm.user_pages[i];
        if (up.pa == 0) continue;
        const kva = allocate_user_page(dst, up.uva, up.flags);
        if (kva == 0) return -1;
        _ = memcpy(@ptrFromInt(kva), @ptrFromInt(up.uva), PAGE_SIZE);
    }
    dst.mm.brk = current.?.mm.brk;
    return 0;
}

/// Walk pgd→pud→pmd→pte for `uva` without allocating intermediate
/// tables. Returns the PTE slot if all four levels are present, else
/// null. Used by unmap_user_range to clear stale entries on
/// brk-shrink: without clearing, a shrink-then-grow re-touches the
/// freed UVA, misses the demand-alloc fault (the PTE still holds the
/// recycled PA), and corrupts the page's new owner.
fn lookup_pte_slot(t: *TaskStruct, uva: u64) ?*u64 {
    if (t.mm.pgd == 0) return null;
    const pgd_table: [*]u64 = @ptrFromInt(paToKva(t.mm.pgd));
    const pgd_idx: u64 = (uva >> PGD_SHIFT) & (ENTRIES_PER_TABLE - 1);
    const pgd_entry = pgd_table[pgd_idx];
    if (pgd_entry == 0) return null;

    const pud_table: [*]u64 = @ptrFromInt(paToKva(pgd_entry & PAGE_MASK));
    const pud_idx: u64 = (uva >> PUD_SHIFT) & (ENTRIES_PER_TABLE - 1);
    const pud_entry = pud_table[pud_idx];
    if (pud_entry == 0) return null;

    const pmd_table: [*]u64 = @ptrFromInt(paToKva(pud_entry & PAGE_MASK));
    const pmd_idx: u64 = (uva >> PMD_SHIFT) & (ENTRIES_PER_TABLE - 1);
    const pmd_entry = pmd_table[pmd_idx];
    if (pmd_entry == 0) return null;

    const pte_table: [*]u64 = @ptrFromInt(paToKva(pmd_entry & PAGE_MASK));
    const pte_idx: u64 = (uva >> PAGE_SHIFT) & (ENTRIES_PER_TABLE - 1);
    return &pte_table[pte_idx];
}

/// Free every user page in [start_uva, end_uva): clear the PTE, free
/// the physical page, and zero the matching `mm.user_pages` slot so
/// the do_wait reap loop won't double-free. Page-table pages
/// (pud/pmd/pte) are not freed — they still map the surrounding
/// regions (stack, text), and `mm.kernel_pages` accounting is not
/// per-VA.
///
/// Precondition: caller issues a TLB flush before resuming user
/// execution (`set_pgd(t.mm.pgd)` suffices); otherwise stale TLB
/// entries keep translating the freed UVA to the recycled PA. Used by
/// sys_brk's shrink path.
export fn unmap_user_range(t: *TaskStruct, start_uva: u64, end_uva: u64) void {
    if (start_uva >= end_uva) return;
    var i: usize = 0;
    while (i < MAX_PAGE_COUNT) : (i += 1) {
        const up = t.mm.user_pages[i];
        if (up.pa == 0) continue;
        if (up.uva < start_uva or up.uva >= end_uva) continue;
        if (lookup_pte_slot(t, up.uva)) |pte_ref| {
            pte_ref.* = 0;
        }
        free_page(up.pa);
        t.mm.user_pages[i] = .{};
    }
}

/// Emit the `[KERN] OOM at 0x<hex>` marker and zombie the current task.
/// Used by the HARD fault path (do_data_abort) when a page allocation
/// fails: the fault context cannot be resumed, so it joins the existing
/// `stack overflow` / `text fault` / `invalid uva` marker family. Returns
/// -1 for the caller's signature; exit_process never returns, so the
/// return is unreachable in practice.
fn oom_zombie(far: u64) i32 {
    main_output(MU, "[KERN] OOM at 0x");
    main_output_u64(MU, far);
    main_output(MU, "\n");
    exit_process();
    return -1;
}

/// Page-fault handler for translation faults — dispatches by user VA
/// region. Accepts DFSC 0x4..0x7 (translation fault at
/// table levels 0..3) so a fault on a UVA whose PUD/PMD/PTE table is
/// missing resolves the same way as a level-3-only fault: map_page
/// allocates whatever intermediate tables are needed and stamps the
/// PTE.
///
/// Region dispatch (matches src/user_layout.zig):
///   * [HEAP_BASE, current.mm.brk) — legal heap, demand-allocate with
///     RW+UXN flags. The brk test is the canonical exerciser; sys_brk's
///     shrink path frees pages out of the same `mm.user_pages` slots
///     this fills.
///   * [STACK_LOW, STACK_TOP) — legal stack growth below the eagerly-
///     mapped top page; demand-allocate with RW+UXN flags.
///   * [STACK_GUARD_LOW, STACK_GUARD_HIGH) — stack overflow. Print
///     `[KERN] stack overflow at 0x<hex>` then zombie the offending
///     task via exit_process; the parent's sys_wait reaps as usual so
///     the harness keeps running. exit_process never returns, so the
///     `return -1` after it is unreachable.
///   * [TEXT_BASE, DATA_BASE) — text. ELF-loaded tasks have every
///     PT_LOAD page eagerly mapped, so a fault here is a jump into an
///     unmapped hole; print `[KERN] text fault at 0x<hex>` and zombie.
///   * everything else (data region, the 16 TiB heap-stack gap, any
///     kernel-half VA) — wild pointer. Print `[KERN] invalid uva at
///     0x<hex>` and zombie. The [TEST] wild-pointer scenario writes to
///     0xDEADBEEF000 to exercise this branch.
export fn do_data_abort(far: u64, esr: u64) i32 {
    const dfsc: u64 = esr & 0x3F;

    // Permission faults (DFSC 0xC..0xF) are a real EL0 protection
    // violation — e.g. a store to a read-only user page. User text is
    // RWX today (no read-only descriptor bit defined), so no EL0 store
    // can raise this branch yet; it is defense-in-depth, placed before
    // the translation-fault dispatch so a permission fault can never fall
    // through to the caller. Zombie the offending task like the text /
    // wild-pointer branches below so the harness keeps running. Falling
    // through to the caller's `-1` would route el0_da → handle_invalid_
    // entry → err_hang and spin the whole core on a single bad EL0 store.
    if (dfsc >= 0xC and dfsc <= 0xF) {
        main_output(MU, "[KERN] perm fault at 0x");
        main_output_u64(MU, far);
        main_output(MU, "\n");
        exit_process();
        return -1;
    }

    // Only translation faults (DFSC 0x4..0x7) get the region dispatch.
    if (dfsc < 0x4 or dfsc > 0x7) return -1;

    const fault_uva: u64 = far & PAGE_MASK;
    const rw_nx: u64 = user_layout.TD_USER_PAGE_FLAGS_DEFAULT | user_layout.TD_USER_XN;

    if (fault_uva >= user_layout.HEAP_BASE and fault_uva < current.?.mm.brk) {
        const page = get_free_page();
        if (page == 0) return oom_zombie(far);
        if (map_page(current.?, fault_uva, page, rw_nx) < 0) {
            free_page(page);
            return oom_zombie(far);
        }
        return 0;
    }

    if (fault_uva >= user_layout.STACK_LOW and fault_uva < user_layout.STACK_TOP) {
        const page = get_free_page();
        if (page == 0) return oom_zombie(far);
        if (map_page(current.?, fault_uva, page, rw_nx) < 0) {
            free_page(page);
            return oom_zombie(far);
        }
        return 0;
    }

    if (fault_uva >= user_layout.STACK_GUARD_LOW and fault_uva < user_layout.STACK_GUARD_HIGH) {
        main_output(MU, "[KERN] stack overflow at 0x");
        main_output_u64(MU, far);
        main_output(MU, "\n");
        exit_process();
        return -1;
    }

    if (fault_uva >= user_layout.TEXT_BASE and fault_uva < user_layout.DATA_BASE) {
        main_output(MU, "[KERN] text fault at 0x");
        main_output_u64(MU, far);
        main_output(MU, "\n");
        exit_process();
        return -1;
    }

    main_output(MU, "[KERN] invalid uva at 0x");
    main_output_u64(MU, far);
    main_output(MU, "\n");
    exit_process();
    return -1;
}

/// EL0 instruction abort (ESR EC 0x20) — the instruction-side twin of
/// do_data_abort, reached from entry.S `el0_ia`. An instruction fetch
/// faulted: a jump to a non-executable (UXN) data/heap/stack page or an
/// unmapped UVA — a corrupted function pointer or a smashed-stack return.
/// Unlike a data abort there is no demand-allocation case (every legal
/// text page is eagerly mapped by the ELF loader), so any faulting fetch
/// is a real crash. Print `[KERN] exec fault at 0x<hex>` and zombie the
/// task via exit_process so the harness keeps running, mirroring
/// do_data_abort's fault branches. exit_process never returns; the
/// `return -1` is unreachable (entry.S err_hangs if the fetch ever did
/// fall through). Before this routing existed, handle_sync_el0_64 matched
/// only SVC + data abort, so an EL0 instruction abort fell through to
/// handle_invalid_entry → err_hang and spun the whole core.
export fn do_instruction_abort(far: u64, esr: u64) i32 {
    _ = esr;
    main_output(MU, "[KERN] exec fault at 0x");
    main_output_u64(MU, far);
    main_output(MU, "\n");
    exit_process();
    return -1;
}

/// Catch-all for any EL0 synchronous exception that handle_sync_el0_64
/// does not route to SVC / data-abort / instruction-abort: an
/// "unknown reason" trap (ESR EC 0x00 — an undefined/unallocated
/// instruction), a PC- or SP-alignment fault (0x22 / 0x26), an FP/SIMD
/// trap, an illegal-execution-state exception, etc. Reached from
/// entry.S `el0_sync_other`. Before this routing, any such EC fell
/// through handle_sync_el0_64 to handle_invalid_entry → err_hang and
/// spun the whole core on a single bad EL0 instruction; now the
/// offending task is zombied via exit_process (the parent's sys_wait
/// reaps it) and the harness keeps running, mirroring
/// do_instruction_abort. The raw EC is printed so an unexpected fault
/// class stays diagnosable. exit_process never returns; the `return -1`
/// is unreachable (entry.S err_hangs if it ever did). `elr` is the
/// faulting EL0 PC, meaningful for every EC (unlike FAR, which is
/// UNKNOWN for several of them).
export fn do_el0_sync_fault(esr: u64, elr: u64) i32 {
    const ec: u64 = (esr >> 26) & 0x3F;
    main_output(MU, "[KERN] el0 sync fault ec=0x");
    main_output_u64(MU, ec);
    main_output(MU, " at 0x");
    main_output_u64(MU, elr);
    main_output(MU, "\n");
    exit_process();
    return -1;
}

/// Soft demand-allocate one user page at `fault_uva`. Returns 0 if the
/// UVA lies in a demand-alloc-able region (heap [HEAP_BASE, brk) or stack
/// [STACK_LOW, STACK_TOP)) and the page was mapped. Returns -1 otherwise
/// — wild UVA, stack guard, text fault, or allocation failure. Unlike
/// do_data_abort, there is no exit_process side-effect; the caller (a
/// syscall via copy_from_user / copy_to_user) gets to return -1 to user
/// without zombifying the task.
fn soft_demand_alloc(fault_uva: u64) i32 {
    const rw_nx: u64 = user_layout.TD_USER_PAGE_FLAGS_DEFAULT | user_layout.TD_USER_XN;

    if (fault_uva >= user_layout.HEAP_BASE and fault_uva < current.?.mm.brk) {
        const page = get_free_page();
        if (page == 0) return -1;
        if (map_page(current.?, fault_uva, page, rw_nx) < 0) {
            free_page(page);
            return -1;
        }
        return 0;
    }

    if (fault_uva >= user_layout.STACK_LOW and fault_uva < user_layout.STACK_TOP) {
        const page = get_free_page();
        if (page == 0) return -1;
        if (map_page(current.?, fault_uva, page, rw_nx) < 0) {
            free_page(page);
            return -1;
        }
        return 0;
    }

    return -1;
}

/// Walk [uva, uva+len) page by page and ensure each is mapped. Pages in
/// the legal heap/stack regions are demand-allocated; pages anywhere else
/// return -1. This is the SOFT path used by copy_from_user /
/// copy_to_user: a wild user pointer becomes a syscall -1, not an
/// exit_process. The HARD path (direct EL0 fault) stays in do_data_abort.
export fn check_and_prefault_user_range(uva: u64, len: u64) i32 {
    if (uva + len < uva) return -1;
    if (uva + len > user_layout.STACK_TOP) return -1;
    if (len == 0) return 0;

    var curr = uva & PAGE_MASK;
    const end = (uva + len - 1) & PAGE_MASK;

    while (curr <= end) {
        var is_mapped = false;
        var i: usize = 0;
        while (i < MAX_PAGE_COUNT) : (i += 1) {
            const up = current.?.mm.user_pages[i];
            if (up.pa != 0 and up.uva == curr) {
                is_mapped = true;
                break;
            }
        }
        if (!is_mapped) {
            if (soft_demand_alloc(curr) < 0) return -1;
        }
        if (curr == end) break;
        curr += PAGE_SIZE;
    }
    return 0;
}

/// Copy `len` bytes from user VA `uva` to kernel buffer `kbuf`.
/// Returns 0 on success, -1 on invalid UVA / fault.
export fn copy_from_user(kbuf: [*]u8, uva: u64, len: u64) i32 {
    if (check_and_prefault_user_range(uva, len) < 0) return -1;
    _ = memcpy(kbuf, @ptrFromInt(uva), len);
    return 0;
}

/// Copy `len` bytes from kernel buffer `kbuf` to user VA `uva`.
/// Returns 0 on success, -1 on invalid UVA / fault.
export fn copy_to_user(uva: u64, kbuf: [*]const u8, len: u64) i32 {
    if (check_and_prefault_user_range(uva, len) < 0) return -1;
    _ = memcpy(@ptrFromInt(uva), kbuf, len);
    return 0;
}

// ---- Host Tests ----
const std = @import("std");
const testing = std.testing;

extern fn reset_phys_mem() void;

test "mm_user: task_kp_count/task_up_count on empty task" {
    var t: TaskStruct = undefined;
    @memset(std.mem.asBytes(&t), 0);
    try testing.expectEqual(@as(i32, 0), task_kp_count(&t));
    try testing.expectEqual(@as(i32, 0), task_up_count(&t));
}

test "mm_user: map_page allocates tables" {
    reset_phys_mem();
    var t: TaskStruct = undefined;
    @memset(std.mem.asBytes(&t), 0);

    const uva: u64 = 0x1000;
    const pa: u64 = 0xDEAD0000;
    const flags: u64 = 0x7;

    const ret = map_page(&t, uva, pa, flags);
    try testing.expectEqual(@as(i32, 0), ret);

    // Should have allocated PGD, PUD, PMD, PTE
    try testing.expect(t.mm.pgd != 0);
    try testing.expectEqual(@as(i32, 4), task_kp_count(&t));
    try testing.expectEqual(@as(i32, 1), task_up_count(&t));
    try testing.expectEqual(pa, t.mm.user_pages[0].pa);
    try testing.expectEqual(uva, t.mm.user_pages[0].uva);
    try testing.expectEqual(flags, t.mm.user_pages[0].flags);
}

test "mm_user: lookup_pte_slot finds mapped page" {
    reset_phys_mem();
    var t: TaskStruct = undefined;
    @memset(std.mem.asBytes(&t), 0);

    const uva: u64 = 0x2000;
    const pa: u64 = 0xBEEF0000;
    _ = map_page(&t, uva, pa, 0x7);

    const pte_ptr = lookup_pte_slot(&t, uva);
    try testing.expect(pte_ptr != null);
    try testing.expectEqual(pa | 0x7, pte_ptr.?.*);

    const unmapped_uva: u64 = 0x3000;
    const pte_ptr_unmapped = lookup_pte_slot(&t, unmapped_uva);
    try testing.expect(pte_ptr_unmapped != null);
    try testing.expectEqual(@as(u64, 0), pte_ptr_unmapped.?.*);

    const far_uva: u64 = 0x1_000_000_000; // different PGD/PUD/PMD
    try testing.expect(lookup_pte_slot(&t, far_uva) == null);
}

test "mm_user: unmap_user_range clears entries" {
    reset_phys_mem();
    var t: TaskStruct = undefined;
    @memset(std.mem.asBytes(&t), 0);

    _ = map_page(&t, 0x1000, 0x10000, 0x7);
    _ = map_page(&t, 0x2000, 0x20000, 0x7);
    _ = map_page(&t, 0x3000, 0x30000, 0x7);

    unmap_user_range(&t, 0x1500, 0x2500);

    try testing.expectEqual(@as(u64, 0), t.mm.user_pages[1].pa);
    try testing.expect(t.mm.user_pages[0].pa != 0);
    try testing.expect(t.mm.user_pages[2].pa != 0);

    const pte_ptr = lookup_pte_slot(&t, 0x2000);
    try testing.expect(pte_ptr != null);
    try testing.expectEqual(@as(u64, 0), pte_ptr.?.*);
}

test "mm_user: do_data_abort maps heap" {
    reset_phys_mem();
    var t: TaskStruct = undefined;
    @memset(std.mem.asBytes(&t), 0);
    t.mm.brk = user_layout.HEAP_BASE + 0x2000;
    current = &t;

    const fault_uva = user_layout.HEAP_BASE + 0x1000;
    const esr = 0x92000004; // Translation fault, level 0

    const ret = do_data_abort(fault_uva, esr);
    try testing.expectEqual(@as(i32, 0), ret);
    try testing.expectEqual(@as(i32, 1), task_up_count(&t));
    try testing.expectEqual(fault_uva, t.mm.user_pages[0].uva);
}

test "mm_user: check_and_prefault_user_range maps range" {
    reset_phys_mem();
    var t: TaskStruct = undefined;
    @memset(std.mem.asBytes(&t), 0);
    t.mm.brk = user_layout.HEAP_BASE + 0x3000;
    current = &t;

    const ret = check_and_prefault_user_range(user_layout.HEAP_BASE + 0x500, 0x2000);
    try testing.expectEqual(@as(i32, 0), ret);
    // Should have mapped 3 pages (at +0, +0x1000, +0x2000 from base)
    // Wait, HEAP_BASE + 0x500 to HEAP_BASE + 0x2500.
    // Pages are at 0x500 & MASK (HEAP_BASE) and 0x1500 & MASK (HEAP_BASE + 0x1000)
    // and 0x2500 & MASK (HEAP_BASE + 0x2000).
    try testing.expectEqual(@as(i32, 3), task_up_count(&t));
}

// Soft path: wild UVA outside [HEAP_BASE, brk) and [STACK_LOW, STACK_TOP)
// must return -1 without invoking exit_process. The host stub at
// tests/host_stubs_mm_user.zig panics on exit_process, so a regression
// that drops back through do_data_abort would crash this test.
test "mm_user: check_and_prefault_user_range -1 on wild UVA (soft path)" {
    reset_phys_mem();
    var t: TaskStruct = undefined;
    @memset(std.mem.asBytes(&t), 0);
    t.mm.brk = user_layout.HEAP_BASE + 0x1000;
    current = &t;

    // 0xDEADBEEF000 sits in the 16 TiB heap-stack gap.
    const ret = check_and_prefault_user_range(0xDEADBEEF000, 1);
    try testing.expectEqual(@as(i32, -1), ret);
    // No pages mapped — soft path bails before any allocation.
    try testing.expectEqual(@as(i32, 0), task_up_count(&t));
}

// The fake pool in tests/host_stubs_mm_user.zig is 256 pages; get_free_page
// returns the 0 sentinel once drained. These tests drive map_page /
// allocate_user_page into that sentinel mid-walk and assert the OOM paths
// fail cleanly without mapping PA 0 and without leaking table bookkeeping.

test "mm_user: map_page rolls back tables and returns -1 on table OOM" {
    reset_phys_mem();
    // Drain the pool to a single free page: the fresh task's pgd alloc
    // takes it, then the pud-table alloc hits the sentinel mid-walk.
    var i: usize = 0;
    while (i < 255) : (i += 1) _ = get_free_page();

    var t: TaskStruct = undefined;
    @memset(std.mem.asBytes(&t), 0);

    const ret = map_page(&t, 0x1000, 0xDEAD0000, 0x7);
    try testing.expectEqual(@as(i32, -1), ret);
    // Rollback restored bookkeeping: no registered tables, pgd reset, no
    // user page recorded. Note: if map_table had written a `0 | flags`
    // descriptor and the walk continued, paToKva(0)==0 on host would
    // null-deref and crash this test — so reaching here also proves the
    // no-PA-0-map invariant.
    try testing.expectEqual(@as(i32, 0), task_kp_count(&t));
    try testing.expectEqual(@as(u64, 0), t.mm.pgd);
    try testing.expectEqual(@as(i32, 0), task_up_count(&t));
}

test "mm_user: map_page returns -1 when the pgd allocation OOMs" {
    reset_phys_mem();
    var i: usize = 0;
    while (i < 256) : (i += 1) _ = get_free_page();

    var t: TaskStruct = undefined;
    @memset(std.mem.asBytes(&t), 0);

    const ret = map_page(&t, 0x1000, 0xDEAD0000, 0x7);
    try testing.expectEqual(@as(i32, -1), ret);
    try testing.expectEqual(@as(u64, 0), t.mm.pgd);
    try testing.expectEqual(@as(i32, 0), task_kp_count(&t));
}

test "mm_user: allocate_user_page returns 0 on OOM" {
    reset_phys_mem();
    var i: usize = 0;
    while (i < 256) : (i += 1) _ = get_free_page();

    var t: TaskStruct = undefined;
    @memset(std.mem.asBytes(&t), 0);

    try testing.expectEqual(@as(u64, 0), allocate_user_page(&t, 0x1000, 0x7));
}

test "mm_user: soft demand-alloc returns -1 on OOM without exit_process" {
    reset_phys_mem();
    var t: TaskStruct = undefined;
    @memset(std.mem.asBytes(&t), 0);
    t.mm.brk = user_layout.HEAP_BASE + 0x2000;
    current = &t;

    // Drain the pool so the demand-alloc inside the soft path OOMs.
    var i: usize = 0;
    while (i < 256) : (i += 1) _ = get_free_page();

    // Heap UVA in [HEAP_BASE, brk): the soft path hits the sentinel and
    // must return -1 WITHOUT exit_process. The host stub panics on
    // exit_process, so a regression that drops to the hard path (or to
    // oom_zombie) would crash this test.
    const ret = check_and_prefault_user_range(user_layout.HEAP_BASE + 0x500, 1);
    try testing.expectEqual(@as(i32, -1), ret);
    try testing.expectEqual(@as(i32, 0), task_up_count(&t));
}
