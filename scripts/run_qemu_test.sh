#!/usr/bin/env bash
# Self-validating QEMU runner for `zig build test-virt` / `test-rpi4b`.
#
# Spawns the supplied QEMU command, tails its serial log, and exits:
#   * 0  on `14/14 passed` with the expected free-page-checkpoint counts
#   * 1  on `ERROR CAUGHT`, drifted counts, or watchdog timeout
#
# Args: TIMEOUT_SECS QEMU_BINARY [QEMU_ARG ...]
#
# Expected success picture (v0.4.0 — FAT32 + fs-roundtrip):
#   * `14/14 passed`
#   * N × `free_pages: 00000000000bbff4`  (test free-page checkpoints)
#   *  1 × `free_pages: 00000000000bc000`  (boot baseline)
#   *  0 × `ERROR CAUGHT`
# The N for the bbff4 checkpoint is read from the first green run.
# Shifts vs v0.3.0's 16 × bbff8: v0.4.0 swapped the blob-loaded
# PID 1 for the larger ELF-loaded pid1.elf (an extra .text page over the
# v0.3.0 blob layout) and added a stack warm-up at run_all entry that
# maps the second EL0 stack page eagerly — without that, sys_readFile's
# EL1 store into an unmapped stack page traps to sync_invalid_el1h
# (kernel-mode user-VA faults bypass do_data_abort, see
# user_space/kernel_tests.zig prefault_buf). v0.4.0's [TEST] vfs-dispatch added one sys_dump_free
# checkpoint (→ 17). v0.4.0's [TEST] fs-roundtrip adds exactly
# one more — every branch (write / verify / skip) calls sys_dump_free
# once, so the count is board-independent (rpi4b runs the real Variant-B
# roundtrip; virt takes the mount-detected skip). Net: 18 × bbff4.
#
# Tally-matcher widening: the harness counts a green
# fs-roundtrip as one PASS whichever of `[PASS] fs-roundtrip-write …`
# / `[PASS] fs-roundtrip` / `[PASS] fs-roundtrip (skip)` it emits; the
# in-kernel run_all tally collapses them, so this script only asserts
# the final `14/14 passed` line plus the 18 × bbff4 invariant.
# (`main_output_u64` prints u64 as 16-digit zero-padded hex.)
set -u

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
    if grep -qF "14/14 passed" "$LOG"; then
        status=passed
        break
    fi
    if grep -qF "ERROR CAUGHT" "$LOG"; then
        status=caught
        break
    fi
    # v0.4.0: EL1-side block-I/O smoke check. The
    # scenario is emitted before PID 1 forks, so it is NOT in the
    # 14/14 EL0 tally — surface its failure here so a buggy
    # block_dev wiring fails the run even if the EL0 harness goes
    # on to print 14/14 passed.
    if grep -qF "[FAIL] emmc2-block" "$LOG"; then
        status=emmc2_fail
        break
    fi
    sleep 0.5
done
kill -TERM "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true

if [ "$status" != "passed" ]; then
    echo "FAIL ($status) — last 50 lines:" >&2
    tail -n 50 "$LOG" >&2
    exit 1
fi

errors=$(grep -cF "ERROR CAUGHT" "$LOG" || true)
ok_chk=$(grep -cF "free_pages: 00000000000bbff4" "$LOG" || true)
ok_base=$(grep -cF "free_pages: 00000000000bc000" "$LOG" || true)

if [ "$errors" -ne 0 ] || [ "$ok_chk" -ne 18 ] || [ "$ok_base" -ne 1 ]; then
    echo "FAIL (counter drift): ERROR_CAUGHT=$errors 0xbbff4=$ok_chk (want 18) 0xbc000=$ok_base (want 1)" >&2
    tail -n 50 "$LOG" >&2
    exit 1
fi

exit 0
