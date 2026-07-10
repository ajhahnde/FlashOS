#!/usr/bin/env bash
# Self-validating QEMU runner for `zig build test-virt` / `test-rpi4b`.
#
# Boot success is reaching the interactive fsh prompt. With the
# login lifecycle, fsh's homescreen marker (user_space/fsh/fsh.zig — the
# stable `type 'help' for commands` tail) appears THREE times per boot: twice
# from [TEST] login's console-scripted sessions and once from the real boot
# login's shell — only the third one means the boot is done, so the early-exit
# below counts markers instead
# of first-matching. This script spawns the supplied QEMU command, tails
# its serial log, and exits:
#   * 0  on the 3rd homescreen marker with no `[FAIL]` / `ERROR CAUGHT`
#        and the expected free-page-checkpoint + marker counts
#   * 1  on `ERROR CAUGHT`, any `[FAIL]` marker, drifted counts, or timeout
#
# Args: TIMEOUT_SECS QEMU_BINARY [QEMU_ARG ...]
#
# REQUIRES the kernel be built with `-Dci-login-seed=true` (the test-virt /
# test-rpi4b steps and CI pass it). That flag makes PID-1 seed `flash\nflash\n`
# into the console before /bin/login so the unattended boot authenticates with
# no typist and reaches the 3rd homescreen marker. Without it the boot
# stops at the real `login:` prompt (correct for a hardware deploy) and this
# watchdog would hang to the timeout. The expected checkpoint values below are
# for the seeded kernel.
#
# Expected success picture:
#   * 30 EL0 scenarios, all `[PASS]` (no `[FAIL]`)
#   * 34 × per-scenario checkpoint at the board's PID-1 baseline
#   *  1 × initial boot-baseline checkpoint (baseline + 0xe = 14 pages,
#         the PID-1 fork delta over the PID-0 boot snapshot)
#   *  1 × healthy kernel-entropy announce (`HWRNG init`), 0 × failed
#         self-test announce
#   *  3 × homescreen marker (`type 'help' for commands`) — two scripted
#         [TEST] login sessions + the real boot login; each session
#         authenticated, dropped privilege in its child, and reached the
#         shell
#   *  0 × `ERROR CAUGHT`
#
# Baseline values are board-specific because the get_free_page pool
# layout is board-specific (page_alloc.mem_map_reserve_below /
# _reserve_above are called from kernel_main with the board's
# `_kernel_pa_end` symbol and, on virt, RAM_END = 0x80000000):
#
#   * rpi4b  — kernel sits at PA 0x80000, far below MALLOC_START
#              (0x40000000), and Pi has 4 GiB of RAM up to MALLOC_END
#              (0xFC000000), so both reserve calls are no-ops. Boot
#              baseline = 0xbc000 (the full MALLOC_PAGES count),
#              per-scenario checkpoint = 0xbbff2 (boot − 0xe).
#   * virt   — kernel is loaded at PA 0x40080000 (inside the pool
#              window), so reserve_below covers the kernel image plus
#              the 64 MiB `.sdscratch` buffer; reserve_above caps the
#              pool at virt's 1 GiB RAM end (0x80000000), well below
#              MALLOC_END's RPi-derived 0xFC000000. Boot baseline =
#              0x3be53, per-scenario checkpoint = 0x3be45.
#
# The script accepts either pattern; the active board's pair must
# match exactly. Net: 34 × {bbff2, 3be45} + 1 × {bc000, 3be53}.
#
# FROZEN (2026-06-17): the virt board is deprioritized — rpi4b + real
# HW are the live gates and CI now boots rpi4b (test-rpi4b), not virt.
# The virt values above (0x3be45 / 0x3be53 + the drift history) were
# refreshed at the v0.5.0 /bin/uptime change (see drift history) and are
# otherwise NOT re-checked while virt is on ice. Detection of the virt
# pattern is kept so `-Dboard=virt test-virt` still works for the
# eventual revive — at which point re-validate and refresh these values.
#
# Drift history (legitimate free-page baseline shifts, newest first):
#   * v0.7.4 — marker WORDING only, no hex shift, no tally bump: the boot-log
#              restyle renamed hwrng's announce lines ("Initialized hwrng" →
#              "HWRNG init", "hwrng: self-test failed" → "HWRNG: self-test
#              failed"); the hwrng greps below track the new strings.
#   * v0.6.0 — NO hex shift, NO tally bump. The FAT32 create/unlink/rename
#              ABI is folded into the existing [TEST] fs-roundtrip (a CRUD
#              leg: create→write→readback→rename→unlink, Pi-only, self-
#              cleaning) rather than added as a new scenario, so EL0 scenarios
#              stay 30 and per-scenario checkpoints stay 34 — the leg adds no
#              sys_dump_free. The grep/cp/mv/rm coreutils grow the initramfs,
#              but rpi4b's reserve calls are no-ops (kernel below MALLOC_START)
#              so 0xbbff2 / 0xbc000 hold; the CRUD leg emits an uncounted
#              `[DBG] fs-crud OK …` marker on a mounted (Pi) boot. virt left on
#              ice (not recaptured — see flashos-virt-deprioritized).
#   * v0.5.0 — virt 0x3be46→0x3be45 (per-scenario), 0x3be54→0x3be53 (boot
#              baseline): the /bin/uptime coreutil added one ELF to the
#              initramfs, growing the kernel image past a page boundary so
#              virt's reserve_below covers one more page. This recapture also
#              folds in the hwmon image growth deferred below (virt was left at
#              0x3be46/0x3be54 then; the measured current pair is now the truth
#              of record). rpi4b unaffected (reserve calls are no-ops — kernel
#              sits below MALLOC_START, so a larger image does not move the
#              count, and the value stays 0xbbff2 / 0xbc000).
#   * v0.5.0 — TALLY bump, not a hex shift: hardware-monitoring adds the
#              [TEST] hwmon-core + hwmon-mailbox scenarios (mem_total /
#              uptime / cpu_temp / cpu_freq), so EL0 scenarios go 28→30 and
#              per-scenario checkpoints 32→34 (one sys_dump_free each). The
#              free-page HEX is unchanged on rpi4b (0xbbff2 / 0xbc000 — the
#              boot pool is identical; reserve_below/_above stay no-ops, so a
#              larger kernel image does not move the count) and the watchdog
#              guard now wants 34. virt's hex drifted ~1 page from the larger
#              image; left un-recaptured then, folded into the /bin/uptime
#              recapture above.
#   * v0.3.0 — virt 0x3be47→0x3be46 (per-scenario), 0x3be55→0x3be54 (boot
#              baseline): the +strict-align build-target feature replaces
#              unaligned NEON stores with aligned codegen, growing the kernel
#              image one page past a 4 KiB boundary so virt's reserve_below
#              covers one more page; this fixes the /bin/less alignment fault
#              on real silicon. rpi4b unaffected (reserve calls are no-ops).
#   * v0.3.0 — virt 0x3be48→0x3be47 (per-scenario), 0x3be56→0x3be55 (boot
#              baseline): the restructured `help` output (per-command
#              descriptions) grew fsh.elf one page past a 4 KiB boundary, so
#              virt's reserve_below covers one more page. rpi4b unaffected.
#   * v0.3.0 — virt 0x3be49→0x3be48 (per-scenario), 0x3be57→0x3be56 (boot
#              baseline): the /bin/less pager added one ELF to the initramfs,
#              growing the kernel image past a page boundary so virt's
#              reserve_below covers one more page. rpi4b unaffected (its
#              reserve calls are no-ops — kernel sits below MALLOC_START).
#
# Tally-matcher note: the harness counts a green fs-roundtrip as one PASS
# whichever of `[PASS] fs-roundtrip-write …` / `[PASS] fs-roundtrip` /
# `[PASS] fs-roundtrip (skip)` it emits; [TEST] passwd has the same
# `[PASS] passwd` / `[PASS] passwd (skip)` split. The v0.6.0 CRUD leg folded
# into fs-roundtrip adds no new [PASS] label — on a mounted (Pi) boot it
# emits an uncounted `[DBG] fs-crud OK …` line and the scenario still closes
# on its existing fs-roundtrip-write / fs-roundtrip PASS. (`main_output_u64`
# prints u64 as 16-digit zero-padded hex.)
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 TIMEOUT_SECS QEMU_BINARY [QEMU_ARG ...]" >&2
    exit 2
fi
TIMEOUT_SECS=$1; shift
QEMU=$1; shift

LOG=$(mktemp -t flashos_qemu_test.XXXXXX)
trap 'rm -f "$LOG"' EXIT

# QEMU's serial stdio is normally line-buffered, but pipe-redirection can
# trigger libc block-buffering on the host side. Force line-buffering when
# coreutils is available; otherwise trust QEMU's defaults.
if command -v stdbuf >/dev/null 2>&1; then
    UNBUF=(stdbuf -oL)
elif command -v gstdbuf >/dev/null 2>&1; then
    UNBUF=(gstdbuf -oL)
else
    UNBUF=()
fi

"${UNBUF[@]}" "$QEMU" "$@" </dev/null >"$LOG" 2>&1 &
QEMU_PID=$!

deadline=$(( $(date +%s) + TIMEOUT_SECS ))
status=timeout
while kill -0 "$QEMU_PID" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        break
    fi
    # Success: the boot reached the interactive shell. With the
    # login lifecycle the homescreen marker appears three times — [TEST]
    # login's two scripted sessions plus the real boot login's shell — so the
    # trigger counts occurrences instead of first-matching (killing on the
    # first one would truncate the run mid-harness). The real boot's shell then
    # blocks reading fd 0 — under QEMU there is no input, so it sits here.
    if [ "$(grep -cF "type 'help' for commands" "$LOG" || true)" -ge 3 ]; then
        status=ready
        break
    fi
    if grep -qF "ERROR CAUGHT" "$LOG"; then
        status=caught
        break
    fi
    # Any [FAIL] (an EL0 scenario or the pre-PID-1 emmc2-block smoke, which
    # is emitted before PID 1 forks and is not in the EL0 tally) fails the
    # run immediately rather than waiting for the prompt or the timeout.
    if grep -qF "[FAIL]" "$LOG"; then
        status=failed
        break
    fi
    sleep 0.5
done
kill -TERM "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true

if [ "$status" != "ready" ]; then
    echo "FAIL ($status) — last 50 lines:" >&2
    tail -n 50 "$LOG" >&2
    exit 1
fi

errors=$(grep -cF "ERROR CAUGHT" "$LOG" || true)
fails=$(grep -cF "[FAIL]" "$LOG" || true)

# Board-specific baseline pair (see header). rpi4b: bbff2 / bc000;
# virt: 3be45 / 3be53. Pick the board whose checkpoint pattern is
# present, then require its exact pair (32 checkpoints + 1 boot
# baseline). Detecting by content keeps this script board-arg-free.
rpi_chk=$(grep -cF "free_pages: 00000000000bbff2" "$LOG" || true)
virt_chk=$(grep -cF "free_pages: 000000000003be45" "$LOG" || true)

if [ "$rpi_chk" -gt 0 ]; then
    ok_chk=$rpi_chk
    ok_base=$(grep -cF "free_pages: 00000000000bc000" "$LOG" || true)
    chk_label="0xbbff2"; base_label="0xbc000"
elif [ "$virt_chk" -gt 0 ]; then
    ok_chk=$virt_chk
    ok_base=$(grep -cF "free_pages: 000000000003be53" "$LOG" || true)
    chk_label="0x3be45"; base_label="0x3be53"
else
    echo "FAIL (no known checkpoint pattern): neither 0xbbff2 (rpi4b) nor 0x3be45 (virt) found" >&2
    tail -n 50 "$LOG" >&2
    exit 1
fi

# The kernel entropy source must announce a healthy bring-up.
# Both QEMU targets take the weak timer-mix fallback (QEMU emulates no
# BCM2711 RNG200); the announce must be the healthy "ok" form and the
# failed-self-test form must never appear. Wording per src/hwrng.zig
# ("HWRNG init" / "HWRNG: self-test failed" since the v0.7.4 boot-log
# restyle — see src/hwrng.flash).
hwrng_ok=$(grep -cF "HWRNG init" "$LOG" || true)
hwrng_bad=$(grep -cF "HWRNG: self-test failed" "$LOG" || true)

# Every login session must reach the interactive shell — exactly three per
# boot: [TEST] login's two scripted sessions (flash, then root, each
# fork+drop+exec'd by the supervisor) plus the real boot login. Each shell
# entry prints fsh's homescreen marker. Fewer means the lifecycle or the auth
# path regressed; more means a scenario leaked an extra session.
fsh_ok=$(grep -cF "type 'help' for commands" "$LOG" || true)

if [ "$errors" -ne 0 ] || [ "$fails" -ne 0 ] || [ "$ok_chk" -ne 34 ] || [ "$ok_base" -ne 1 ] \
    || [ "$hwrng_ok" -ne 1 ] || [ "$hwrng_bad" -ne 0 ] || [ "$fsh_ok" -ne 3 ]; then
    echo "FAIL (guard): ERROR_CAUGHT=$errors [FAIL]=$fails ${chk_label}=$ok_chk (want 34) ${base_label}=$ok_base (want 1) hwrng_ok=$hwrng_ok (want 1) hwrng_bad=$hwrng_bad (want 0) fsh_ok=$fsh_ok (want 3)" >&2
    tail -n 50 "$LOG" >&2
    exit 1
fi

exit 0
