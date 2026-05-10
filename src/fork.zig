// Process creation — fork() / move-to-user setup.
// Layouts (TaskStruct, KeRegs, ...) come from src/task_layout.zig.

const layout = @import("task_layout.zig");
const TaskStruct = layout.TaskStruct;
const CoreContext = layout.CoreContext;
const KeRegs = layout.KeRegs;
const TASK_RUNNING = layout.TASK_RUNNING;
const KTHREAD = layout.KTHREAD;
const MAX_PAGE_COUNT = layout.MAX_PAGE_COUNT;

// User VA layout + default permission bag. The blob path stamps the
// historical combined-permission flags; the ELF loader chooses per-
// region flags here.
const user_layout = @import("user_layout");

// ELF parser — same module the host tests cover (src/elf.zig). Keeping
// it as a sibling @import (instead of a named module) means the host
// test build keeps working without extra wiring; the kernel build pulls
// in only the symbols prepare_move_to_user_elf actually references.
const elf = @import("elf.zig");

const NR_TASKS: usize = 64;
const PAGE_SIZE: u64 = 1 << 12;
const THREAD_SIZE: u64 = PAGE_SIZE;
const USER_SP_INIT_POS: u64 = 2 * PAGE_SIZE;
const SPSR_EL1_MODE_EL0t: u64 = 0;
const MU: i32 = 0;

// Kernel-thread PCs must run via TTBR1 (high-mem linear map). Otherwise
// the moment a process does set_pgd() to a user pgd, TTBR0 stops mapping
// the kernel's low-VA copy and the next ret/blr to a kernel function
// faults. ORing instead of adding is idempotent if the address is
// already high.
const LINEAR_MAP_BASE: u64 = 0xffff000000000000;

extern fn get_kernel_page() u64;
extern fn free_kernel_page(kp: u64) void;
extern fn allocate_user_page(task: *TaskStruct, uva: u64, flags: u64) u64;
extern fn copy_virt_memory(dst: *TaskStruct) i32;
extern fn memzero(start: u64, size: u64) void;
extern fn memcpy(dst: [*]u64, src: [*]const u64, bytes: u64) void;
extern fn copy_ke_regs(to: *KeRegs, from: *KeRegs) void;
extern fn set_pgd(pgd: u64) void;
extern fn preempt_disable() void;
extern fn preempt_enable() void;
extern fn ret_from_fork() void;
extern fn main_output(interface: i32, str: [*:0]const u8) void;
extern fn main_output_u64(interface: i32, in: u64) void;
extern fn main_output_char(interface: i32, ch: u8) void;

extern var current: *TaskStruct;
extern var task: [NR_TASKS]?*TaskStruct;
extern var nr_tasks: i32;
extern var next_pid: i32;

export fn task_ke_regs(tsk: *TaskStruct) *KeRegs {
    const p: u64 = @intFromPtr(tsk) + THREAD_SIZE - @sizeOf(KeRegs);
    return @ptrFromInt(p);
}

export fn copy_process_impl(clone_flags: u64, fn_addr: u64, arg: u64) i32 {
    preempt_disable();

    const p: *TaskStruct = @ptrFromInt(get_kernel_page());

    const childregs = task_ke_regs(p);
    memzero(@intFromPtr(childregs), @sizeOf(KeRegs));
    memzero(@intFromPtr(&p.core_context), @sizeOf(CoreContext));

    if ((clone_flags & KTHREAD) != 0) {
        p.core_context.x19 = fn_addr | LINEAR_MAP_BASE;
        p.core_context.x20 = arg;
    } else {
        const cur_regs = task_ke_regs(current);
        // copy_ke_regs avoids gcc emitting a memcpy call
        copy_ke_regs(childregs, cur_regs);
        // child returns 0 from fork
        childregs.regs[0] = 0;
        if (copy_virt_memory(p) != 0) {
            free_kernel_page(@intFromPtr(p));
            return -1;
        }
    }

    p.flags = clone_flags;
    p.priority = current.priority;
    p.state = TASK_RUNNING;
    // Halved so a freshly forked child doesn't out-budget a parent that has
    // already burned ticks; gives the round-robin path a chance to interleave
    // parent/child during fork-stress instead of running parent in a tight
    // burst.
    p.counter = @divTrunc(p.priority, 2);
    p.preempt_count = 1;
    p.parent = current;

    p.core_context.lr = @intFromPtr(&ret_from_fork) | LINEAR_MAP_BASE;
    p.core_context.sp = @intFromPtr(childregs);

    // First-null-slot scan instead of monotonic nr_tasks bump so that slots
    // freed by do_wait get reused; otherwise long fork-stress runs hit
    // NR_TASKS=64 well before allocator pressure. nr_tasks is kept as a
    // high-water mark only.
    var slot: i32 = -1;
    var i: usize = 0;
    while (i < NR_TASKS) : (i += 1) {
        if (task[i] == null) {
            slot = @intCast(i);
            break;
        }
    }
    if (slot < 0) {
        free_kernel_page(@intFromPtr(p));
        preempt_enable();
        return -1;
    }
    // Pid is monotonic (next_pid++), independent of the reusable slot index.
    p.pid = next_pid;
    next_pid += 1;
    task[@intCast(slot)] = p;
    if (slot + 1 > nr_tasks) nr_tasks = slot + 1;

    main_output(MU, "created pid ");
    if (p.pid < 10) {
        main_output_char(MU, @intCast('0' + p.pid));
    } else {
        main_output_char(MU, @intCast('0' + @divTrunc(p.pid, 10)));
        main_output_char(MU, @intCast('0' + @mod(p.pid, 10)));
    }
    main_output(MU, " at ");
    main_output_u64(MU, @intFromPtr(p));
    main_output(MU, "\n");

    preempt_enable();
    return p.pid;
}

export fn prepare_move_to_user(start_addr: u64, size: u64, fn_addr: u64) i32 {
    const regs = task_ke_regs(current);
    memzero(@intFromPtr(regs), @sizeOf(KeRegs));
    regs.elr = fn_addr;
    regs.pstate = SPSR_EL1_MODE_EL0t;
    regs.sp = USER_SP_INIT_POS;

    const code_page = allocate_user_page(current, 0, user_layout.TD_USER_PAGE_FLAGS_DEFAULT);
    if (code_page == 0) return -1;

    memcpy(@ptrFromInt(code_page), @ptrFromInt(start_addr), size);
    // Heap starts empty at HEAP_BASE for blob-loaded tasks too — keeps
    // sys_brk's bounds check uniform across the blob and ELF paths so
    // children forked from the (blob-loaded) PID 1 can also exercise
    // brk/sbrk in [HEAP_BASE, …).
    current.mm.brk = user_layout.HEAP_BASE;
    set_pgd(current.mm.pgd);
    return 0;
}

// ELF path counterpart of prepare_move_to_user. Caller (sys_exec) has
// already snapshotted the ELF bytes into a kernel-owned page at
// `blob_addr_kva`, freed the old user pages, and zeroed `current.mm.pgd`.
// Walks PT_LOAD segments via src/elf.zig, allocates fresh user pages
// per segment with region-aware flags (text=R-X, data/heap/stack=RW-NX),
// memcpys file-backed bytes from the blob, eagerly maps one stack page
// at the top of the user VA, then sets ELR=e_entry / SP=STACK_TOP and
// installs the new pgd. Returns 0 on success, -1 on parse failure /
// alloc failure / non-page-aligned p_vaddr / inconsistent memsz<filesz.
//
// Per-page memcpy uses the kernel-virtual alias of the freshly mapped
// page (returned by allocate_user_page) so the copy works while TTBR0
// still holds the old (now freed) pgd — set_pgd is the last thing
// before return, mirroring the blob path.
export fn prepare_move_to_user_elf(blob_addr_kva: u64, blob_size: u64) i32 {
    const blob: []const u8 = @as([*]const u8, @ptrFromInt(blob_addr_kva))[0..blob_size];
    const ehdr = elf.parseEhdr(blob) catch return -1;

    var it = elf.iteratePhdrs(blob, ehdr);
    while (true) {
        const ph_opt = it.next() catch return -1;
        const ph = ph_opt orelse break;
        if (ph.p_type != elf.PT_LOAD) continue;

        // Sanity: page-aligned vaddr and memsz >= filesz. Mis-aligned
        // segments would force partial-page memcpys that break the
        // page-grain free-page accounting; reject and document.
        if ((ph.p_vaddr & (PAGE_SIZE - 1)) != 0) return -1;
        if (ph.p_memsz < ph.p_filesz) return -1;
        if (ph.p_memsz == 0) continue;

        const flags: u64 = if ((ph.p_flags & elf.PF_X) != 0)
            user_layout.TD_USER_PAGE_FLAGS_DEFAULT
        else
            user_layout.TD_USER_PAGE_FLAGS_DEFAULT | user_layout.TD_USER_XN;

        const num_pages: u64 = (ph.p_memsz + PAGE_SIZE - 1) / PAGE_SIZE;
        var i: u64 = 0;
        while (i < num_pages) : (i += 1) {
            const uva = ph.p_vaddr + i * PAGE_SIZE;
            const kva = allocate_user_page(current, uva, flags);
            if (kva == 0) return -1;

            const seg_off: u64 = i * PAGE_SIZE;
            if (seg_off < ph.p_filesz) {
                const remaining: u64 = ph.p_filesz - seg_off;
                const copy_bytes: u64 = if (remaining > PAGE_SIZE) PAGE_SIZE else remaining;
                // Byte-granular copy: utilc.memcpy is `[*]u64`-typed and
                // rounds the size down to a multiple of 8, which silently
                // truncates trailing bytes for any segment whose
                // p_filesz isn't 8-aligned (e.g. hello.elf at 0x1f).
                const dst_b: [*]u8 = @ptrFromInt(kva);
                const src_b: [*]const u8 = @ptrFromInt(blob_addr_kva + ph.p_offset + seg_off);
                var bi: u64 = 0;
                while (bi < copy_bytes) : (bi += 1) dst_b[bi] = src_b[bi];
            }
            // Trailing memsz-filesz BSS bytes are implicitly zero
            // because get_free_page returns zeroed pages.
        }
    }

    // Eagerly map the top stack page so EL0 entry doesn't fault before
    // the first instruction. Lazy stack growth + guard-page handling
    // arrives in 2.5 / 2.6.
    const stack_uva: u64 = user_layout.STACK_TOP - PAGE_SIZE;
    const stack_kva = allocate_user_page(
        current,
        stack_uva,
        user_layout.TD_USER_PAGE_FLAGS_DEFAULT | user_layout.TD_USER_XN,
    );
    if (stack_kva == 0) return -1;

    const regs = task_ke_regs(current);
    memzero(@intFromPtr(regs), @sizeOf(KeRegs));
    regs.elr = ehdr.e_entry;
    regs.pstate = SPSR_EL1_MODE_EL0t;
    regs.sp = user_layout.STACK_TOP;

    // Heap starts empty at HEAP_BASE — sys_brk grows / shrinks from
    // here, do_data_abort demand-allocates pages as the heap is touched.
    current.mm.brk = user_layout.HEAP_BASE;

    set_pgd(current.mm.pgd);
    return 0;
}
