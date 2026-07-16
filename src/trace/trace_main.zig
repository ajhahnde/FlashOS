// Dynamic kernel tracing — patches `bl` to `hook` into `mov x9, lr` slots
// at the entry of every function compiled with -fpatchable-function-entry=2.
// Zig has no equivalent flag yet, so the patchable-function-entries section
// is currently empty and trace_init is effectively a no-op at runtime; the
// machinery stays compiled so it lights up the moment entries appear.

const PL: i32 = 1;

const MOV_X9_LR: u32 = 0xAA1E03E9;
const BL_OP: u32 = 0x94000000;
const BL_MASK: u32 = 0x03FFFFFF;

extern fn trace_output(interface: i32, str: [*:0]const u8) void;
extern fn trace_output_u64(interface: i32, in: u64) void;
extern fn trace_output_insn(interface: i32, addr: u64) void;
extern fn ksym_name_from_addr(addr: u64) ?[*:0]const u8;

extern var __start_patchable_functions: u64;
extern var __stop_patchable_functions: u64;
extern var hook: u64;

// Kernel high-mapping base. Same constant as the syscall and process-loader
// modules.
// trace_relocate ORs this into each link-time low-VA entry to obtain the
// runtime kernel-virtual alias the patch path needs.
const LINEAR_MAP_BASE: u64 = 0xFFFF000000000000;

/// Endless loop demonstrating the tracing functionality.
export fn do_trace() noreturn {
    var k: u32 = 0;
    while (true) {
        trace_output(PL, "TRACE..\n");
        var i: u32 = 0;
        while (i < 1_000_000) : (i += 1) {
            k +%= 1;
        }
    }
}

/// Stub: ideally sends IPIs to spin all cores during code patching.
export fn gather_cores() void {}

/// Stub: releases gathered cores.
export fn put_back_cores() void {}

/// Instruction-count offset from `addr` to `hook`. Signed; assumes |offset| < 2^26.
export fn trace_calculate_offset(addr: u64) i32 {
    const hook_addr: i64 = @bitCast(@intFromPtr(&hook));
    const here: i64 = @bitCast(addr);
    const diff: i64 = @divTrunc(hook_addr - here, 4);
    return @truncate(diff);
}

/// Generates a `bl <offset>` instruction word.
export fn trace_generate_bl(offset_in: i32) u32 {
    const offset_u: u32 = @bitCast(offset_in);
    const insn: u32 = BL_OP | (offset_u & BL_MASK);
    trace_output(PL, "generated: ");
    trace_output_u64(PL, insn);
    trace_output(PL, "\n");
    return insn;
}

/// Writes a 32-bit instruction word at `addr` and forces I-/D-cache
/// coherency for self-modifying code on AArch64. The dc cvau /
/// ic ivau / isb sequence is required: without it the freshly
/// written bytes stay invisible to the instruction-fetch path and
/// the patched slot keeps reading as a NOP. Recipe from the ARMv8
/// reference (B2.2.5, "Self-modifying code"). dsb ish completes the
/// data-side push to PoU before ic ivau / isb starts the
/// instruction-side flush.
export fn trace_modify_code(addr: u64, insn: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = insn;
    asm volatile (
        \\dc cvau, %[a]
        \\dsb ish
        \\ic ivau, %[a]
        \\dsb ish
        \\isb
        :
        : [a] "r" (addr),
        : .{ .memory = true });
}

/// Promotes each link-time low-VA entry to its kernel-virtual high alias.
export fn trace_relocate(start: [*]u64, end: [*]u64) void {
    const count: usize = (@intFromPtr(end) - @intFromPtr(start)) / @sizeOf(u64);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        start[i] |= LINEAR_MAP_BASE;
    }
}

/// Replaces the first nop of every patchable entry with `mov x9, lr`.
export fn trace_setup_movx9lr(start: [*]u64, end: [*]u64) void {
    const count: usize = (@intFromPtr(end) - @intFromPtr(start)) / @sizeOf(u64);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        trace_modify_code(start[i], MOV_X9_LR);
        trace_output_insn(PL, start[i]);
    }
}

/// Injects `bl hook` at the second nop of every patchable entry.
export fn trace_enable(start: [*]u64, end: [*]u64) void {
    const count: usize = (@intFromPtr(end) - @intFromPtr(start)) / @sizeOf(u64);
    gather_cores();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const slot: u64 = start[i] + 4;
        const offset: i32 = trace_calculate_offset(slot);
        const insn: u32 = trace_generate_bl(offset);
        trace_modify_code(slot, insn);
        trace_output_insn(PL, slot);
    }
    put_back_cores();
}

/// Initializes dynamic tracing: relocate the address table and patch entries.
export fn trace_init() void {
    const start: [*]u64 = @ptrCast(&__start_patchable_functions);
    const end: [*]u64 = @ptrCast(&__stop_patchable_functions);
    trace_relocate(start, end);
    trace_setup_movx9lr(start, end);
    trace_output(PL, "modified mov x9, lr\n");
    trace_enable(start, end);
}

/// Called from hook.S after a patched `bl hook` — looks up and prints the symbol.
export fn traced(real_func_entry: u64) void {
    const name = ksym_name_from_addr(real_func_entry - 8);
    if (name) |n| {
        trace_output(PL, n);
    } else {
        trace_output(PL, "NOT FOUND!\n");
    }
    trace_output(PL, "\n");
}
