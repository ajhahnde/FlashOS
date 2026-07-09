# FlashOS shell helpers. Source from ~/.zshrc:
#   [[ -f /path/to/FlashOS/flashos.env.zsh ]] && source /path/to/FlashOS/flashos.env.zsh
#
# Public interface — two verb dispatchers plus a build wrapper:
#   pi    connect|capture|list|quit|log|tail   serial-console helpers (Raspberry Pi)
#   run   qemu|virt|test|watchdog|hw|auto       build-and-run a board, the boot-watchdog, or attach to HW
#   port  check|diff|gates|pin                  Flash-port helpers (transpile, review-diff, gate battery)
#   build                                       two-pass kernel build (wraps ./build.sh)
#   flashos                                     list shell helpers + zig build steps
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

# Default mount point for `zig build deploy`. Override per-shell with
# SD_BOOT=/Volumes/OTHER zig build deploy.
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
  # an empty line is a no-op dispatch), and watch for the one-time boot marker
  # `type 'help' for commands` — the same interactive-REPL signal run_qemu_test.sh
  # and mu-mode trust. The shell prompt is `# ` / `$ `; it never prints `>>> `.
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
    if [[ -f "$logfile" ]] && grep -qF "type 'help' for commands" "$logfile"; then
      result=success
      break
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
#                     (`type 'help' for commands`)
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
#   build -clean-stack  clear the build history stack
#   build -t            show both stacks (img, elf) as a tree
#   build -s <stack> <id>     show stats (creation date, etc.) for a specific build ID in a stack (img/elf)
#   build help          show usage information
#   BOARD=virt build    virt build (deploy skipped)
#   NM=llvm-nm build    override the nm binary
#
# NOTE on Caching: This wrapper manages the rotating .build_history stack.
# The actual Zig compiler cache (.zig-cache) is wiped automatically to prevent bloat.
_flashos_build_usage() {
  print -- "usage: build [args...]"
  print -- "  -d                  build and deploy to SD card (rpi4b only)"
  print -- "  -clean-stack        clear the build history stack (.build_history)"
  print -- "  -t                  show both stacks (img, elf) as a tree"
  print -- "  -s <stack> <id>     show stats (creation date, etc.) for a specific build ID in a stack (img/elf)"
  print -- "  help                show this usage information"
  print -- "  [zig args...]       passed transparently to the underlying build passes"
}

build() {
  emulate -L zsh

  # Check if help flag is present anywhere in the arguments
  if (( ${@[(I)help]} )) || (( ${@[(I)-h]} )) || (( ${@[(I)--help]} )); then
    _flashos_build_usage
    print -- ""
    print -- "--- zig build options ---"
    _flashos_root zig build --help
    return 0
  fi

  # Check if -clean-stack is present anywhere in the arguments
  if (( ${@[(I)-clean-stack]} )); then
    _flashos_root zsh -c '
      rm -rf .build_history
      print -- "[ \033[0;32mOK\033[0m ] Build history stack cleared"
    '
    return 0
  fi

  if (( ${@[(I)-t]} )); then
    _flashos_root zsh -c '
      if command -v tree >/dev/null 2>&1; then
        tree .build_history
      else
        print -- "tree command not found, falling back to ls:"
        ls -R -lh .build_history
      fi
    '
    return 0
  fi

  local idx_s=${@[(I)-s]}
  if (( idx_s > 0 )); then
    local stack="${@[$((idx_s + 1))]}"
    local id="${@[$((idx_s + 2))]}"
    if [[ -z "$stack" || -z "$id" ]]; then
      print -- "usage: build -s <img|elf> <id>"
      return 1
    fi
    _flashos_root zsh -c '
      local s=$1
      local i=$2
      local search_dir
      case "$s" in
        img) search_dir="img" ;;
        elf) search_dir="elf" ;;
        *) print -- "Unknown stack: $s (must be img or elf)"; return 1 ;;
      esac

      local target=(.build_history/*/$search_dir/*${i}*(N))
      if (( ${#target[@]} > 0 )); then
        print -- "--- Stats for $s (ID: $i) ---"
        for t in "${target[@]}"; do
          print -- "Board: ${t:h:h:t}"
          # macOS stat -x provides detailed creation/modification output
          stat -x "$t" 2>/dev/null || stat "$t" 2>/dev/null || ls -lhd "$t"
          print -- ""
        done
      else
        print -- "Not found: No entry for ID $i in .build_history/*/$search_dir"
        return 1
      fi
    ' _ "$stack" "$id"
    return 0
  fi

  _flashos_root zsh -c '
    set -eo pipefail

    local BOARD="${BOARD:-rpi4b}"
    local DEPLOY=0
    local -a ZIG_ARGS=()

    # Parse arguments: extract -d for deploy, extract -Dboard, forward all others to Zig
    for arg in "$@"; do
      if [[ "$arg" == "-d" ]]; then
        DEPLOY=1
      elif [[ "$arg" == -Dboard=* ]]; then
        BOARD="${arg#-Dboard=}"
      else
        ZIG_ARGS+=("$arg")
      fi
    done

    print -- "BOARD: $BOARD"

    local RED="\033[0;31m"
    local GREEN="\033[0;32m"
    local YELLOW="\033[1;33m"
    local NC="\033[0m"

    local KERNEL_ELF="zig-out/bin/kernel8.elf"
    local NM_BIN="${NM:-aarch64-elf-nm}"

    # Pre-flight 1: Ensure nm (symbol extraction tool) is installed
    if ! command -v "$NM_BIN" >/dev/null 2>&1; then
      print -- "${RED}error: $NM_BIN not found in PATH (set \$NM to override).${NC}"
      exit 1
    fi

    # Pre-flight 2: Verify execution from project root
    if [[ ! -f .zigversion ]]; then
      print -- "${RED}error: .zigversion not found — build must run from the project root.${NC}"
      exit 1
    fi

    local REQUIRED_ZIG_VERSION="$(cat .zigversion)"
    # Pre-flight 3: check zig command exists before running it
    if ! command -v zig >/dev/null 2>&1; then
      print -- "${RED}error: zig not found in PATH.${NC}"
      exit 1
    fi
    local ACTUAL_ZIG_VERSION="$(zig version)"
    # Pre-flight 3: Strictly pin the Zig version to prevent silent compiler regressions
    if [[ "$ACTUAL_ZIG_VERSION" != "$REQUIRED_ZIG_VERSION" ]]; then
      print -- "${RED}error: flashos requires zig ${REQUIRED_ZIG_VERSION} (found ${ACTUAL_ZIG_VERSION}).${NC}"
      print -- "${YELLOW}switch with one of:${NC}"
      print -- "  zigup ${REQUIRED_ZIG_VERSION}"
      print -- "  zvm use ${REQUIRED_ZIG_VERSION}"
      print -- "  anyzig use ${REQUIRED_ZIG_VERSION}"
      exit 1
    fi

    # Create a temporary directory for symbol diffs. Auto-cleaned on exit (even on failure).
    local NM_TMPDIR=$(mktemp -d -t flashos_buildsh.XXXXXX)
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

        local -a dots=( ".  " ".. " "..." "   " )
        local i=1

        # Animate while the background process is running
        while kill -0 $pid 2>/dev/null; do
            printf "\r\033[K[ ${YELLOW}%s${NC} ] %s" "${dots[i]}" "$task_name"
            i=$(( (i % 4) + 1 ))
            sleep 0.2
        done

        # Wait for the exact exit code. || exit_code=$? prevents set -e from aborting the script.
        local exit_code=0
        wait $pid || exit_code=$?

        if (( exit_code == 0 )); then
            # Use exactly "[ OK ]" as requested.
            printf "\r\033[K[ ${GREEN}OK${NC} ] %s\n" "$task_name"
            if [[ -s "$logfile" ]]; then
                cat "$logfile"
            fi
        else
            printf "\r\033[K[ ${RED}ERR${NC} ] %s\n" "$task_name"
            cat "$logfile"
            exit 1
        fi
    }

    save_first_pass() {
        "$NM_BIN" -n "$KERNEL_ELF" | grep -v "[\$]" > "$NM_TMPDIR/nmfirstpass"
    }

    save_second_pass() {
        "$NM_BIN" -n "$KERNEL_ELF" | grep -v "[\$]" > "$NM_TMPDIR/nmsecondpass"
    }

    check_diff() {
        diff "$NM_TMPDIR/nmfirstpass" "$NM_TMPDIR/nmsecondpass"
    }

    # --- Core Two-Pass Build Pipeline ---
    # 1. First pass linking -> 2. Symbol layout generation -> 3. Final linking -> 4. Verification
    run_task "clean build cache" rm -rf .zig-cache zig-out
    run_task "check whitespace" sh scripts/check_whitespace_hygiene.sh
    run_task "check hex hygiene" sh scripts/check_hex_hygiene.sh
    run_task "link kernel (pass 1: initial)" zig build -Dboard="$BOARD" "${ZIG_ARGS[@]}"
    run_task "extract symbol table (pass 1)" save_first_pass
    run_task "generate layout (src/symbol_area.S)" zig build populate-syms -Dboard="$BOARD" -Dskip-hygiene=true "${ZIG_ARGS[@]}"
    run_task "link kernel (pass 2: final)" zig build -Dboard="$BOARD" -Dskip-hygiene=true "${ZIG_ARGS[@]}"
    run_task "extract symbol table (pass 2)" save_second_pass
    run_task "verify symbol layout consistency" check_diff

    if [[ "$BOARD" != "rpi4b" ]]; then
        printf "[ ${YELLOW}SKIP${NC} ] deploy (board=$BOARD, rpi4b-only)\n"
    elif (( DEPLOY == 1 )); then
        run_task "deploy to SD card" zig build deploy -Dboard="$BOARD" "${ZIG_ARGS[@]}"
    else
        printf "[ ${YELLOW}SKIP${NC} ] deploy (run with -d to deploy)\n"
    fi

    local hist=".build_history/$BOARD"
    mkdir -p "$hist/img" "$hist/elf"

    # 2. Check if artifacts are identical to the previous build
    if [[ -f zig-out/kernel8.img ]] && [[ -f "$hist/img/kernel8_1.img" ]] && cmp -s zig-out/kernel8.img "$hist/img/kernel8_1.img"; then
      # Update slot 1 so that the .elf debug symbols always match the current source code,
      # even if the compiled binary instructions (.img) did not change (e.g. comment changes).
      [[ -f zig-out/kernel8.img ]] && cp zig-out/kernel8.img "$hist/img/kernel8_1.img"
      [[ -f zig-out/bin/kernel8.elf ]] && cp zig-out/bin/kernel8.elf "$hist/elf/kernel8_1.elf"
      print -- "[ \033[0;32mOK\033[0m ] Build successful (Artifacts identical to previous, history unchanged)"
      return 0
    fi

    # 3. Rotate and save build history
    # Drop oldest entry (ID 5)
    rm -f "$hist/img"/kernel8_5.img "$hist/elf"/kernel8_5.elf 2>/dev/null

    # Rotate remaining entries (4->5, 3->4, 2->3, 1->2)
    for i in {4..1}; do
      local next=$((i+1))
      [[ -f "$hist/img/kernel8_$i.img" ]] && mv "$hist/img/kernel8_$i.img" "$hist/img/kernel8_$next.img"
      [[ -f "$hist/elf/kernel8_$i.elf" ]] && mv "$hist/elf/kernel8_$i.elf" "$hist/elf/kernel8_$next.elf"
    done

    # Save the new build as ID 1
    [[ -f zig-out/kernel8.img ]] && cp zig-out/kernel8.img "$hist/img/kernel8_1.img"
    [[ -f zig-out/bin/kernel8.elf ]] && cp zig-out/bin/kernel8.elf "$hist/elf/kernel8_1.elf"

    print -- "[ \033[0;32mOK\033[0m ] Build successful. Artifacts saved to stack ($hist/*_1)"
  ' _ "$@"
}

# run <mode> — build-and-run a board in QEMU, run the boot-watchdog, or attach
# to real hardware.
_flashos_run_usage() {
  print -- "usage: run [qemu|virt|test|watchdog|hw|auto] [zig args...]"
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
    qemu|auto) _flashos_root zig build -Dboard=rpi4b run "$@" ;;
    virt)      _flashos_root zig build -Dboard=virt run-virt "$@" ;;
    test)
      # A bare `--NAME` is sugar for the host-test substring filter
      # (`run test --fat32` -> `zig build test -Dtest-filter=fat32`); -D… and
      # other args pass through untouched, and `--help` reaches zig verbatim.
      local -a targs=() a
      for a in "$@"; do
        case "$a" in
          --help) targs+=(--help) ;;
          --?*)   targs+=("-Dtest-filter=${a#--}") ;;
          *)      targs+=("$a") ;;
        esac
      done
      _flashos_root zig build test "${targs[@]}"
      ;;
    watchdog|check)
      # Boot-watchdog (test-virt / test-rpi4b). It hangs to its FULL timeout
      # unless the kernel is built with BOTH -Dci-login-seed=true (auto-auth
      # past the login: prompt) AND -Dboot-selftest=true (the in-kernel test
      # scenarios the contract counts). Missing either flag rides the timeout —
      # and on rpi4b that is ~12 min of TCG. Bake both in so
      # the footgun cannot happen. Defaults to rpi4b (the live board); virt
      # is frozen as of 2026-06-17 (deprioritized) but still an explicit opt-in.
      local wb="${1:-rpi4b}" step
      (( $# > 0 )) && shift
      case "$wb" in
        virt)  step=test-virt
               _flashos_warn "virt watchdog: board is FROZEN (deprioritized 2026-06-17); rpi4b + HW are the live gates" ;;
        rpi4b) step=test-rpi4b
               _flashos_warn "rpi4b watchdog: ~5-8 min of TCG (720s ceiling)" ;;
        *) _flashos_err "run watchdog: unknown board '$wb' (virt|rpi4b)"; return 1 ;;
      esac
      _flashos_root zig build -Dboard="$wb" -Dci-login-seed=true -Dboot-selftest=true "$step" "$@"
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

# ── flash port ──────────────────────────────────────────────────────────────
# Helpers for porting modules to Flash (*.flash transpiled to Zig at build
# time). A module counts as ported only when it transpiles clean, its
# generated Zig review-diffs against the original down to mechanical lowering
# noise, and the full gate battery is green. The flashc binary resolves like
# build.zig's -Dflashc default: $FLASHC if set, else
# $HOME/Flash/zig-out/bin/flashc-stage1 (override the checkout location with
# $FLASH_DIR). The pinned compiler revision lives in flash-toolchain.lock.

_flashos_flashc() {
  local bin="${FLASHC:-${FLASH_DIR:-$HOME/Flash}/zig-out/bin/flashc-stage1}"
  if [[ ! -x "$bin" ]]; then
    _flashos_err "flashc not found: $bin (set \$FLASHC, or build the Flash checkout with 'zig build')"
    return 1
  fi
  print -- "$bin"
}

_flashos_port_check() {
  local src="$1"
  [[ -n "$src" ]] || { _flashos_err "usage: port check <module.flash>"; return 1; }
  local bin; bin="$(_flashos_flashc)" || return 1
  local tmpd; tmpd="$(mktemp -d "${TMPDIR:-/tmp}/flashport.XXXXXX")" || return 1
  if "$bin" "$src" -o "$tmpd/out.zig"; then
    _flashos_ok "transpile clean: $src"
    rm -rf "$tmpd"
  else
    rm -rf "$tmpd"
    return 1
  fi
}

_flashos_port_diff() {
  local src="$1" orig="${2:-}"
  [[ -n "$src" ]] || { _flashos_err "usage: port diff <module.flash> [original.zig]"; return 1; }
  # Default original: same directory, same stem, .zig extension. The pilot
  # already breaks that guess (hello.flash vs hello_elf.zig), so the second
  # arg stays first-class.
  [[ -n "$orig" ]] || orig="${src:r}.zig"
  if [[ ! -f "$orig" ]]; then
    _flashos_err "port diff: original not found: $orig (pass it explicitly)"
    return 1
  fi
  local bin; bin="$(_flashos_flashc)" || return 1
  local tmpd; tmpd="$(mktemp -d "${TMPDIR:-/tmp}/flashport.XXXXXX")" || return 1
  local gen="$tmpd/${src:t:r}.zig"
  if ! "$bin" "$src" -o "$gen"; then
    rm -rf "$tmpd"
    return 1
  fi
  # Lowering drops comments, so hunks are expected; the review bar is that
  # every hunk is mechanical (comments, formatting), never semantic.
  if diff -u "$orig" "$gen"; then
    _flashos_ok "port diff: generated Zig is identical to $orig"
  else
    _flashos_warn "port diff: review the hunks above — only mechanical lowering differences are acceptable"
  fi
  rm -rf "$tmpd"
}

_flashos_port_gates() {
  # The per-module gate battery: host tests, then the boot watchdog(s).
  # Fail-fast — a red gate stops the run so the log tail is the culprit's.
  local board="${1:-all}"
  case "$board" in
    virt|rpi4b|all) ;;
    *) _flashos_err "port gates: unknown board '$board' (virt|rpi4b|all)"; return 1 ;;
  esac
  run test || { _flashos_err "port gates: host tests FAILED"; return 1; }
  if [[ "$board" == virt || "$board" == all ]]; then
    run watchdog virt || return 1
  fi
  if [[ "$board" == rpi4b || "$board" == all ]]; then
    run watchdog rpi4b || return 1
  fi
  _flashos_ok "port gates: all green ($board)"
}

_flashos_port_pin() {
  # Compare flash-toolchain.lock against the live Flash checkout. The port
  # must never ride a moving compiler: drift means rebuild at the pin, or
  # bump the lock as its own deliberate commit.
  local lock="$_FLASHOS_DIR/flash-toolchain.lock"
  [[ -f "$lock" ]] || { _flashos_err "port pin: no flash-toolchain.lock in the tree (not on the port branch?)"; return 1; }
  local flash_dir="${FLASH_DIR:-$HOME/Flash}"
  local pinned live
  pinned="$(grep -E '^flash-commit' "$lock" | sed 's/.*= *//')"
  live="$(git -C "$flash_dir" rev-parse HEAD 2>/dev/null)" || {
    _flashos_err "port pin: no Flash checkout at $flash_dir (set \$FLASH_DIR)"
    return 1
  }
  if [[ "$pinned" != "$live" ]]; then
    _flashos_warn "port pin: DRIFT — lock $pinned, live $live"
    _flashos_warn "  rebuild the Flash checkout at the pin, or bump the lock in its own commit"
    return 1
  fi
  if [[ -n "$(git -C "$flash_dir" status --porcelain 2>/dev/null)" ]]; then
    _flashos_warn "port pin: commit matches but the Flash tree is DIRTY — flashc may not match the pin"
    return 1
  fi
  _flashos_ok "port pin: OK ($pinned)"
}

_flashos_port_usage() {
  print -- "usage: port [check|diff|gates|pin]"
  print -- "  check <module.flash>          transpile-only; show flashc diagnostics"
  print -- "  diff  <module.flash> [orig.zig]"
  print -- "                                transpile and diff the generated Zig against"
  print -- "                                the original (default: <stem>.zig next to it)"
  print -- "  gates [virt|rpi4b|all]        per-module gate battery: host tests, then the"
  print -- "                                boot watchdog(s); fail-fast (default: all)"
  print -- "  pin                           verify flash-toolchain.lock against the live"
  print -- "                                Flash checkout (\$FLASH_DIR, default ~/Flash)"
}

port() {
  emulate -L zsh
  local verb="${1:-help}"
  (( $# > 0 )) && shift
  case "$verb" in
    check) _flashos_port_check "$@" ;;
    diff)  _flashos_port_diff "$@" ;;
    gates) _flashos_port_gates "$@" ;;
    pin)   _flashos_port_pin "$@" ;;
    help|-h|--help) _flashos_port_usage ;;
    *)
      _flashos_err "port: unknown verb '$verb'"
      _flashos_port_usage >&2
      return 1
      ;;
  esac
}

# ── introspection ──────────────────────────────────────────────────────────

# List the public shell helpers and the zig build steps. Named `flashos` rather
# than `help` so sourcing this file does not clobber a user's `help`/`run-help`.
flashos() {
  emulate -L zsh
  local project_file="$_FLASHOS_DIR/flashos.env.zsh"
  local zig_file="$_FLASHOS_DIR/build.zig"

  # Only the public surface — internal _flashos_* helpers start with '_'.
  print -- "--- shell functions (flashos.env.zsh) ---"
  if [[ -f "$project_file" ]]; then
    grep -E '^[[:alpha:]][[:alnum:]_-]*\(\)' "$project_file" | sed 's/().*//'
  else
    _flashos_err "not found: $project_file"
  fi

  print -- "\n--- zig build steps (build.zig) ---"
  if [[ -f "$zig_file" ]]; then
    _flashos_root zig build --list-steps 2>/dev/null
  else
    _flashos_err "not found: $zig_file"
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

_flashos_port_completion() {
  local -a verbs=(
    'check:transpile-only, show flashc diagnostics'
    'diff:diff generated Zig against the original'
    'gates:host tests + boot watchdog(s), fail-fast'
    'pin:verify flash-toolchain.lock against the live checkout'
    'help:usage'
  )
  if (( CURRENT == 2 )); then
    _describe -t verbs 'port verb' verbs
  elif (( CURRENT == 3 )); then
    case "${words[2]}" in
      check|diff) _files -g '*.flash' ;;
      gates)      _values 'board' virt rpi4b all ;;
    esac
  elif (( CURRENT == 4 )); then
    case "${words[2]}" in
      diff) _files -g '*.zig' ;;
    esac
  fi
}

_flashos_build_completion() {
  local -a args=(
    '-d:build and deploy to SD card'
    '-clean-stack:clear the build history stack'
    '-t:show all three stacks (img, elf, zig) as a tree'
    '-s:show stats (creation date, etc.) for a specific build ID'
    'help:usage'
  )
  if (( CURRENT == 2 )); then
    _describe -t args 'build flag' args
  elif (( CURRENT == 3 )) && [[ "${words[2]}" == "-s" ]]; then
    local -a stacks=(img elf zig)
    _describe -t stacks 'stack' stacks
  elif (( CURRENT == 4 )) && [[ "${words[2]}" == "-s" ]]; then
    local -a ids=(1 2 3 4 5)
    _describe -t ids 'build ID' ids
  fi
}

if (( $+functions[compdef] )); then
  compdef _flashos_pi_completion pi
  compdef _flashos_run_completion run
  compdef _flashos_port_completion port
  compdef _flashos_build_completion build
fi
