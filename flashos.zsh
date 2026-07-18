# FlashOS shell helpers. Source from ~/.zshrc:
#   [[ -f /path/to/FlashOS/flashos.zsh ]] && source /path/to/FlashOS/flashos.zsh
#
# Public interface — two verb dispatchers plus a build wrapper:
#   pi    connect|capture|list|quit|log|tail   serial-console helpers (Raspberry Pi)
#   run   qemu|virt|test|watchdog|hw|auto       build-and-run a board, the boot-watchdog, or attach to HW
#   build                                       two-pass kernel build orchestrator
#   flashos                                     list shell helpers + cargo xtask commands
# Legacy flat names (piconnect/picapture/pilist/piquit) stay as thin aliases.

# Resolve the directory of this file once at source time. Inside a function,
# ${0:A:h} refers to the function name, not the source file — capture it now
# while %x still points at the file being sourced.
typeset -g _FLASHOS_DIR="${${(%):-%x}:A:h}"

typeset -g _RED=$'\033[0;31m'
typeset -g _GREEN=$'\033[0;32m'
typeset -g _YELLOW=$'\033[1;33m'
typeset -g _NC=$'\033[0m'

# Screen session name shared by `pi capture` (creates it) and `pi quit` (kills it).
typeset -g _FLASHOS_CAPTURE_SESSION="pi_capture"

# Console serial parameters and the device tables the helpers match on, keyed by
# logical name (usb|mu). Mini-UART trace rides a USB-serial adapter
# (/dev/cu.usbserial-*); the USB CDC console (fsh) enumerates as
# /dev/cu.usbmodem*. _GLOB = the match pattern, _OVERRIDE = an env-var honored
# verbatim when set, _LABEL = the human name used in messages. Adding a second
# adapter later is one aligned row per table.
typeset -g _FLASHOS_BAUD=115200
typeset -gA _FLASHOS_DEV_GLOB=(     usb '/dev/cu.usbmodem*'    mu '/dev/cu.usbserial-*' )
typeset -gA _FLASHOS_DEV_OVERRIDE=( usb PI_USB_CONSOLE_DEVICE  mu PI_SERIAL_DEVICE )
typeset -gA _FLASHOS_DEV_LABEL=(    usb 'usb console (fsh)'    mu 'usb-serial adapter (MU trace)' )

# Default mount point for `build -d`. Override per-shell with
# SD_BOOT=/Volumes/OTHER build -d.
: "${SD_BOOT:=/Volumes/BOOT}"
export SD_BOOT

# ── shared primitives ──────────────────────────────────────────────────────
# One idiom each for diagnostics and for running argv in the project root, so
# every helper below speaks the same way: red/yellow go to stderr, green to
# stdout, and project commands run from $_FLASHOS_DIR in a subshell.
_flashos_err()  { print -u2 -- "${_RED}$*${_NC}"; }
_flashos_warn() { print -u2 -- "${_YELLOW}$*${_NC}"; }
_flashos_ok()   { print    -- "${_GREEN}$*${_NC}"; }
_flashos_root() { ( cd "$_FLASHOS_DIR" && "$@" ); }

# Run Cargo through the exact rustup toolchain pinned by rust-toolchain.toml.
# This stays deterministic when a package-manager cargo precedes rustup's
# shims on PATH (Homebrew commonly does that on the development Mac).
_flashos_cargo() {
  emulate -L zsh
  local toolchain_file="$_FLASHOS_DIR/rust-toolchain.toml"
  local channel
  channel="$(sed -n 's/^channel = "\([^"]*\)"/\1/p' "$toolchain_file" | head -1)"
  if [[ -z "$channel" ]] || ! command -v rustup >/dev/null 2>&1; then
    _flashos_err "cannot resolve the pinned rustup toolchain from $toolchain_file"
    return 1
  fi
  local rustc_bin
  rustc_bin="$(rustup which --toolchain "$channel" rustc)" || return 1
  _flashos_root env PATH="${rustc_bin:h}:$PATH" rustup run "$channel" cargo "$@"
}

# Echo a console device path on stdout, or return non-zero with a message on
# stderr. $1 = NAME of an override env-var (honored verbatim if set), $2 = the
# glob to match otherwise, $3 = human label used in the not-found message.
_flashos_pick_device() {
  emulate -L zsh
  local override=${(P)1}
  if [[ -n "$override" ]]; then
    if [[ ! -e "$override" ]]; then
      _flashos_err "\$$1 ($override) does not exist"
      return 1
    fi
    print -r -- "$override"
    return 0
  fi
  local devs=(${~2}(N))
  if (( ${#devs} == 0 )); then
    _flashos_err "no '$3' device found"
    return 1
  fi
  (( ${#devs} > 1 )) && _flashos_warn "multiple '$3' devices match; using ${devs[1]}"
  print -r -- "${devs[1]}"
}

# $1 = usb|mu. Echoes a console device path on stdout, or errors with the
# device's human label. The override env-vars (PI_USB_CONSOLE_DEVICE /
# PI_SERIAL_DEVICE) are honored verbatim; see the _FLASHOS_DEV_* tables above.
_flashos_device() {
  emulate -L zsh
  _flashos_pick_device "${_FLASHOS_DEV_OVERRIDE[$1]}" "${_FLASHOS_DEV_GLOB[$1]}" "${_FLASHOS_DEV_LABEL[$1]}"
}

# Named wrappers kept for readability at the call sites.
#   _flashos_serial_device       — Mini-UART trace adapter; honors $PI_SERIAL_DEVICE.
#   _flashos_usb_console_device  — USB CDC console (where fsh lives once the
#                                  gadget enumerates); honors $PI_USB_CONSOLE_DEVICE.
_flashos_serial_device()      { _flashos_device mu; }
_flashos_usb_console_device() { _flashos_device usb; }

# ── pi domain: serial-console helpers ──────────────────────────────────────
# Verbs are dispatched by pi() below; each impl is also reachable through its
# legacy flat alias (piquit/pilist/piconnect/picapture).

# Quit the capture screen session.
_flashos_pi_quit() {
  emulate -L zsh
  if screen -S "$_FLASHOS_CAPTURE_SESSION" -X quit 2>/dev/null; then
    _flashos_ok "capture session terminated"
  else
    _flashos_warn "no capture session is running"
  fi
}

# List attached console devices, iterating the device table so a new adapter
# row shows up here for free.
_flashos_pi_list() {
  emulate -L zsh
  local any=0 k devs
  for k in usb mu; do
    devs=(${~_FLASHOS_DEV_GLOB[$k]}(N))
    (( ${#devs} == 0 )) && continue
    any=1
    print -- "${_FLASHOS_DEV_LABEL[$k]}:"
    print -l -- "  "${^devs}
  done
  (( any )) || { _flashos_err "no device found"; return 1; }
}

# Page the last boot.log capture (created by `pi capture`).
_flashos_pi_log() {
  emulate -L zsh
  local f="$_FLASHOS_DIR/boot.log"
  if [[ ! -s "$f" ]]; then
    _flashos_warn "no capture yet (run 'pi capture'): $f"
    return 1
  fi
  ${PAGER:-less} "$f"
}

# Live-tail the last boot.log. `-F` follows across the rm+recreate the next
# `pi capture` does, so it keeps working through a re-run.
#   pi tail [N]    show the last N lines (default 40), then follow
_flashos_pi_tail() {
  emulate -L zsh
  tail -n "${1:-40}" -F "$_FLASHOS_DIR/boot.log"
}

# Attach an interactive screen session to the Pi console.
#   pi connect        auto: USB CDC console (fsh) if present, else MU trace adapter
#   pi connect usb    force the USB CDC console (/dev/cu.usbmodem*)
#   pi connect mu     force the Mini-UART trace adapter (/dev/cu.usbserial-*)
# Once the gadget enumerates, fsh I/O rides USB; the MU adapter then only
# carries kernel [Debug] prints and the USB bring-up trace.
_flashos_pi_connect() {
  emulate -L zsh
  local mode="${1:-auto}"
  local device
  case "$mode" in
    usb)
      device="$(_flashos_usb_console_device)" || return 1
      ;;
    mu)
      device="$(_flashos_serial_device)" || return 1
      ;;
    auto)
      if device="$(_flashos_usb_console_device 2>/dev/null)"; then
        _flashos_ok "usb console (fsh): ${device}"
      elif device="$(_flashos_serial_device 2>/dev/null)"; then
        _flashos_warn "mu trace adapter (${device}) — kernel [Debug] only; fsh rides usb once enumerated"
      else
        _flashos_err "no console device found (no ${_FLASHOS_DEV_GLOB[usb]} or ${_FLASHOS_DEV_GLOB[mu]})"
        return 1
      fi
      ;;
    *)
      _flashos_err "pi connect: unknown target '$mode' (usb|mu|auto)"
      return 1
      ;;
  esac
  screen "$device" "$_FLASHOS_BAUD"
}

# ── pi capture: orchestrator + extracted stages ────────────────────────────
# `pi capture` watches the Pi console until boot success is confirmed, then
# closes the session. The log always lands at $_FLASHOS_DIR/boot.log (covered by
# the repo .gitignore), regardless of the current directory. The work is split
# so each stage is readable and the two poll loops are testable against a
# fixture logfile without a Pi or a screen session: the wait helpers echo a
# single result token on stdout and route progress/status to stderr.

# Wait for the USB CDC gadget to enumerate. Echoes the device path on stdout;
# the /dev/cu.usbmodem* node only exists once the gadget is up, so its
# appearance is itself the first boot signal.
_flashos_capture_wait_enumerate() {
  emulate -L zsh
  local timeout=${PI_CAPTURE_TIMEOUT:-120} waited=0 device
  print -u2 -- "plug in the C-to-C cable now (powers the pi + carries the console)..."
  print -nu2 -- "waiting for enumeration "
  while ! device="$(_flashos_usb_console_device 2>/dev/null)"; do
    sleep 1
    (( waited++ ))
    print -nu2 -- "."
    if (( waited >= timeout )); then
      _flashos_err "\ntimeout: no ${_FLASHOS_DEV_GLOB[usb]} appeared after ${timeout}s"
      _flashos_warn "kernel faults only print on the mu adapter — try 'pi capture mu' with external power"
      return 1
    fi
  done
  _flashos_ok "\nenumerated (${device})" >&2
  print -r -- "$device"
}

# Acquire the capture device for the given mode. Echoes the device path on
# stdout; all status goes to stderr so the caller can capture the path cleanly.
_flashos_capture_acquire() {
  emulate -L zsh
  local mode=$1 device
  if [[ "$mode" == "mu" ]]; then
    device="$(_flashos_serial_device)" || return 1
    _flashos_ok "cable detected (${device})" >&2
    print -u2 -- "please connect pi to power now..."
  elif device="$(_flashos_usb_console_device 2>/dev/null)"; then
    _flashos_ok "usb console already present (${device}) — pi appears to be running" >&2
  else
    device="$(_flashos_capture_wait_enumerate)" || return 1
  fi
  print -r -- "$device"
}

# Start a detached, logging screen session on $device. Returns 0 on success.
_flashos_capture_screen_start() {
  emulate -L zsh
  local session=$1 device=$2 logfile=$3 screenrc
  screen -S "$session" -X quit >/dev/null 2>&1

  # macOS ships screen 4.00.03, which has no -Logfile flag; the log filename
  # comes from a screenrc `logfile` directive instead (plain -L would write
  # screenlog.0). `logfile flush 1` flushes every 1s so the live grep in the
  # wait loops sees the boot marker without screen's default 10s buffering.
  screenrc="$(mktemp)" || { _flashos_err "mktemp failed"; return 1; }
  print -r -- "logfile \"$logfile\"" > "$screenrc"
  print -r -- "logfile flush 1"     >> "$screenrc"

  if ! screen -c "$screenrc" -L -dmS "$session" "$device" "$_FLASHOS_BAUD"; then
    rm -f -- "$screenrc"
    _flashos_err "failed to start screen session"
    return 1
  fi

  sleep 1
  if ! screen -list | grep -q "\.${session}[[:space:]]"; then
    rm -f -- "$screenrc"
    _flashos_err "screen session failed to start; port may be occupied"
    return 1
  fi
  rm -f -- "$screenrc" # screen has read the rc; safe to remove now
}

# Mini-UART capture loop. Echoes one result token (success|error|failed|timeout)
# on stdout; progress dots go to stderr.
_flashos_capture_wait_mu() {
  emulate -L zsh
  local logfile=$1
  local timeout=${PI_CAPTURE_TIMEOUT:-120} elapsed=0 result=timeout
  print -nu2 -- "monitoring "
  while (( elapsed < timeout )); do
    sleep 1
    (( elapsed++ ))
    print -nu2 -- "."
    [[ -f "$logfile" ]] || continue

    # Check ERROR before success: if both appear, the error is the more
    # informative outcome.
    if grep -qF "ERROR CAUGHT:" "$logfile"; then
      result=error
      break
    fi
    if grep -qF "[FAIL]" "$logfile"; then
      result=failed
      break
    fi
    # Boot-complete depends on the build:
    #   * A self-test build runs the in-kernel suite, whose scripted login
    #     scenario prints `login:` TWICE mid-run -- so a bare `login:` match
    #     fires before the suite finishes and truncates the capture. Its real
    #     completion is the 3rd homescreen marker (`type 'help' for commands`;
    #     two scripted login sessions + the real boot login), the same count
    #     run_qemu_test.sh trusts.
    #   * A clean deploy/shipping kernel has no scripted test lines and never
    #     auto-logs-in, so it stops at the password-gated `login:` -- that
    #     prompt is its boot-complete signal (the homescreen marker never
    #     anchors there, so waiting on it would hang).
    if grep -qF "[TEST]" "$logfile"; then
      if [[ "$(grep -cF "type 'help' for commands" "$logfile")" -ge 3 ]]; then
        result=success
        break
      fi
    elif grep -qF "login:" "$logfile"; then
      result=success
      break
    fi
  done
  print -r -- "$result"
}

# USB CDC capture loop. Echoes one result token (success|died|timeout) on
# stdout; progress dots go to stderr.
_flashos_capture_wait_usb() {
  emulate -L zsh
  local session=$1 logfile=$2
  local timeout=${PI_PROBE_TIMEOUT:-30} elapsed=0 result=timeout
  # Stuff a CR each second to wake/keep the session (readline submits on CR,
  # an empty line is a no-op dispatch), and watch for a boot signal — the
  # homescreen marker `type 'help' for commands`, or on a clean shipping
  # kernel the password-gated `login:` prompt (it never auto-logs-in, so the
  # marker never prints; mu-mode draws the same distinction). The shell
  # prompt is `# ` / `$ `; it never prints `>>> `.
  # `-p 0` is mandatory: a born-detached (-dmS) session has no current
  # window on macOS screen 4.00.03, so -X stuff silently goes nowhere
  # without an explicit window target.
  print -nu2 -- "monitoring "
  while (( elapsed < timeout )); do
    screen -S "$session" -p 0 -X stuff $'\r' >/dev/null 2>&1
    sleep 1
    (( elapsed++ ))
    print -nu2 -- "."

    if ! screen -list 2>/dev/null | grep -q "\.${session}[[:space:]]"; then
      result=died
      break
    fi
    if [[ -f "$logfile" ]]; then
      if grep -qF "[TEST]" "$logfile"; then
        # Self-test build: its scripted login scenario prints `login:`
        # mid-run, so a bare `login:` match would truncate the capture —
        # only the homescreen marker counts (same trap mu-mode documents).
        if grep -qF "type 'help' for commands" "$logfile"; then
          result=success
          break
        fi
      elif grep -qF "type 'help' for commands" "$logfile" || grep -qF "login:" "$logfile"; then
        result=success
        break
      fi
    fi
  done
  print -r -- "$result"
}

# Report the capture outcome, tear the session down, and return 0 on success.
_flashos_capture_report() {
  emulate -L zsh
  local mode=$1 result=$2 logfile=$3
  local timeout=${PI_CAPTURE_TIMEOUT:-120} probe_timeout=${PI_PROBE_TIMEOUT:-30}

  case "$result" in
    success)
      _flashos_ok "\nboot successful"
      ;;
    error)
      _flashos_err "\nkernel fault: 'error caught' identified"
      ;;
    failed)
      _flashos_err "\nharness failure: a '[FAIL]' scenario was detected"
      ;;
    died)
      _flashos_err "\nscreen session died mid-capture — device disconnected or re-enumerated"
      _flashos_warn "device re-enumerated: re-run pi capture to attach to the fresh node"
      ;;
    timeout)
      if [[ "$mode" == "mu" ]]; then
        _flashos_warn "\ntimeout: no relevant kernel messages detected after ${timeout}s"
      else
        _flashos_warn "\ntimeout: enumerated, but fsh did not answer the prompt probe after ${probe_timeout}s"
        _flashos_warn "kernel faults only print on the mu adapter — try 'pi capture mu' with external power"
      fi
      ;;
  esac

  screen -S "$_FLASHOS_CAPTURE_SESSION" -X quit >/dev/null 2>&1
  print -- "session terminated"
  print -- "output saved to: $logfile"

  # On a bad outcome, show the tail of the capture so the failure is visible
  # without opening the log.
  if [[ "$result" != "success" && -s "$logfile" ]]; then
    print -- "last lines:"
    tail -n 15 "$logfile"
  fi

  if [[ ! -s "$logfile" ]]; then
    _flashos_warn "warning: $logfile is empty"
    if [[ "$mode" == "mu" ]]; then
      _flashos_warn "verify tx/rx wiring (pins 14/15) and power supply"
    else
      _flashos_warn "fsh may be wedged — power-cycle the pi and re-run"
    fi
  fi

  [[ "$result" == "success" ]]
}

# Capture the Pi console until boot success is confirmed, then close the session.
#   pi capture        usb mode (default): wait for the CDC gadget to enumerate
#                     on /dev/cu.usbmodem*, then wait for the homescreen marker
#                     (`type 'help' for commands`) — or, on a clean shipping
#                     kernel, the password-gated `login:` prompt
#   pi capture mu     mini-UART mode: capture /dev/cu.usbserial-* until the
#                     harness prints its `N/N passed` tally (green; the shipping
#                     kernel then waits at the real `login:` prompt) or a
#                     `[FAIL]` / `ERROR CAUGHT:` appears
# Kernel faults always print on the MU adapter, never on USB — use mu mode
# (trace adapter + external non-host power) for fault diagnosis.
_flashos_pi_capture() {
  emulate -L zsh
  local mode="${1:-usb}"
  case "$mode" in
    usb|mu) ;;
    *)
      _flashos_err "pi capture: unknown target '$mode' (usb|mu)"
      return 1
      ;;
  esac

  local logfile="$_FLASHOS_DIR/boot.log"
  local session="$_FLASHOS_CAPTURE_SESSION"
  local device result

  device="$(_flashos_capture_acquire "$mode")" || return 1
  rm -f -- "$logfile"
  _flashos_capture_screen_start "$session" "$device" "$logfile" || return 1

  if [[ "$mode" == "mu" ]]; then
    result="$(_flashos_capture_wait_mu "$logfile")"
  else
    result="$(_flashos_capture_wait_usb "$session" "$logfile")"
  fi

  _flashos_capture_report "$mode" "$result" "$logfile"
}

# pi <verb> — dispatcher for the serial-console helpers above.
_flashos_pi_usage() {
  print -- "usage: pi <verb> [args]"
  print -- "  connect [usb|mu|auto]   attach an interactive screen session (default: auto)"
  print -- "  capture [usb|mu]        capture boot.log until success/fault (default: usb)"
  print -- "  list                    list attached console devices"
  print -- "  log                     page the last boot.log capture"
  print -- "  tail [N]                live-tail the last boot.log (default: 40 lines)"
  print -- "  quit                    kill the detached capture session"
}

pi() {
  emulate -L zsh
  local verb="${1:-help}"
  (( $# > 0 )) && shift
  case "$verb" in
    connect) _flashos_pi_connect "$@" ;;
    capture) _flashos_pi_capture "$@" ;;
    list)    _flashos_pi_list "$@" ;;
    log)     _flashos_pi_log "$@" ;;
    tail)    _flashos_pi_tail "$@" ;;
    quit)    _flashos_pi_quit "$@" ;;
    help|-h|--help) _flashos_pi_usage ;;
    *)
      _flashos_err "pi: unknown verb '$verb'"
      _flashos_pi_usage >&2
      return 1
      ;;
  esac
}

# Legacy flat names — kept so existing docs, scripts, and muscle memory keep
# working. Prefer the `pi <verb>` form; these forward to the same impls.
piconnect() { _flashos_pi_connect "$@"; }
picapture() { _flashos_pi_capture "$@"; }
pilist()    { _flashos_pi_list "$@"; }
piquit()    { _flashos_pi_quit "$@"; }

# ── run domain: build + emulate/run ────────────────────────────────────────

# Two-pass kernel build orchestrator.
#   build               rpi4b build (two-pass)
#   build -d            build and deploy to SD card
#   build help          show usage information
#   BOARD=virt build    virt build (deploy skipped)
#   NM=llvm-nm build    override the nm binary
_flashos_build_usage() {
  print -- "usage: build [args...]"
  print -- "  -d                  build and deploy to SD card (rpi4b only)"
  print -- "  help                show this usage information"
  print -- "  [xtask flags...]    passed to cargo xtask build/populate-syms"
}

build() {
  emulate -L zsh

  # Check if help flag is present anywhere in the arguments
  if (( ${@[(I)help]} )) || (( ${@[(I)-h]} )) || (( ${@[(I)--help]} )); then
    _flashos_build_usage
    print -- ""
    print -- "--- cargo xtask options ---"
    _flashos_cargo xtask help
    return 0
  fi

  _flashos_root zsh -c '
    set -euo pipefail

    local BOARD="${BOARD:-rpi4b}"
    local DEPLOY=0
    local -a XTASK_ARGS=()

    # Keep the historical -Dboard= spelling as a compatibility alias while
    # forwarding every other flag to the native xtask build.
    for arg in "$@"; do
      if [[ "$arg" == "-d" ]]; then
        DEPLOY=1
      elif [[ "$arg" == -Dboard=* ]]; then
        BOARD="${arg#-Dboard=}"
      elif [[ "$arg" == --board=* ]]; then
        BOARD="${arg#--board=}"
      else
        XTASK_ARGS+=("$arg")
      fi
    done

    print -- "BOARD: $BOARD"

    local RED="\033[0;31m"
    local GREEN="\033[0;32m"
    local YELLOW="\033[1;33m"
    local NC="\033[0m"

    # rust-toolchain.toml is the pin; bypass any package-manager Rust earlier
    # on PATH and run the exact channel through rustup.
    local RUST_CHANNEL="$(awk -F\" "/^channel = / { print \$2; exit }" rust-toolchain.toml)"
    if [[ -z "$RUST_CHANNEL" ]] || ! command -v rustup >/dev/null 2>&1; then
      print -- "${RED}error: cannot resolve the pinned rustup toolchain.${NC}"
      exit 1
    fi
    local RUSTC_BIN="$(rustup which --toolchain "$RUST_CHANNEL" rustc)"
    export PATH="${RUSTC_BIN:h}:$PATH"

    local KERNEL_ELF="rust-out/$BOARD/kernel8.elf"
    local KERNEL_IMG="rust-out/$BOARD/kernel8.img"
    local -a CARGO=(rustup run "$RUST_CHANNEL" cargo)
    local RUST_SYSROOT="$(rustup run "$RUST_CHANNEL" rustc --print sysroot)"
    local HOST_TRIPLE="$(rustup run "$RUST_CHANNEL" rustc -vV | awk "/^host:/ { print \$2 }")"
    local NM_BIN="${NM:-$RUST_SYSROOT/lib/rustlib/$HOST_TRIPLE/bin/llvm-nm}"

    # Pre-flight 1: Ensure nm (symbol extraction tool) is installed
    if ! command -v "$NM_BIN" >/dev/null 2>&1; then
      print -- "${RED}error: $NM_BIN not found in PATH (set \$NM to override).${NC}"
      exit 1
    fi

    # Pre-flight 2: Verify execution from project root
    if [[ ! -f Cargo.toml || ! -f rust-toolchain.toml ]]; then
      print -- "${RED}error: Cargo.toml/rust-toolchain.toml not found — build must run from the project root.${NC}"
      exit 1
    fi

    # Create a temporary directory for symbol diffs. Auto-cleaned on exit (even on failure).
    local NM_TMPDIR=$(mktemp -d -t flashos_build.XXXXXX)
    trap "rm -rf \"$NM_TMPDIR\"" EXIT

    # Helper: Runs a command in the background, showing a loading animation
    # and hiding output unless an error occurs.
    run_task() {
        local task_name="$1"
        shift
        local logfile="$NM_TMPDIR/step.log"

        # Start command in background
        "$@" > "$logfile" 2>&1 &
        local pid=$!

        if [[ -t 1 ]]; then
            local -a dots=( ".  " ".. " "..." "   " )
            local i=1

            # Animate while the background process is running (tty only)
            while kill -0 $pid 2>/dev/null; do
                printf "\r\033[K[ ${YELLOW}%s${NC} ] %s" "${dots[i]}" "$task_name"
                i=$(( (i % 4) + 1 ))
                sleep 0.2
            done
        fi

        # Wait for the exact exit code. || exit_code=$? prevents set -e from aborting the script.
        local exit_code=0
        wait $pid || exit_code=$?

        # In a pipe/CI/editor (non-tty), emit plain result lines without the
        # \r\033[K animation control codes that would otherwise garble logs.
        local clear_seq=""
        [[ -t 1 ]] && clear_seq="\r\033[K"

        if (( exit_code == 0 )); then
            # Use exactly "[ OK ]" as requested.
            printf "${clear_seq}[ ${GREEN}OK${NC} ] %s\n" "$task_name"
            if [[ -s "$logfile" ]]; then
                cat "$logfile"
            fi
        else
            printf "${clear_seq}[ ${RED}ERR${NC} ] %s\n" "$task_name"
            cat "$logfile"
            exit 1
        fi
    }

    save_first_pass() {
        "$NM_BIN" -n "$KERNEL_ELF" | sort | grep -v "[\$]" > "$NM_TMPDIR/nmfirstpass"
    }

    save_second_pass() {
        "$NM_BIN" -n "$KERNEL_ELF" | sort | grep -v "[\$]" > "$NM_TMPDIR/nmsecondpass"
    }

    check_diff() {
        diff "$NM_TMPDIR/nmfirstpass" "$NM_TMPDIR/nmsecondpass"
    }

    deploy_to_sd() {
        local FIRMWARE="${FIRMWARE:-firmware}"
        # Refuse to wipe anything that is not the explicitly mounted FAT card.
        if ! mount | grep -q " on $SD_BOOT (msdos"; then
            print -u2 -- "error: $SD_BOOT is not a mounted FAT32 volume — refusing to wipe it"
            return 1
        fi
        rm -rf "$SD_BOOT"/*
        cp "$KERNEL_IMG" rust-out/rpi4b/armstub8.bin config.txt "$SD_BOOT/"
        cp "$FIRMWARE/bcm2711-rpi-4-b.dtb" "$SD_BOOT/"
        cp "$FIRMWARE/start4.elf" "$SD_BOOT/"
        cp "$FIRMWARE/fixup4.dat" "$SD_BOOT/"
        mkdir -p "$SD_BOOT/overlays"
        cp "$FIRMWARE/overlays/miniuart-bt.dtbo" "$SD_BOOT/overlays/"
        dd if=/dev/zero of="$SD_BOOT/ROUNDTR.DAT" bs=4096 count=1 2>/dev/null
        dd if=/dev/zero of="$SD_BOOT/ROUNDTR.MAG" bs=1 count=1 2>/dev/null
        : > "$SD_BOOT/EMPTY.TXT"
        cp rust-out/initramfs-stage/etc/shadow "$SD_BOOT/SHADOW"
        cp user_space/etc/perms.tab "$SD_BOOT/PERMS.TAB"
        rm -f "$SD_BOOT"/._ROUNDTR* "$SD_BOOT"/._EMPTY* \
              "$SD_BOOT"/._SHADOW "$SD_BOOT"/._PERMS* 2>/dev/null || true
        sync
        diskutil eject "$SD_BOOT"
    }

    # --- Core Two-Pass Build Pipeline ---
    # 1. First pass linking -> 2. Symbol layout generation -> 3. Final linking -> 4. Verification
    run_task "clean build cache" "${CARGO[@]}" xtask clean
    run_task "check hygiene" "${CARGO[@]}" xtask check-hygiene
    run_task "link kernel (pass 1: initial)" "${CARGO[@]}" xtask build --board "$BOARD" "${XTASK_ARGS[@]}"
    run_task "extract symbol table (pass 1)" save_first_pass
    run_task "generate layout (src/symbol_area.S)" "${CARGO[@]}" xtask populate-syms --board "$BOARD" "${XTASK_ARGS[@]}"
    run_task "link kernel (pass 2: final)" "${CARGO[@]}" xtask build --board "$BOARD" "${XTASK_ARGS[@]}"
    run_task "extract symbol table (pass 2)" save_second_pass
    run_task "verify symbol layout consistency" check_diff
    [[ "$BOARD" == "rpi4b" ]] && run_task "build armstub" "${CARGO[@]}" xtask armstub

    if [[ "$BOARD" != "rpi4b" ]]; then
        printf "[ ${YELLOW}SKIP${NC} ] deploy (board=$BOARD, rpi4b-only)\n"
    elif (( DEPLOY == 1 )); then
        run_task "deploy to SD card" deploy_to_sd
    else
        printf "[${YELLOW}SKIP${NC}] deploy (run with -d to deploy)\n"
    fi

    print -- "[ \033[0;32mOK\033[0m ] Build successful"
  ' _ "$@"
}

# run <mode> — build-and-run a board in QEMU, run the boot-watchdog, or attach
# to real hardware.
_flashos_run_usage() {
  print -- "usage: run [qemu|virt|test|watchdog|hw|auto] [xtask flags...]"
  print -- "  qemu                rpi4b board in QEMU (default via 'auto')"
  print -- "  virt                qemu virt board (FROZEN 2026-06-17 — deprioritized; still builds)"
  print -- "  test                host unit tests   (--NAME filters by test name, e.g. run test --fat32)"
  print -- "  watchdog [virt|rpi4b]  boot-watchdog; always seeds login + selftest (default: rpi4b)"
  print -- "  hw                  attach to the Raspberry Pi over serial (pi connect; --trace = MU adapter)"
  print -- "  auto                alias for qemu"
}

run() {
  emulate -L zsh
  local mode="${1:-auto}"
  (( $# > 0 )) && shift
  case "$mode" in
    qemu|auto)
      _flashos_cargo xtask build --board rpi4b "$@" || return 1
      _flashos_root sh scripts/make_test_disk.sh \
        rust-out/initramfs-stage/etc/shadow user_space/etc/perms.tab || return 1
      _flashos_root qemu-system-aarch64 \
        -M raspi4b -display none -serial null -serial stdio \
        -kernel rust-out/rpi4b/kernel8.img \
        -drive if=sd,file=rust-out/test_sd.img,format=raw
      ;;
    virt)
      _flashos_warn "virt is FROZEN (deprioritized); rpi4b + HW are the live gates"
      _flashos_cargo xtask build --board virt "$@" || return 1
      _flashos_root qemu-system-aarch64 \
        -M virt,gic-version=3 -cpu cortex-a72 -m 1G -nographic \
        -kernel rust-out/virt/kernel8.img
      ;;
    test)
      # A bare `--NAME` is sugar for the host-test substring filter
      # (`run test --fat32` -> `cargo test … fat32`).
      local -a targs=() a
      for a in "$@"; do
        case "$a" in
          --help) targs+=(--help) ;;
          --?*)   targs+=("${a#--}") ;;
          *)      targs+=("$a") ;;
        esac
      done
      if (( ${#targs[@]} == 0 )); then
        _flashos_cargo xtask test
      else
        _flashos_cargo test --workspace --exclude flashos-canary \
          --exclude flashos-klib "${targs[@]}"
      fi
      ;;
    watchdog|check)
      # The watchdog hangs to its FULL timeout unless the kernel is built with
      # BOTH --ci-login-seed (auto-auth past the login: prompt) AND
      # --boot-selftest (the in-kernel test
      # scenarios the contract counts). Missing either flag rides the timeout —
      # and on rpi4b that is ~12 min of TCG. Bake both in so
      # the footgun cannot happen. Defaults to rpi4b (the live board); virt
      # is frozen as of 2026-06-17 (deprioritized) but still an explicit opt-in.
      local wb="${1:-rpi4b}" timeout
      (( $# > 0 )) && shift
      case "$wb" in
        virt)  timeout=60
               _flashos_warn "virt watchdog: board is FROZEN (deprioritized 2026-06-17); rpi4b + HW are the live gates" ;;
        rpi4b) timeout=720
               _flashos_warn "rpi4b watchdog: ~5-8 min of TCG (720s ceiling)" ;;
        *) _flashos_err "run watchdog: unknown board '$wb' (virt|rpi4b)"; return 1 ;;
      esac
      _flashos_cargo xtask build --board "$wb" \
        --ci-login-seed --boot-selftest "$@" || return 1
      if [[ "$wb" == "rpi4b" ]]; then
        _flashos_root sh scripts/make_test_disk.sh \
          rust-out/initramfs-stage/etc/shadow user_space/etc/perms.tab || return 1
        _flashos_root scripts/run_qemu_test.sh "$timeout" qemu-system-aarch64 \
          -M raspi4b -display none -serial null -serial stdio \
          -kernel rust-out/rpi4b/kernel8.img \
          -drive if=sd,file=rust-out/test_sd.img,format=raw
      else
        _flashos_root scripts/run_qemu_test.sh "$timeout" qemu-system-aarch64 \
          -M virt,gic-version=3 -cpu cortex-a72 -m 1G -nographic \
          -kernel rust-out/virt/kernel8.img
      fi
      local rc=$?
      # run_qemu_test.sh is silent on success — QEMU output goes to a temp log it
      # deletes on exit, and only a FAIL dumps the tail. Without an explicit
      # verdict a green run is indistinguishable from a no-op (e.g. a cache
      # skip), so print one keyed on the exit status.
      if (( rc == 0 )); then
        _flashos_ok "watchdog $wb: PASS — boot contract satisfied (rc=0)"
      else
        _flashos_err "watchdog $wb: FAIL (rc=$rc) — see the log tail above"
      fi
      return $rc
      ;;
    hw)
      # `--trace` (or `--Trace`) selects the Mini-UART adapter that carries the
      # bring-up trace; everything else forwards to `pi connect` (usb|mu|auto).
      local -a hargs=() a
      for a in "$@"; do
        case "$a" in
          --trace|--Trace) hargs+=(mu) ;;
          *)               hargs+=("$a") ;;
        esac
      done
      _flashos_pi_connect "${hargs[@]:-auto}"
      ;;
    help|-h|--help) _flashos_run_usage ;;
    *)
      _flashos_err "run: unknown mode '$mode'"
      _flashos_run_usage >&2
      return 1
      ;;
  esac
}

# ── introspection ──────────────────────────────────────────────────────────

# List the public shell helpers and the cargo xtask commands. Named `flashos` rather
# than `help` so sourcing this file does not clobber a user's `help`/`run-help`.
flashos() {
  emulate -L zsh
  local project_file="$_FLASHOS_DIR/flashos.zsh"
  local cargo_file="$_FLASHOS_DIR/Cargo.toml"

  # Only the public surface — internal _flashos_* helpers start with '_'.
  print -- "--- shell functions (flashos.zsh) ---"
  if [[ -f "$project_file" ]]; then
    grep -E '^[[:alpha:]][[:alnum:]_-]*\(\)' "$project_file" | sed 's/().*//'
  else
    _flashos_err "not found: $project_file"
  fi

  print -- "\n--- cargo xtask commands ---"
  if [[ -f "$cargo_file" ]]; then
    _flashos_cargo xtask help
  else
    _flashos_err "not found: $cargo_file"
  fi
}

# ── completion ──────────────────────────────────────────────────────────────
# zsh tab-completion for the pi/run verb dispatchers. compinit runs from
# ~/.zshrc before this file is sourced, so compdef is defined by the time we
# get here; the $+functions guard keeps the file safe to source in a shell
# where it is not.
_flashos_pi_completion() {
  local -a verbs=(
    'connect:attach an interactive screen session'
    'capture:capture boot.log until success/fault'
    'list:list attached console devices'
    'log:page the last boot.log capture'
    'tail:live-tail the last boot.log'
    'quit:kill the detached capture session'
    'help:usage'
  )
  if (( CURRENT == 2 )); then
    _describe -t verbs 'pi verb' verbs
  elif (( CURRENT == 3 )); then
    case "${words[2]}" in
      connect) _values 'target' usb mu auto ;;
      capture) _values 'mode' usb mu ;;
    esac
  fi
}

_flashos_run_completion() {
  local -a modes=(
    'qemu:rpi4b board in QEMU'
    'virt:qemu virt board'
    'test:host unit tests (--NAME filters)'
    'watchdog:boot-watchdog (seeds login + selftest)'
    'hw:attach to the Pi over serial'
    'auto:alias for qemu'
    'help:usage'
  )
  if (( CURRENT == 2 )); then
    _describe -t modes 'run mode' modes
  elif (( CURRENT == 3 )); then
    case "${words[2]}" in
      watchdog|check) _values 'board' virt rpi4b ;;
      hw)             _values 'target' usb mu auto --trace ;;
    esac
  fi
}

_flashos_build_completion() {
  local -a args=(
    '-d:build and deploy to SD card'
    'help:usage'
  )
  if (( CURRENT == 2 )); then
    _describe -t args 'build flag' args
  fi
}

if (( $+functions[compdef] )); then
  compdef _flashos_pi_completion pi
  compdef _flashos_run_completion run
  compdef _flashos_build_completion build
fi
