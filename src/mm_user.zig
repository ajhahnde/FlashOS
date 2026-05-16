// User-page mapping and page-table walk.
// Layouts come from src/task_layout.zig.

const layout = @import("task_layout");
const TaskStruct = layout.TaskStruct;
const MAX_PAGE_COUNT = layout.MAX_PAGE_COUNT;

// User VA regions + per-region permission bags. The ELF loader
// (prepare_move_to_user_elf) chooses flags per PT_LOAD region.
const user_layout = @import("user_layout");

const PAGE_SHIFT: u6 = 12;
const TABLE_SHIFT: u6 = 9;
const PAGE_SIZE: u64 = 1 << PAGE_SHIFT;
const PAGE_MASK: u64 = 0xfffffffffffff000;
const PGD_SHIFT: u6 = PAGE_SHIFT + 3 * TABLE_SHIFT;
const PUD_SHIFT: u6 = PAGE_SHIFT + 2 * TABLE_SHIFT;
const PMD_SHIFT: u6 = PAGE_SHIFT + TABLE_SHIFT;
const ENTRIES_PER_TABLE: u64 = 512;

const LINEAR_MAP_BASE: u64 = 0xffff000000000000;

// MMU descriptor flags (user). Page-table internals only — the
// per-leaf permission bag now lives in src/user_layout.zig
// (TD_USER_PAGE_FLAGS_DEFAULT) so the future loader and the existing
// blob path can share it.
const TD_VALID: u64 = 1 << 0;
const TD_TABLE: u64 = 1 << 1;
const TD_USER_TABLE_FLAGS: u64 = TD_TABLE | TD_VALID;

fn paToKva(pa: u64) u64 {
    return pa + LINEAR_MAP_BASE;
}

extern fn get_free_page() u64;
extern fn free_page(p: u64) void;
extern fn memcpy(dst: [*]u64, src: [*]const u64, bytes: u64) void;
extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn main_output_u64(interface: i32, in: u64) void;
extern fn exit_process() void;
extern var current: *TaskStruct;

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
        new_table.* = 1;
        const next_level: u64 = get_free_page();
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

/// Map `phys_page` to user-virtual `uva` in `task` with permission `flags`,
/// allocating PUD/PMD/PTE pages as needed. Returns 0 on success, -1 if the
/// task ran out of slots. Pass `user_layout.TD_USER_PAGE_FLAGS_DEFAULT` for
/// the historical combined-permission bag; the ELF loader will choose
/// per-region values (text vs data/heap/stack).
export fn map_page(t: *TaskStruct, uva: u64, phys_page: u64, flags: u64) i32 {
    if (t.mm.pgd == 0) {
        const kp_count = task_kp_count(t);
        if (kp_count == @as(i32, @intCast(MAX_PAGE_COUNT))) return -1;
        t.mm.pgd = get_free_page();
        t.mm.kernel_pages[@intCast(kp_count)] = t.mm.pgd;
    }
    const pgd: u64 = t.mm.pgd;
    var new_table: i32 = 0;

    const pud = map_table(@ptrFromInt(paToKva(pgd)), PGD_SHIFT, uva, &new_table);
    if (new_table != 0) {
        const kp_count = task_kp_count(t);
        if (kp_count == @as(i32, @intCast(MAX_PAGE_COUNT))) {
            free_page(pud);
            return -1;
        }
        t.mm.kernel_pages[@intCast(kp_count)] = pud;
    }

    const pmd = map_table(@ptrFromInt(paToKva(pud)), PUD_SHIFT, uva, &new_table);
    if (new_table != 0) {
        const kp_count = task_kp_count(t);
        if (kp_count == @as(i32, @intCast(MAX_PAGE_COUNT))) {
            free_page(pmd);
            return -1;
        }
        t.mm.kernel_pages[@intCast(kp_count)] = pmd;
    }

    const pte = map_table(@ptrFromInt(paToKva(pmd)), PMD_SHIFT, uva, &new_table);
    if (new_table != 0) {
        const kp_count = task_kp_count(t);
        if (kp_count == @as(i32, @intCast(MAX_PAGE_COUNT))) {
            free_page(pte);
            return -1;
        }
        t.mm.kernel_pages[@intCast(kp_count)] = pte;
    }

    map_table_entry(@ptrFromInt(paToKva(pte)), uva, phys_page, flags);

    const up_count = task_up_count(t);
    if (up_count == @as(i32, @intCast(MAX_PAGE_COUNT))) return -1;
    t.mm.user_pages[@intCast(up_count)] = .{ .pa = phys_page, .uva = uva };
    return 0;
}

/// Allocate a fresh physical page and map it at `uva` in `task` with
/// permission `flags`. Returns the kernel-virtual address of the page
/// (linear map), or 0 on failure.
export fn allocate_user_page(t: *TaskStruct, uva: u64, flags: u64) u64 {
    const phys_page = get_free_page();
    if (map_page(t, uva, phys_page, flags) < 0) return 0;
    return paToKva(phys_page);
}

/// Clone current's user-mapped pages into `dst`. Per-page region flags
/// are not tracked on `mm.user_pages`, so every clone gets the default
/// bag — adequate today because the only consumer of fork is the test
/// harness's own scenarios, which fork before exec'ing the ELF demos
/// (the child inherits the blob image briefly, then exec replaces it
/// with per-region-flagged ELF mappings).
///
// TODO: add a per-page flag column on `mm.user_pages` so fork preserves
// per-region permissions (text RX, data/heap/stack RW+UXN). Required
// once a scenario fork's a process with already-RX text pages without
// immediately exec'ing — until then the default-bag clone is fine.
///
/// The heap break (`mm.brk`) is inherited from the parent so a child
/// that grew its heap pre-fork keeps a coherent break value — sys_brk
/// in the child sees the same upper bound the parent had. The actual
/// page contents come over via the user_pages copy above; an unwritten
/// (post-grow, pre-touch) page in the parent simply isn't in
/// user_pages yet and will demand-alloc on first touch in the child.
export fn copy_virt_memory(dst: *TaskStruct) i32 {
    const cnt = task_up_count(current);
    var i: i32 = 0;
    while (i < cnt) : (i += 1) {
        const idx: usize = @intCast(i);
        const uva = current.mm.user_pages[idx].uva;
        const kva = allocate_user_page(dst, uva, user_layout.TD_USER_PAGE_FLAGS_DEFAULT);
        if (kva == 0) return -1;
        memcpy(@ptrFromInt(kva), @ptrFromInt(uva), PAGE_SIZE);
    }
    dst.mm.brk = current.mm.brk;
    return 0;
}

/// Walk pgd→pud→pmd→pte for `uva` without allocating intermediate
/// tables. Returns a pointer to the PTE slot if all four levels are
/// present (so the caller can read or zero it), or null if any level
/// is missing. Used by unmap_user_range to clear stale entries on
/// brk-shrink — without this clearing, a shrink-then-grow inside the
/// same process would re-touch the freed UVA, miss the demand-alloc
/// fault path because the PTE still holds the (recycled) PA, and
/// silently scribble onto whoever owns that page now.
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

/// Free every user page mapped in [start_uva, end_uva): clears the PTE,
/// frees the physical page, and zeroes the matching `mm.user_pages`
/// slot so the do_wait reap loop won't double-free. Page-table pages
/// (pud/pmd/pte) are NOT freed — they keep mapping the surrounding
/// regions (stack, text), and the slot accounting in
/// `mm.kernel_pages` doesn't track per-VA ownership.
///
/// Caller MUST issue a TLB flush before resuming user execution
/// (`set_pgd(t.mm.pgd)` is the existing big-hammer); otherwise stale
/// TLB entries continue to translate the freed UVA to the (now
/// recycled) PA. Used by sys_brk's shrink path.
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
    const dfsc: u64 = esr & 0x3f;
    if (dfsc < 0x4 or dfsc > 0x7) return -1;

    const fault_uva: u64 = far & PAGE_MASK;
    const rw_nx: u64 = user_layout.TD_USER_PAGE_FLAGS_DEFAULT | user_layout.TD_USER_XN;

    if (fault_uva >= user_layout.HEAP_BASE and fault_uva < current.mm.brk) {
        const page = get_free_page();
        if (map_page(current, fault_uva, page, rw_nx) < 0) return -1;
        return 0;
    }

    if (fault_uva >= user_layout.STACK_LOW and fault_uva < user_layout.STACK_TOP) {
        const page = get_free_page();
        if (map_page(current, fault_uva, page, rw_nx) < 0) return -1;
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
