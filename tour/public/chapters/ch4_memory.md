# 4. Memory: Pages, Address Spaces, and Faults

FlashOS uses 4 KiB pages and AArch64's four-level translation tables. The boot
code creates an early identity map and a linear kernel mapping beginning at
`0xffff000000000000`.

## Physical-page allocation

`crates/kernel/src/mm/page_alloc.rs` manages the Pi range
`0x40000000..0xfc000000`, which contains 770,048 possible pages. A byte-per-page
bitmap records ownership. Allocation returns a physical address; zero means
OOM and must never be mapped.

Every dynamically created task owns a page containing `TaskStruct`, a separate
4 KiB kernel-stack page, a page-table root, tracked page-table pages, and its
user pages. Keeping the kernel stack separate prevents deep syscall frames from
reaching process credentials stored in `TaskStruct`.

## EL0 address-space layout

`crates/kernel-abi/src/user.rs` is the source of truth:

| Region | Address policy |
| :----- | :------------- |
| Text | executable ELF segments from address zero |
| Data | non-executable ELF segments from `0x100000` |
| Heap | grows upward from `0x200000` to `brk` |
| Stack | 16 pages below `0x00000ffffffff000` |
| Guard | one unmapped page below the legal stack window |

Executable segments currently remain writable because the active descriptor
set has no user read-only bit. Data, heap, and stack mappings carry XN. Full
W^X enforcement is therefore future work, not a current property.

## Demand mapping

The ELF loader eagerly maps the top stack page and writes `argc`, `argv`, and
the argument strings there. `crates/kernel/src/mm/user.rs` handles later
translation faults:

```text
heap below brk       → allocate RW+XN page
legal stack window   → allocate RW+XN page
stack guard          → terminate task: stack overflow
text or unknown UVA  → terminate task with diagnostic
```

The parent can still reap a task terminated by a bad user address, so its page
tables and memory are returned normally.

## Crossing the user boundary

Syscalls never treat an EL0 pointer as a trusted Rust reference. The
`copy_from_user` and `copy_to_user` paths validate and prefault the complete
range before copying. Invalid or oversized ranges return an error instead of
turning a bad argument into a kernel crash.

Partial allocation has rollback paths in fork, exec, page-table construction,
pipes, and files. After exec passes its point of no return, a load-time OOM
terminates the task rather than attempting to revive the replaced image.

> [!NOTE]
> A saved `KeRegs` exception frame consumes 272 bytes at the top of the 4 KiB
> kernel stack, leaving 3,824 bytes for the active call chain. Nested IRQ entry
> consumes some of the same finite budget.

Next, we connect user input, user output, and kernel diagnostics.
