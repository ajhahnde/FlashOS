# 6. Scheduler and Process Lifecycle

`crates/kernel/src/process/sched.rs` owns a fixed table of 64 task pointers. The
scheduler is uniprocessor, preemptive, and priority-weighted.

## Counters and priorities

A runnable task spends a counter while it executes. When no runnable task has
time left, a new round derives counters from task priorities. The generic timer
drives preemption; `arch/aarch64/sched.S` performs the architecture-specific
context switch.

The split is deliberate:

- Rust decides task state, counters, priority, ownership, and the next task;
- assembly swaps callee-saved registers, SP, FP, LR, and the translation base.

Assembly-visible offsets are generated from `crates/kernel-abi/`, so the switch code
does not maintain a handwritten mirror of `TaskStruct`.

## The lifecycle

```text
fork → runnable child → scheduled → exit/kill → zombie → parent wait → free
```

`fork` allocates a task page and separate kernel stack, clones the user address
space, inherits credentials, CWD, and descriptors, and only then publishes the
child. If an intermediate step fails, rollback releases everything allocated so
far.

`exit` marks the current process as a zombie and wakes its parent. `wait`
blocks until a child is reapable, then closes descriptors and frees user pages,
page tables, kernel stack, and task page. `kill` applies the same terminal state
to another process; a process exits itself through `exit`.

## Why zombies exist

A task cannot free the kernel stack on which it is currently executing. The
zombie state also preserves the exit relationship long enough for the parent
to observe and reap it. Cleanup therefore belongs to the waiter, not to the
dying task.

## `execve` is not a new process

`crates/kernel/src/process/execve.rs` resolves an ELF through the VFS, copies the image
and arguments into bounded kernel scratch space, creates a fresh address space,
and enters at the ELF entry point. PID, credentials, CWD, and open descriptors
survive.

The old address space is replaced only after validation and staging. Once the
replacement crosses its point of no return, an OOM kills the task cleanly
instead of restoring a half-discarded image.

## Runtime evidence

The 30-scenario boot harness stresses fork/reap balance, graceful OOM, kill,
heap growth, stack overflow, wild pointers, ELF faults, and invalid syscall
pointers. Each scenario checks the physical free-page baseline after cleanup.

> [!NOTE]
> FlashOS is not SMP yet. IRQ-safe locking, wait-queue semantics, signals, and
> per-CPU state must be hardened before secondary cores become runnable.

Next, we cross from EL0 into the syscall table.
