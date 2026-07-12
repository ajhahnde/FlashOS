# Chapter 4: Memory: MMU & Page Allocator

Chapter 3 stopped just short of `map_identity` and `map_high` — the
page-table construction `boot.S` runs before the MMU turns on and
`kernel_main` starts. FlashOS uses a four-level AArch64 translation
regime (PGD → PUD → PMD → PTE) with 4 KiB pages throughout. This
chapter is not about fault handling — the fault-dispatch table below
was already touched on in earlier chapters and gets its own detailed
treatment later — it is about two more basic questions: where does
physical memory go, and how does the kernel hand pages to user tasks?

## Physical layout (RPi 4, 4 GiB SKU)

| Range                      | Region           | Usage                            |
| :------------------------- | :--------------- | :-------------------------------- |
| `0x00000000`–`0x38400000`  | 0 – 948 MiB      | Free / kernel image at `0x80000` |
| `0x38400000`–`0x40000000`  | 948 – 1024 MiB   | VideoCore reserved               |
| `0x40000000`–`0xFC000000`  | 1 GiB – 3960 MiB | `get_free_page` pool             |
| `0xFC000000`–`0x100000000` | > 3960 MiB       | MMIO (GIC, UART, GPIO)           |

(DOCUMENTATION.md §3 "Physical layout".) The kernel image itself lives
below the pool, at `0x80000`; the GPU firmware reserves the region
just above it for VideoCore; everything from `0x40000000` up to the
MMIO window is the allocatable physical page pool `get_free_page`
draws from — the subject of the rest of this chapter.

## Kernel virtual layout (EL1)

| Region       | Virtual base         | Physical base | Attributes           |
| :----------- | :------------------- | :------------ | :-------------------- |
| Identity map | `0x0000000000000000` | `0x00000000`  | Normal-NC (0–16 MiB) |
| Linear high  | `0xffff000000000000` | `0x00000000`  | Normal-NC            |
| RAM high     | `0xffff000040000000` | `0x40000000`  | Normal-NC            |
| Device high  | `0xffff0000FC000000` | `0xFC000000`  | Device-nGnRnE        |

This is the pair of trees `boot.S`'s `map_identity` and `map_high`
build: the identity map keeps code executing correctly right up to the
instant the MMU turns on, and the "high" mapping is where the kernel
actually lives once it does. Translating between a physical address
and its linear-high counterpart is a fixed offset add/subtract —
`PA_TO_KVA` / `KVA_TO_PA` in `src/mm_user.flash` — not a table walk.
A reader should recognize this layout when it appears in a stack trace
or a panic address; it is infrastructure, not something to memorize.

## User virtual layout (EL0)

| Region | Virtual base         | Direction      | Attributes (post-loader) |
| :----- | :------------------- | :-------------- | :------------------------ |
| Text   | `0x0000000000000000` | static         | RWX (no UXN, no RO bit)  |
| Data   | `0x0000000000100000` | static         | RW- (UXN)                |
| Heap   | `0x0000000000200000` | grows up (brk) | RW- (UXN)                |
| Stack  | `0x00000FFFFFFFF000` | grows down     | RW- (UXN), guard below   |

These four constants (`TEXT_BASE`, `DATA_BASE`, `HEAP_BASE`,
`STACK_TOP`) come from `src/user_layout.flash`, the single source both
the ELF loader (`src/fork.flash`) and the page-fault path
(`src/mm_user.flash`) read so they agree on where each region sits.
The gap between `HEAP_BASE` and `STACK_TOP` is roughly 16 TiB — heap
and stack are placed at opposite ends of the address space on purpose,
not packed close together. That gap is the guard: a wild pointer that
isn't a legitimate heap or stack address lands in the gap and faults
immediately, rather than silently colliding with whatever the heap or
stack happened to grow into that day.

> [!NOTE]
> Text is mapped RWX today — the loader's default page bag grants EL0
> read/write and clears UXN, and no read-only descriptor bit is
> defined yet, so W^X isn't enforced for user code. Data, heap, and
> stack all set UXN (execute-never), so only the text region can ever
> run instructions.

For completeness, here is the fault-dispatch table this layout feeds
(DOCUMENTATION.md §3 "User pages") — a page fault's target address
decides what happens, and the guard gap above is exactly why "anything
else" reliably means a bug rather than a coincidence:

| Fault UVA range                       | Action                                                |
| :------------------------------------- | :------------------------------------------------------ |
| `[HEAP_BASE, current.mm.brk)`         | Demand-allocate (RW+UXN); OOM → `[KERN] OOM` + zombie |
| `[STACK_LOW, STACK_TOP)`              | Demand-allocate (RW+UXN); OOM → `[KERN] OOM` + zombie |
| `[STACK_GUARD_LOW, STACK_GUARD_HIGH)` | Panic `stack overflow` + zombie task                  |
| `[TEXT_BASE, DATA_BASE)`              | Panic `text fault` + zombie task                      |
| anything else                          | Panic `invalid uva` + zombie task                     |

## The physical page allocator

`src/page_alloc.flash` is what actually hands out the physical pages
that back both kernel structures and demand-allocated user pages. Its
tracking structure is deliberately simple: one status byte per page in
a plain array, not a packed bitmask.

```flash
// Constants
pub const PAGE_SIZE u64 = 1 << 12
pub const MALLOC_START u64 = 0x40000000
pub const MALLOC_END u64 = 0xFC000000
pub const MALLOC_SIZE u64 = MALLOC_END - MALLOC_START
pub const MALLOC_PAGES u64 = MALLOC_SIZE / PAGE_SIZE

// …

// Memory map: tracks which physical pages are allocated (1 = allocated, 0 = free)
// Stored in kernel BSS section. Must be initialized once via mem_map_init
// from the boot path before any get_free_page / free_page / dump_free_count
// call. The init is idempotent (re-zeroes the bitmap), so callers in test
// code can reset state by calling it again.
var mem_map [MALLOC_PAGES]u8 = undefined
```

*(excerpt — not standalone-compilable)*

`mem_map` is a `[MALLOC_PAGES]u8` array — one whole byte tracks one
page's allocated/free state, not one bit. `get_free_page` does a
linear scan for the first `0` entry, marks it `1`, zeroes the page,
and returns its physical address:

```flash
export fn get_free_page() u64 {
    for i in 0..MALLOC_PAGES {
        if mem_map[i] == 0 {
            mem_map[i] = 1 // Mark as allocated

            const ret u64 = MALLOC_START + #as(u64, #intCast(i)) * PAGE_SIZE

            // Zero the page before handing it out.
            memzero(pa_to_kva(ret), PAGE_SIZE)

            return ret
        }
    }

    // Out of physical memory — return the sentinel; the caller handles it.
    return 0
}
```

*(excerpt — not standalone-compilable)*

The return value on exhaustion is `0` — an unambiguous sentinel,
because no live allocation is ever PA `0`: the pool starts at
`MALLOC_START` (`0x40000000`), well above address `0`. Every call site
checks `== 0` and fails its own operation cleanly (a syscall returns
`-1`, a fault path zombies the task) rather than trusting the
allocator to abort the kernel on its behalf (DOCUMENTATION.md §3
"Out-of-memory policy"). `get_kernel_page`, the kernel-virtual-address
wrapper, is careful to propagate a raw `0` too, rather than translating
it through `pa_to_kva` — `pa_to_kva(0)` is `LINEAR_MAP_BASE`, a
non-zero, valid-looking address that would silently hide a failed
allocation.

There is no general `free()`/`malloc()` pair yet. The allocator is
allocate-mostly: pages come back to the pool through `free_page`
(called explicitly, e.g. when a mid-walk page-table build rolls back)
and through the per-task sweep that runs when a process is reaped, not
through an arbitrary free-anytime API.

## Bridge to the lab

One status byte per page is simple and cheap to reason about, but it
is not the densest way to track allocation state. The lab below builds
a small standalone toy that packs multiple pages' status into the
*bits* of a single `u64` instead of one array *byte* per page — same
allocate/free idea, denser storage. This toy is a teaching exercise,
not a description of how FlashOS's real allocator works; the real one
is the byte-array `mem_map` above.

## Lab: a toy bitmap allocator

This program packs 64 "pages" into one `u64` mask, where bit `1` means
allocated and bit `0` means free. `alloc` scans for the lowest clear
bit, sets it, and returns its index (or the sentinel `NONE` if every
bit is taken); `free` clears a given bit.

```flash
// bitmap_alloc — toy page allocator, ch4 lab.
//
// FlashOS's real allocator (src/page_alloc.flash) spends one whole `u8`
// per page in `mem_map`. This teaching toy packs 64 page-slots into the
// bits of a single u64 instead: bit 1 = allocated, bit 0 = free. Same
// allocate/free idea, denser storage — not FlashOS's actual allocator.

use flibc

link "flibc_start"
link "flibc_mem"

const NPAGES u64 = 64
const NONE u64 = 0xffffffffffffffff

var pages u64 = 0

// Find the lowest clear bit, set it, and return its index — or NONE if
// every bit is already taken.
fn alloc() u64 {
    var i u64 = 0
    while i < NPAGES {
        const mask u64 = #as(u64, 1) << #intCast(i)
        if (pages & mask) == 0 {
            pages |= mask
            return i
        }
        i += 1
    }
    return NONE
}

// Clear bit `idx`, marking that page free again.
fn free(idx u64) void {
    if idx < NPAGES {
        pages &= ~(#as(u64, 1) << #intCast(idx))
    }
}

export fn main(_ usize, _ argv) noreturn {
    a := alloc()
    b := alloc()
    c := alloc()
    flibc.printf("alloc: %u %u %u\n", .{a, b, c})

    free(b)
    flibc.printf("freed: %u\n", .{b})

    d := alloc()
    flibc.printf("alloc: %u (reused slot %u)\n", .{d, b})

    flibc.exit()
}
```

> [!NOTE]
> `flibc.printf` is the same comptime-format helper `/bin/meminfo` uses
> (`tools/meminfo.flash`) — a deliberate subset of C `printf` (`%u` for
> unsigned decimal here) that formats into a stack buffer and flushes it
> with a single `write_fd` call.

Copy it into the Flash Editor and choose **Check lab**: allocating three pages should hand
back indices `0`, `1`, `2`; freeing index `1` and allocating again
should reuse it rather than moving on to `3`.

## What's next

Chapter 5 turns to the console drivers `kernel_main` brings up right
after memory management — the Mini-UART and PL011 paths this whole
tour has been reading its boot log through.
