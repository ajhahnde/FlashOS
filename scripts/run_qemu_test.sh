#!/usr/bin/env bash
# Self-validating QEMU runner for `zig build test-virt` / `test-rpi4b`.
#
# Spawns the supplied QEMU command, tails its serial log, and exits:
#   * 0  on `9/9 passed` with the expected free-page-checkpoint counts
#   * 1  on `ERROR CAUGHT`, drifted counts, or watchdog timeout
#
# Args: TIMEOUT_SECS QEMU_BINARY [QEMU_ARG ...]
#
# Expected success picture (verified against virt boot 2026-05-10):
#   * `9/9 passed`
#   * 13 × `free_pages: 00000000000bbff9`  (test free-page checkpoints)
#   *  1 × `free_pages: 00000000000bc000`  (boot baseline)
#   *  0 × `ERROR CAUGHT`
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
    if grep -qF "9/9 passed" "$LOG"; then
        status=passed
        break
    fi
    if grep -qF "ERROR CAUGHT" "$LOG"; then
        status=caught
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
ok_chk=$(grep -cF "free_pages: 00000000000bbff9" "$LOG" || true)
ok_base=$(grep -cF "free_pages: 00000000000bc000" "$LOG" || true)

if [ "$errors" -ne 0 ] || [ "$ok_chk" -ne 13 ] || [ "$ok_base" -ne 1 ]; then
    echo "FAIL (counter drift): ERROR_CAUGHT=$errors 0xbbff9=$ok_chk (want 13) 0xbc000=$ok_base (want 1)" >&2
    tail -n 50 "$LOG" >&2
    exit 1
fi

exit 0
