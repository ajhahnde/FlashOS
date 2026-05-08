// User-page mapping and page-table walk.
// Layouts come from src/task_layout.zig.

const layout = @import("task_layout.zig");
const TaskStruct = layout.TaskStruct;
const MAX_PAGE_COUNT = layout.MAX_PAGE_COUNT;

const PAGE_SHIFT: u6 = 12;
const TABLE_SHIFT: u6 = 9;
const PAGE_SIZE: u64 = 1 << PAGE_SHIFT;
const PAGE_MASK: u64 = 0xfffffffffffff000;
const PGD_SHIFT: u6 = PAGE_SHIFT + 3 * TABLE_SHIFT;
const PUD_SHIFT: u6 = PAGE_SHIFT + 2 * TABLE_SHIFT;
const PMD_SHIFT: u6 = PAGE_SHIFT + TABLE_SHIFT;
const ENTRIES_PER_TABLE: u64 = 512;

const LINEAR_MAP_BASE: u64 = 0xffff000000000000;

// MMU descriptor flags (user)
const TD_VALID: u64 = 1 << 0;
const TD_TABLE: u64 = 1 << 1;
const TD_PAGE: u64 = 1 << 1;
const TD_ACCESS: u64 = 1 << 10;
const TD_USER_PERMS: u64 = 1 << 6;
const TD_INNER_SHARABLE: u64 = 3 << 8;
const TD_USER_TABLE_FLAGS: u64 = TD_TABLE | TD_VALID;
const TD_USER_PAGE_FLAGS: u64 = TD_ACCESS | TD_INNER_SHARABLE | TD_USER_PERMS | TD_PAGE | TD_VALID;

fn paToKva(pa: u64) u64 {
    return pa + LINEAR_MAP_BASE;
}

extern fn get_free_page() u64;
extern fn free_page(p: u64) void;
extern fn memcpy(dst: [*]u64, src: [*]const u64, bytes: u64) void;
extern var current: *TaskStruct;

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

export fn map_table_entry(pte: [*]u64, uva: u64, phys_page: u64) void {
    var index: u64 = uva >> PAGE_SHIFT;
    index = index & (ENTRIES_PER_TABLE - 1);
    pte[index] = phys_page | TD_USER_PAGE_FLAGS;
}

/// Map `phys_page` to user-virtual `uva` in `task`, allocating PUD/PMD/PTE
/// pages as needed. Returns 0 on success, -1 if the task ran out of slots.
export fn map_page(t: *TaskStruct, uva: u64, phys_page: u64) i32 {
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

    map_table_entry(@ptrFromInt(paToKva(pte)), uva, phys_page);

    const up_count = task_up_count(t);
    if (up_count == @as(i32, @intCast(MAX_PAGE_COUNT))) return -1;
    t.mm.user_pages[@intCast(up_count)] = .{ .pa = phys_page, .uva = uva };
    return 0;
}

/// Allocate a fresh physical page and map it at `uva` in `task`.
/// Returns the kernel-virtual address of the page (linear map), or 0 on failure.
export fn allocate_user_page(t: *TaskStruct, uva: u64) u64 {
    const phys_page = get_free_page();
    if (map_page(t, uva, phys_page) < 0) return 0;
    return paToKva(phys_page);
}

/// Clone current's user-mapped pages into `dst`.
export fn copy_virt_memory(dst: *TaskStruct) i32 {
    const cnt = task_up_count(current);
    var i: i32 = 0;
    while (i < cnt) : (i += 1) {
        const idx: usize = @intCast(i);
        const uva = current.mm.user_pages[idx].uva;
        const kva = allocate_user_page(dst, uva);
        if (kva == 0) return -1;
        memcpy(@ptrFromInt(kva), @ptrFromInt(uva), PAGE_SIZE);
    }
    return 0;
}

/// Page-fault handler for level-3 translation faults — demand-allocates a page.
export fn do_data_abort(far: u64, esr: u64) i32 {
    const dfsc: u64 = esr & 0x3f;
    if (dfsc == 0x7) {
        const page = get_free_page();
        if (map_page(current, far & PAGE_MASK, page) < 0) return -1;
        return 0;
    }
    return -1;
}
