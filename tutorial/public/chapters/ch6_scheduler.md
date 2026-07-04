# Chapter 6: Tasks & the Scheduler

Chapter 5 covered the console — bytes moving in and out of the system.
This chapter turns to something more central: how FlashOS represents a
running program at all, and how it decides which one gets the CPU next.

Every process on FlashOS is a `TaskStruct` (`src/task_layout.flash`). Among
its fields are `state`, `counter`, `priority`, and `pid`:

```flash
pub const TaskStruct = extern struct {
    core_context CoreContext = .{},
    state i64 = 0,
    counter i64 = 0,
    priority i64 = 1,
    preempt_count i64 = 0,
    flags u64 = 0,
    mm MmStruct = .{},
    // …
    parent ?*mut TaskStruct = null,
    pid i32 = 0,
    // …
}
```

*(excerpt — not standalone-compilable)*

`counter` and `priority` are the two fields the scheduler actually reads.
FlashOS uses a **priority round-robin** scheduler: it is not a fully
preemptive, multi-level design with dynamic priority classes — it is a
single flat pool of tasks, each carrying a "time slice remaining"
counter, picked and re-armed by two small, pure functions in
`src/sched.flash`.

## `pick_next_running`: highest counter wins

`pick_next_running` walks the task table and returns the index of the
`TASK_RUNNING` task with the largest `counter`:

```flash
/// Index of the RUNNING task with the highest `counter`, or null if no
/// task is RUNNING. Ties broken by lower index (strict `>` means the
/// first equal-counter slot wins). Pure: walks the slice as-is, no
/// mutation, no extern calls — host-testable.
pub fn pick_next_running(tasks []?*mut TaskStruct) ?usize {
    var best ?usize = null
    var best_c i64 = -1
    var i usize = 0
    while i < tasks.len {
        if tasks[i] |p| {
            if p.state == TASK_RUNNING && p.counter > best_c {
                best_c = p.counter
                best = i
            }
        }
        i += 1
    }
    return best
}
```

*(excerpt — not standalone-compilable)*

The comparison is a strict `>`, not `>=`, which is what makes ties
resolve to the *first* equal-counter slot rather than the last. There is
no extern call and no mutation anywhere in the function — it only reads
the slice it is handed — which is also why it is one of the two pieces
of the scheduler that are host-tested directly, without booting a
kernel.

## `refill_counters`: round-end decay

When the task `pick_next_running` selected has a `counter` of zero, the
round has ended and every task's counter is rewritten:

```flash
/// Refill every non-null task's counter to `(counter >> 1) + priority`.
/// Called when the highest-counter RUNNING task has counter == 0 (round-
/// end). `counter` is i64 — `>>` is arithmetic, so an over-decremented
/// counter halves toward zero without flipping sign.
pub fn refill_counters(tasks []?*mut TaskStruct) void {
    var i usize = 0
    while i < tasks.len {
        if tasks[i] |p| {
            p.counter = (p.counter >> 1) + p.priority
        }
        i += 1
    }
}
```

*(excerpt — not standalone-compilable)*

`(counter >> 1) + priority` is a decaying round-robin: a task's new
slice is half of whatever it had left, plus its fixed priority weight.
Because `counter` is declared `i64`, `>>` is an *arithmetic* shift — it
preserves sign. The doc comment calls this out deliberately: even a
counter that went slightly negative (an over-decrement edge case) halves
back toward zero rather than toward negative infinity, so the value
converges instead of drifting further away every round.

## `timer_tick`: the clock that drives it

`pick_next_running` and `refill_counters` are pure — something has to
actually call them on a schedule. That is `timer_tick`:

```flash
export fn timer_tick() void {
    const cur = current.?
    cur.counter -= 1
    if cur.counter > 0 || cur.preempt_count > 0 {
        return
    }
    cur.counter = 0
    irq_enable()
    _schedule()
    irq_disable()
}
```

*(excerpt — not standalone-compilable)*

Every tick decrements the current task's `counter`. If it is still
positive, or the task is inside a `preempt_disable` section, `timer_tick`
returns and nothing else happens. Once it reaches zero, the tick clamps
it there and calls `_schedule` — which internally loops
`pick_next_running` / `refill_counters` until it finds a runnable task
with a nonzero counter, then hands off via `switch_to`.

## Task states

A task's `state` field is one of three values FlashOS defines:

- `TASK_RUNNING` — eligible to be picked by `pick_next_running`.
- `TASK_INTERRUPTIBLE` — blocked (e.g. waiting on a `WaitQueue`, as in
  chapter 5's console reader), skipped by the picker until woken.
- `TASK_ZOMBIE` — exited, waiting for its parent to reap it.

## Context switch: where Flash hands off to assembly

Once `_schedule` has picked a target, `switch_to` does the bookkeeping
part of the handoff — updating the `current` pointer and programming the
new task's page table via `set_pgd` — then calls `core_switch_to`
(`arch/aarch64/sched.S`) to do the part that Flash cannot express at all:
swapping the callee-saved registers, frame pointer, stack pointer, and
link register out from under the currently executing function. That is
raw register manipulation with no notion of a call stack to return
through in the normal sense — `core_switch_to` saves the outgoing task's
registers, loads the incoming task's, and returns into whatever function
the incoming task was last suspended inside. It is one of the few places
in FlashOS that has to stay hand-written assembly rather than a
host-testable Flash function.

## Fork, exit, kill, exec

Four more operations round out task lifecycle management, all built on
top of the same `TaskStruct` and scheduler primitives above:

- **Fork.** `copy_process` allocates a kernel page for the new task,
  copies the parent's exception-frame registers, clones the user page
  table, and links the new task into the task table.
- **Exit / wait.** `exit_process` flips the current task to
  `TASK_ZOMBIE` and wakes a waiting parent; `do_wait` then reaps the
  zombie's user pages, kernel page, and task-table slot. That reap is
  exactly the free-page balance chapter 4 traced through the allocator —
  it is also the signal the in-kernel test harness checks for a leak,
  which chapter 13 covers in more depth.
- **Kill.** `sys_kill(pid)` finds the matching task by `pid` and zombifies
  it the same way exit does — except a task is not allowed to kill
  itself this way, since it is still occupying its own kernel page while
  running; `sys_exit` is the safe path for a task to end itself.
- **Exec.** `sys_execve(path, argv)` is the path-resolved ELF loader:
  once the target's ELF header validates, it tears down the caller's
  address space, installs a fresh page table, streams in the new
  program's segments, and lays out the argv block — all while preserving
  the task's `pid` across the rebuild. Chapter 8 covers what that loaded
  userland program actually looks like from the inside.

## What's next

The scheduler decides *which* task runs; chapter 7 covers *how* a
running userland task ever gets the kernel's attention in the first
place — the syscall boundary that every read, write, fork, and exec
above crosses to get from user code into the functions this chapter just
walked through.

## Lab: a toy round-robin task queue

This lab is a small, standalone cousin of `pick_next_running` and
`refill_counters`: a fixed array of tasks, a pick-the-highest-counter
function, and a refill function, run through a handful of scheduling
rounds. It uses a plain (non-`extern`) struct and a flat `+2` refill
rule rather than `TaskStruct`'s layout or the real `(counter >> 1) +
priority` decay — the point is the shape of the two decisions, not a
byte-for-byte mirror of the kernel type.

```flash
// scheduler_lab.flash - toy round-robin task queue, ch6 lab.
//
// A teaching-sized cousin of src/sched.flash's pick_next_running /
// refill_counters: a fixed array of tasks, each carrying a counter, and
// two pure helpers that mirror the real scheduler's shape without its
// TaskStruct layout, priority weighting, or extern linkage.

use flibc

link "flibc_start"
link "flibc_mem"

const NTASKS usize = 4
const ROUNDS usize = 8
const REFILL i32 = 2

pub const Task = struct {
    id u32,
    counter i32,
}

var tasks [NTASKS]Task = .{
    .{ .id = 0, .counter = 3 },
    .{ .id = 1, .counter = 1 },
    .{ .id = 2, .counter = 2 },
    .{ .id = 3, .counter = 0 },
}

// Index of the task with the highest counter; ties go to the first
// match — mirrors pick_next_running's strict `>` comparison.
fn pick_next(t []Task) usize {
    var best usize = 0
    var best_c i32 = t[0].counter
    var i usize = 1
    while i < NTASKS {
        if t[i].counter > best_c {
            best_c = t[i].counter
            best = i
        }
        i += 1
    }
    return best
}

// True once every task's counter has hit zero (round end).
fn all_zero(t []Task) bool {
    var i usize = 0
    while i < NTASKS {
        if t[i].counter != 0 {
            return false
        }
        i += 1
    }
    return true
}

// Give every task a fresh slice of counter — a flat refill in place of
// refill_counters' `(counter >> 1) + priority` decay.
fn refill(t []mut Task) void {
    var i usize = 0
    while i < NTASKS {
        t[i].counter = t[i].counter + REFILL
        i += 1
    }
}

export fn main(_ usize, _ argv) noreturn {
    var round usize = 0
    while round < ROUNDS {
        if all_zero(&tasks) {
            refill(&tasks)
        }
        const idx = pick_next(&tasks)
        flibc.printf("round %u: task %u ran (counter %d)\n", .{round, tasks[idx].id, tasks[idx].counter})
        tasks[idx].counter -= 1
        round += 1
    }
    flibc.exit()
}
```

> [!NOTE]
> Watch task 0 get picked three rounds in a row before another task
> overtakes it, then watch every counter bottom out at zero and jump
> back up together once `refill` runs — the same round-end refill
> moment `refill_counters` handles for the real scheduler, just with a
> flat `+2` instead of a priority-weighted decay.

Compile it with the button below and read the compiler's output: two plain
loops over a fixed array and a `printf` call per round, the same shape
`pick_next_running` and `refill_counters` have, minus the pointer-based
task table and the `i64` arithmetic shift.
