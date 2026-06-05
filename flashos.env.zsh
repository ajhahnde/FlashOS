# FlashOS shell helpers. Source from ~/.zshrc:
#   [[ -f /path/to/FlashOS/flashos.env.zsh ]] && source /path/to/FlashOS/flashos.env.zsh
#
# Naming: pi*  = serial console helpers, build/showfns = project utilities.

# Resolve the directory of this file once at source time. Inside a function,
# ${0:A:h} refers to the function name, not the source file — capture it now
# while %x still points at the file being sourced.
typeset -g _FLASHOS_DIR="${${(%):-%x}:A:h}"

typeset -g _RED=$'\033[0;31m'
typeset -g _GREEN=$'\033[0;32m'
typeset -g _YELLOW=$'\033[1;33m'
typeset -g _NC=$'\033[0m'

# Screen session name shared by picapture (creates it) and piquit (kills it).
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

# Echo a console device path on stdout, or return non-zero with a message on
# stderr. $1 = NAME of an override env-var (honored verbatim if set), $2 = the
# glob to match otherwise, $3 = human label used in the not-found message.
_flashos_pick_device() {
  emulate -L zsh
  local override=${(P)1}
  if [[ -n "$override" ]]; then
    if [[ ! -e "$override" ]]; then
      print -u2 "${_RED}\$$1 ($override) does not exist${_NC}"
      return 1
    fi
    print -r -- "$override"
    return 0
  fi
  local devs=(${~2}(N))
  if (( ${#devs} == 0 )); then
    print -u2 "${_RED}no '$3' device found${_NC}"
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

# Quit the picapture screen session.
piquit() {
  emulate -L zsh
  if screen -S "$_FLASHOS_CAPTURE_SESSION" -X quit 2>/dev/null; then
    print -- "${_GREEN}picapture session terminated${_NC}"
  else
    print -u2 "${_YELLOW}no picapture session is running${_NC}"
  fi
}

# List attached console devices: the USB CDC console (fsh) and any USB-serial
# adapters (Mini-UART trace).
pilist() {
  emulate -L zsh
  local usb_devs=(${~_FLASHOS_USB_GLOB}(N))
  local mu_devs=(${~_FLASHOS_MU_GLOB}(N))
  if (( ${#usb_devs} == 0 && ${#mu_devs} == 0 )); then
    print -u2 "${_RED}no device found${_NC}"
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
#   piconnect        auto: USB CDC console (fsh) if present, else MU trace adapter
#   piconnect usb    force the USB CDC console (/dev/cu.usbmodem*)
#   piconnect mu     force the Mini-UART trace adapter (/dev/cu.usbserial-*)
# Once the gadget enumerates, fsh I/O rides USB; the MU adapter then only
# carries kernel [Debug] prints and the USB bring-up trace.
piconnect() {
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
        print -- "${_GREEN}usb console (fsh): ${device}${_NC}"
      elif device="$(_flashos_serial_device 2>/dev/null)"; then
        print -- "${_YELLOW}mu trace adapter (${device}) — kernel [Debug] only; fsh rides usb once enumerated${_NC}"
      else
        print -u2 "${_RED}no console device found (no /dev/cu.usbmodem* or /dev/cu.usbserial-*)${_NC}"
        return 1
      fi
      ;;
    *)
      print -u2 "usage: piconnect [usb|mu]"
      return 1
      ;;
  esac
  screen "$device" "$_FLASHOS_BAUD"
}

# Capture the Pi console until boot success is confirmed, then close the
# session. The log always lands at $_FLASHOS_DIR/boot.log (covered by the
# repo .gitignore), regardless of the current directory.
#   picapture        usb mode (default): wait for the CDC gadget to enumerate
#                    on /dev/cu.usbmodem*, then wait for the `[ OK ] Reached target Shell.` marker
#   picapture mu     mini-UART mode: capture /dev/cu.usbserial-* until the
#                    harness prints its `N/N passed` tally (green; the shipping
#                    kernel then waits at the real `login:` prompt) or a
#                    `[FAIL]` / `ERROR CAUGHT:` appears
# Kernel faults always print on the MU adapter, never on USB — use mu mode
# (trace adapter + external non-host power) for fault diagnosis.
picapture() {
  emulate -L zsh
  local mode="${1:-usb}"
  case "$mode" in
    usb|mu) ;;
    *)
      print -u2 "usage: picapture [usb|mu]"
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
    print -- "${_GREEN}cable detected (${device})${_NC}"
    print -- "please connect pi to power now..."
  else
    # The /dev/cu.usbmodem* node only exists once the gadget enumerates, so
    # its appearance is itself the first boot signal.
    if device="$(_flashos_usb_console_device 2>/dev/null)"; then
      print -- "${_GREEN}usb console already present (${device}) — pi appears to be running${_NC}"
    else
      print -- "plug in the C-to-C cable now (powers the pi + carries the console)..."
      print -n -- "waiting for enumeration "
      local waited=0
      while ! device="$(_flashos_usb_console_device 2>/dev/null)"; do
        sleep 1
        (( waited++ ))
        print -n -- "."
        if (( waited >= timeout )); then
          print -u2 "\n${_RED}timeout: no /dev/cu.usbmodem* appeared after ${timeout}s${_NC}"
          print -u2 "${_YELLOW}kernel faults only print on the mu adapter — try 'picapture mu' with external power${_NC}"
          return 1
        fi
      done
      print -- "\n${_GREEN}enumerated (${device})${_NC}"
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
    print -u2 "${_RED}failed to start screen session${_NC}"
    return 1
  fi

  sleep 1
  if ! screen -list | grep -q "\.${session}[[:space:]]"; then
    rm -f -- "$screenrc"
    print -u2 "${_RED}screen session failed to start; port may be occupied${_NC}"
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
        # Success = the boot reached the `login:` prompt. The shipping/deploy
        # kernel boots clean (no self-test harness unless built with
        # -Dboot-selftest) straight to the password-gated `login:`, so reaching
        # it is the boot-complete signal. A -Dboot-selftest build also prints a
        # `N/N passed` tally first; accept either. (The `[ OK ] Reached target
        # Shell.` marker cannot anchor here: the deploy kernel never auto-logs-
        # in, so it never reaches fsh on a real boot — waiting on it hangs.)
        if grep -qF "login:" "$logfile" || grep -qE "[0-9]+/[0-9]+ passed" "$logfile"; then
          result="success"
          break
        fi
      fi
    done
  else
    # Stuff a CR each second to wake/keep the session (readline submits on CR,
    # an empty line is a no-op dispatch), and watch for the one-time boot marker
    # `[ OK ] Reached target Shell.` — the same interactive-REPL signal run_qemu_test.sh
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
      if [[ -f "$logfile" ]] && grep -qF "[ OK ] Reached target Shell." "$logfile"; then
        result="success"
        break
      fi
    done
  fi

  case "$result" in
    success)
      print -- "\n${_GREEN}boot successful${_NC}"
      ;;
    error)
      print -- "\n${_RED}kernel fault: 'error caught' identified${_NC}"
      ;;
    failed)
      print -- "\n${_RED}harness failure: a '[FAIL]' scenario was detected${_NC}"
      ;;
    died)
      print -- "\n${_RED}screen session died mid-capture — device disconnected or re-enumerated${_NC}"
      print -- "${_YELLOW}device re-enumerated: re-run picapture to attach to the fresh node${_NC}"
      ;;
    timeout)
      if [[ "$mode" == "mu" ]]; then
        print -- "\n${_YELLOW}timeout: no relevant kernel messages detected after ${timeout}s${_NC}"
      else
        print -- "\n${_YELLOW}timeout: enumerated, but fsh did not answer the prompt probe after ${probe_timeout}s${_NC}"
        print -- "${_YELLOW}kernel faults only print on the mu adapter — try 'picapture mu' with external power${_NC}"
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
    print -u2 "${_YELLOW}warning: $logfile is empty${_NC}"
    if [[ "$mode" == "mu" ]]; then
      print -u2 "${_YELLOW}verify tx/rx wiring (pins 14/15) and power supply${_NC}"
    else
      print -u2 "${_YELLOW}fsh may be wedged — power-cycle the pi and re-run${_NC}"
    fi
  fi

  [[ "$result" == "success" ]]
}

# List shell helpers, zig build steps, and zig functions defined in build.zig.
showfns() {
  emulate -L zsh
  local project_file="$_FLASHOS_DIR/flashos.env.zsh"
  local zig_file="$_FLASHOS_DIR/build.zig"

  # Only the public surface — internal _flashos_* helpers start with '_'.
  print -- "--- shell functions (flashos.env.zsh) ---"
  if [[ -f "$project_file" ]]; then
    grep -E '^[[:alpha:]][[:alnum:]_-]*\(\)' "$project_file" | sed 's/().*//'
  else
    print -- "${_RED}not found: $project_file${_NC}"
  fi

  print -- "\n--- zig build steps (build.zig) ---"
  if [[ -f "$zig_file" ]]; then
    (cd "$_FLASHOS_DIR" && zig build --list-steps 2>/dev/null)
  else
    print -- "${_RED}not found: $zig_file${_NC}"
  fi

  print -- "\n--- zig src functions (build.zig) ---"
  if [[ -f "$zig_file" ]]; then
    grep -E '^(pub )?fn ' "$zig_file" | sed -E 's/.*fn ([[:alnum:]_]+).*/\1/'
  fi
}

# Two-pass kernel build — thin wrapper around ./build.sh, anchored to the
# project root so it works from any directory. All build logic (zig version
# pin, nm passes, symbol diff, deploy prompt) lives in build.sh; keep it
# there so the two can never drift apart.
#   build               rpi4b build, deploy prompt at the end
#   BOARD=virt build    virt build (deploy skipped)
#   NM=llvm-nm build    override the nm binary
build() {
  emulate -L zsh
  ( cd "$_FLASHOS_DIR" && ./build.sh "$@" )
}
