# FlashOS shell helpers. Source from ~/.zshrc:
#   [[ -f /path/to/FlashOS/flashos.env.zsh ]] && source /path/to/FlashOS/flashos.env.zsh
#
# Public interface — two verb dispatchers plus a build wrapper:
#   pi   connect|capture|list|quit    serial-console helpers (Raspberry Pi)
#   run  qemu|virt|test|hw|auto        build-and-run a board, or attach to HW
#   build                              two-pass kernel build (wraps ./build.sh)
#   help                               list shell helpers + zig build steps + build.zig fns
# Legacy flat names (piconnect/picapture/pilist/piquit/showfns) stay as thin aliases.

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

# Console serial parameters and the device-node globs the helpers match on.
# Mini-UART trace rides a USB-serial adapter (/dev/cu.usbserial-*); the USB CDC
# console (fsh) enumerates as /dev/cu.usbmodem*.
typeset -g _FLASHOS_BAUD=115200
typeset -g _FLASHOS_USB_GLOB='/dev/cu.usbmodem*'
typeset -g _FLASHOS_MU_GLOB='/dev/cu.usbserial-*'

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
  print -r -- "${devs[1]}"
}

# Mini-UART trace adapter; honors $PI_SERIAL_DEVICE.
_flashos_serial_device() {
  _flashos_pick_device PI_SERIAL_DEVICE "$_FLASHOS_MU_GLOB" "$_FLASHOS_MU_GLOB"
}

# USB CDC console (where fsh lives once the gadget enumerates); honors
# $PI_USB_CONSOLE_DEVICE.
_flashos_usb_console_device() {
  _flashos_pick_device PI_USB_CONSOLE_DEVICE "$_FLASHOS_USB_GLOB" "$_FLASHOS_USB_GLOB"
}

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

# List attached console devices: the USB CDC console (fsh) and any USB-serial
# adapters (Mini-UART trace).
_flashos_pi_list() {
  emulate -L zsh
  local usb_devs=(${~_FLASHOS_USB_GLOB}(N))
  local mu_devs=(${~_FLASHOS_MU_GLOB}(N))
  if (( ${#usb_devs} == 0 && ${#mu_devs} == 0 )); then
    _flashos_err "no device found"
    return 1
  fi
  if (( ${#usb_devs} > 0 )); then
    print -- "usb console (fsh):"
    print -l -- "  "${^usb_devs}
  fi
  if (( ${#mu_devs} > 0 )); then
    print -- "usb-serial adapter(s) (MU trace):"
    print -l -- "  "${^mu_devs}
  fi
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
        _flashos_err "no console device found (no /dev/cu.usbmodem* or /dev/cu.usbserial-*)"
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

# Capture the Pi console until boot success is confirmed, then close the
# session. The log always lands at $_FLASHOS_DIR/boot.log (covered by the
# repo .gitignore), regardless of the current directory.
#   pi capture        usb mode (default): wait for the CDC gadget to enumerate
#                     on /dev/cu.usbmodem*, then wait for the homescreen marker (`type 'help' for commands`)
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
  local timeout=${PI_CAPTURE_TIMEOUT:-120}
  local probe_timeout=${PI_PROBE_TIMEOUT:-30}
  local device

  if [[ "$mode" == "mu" ]]; then
    device="$(_flashos_serial_device)" || return 1
    _flashos_ok "cable detected (${device})"
    print -- "please connect pi to power now..."
  else
    # The /dev/cu.usbmodem* node only exists once the gadget enumerates, so
    # its appearance is itself the first boot signal.
    if device="$(_flashos_usb_console_device 2>/dev/null)"; then
      _flashos_ok "usb console already present (${device}) — pi appears to be running"
    else
      print -- "plug in the C-to-C cable now (powers the pi + carries the console)..."
      print -n -- "waiting for enumeration "
      local waited=0
      while ! device="$(_flashos_usb_console_device 2>/dev/null)"; do
        sleep 1
        (( waited++ ))
        print -n -- "."
        if (( waited >= timeout )); then
          _flashos_err "\ntimeout: no /dev/cu.usbmodem* appeared after ${timeout}s"
          _flashos_warn "kernel faults only print on the mu adapter — try 'pi capture mu' with external power"
          return 1
        fi
      done
      _flashos_ok "\nenumerated (${device})"
    fi
  fi

  rm -f -- "$logfile"
  screen -S "$session" -X quit >/dev/null 2>&1

  # macOS ships screen 4.00.03, which has no -Logfile flag; the log filename
  # comes from a screenrc `logfile` directive instead (plain -L would write
  # screenlog.0). `logfile flush 1` flushes every 1s so the live grep below
  # sees the boot marker without screen's default 10s buffering.
  local screenrc
  screenrc="$(mktemp)"
  print -r -- "logfile \"$logfile\"" > "$screenrc"
  print -r -- "logfile flush 1" >> "$screenrc"

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

  local elapsed=0
  local result="timeout"
  print -n -- "monitoring "

  if [[ "$mode" == "mu" ]]; then
    while (( elapsed < timeout )); do
      sleep 1
      (( elapsed++ ))
      print -n -- "."

      if [[ -f "$logfile" ]]; then
        # Check ERROR before success: if both appear, the error is the more
        # informative outcome.
        if grep -qF "ERROR CAUGHT:" "$logfile"; then
          result="error"
          break
        fi
        if grep -qF "[FAIL]" "$logfile"; then
          result="failed"
          break
        fi
        # Boot-complete depends on the build:
        #   * A -Dboot-selftest build runs the in-kernel suite, whose scripted
        #     `[TEST] login` scenario prints `login:` TWICE mid-run -- so a bare
        #     `login:` match fires before the suite finishes and truncates the
        #     capture. Its real completion is the 3rd homescreen marker
        #     (`type 'help' for commands`; two scripted login sessions + the
        #     real boot login), the same count run_qemu_test.sh trusts.
        #   * A clean deploy/shipping kernel has no `[TEST]` lines and never
        #     auto-logs-in, so it stops at the password-gated `login:` -- that
        #     prompt is its boot-complete signal (the homescreen marker never
        #     anchors there, so waiting on it would hang).
        if grep -qF "[TEST]" "$logfile"; then
          if [[ "$(grep -cF "type 'help' for commands" "$logfile")" -ge 3 ]]; then
            result="success"
            break
          fi
        elif grep -qF "login:" "$logfile"; then
          result="success"
          break
        fi
      fi
    done
  else
    # Stuff a CR each second to wake/keep the session (readline submits on CR,
    # an empty line is a no-op dispatch), and watch for the one-time boot marker
    # `type 'help' for commands` — the same interactive-REPL signal run_qemu_test.sh
    # and mu-mode trust. The shell prompt is `# ` / `$ `; it never prints `>>> `.
    # `-p 0` is mandatory: a born-detached (-dmS) session has no current
    # window on macOS screen 4.00.03, so -X stuff silently goes nowhere
    # without an explicit window target.
    while (( elapsed < probe_timeout )); do
      screen -S "$session" -p 0 -X stuff $'\r' >/dev/null 2>&1
      sleep 1
      (( elapsed++ ))
      print -n -- "."

      if ! screen -list 2>/dev/null | grep -q "\.${session}[[:space:]]"; then
        result="died"
        break
      fi
      if [[ -f "$logfile" ]] && grep -qF "type 'help' for commands" "$logfile"; then
        result="success"
        break
      fi
    done
  fi

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

  screen -S "$session" -X quit >/dev/null 2>&1
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

# pi <verb> — dispatcher for the serial-console helpers above.
_flashos_pi_usage() {
  print -- "usage: pi <verb> [args]"
  print -- "  connect [usb|mu|auto]   attach an interactive screen session (default: auto)"
  print -- "  capture [usb|mu]        capture boot.log until success/fault (default: usb)"
  print -- "  list                    list attached console devices"
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

# Two-pass kernel build — thin wrapper around ./build.sh, anchored to the
# project root so it works from any directory. All build logic (zig version
# pin, nm passes, symbol diff, deploy prompt) lives in build.sh; keep it
# there so the two can never drift apart.
#   build               rpi4b build, deploy prompt at the end
#   BOARD=virt build    virt build (deploy skipped)
#   NM=llvm-nm build    override the nm binary
build() {
  emulate -L zsh
  _flashos_root ./build.sh "$@"
}

# run <mode> — build-and-run a board in QEMU, or attach to real hardware.
_flashos_run_usage() {
  print -- "usage: run [qemu|virt|test|hw|auto] [zig args...]"
  print -- "  qemu   rpi4b board in QEMU (default via 'auto')"
  print -- "  virt   qemu virt board"
  print -- "  test   host unit tests   (--NAME filters by test name, e.g. run test --fat32)"
  print -- "  hw     attach to the Raspberry Pi over serial (pi connect; --trace = MU adapter)"
  print -- "  auto   alias for qemu"
}

run() {
  emulate -L zsh
  local mode="${1:-auto}"
  (( $# > 0 )) && shift
  case "$mode" in
    qemu|auto) _flashos_root zig build -Dboard=rpi4b run "$@" ;;
    virt)      _flashos_root zig build -Dboard=virt run "$@" ;;
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

# List shell helpers, zig build steps, and zig functions defined in build.zig.
help() {
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

  print -- "\n--- zig src functions (build.zig) ---"
  if [[ -f "$zig_file" ]]; then
    grep -E '^(pub )?fn ' "$zig_file" | sed -E 's/.*fn ([[:alnum:]_]+).*/\1/'
  fi
}
