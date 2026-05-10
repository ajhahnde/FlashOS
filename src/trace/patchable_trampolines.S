/*
 * Naked trampolines for hand-rolled patchable-function-entry tracing.
 *
 * Zig has no -fpatchable-function-entry, so we synthesise the two-NOP
 * prologue the trace pipeline expects in hand-written assembly. Each
 * traced function's canonical name lives on the trampoline; the real
 * implementation is renamed to <name>_impl. Callers see no change.
 *
 * Layout per entry:
 *     name:    nop              ; slot 0 -> patched to `mov x9, lr`
 *              nop              ; slot 1 -> patched to `bl hook`
 *              b name_impl      ; tail call, LR untouched
 *
 * trace_init walks __patchable_function_entries (bracketed by
 * __start/__stop_patchable_functions in linker.ld), patches both
 * slots, and the next entry into `name` is what fires the hook.
 */

.macro patchable_trampoline name, impl
.globl \name
.type \name, %function
\name:
    nop
    nop
    b \impl
.size \name, . - \name
.endm

patchable_trampoline kernel_main,  kernel_main_impl
patchable_trampoline _schedule,    _schedule_impl
patchable_trampoline do_wait,      do_wait_impl
patchable_trampoline copy_process, copy_process_impl

/*
 * Pointer table consumed by trace_init. linker.ld brackets
 * `__patchable_function_entries` with __start/__stop_patchable_functions.
 *
 * Each entry is the trampoline's absolute link-time VA (low-half,
 * because the kernel ELF is linked at PA 0x80000 / 0x40080000).
 * trace_relocate ORs LINEAR_MAP_BASE (0xffff_0000_0000_0000) into each
 * entry to obtain the kernel-virtual high alias the patch path uses.
 * `.quad kernel_main` is a single R_AARCH64_ABS64 the linker resolves
 * — clang's integrated assembler rejects the (function - _start)
 * subtraction-of-two-extern-symbols form, hence the OR-based design.
 */
.section __patchable_function_entries, "a"
.balign 8
.quad kernel_main
.quad _schedule
.quad do_wait
.quad copy_process
.previous
