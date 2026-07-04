# Chapter 13: How FlashOS Tests Itself

Every mechanism this tour has walked through — the page allocator,
the scheduler, the syscall boundary, the VFS — is exercised by two
complementary test surfaces before it ever ships. This chapter is about
that machinery: not what it currently counts (those numbers move every
release), but how it proves the kernel still works, on real hardware,
without a human watching.

## Two surfaces: host logic, in-kernel behavior

**Host-side unit tests** (`zig build test`) run pure-logic modules on
the *build machine's* CPU, not the target AArch64 board at all. Each
tested module is its own test root, linked against a shared stub object
that fills in the assembly-only externs a kernel module normally calls
— `memzero`, `panic`, the page-allocator entry points, the context-switch
primitives. A page allocator's bitmap math, a tokenizer, a gap buffer's
insert/delete logic — none of that needs a booted kernel to prove
correct, so it never pays QEMU's boot time to run.

**The in-kernel runtime harness** (`user_space/kernel_tests.flash`) is
the other half: PID 1 itself, on real kernel state, running dozens of
named `[TEST]` scenarios end to end. This is where fork/reap cycles,
real page-table teardown, actual syscall dispatch, and real hardware
drivers get proven — things no host stub can fake convincingly. Each
scenario prints `[TEST] name` on entry and `[PASS] name` or `[FAIL]
name` on exit; `run_all()` tallies the results into one line.

## The free-page checkpoint: the leak detector

The harness's most distinctive habit is calling `sys_dump_free()` after
almost every scenario and comparing the result against a known
baseline. A scenario that forks, execs, and reaps a child should return
the *exact* free-page count it started with — any drift means a page
leaked somewhere in fork, exec, or reap. This is why a scenario like
`fork-stress` checks the baseline after every round, not just at the
end: a leak in round 2 that round 3 happens to mask would otherwise go
undetected.

Because the checkpoint count is per-board (the page pool's layout
differs between `rpi4b` and `virt`), the exact hex values live in
exactly one place — the header of `scripts/run_qemu_test.sh` — rather
than being copied into documentation that could quietly drift out of
sync with the source of truth.

## Boot success is a marker count, not a timeout

The CI watchdog doesn't wait a fixed number of seconds and hope; it
tails the serial log and counts a specific string. With the login
lifecycle chapter 9 walked through, fsh's homescreen banner — the
stable `type 'help' for commands` tail — appears **three times** in a
successful boot: twice from the in-harness `login` scenario's two
scripted sessions, and once from the real PID-1 → login → fsh hand-off
at the end of boot. The watchdog's early-exit fires on the *third*
occurrence, with zero `[FAIL]` markers and zero `ERROR CAUGHT` lines
anywhere in the log. Any drift in the expected scenario tally or
checkpoint hex fails the run loudly rather than silently passing on a
count that no longer means what it used to.

## A scenario built to catch a real regression

Not every scenario just proves a feature works — some exist specifically
to guard against a bug that already happened once. The `authenticate`
scenario drives `sys_authenticate` (chapter 9) but also re-reads PID 1's
own credentials immediately afterward, as a stack-overflow canary: the
password-verification KDF is the deepest call chain in the kernel, and
before each task's kernel stack moved onto its own dedicated page (away
from the `TaskStruct` holding its credentials), a deep enough frame
could silently corrupt `uid`/`euid` on the way back up. The scenario
flips to `[FAIL]` immediately if that regression class ever returns —
a test written after the fact, from a real incident, rather than
written speculatively in advance.

## Hardware-only scenarios: the SKIP pattern

Some scenarios genuinely cannot run under QEMU — `fs-roundtrip`, the
scenario that proves FAT32 writes survive a power cycle, needs a real
SD card behind a real EMMC2 controller that QEMU's `raspi4b` machine
does not model closely enough to pass the SD initialization sequence.
Rather than skip the scenario silently or fake success, it takes an
explicit, logged **SKIP** path — `[PASS] fs-roundtrip (skip)` — when it
detects the mount is absent, still emitting its one baseline checkpoint
so the free-page accounting stays consistent whether or not the real
write path ran. On real Pi-4 hardware the same scenario takes its full
branch: write a pattern, reboot, read it back, byte-compare. The
distinction between "skipped because the environment can't support it"
and "silently passing" is deliberate everywhere this pattern appears.

## Running it yourself

```text
zig build test                      # host-side unit tests
zig build -Dboard=virt run-virt     # in-kernel harness, QEMU virt
zig build -Dboard=rpi4b run         # in-kernel harness, QEMU rpi4b
./build.sh                          # two-pass build; optional real-HW deploy
```

The in-kernel harness runs identically whether the board is emulated or
real silicon — the same `[TEST]`/`[PASS]` protocol, the same baseline
math — which is exactly what lets a QEMU-green run stand in as evidence
for a real-hardware boot on everything that isn't hardware-specific
(the FAT32 write path, USB-C enumeration, and a handful of others are
explicitly the exceptions, gated behind their own SKIP or Pi-only
scenarios).

## What's next

Chapter 14 turns from *what* gets tested to *how the source gets built
at all* — the two-pass symbol-table build, the compile step every
`.flash` module goes through, and the toolchain pin that keeps it
reproducible.
