# shellcheck shell=bash
# FlashOS shell helpers for Bash and Zsh.
#
# Source this file from the shell startup file, or use flashos.zsh for Zsh
# directory-based auto-source setups:
#   source /path/to/FlashOS/flashos.sh
#
# Public interface:
#   flashos help                 complete command overview
#   flashos status|doctor        orientation and environment readiness
#   flashos build|run|smoke      normal image development loop
#   flashos recipe               focused package/recipe development
#   flashos artifacts|logs       generated output inspection
#   flashos check|qualify        host gates and end-to-end qualification
#   flashos changes|clean        read-only Git inspection and maintenance
#
# Direct flashos-* functions expose the same wrappers. This file deliberately
# does not define generic build or run functions, perform Git writes, or write
# physical devices.

if [ -n "${BASH_VERSION:-}" ]; then
  _flashos_source_path="${BASH_SOURCE[0]}"
  _FLASHOS_DIR="$(CDPATH='' cd -- "$(dirname -- "$_flashos_source_path")" && pwd -P)"
elif [ -n "${ZSH_VERSION:-}" ]; then
  eval '_flashos_source_path="${(%):-%x}"'
  # Zsh's :A modifier resolves the sourced file without cd. That matters for
  # directory-change auto-source hooks, where cd would recursively fire chpwd.
  eval '_FLASHOS_DIR="${_flashos_source_path:A:h}"'
else
  printf '%s\n' "flashos: flashos.sh supports Bash and Zsh" >&2
  # The exit is the executed-file fallback.
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi

unset _flashos_source_path

FLASHOS_ARCH="${FLASHOS_ARCH:-x86_64}"
FLASHOS_CONFIG_NAME="${FLASHOS_CONFIG_NAME:-flashos}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _FLASHOS_RED="$(printf '\033[0;31m')"
  _FLASHOS_GREEN="$(printf '\033[0;32m')"
  _FLASHOS_YELLOW="$(printf '\033[1;33m')"
  _FLASHOS_BLUE="$(printf '\033[0;34m')"
  _FLASHOS_RESET="$(printf '\033[0m')"
else
  _FLASHOS_RED=""
  _FLASHOS_GREEN=""
  _FLASHOS_YELLOW=""
  _FLASHOS_BLUE=""
  _FLASHOS_RESET=""
fi

_flashos_error() {
  printf '%s\n' "${_FLASHOS_RED}flashos: $*${_FLASHOS_RESET}" >&2
}

_flashos_warn() {
  printf '%s\n' "${_FLASHOS_YELLOW}flashos: $*${_FLASHOS_RESET}" >&2
}

_flashos_ok() {
  printf '%s\n' "${_FLASHOS_GREEN}$*${_FLASHOS_RESET}"
}

_flashos_heading() {
  printf '\n%s\n' "${_FLASHOS_BLUE}== $* ==${_FLASHOS_RESET}"
}

_flashos_root() {
  (builtin cd -- "$_FLASHOS_DIR" && "$@")
}

_flash_root() {
  (builtin cd -- "$_FLASHOS_DIR/components/flash" && "$@")
}

_flashos_make() {
  _flashos_root command make \
    "ARCH=$FLASHOS_ARCH" \
    "CONFIG_NAME=$FLASHOS_CONFIG_NAME" \
    "$@"
}

_flashos_build_dir() {
  printf '%s\n' "$_FLASHOS_DIR/build/$FLASHOS_ARCH/$FLASHOS_CONFIG_NAME"
}

_flashos_require_file() {
  if [ ! -f "$1" ]; then
    _flashos_error "required file not found: $1"
    return 1
  fi
}

_flashos_no_arguments() {
  local command_name=$1
  shift
  if [ "$#" -ne 0 ]; then
    _flashos_error "flashos $command_name accepts no arguments"
    return 1
  fi
}

# -- Profile and image workflows -------------------------------------------

flashos-profile() {
  local requested="${1:-}"

  if [ "$#" -gt 1 ]; then
    _flashos_error "flashos profile accepts at most one profile"
    return 1
  fi

  if [ -z "$requested" ]; then
    printf '%s\n' "$FLASHOS_CONFIG_NAME"
    return 0
  fi

  case "$requested" in
    dev)             requested=flashos ;;
    release)         requested=flashos-release ;;
    help|-h|--help)
      printf '%s\n' "usage: flashos profile [dev|release|CONFIG_NAME]"
      printf '%s\n' "current profile: $FLASHOS_CONFIG_NAME"
      return 0
      ;;
  esac

  local manifest="$_FLASHOS_DIR/config/$FLASHOS_ARCH/$requested.toml"
  if [ ! -f "$manifest" ]; then
    _flashos_error "profile does not exist: ${manifest#"$_FLASHOS_DIR/"}"
    return 1
  fi

  FLASHOS_CONFIG_NAME="$requested"
  printf '%s\n' "FlashOS profile: $FLASHOS_CONFIG_NAME"
}

flashos-version() {
  local version_file="$_FLASHOS_DIR/versions.env"
  local version
  _flashos_no_arguments version "$@" || return 1
  _flashos_require_file "$version_file" || return 1

  version="$(sed -n 's/^FLASHOS_RELEASE_VERSION=//p' "$version_file" | head -1)"
  if [ -z "$version" ]; then
    _flashos_error "FLASHOS_RELEASE_VERSION is missing from versions.env"
    return 1
  fi
  printf '%s\n' "$version"
}

flashos-env() {
  _flashos_make setenv "$@"
}

flashos-build() {
  local mode=disk
  case "${1:-}" in
    disk|live|both|rebuild)
      mode=$1
      shift
      ;;
    help|-h|--help)
      printf '%s\n' "usage: flashos build [disk|live|both|rebuild] [make arguments]"
      printf '%s\n' "profile: $FLASHOS_CONFIG_NAME  arch: $FLASHOS_ARCH"
      return 0
      ;;
    ""|-*) ;;
    *)
      _flashos_error "unknown build mode: $1 (expected disk, live, both, or rebuild)"
      return 1
      ;;
  esac

  case "$mode" in
    disk)    _flashos_make all "$@" ;;
    live)    _flashos_make live "$@" ;;
    both)    _flashos_make all "$@" && _flashos_make live "$@" ;;
    rebuild) _flashos_make rebuild "$@" ;;
  esac
}

flashos-run() {
  local mode=disk
  case "${1:-}" in
    disk|live)
      mode=$1
      shift
      ;;
    help|-h|--help)
      printf '%s\n' "usage: flashos run [disk|live] [make arguments]"
      return 0
      ;;
    ""|-*) ;;
    *)
      _flashos_error "unknown run mode: $1 (expected disk or live)"
      return 1
      ;;
  esac

  case "$mode" in
    disk) _flashos_make qemu live=no "$@" ;;
    live) _flashos_make qemu live=yes "$@" ;;
  esac
}

_flashos_smoke_one() {
  local mode=$1
  local build_dir image interface log
  shift

  build_dir="$(_flashos_build_dir)"
  case "$mode" in
    disk)
      image="$build_dir/harddrive.img"
      interface=nvme
      log="$build_dir/qemu-harddrive-smoke.log"
      ;;
    live)
      image="$build_dir/redox-live.iso"
      interface=usb
      log="$build_dir/qemu-live-usb-smoke.log"
      ;;
    *)
      _flashos_error "unknown smoke mode: $mode"
      return 1
      ;;
  esac

  _flashos_require_file "$image" || {
    _flashos_error "build it first with: flashos build $mode"
    return 1
  }

  if [ "$FLASHOS_CONFIG_NAME" = flashos-release ]; then
    _flashos_root command python3 ci/qemu_smoke.py \
      --image "$image" \
      --disk-interface "$interface" \
      --log "$log" \
      --expect-root-locked \
      "$@"
  else
    _flashos_root command python3 ci/qemu_smoke.py \
      --image "$image" \
      --disk-interface "$interface" \
      --log "$log" \
      "$@"
  fi
}

flashos-smoke() {
  local mode="${1:-disk}"
  [ "$#" -eq 0 ] || shift

  case "$mode" in
    disk) _flashos_smoke_one disk "$@" ;;
    live) _flashos_smoke_one live "$@" ;;
    all)  _flashos_smoke_one disk "$@" && _flashos_smoke_one live "$@" ;;
    help|-h|--help)
      printf '%s\n' "usage: flashos smoke [disk|live|all] [qemu_smoke.py arguments]"
      ;;
    *)
      _flashos_error "unknown smoke mode: $mode (expected disk, live, or all)"
      return 1
      ;;
  esac
}

# -- Host and target quality gates -----------------------------------------

flash-check() {
  local scope="${1:-all}"
  [ "$#" -eq 0 ] || shift

  case "$scope" in
    fmt)    _flash_root command cargo fmt --all --check "$@" ;;
    clippy) _flash_root command cargo clippy --workspace --all-targets "$@" -- -D warnings ;;
    test)   _flash_root command cargo test --workspace --locked "$@" ;;
    target) _flash_root command redoxer build -p flash-cli --bin fsh "$@" ;;
    all)
      _flash_root command cargo fmt --all --check "$@" &&
        _flash_root command cargo clippy --workspace --all-targets -- -D warnings &&
        _flash_root command cargo test --workspace --locked
      ;;
    help|-h|--help)
      printf '%s\n' "usage: flashos shell [fmt|clippy|test|target|all] [arguments]"
      ;;
    *)
      _flashos_error "unknown Flash check: $scope"
      return 1
      ;;
  esac
}

_flashos_check_shell_helpers() {
  _flashos_root command python3 ci/check_developer_interface.py
}

_flashos_check_quick() {
  _flashos_check_shell_helpers &&
    _flashos_root command python3 ci/check_profile.py &&
    _flashos_root command git diff --check
}

_flashos_check_python() {
  _flashos_root command ruff check ci/ "$@" &&
    _flashos_root command python3 -m unittest discover \
      -s ci/tests -p 'test_*.py'
}

_flashos_check_root() {
  _flashos_root command cargo fmt --all --check &&
    _flashos_root command cargo test --locked
}

flashos-check() {
  local scope="${1:-quick}"
  [ "$#" -eq 0 ] || shift

  case "$scope" in
    quick)   _flashos_check_quick ;;
    profile) _flashos_root command python3 ci/check_profile.py "$@" ;;
    root)    _flashos_check_root ;;
    shell)   flash-check all "$@" ;;
    python)  _flashos_check_python "$@" ;;
    docs)    _flashos_check_docs ;;
    target)  flash-check target "$@" ;;
    ci)
      _flashos_check_quick &&
        _flashos_check_root &&
        flash-check all &&
        _flashos_check_python
      ;;
    all)
      flashos-check ci && _flashos_check_docs
      ;;
    help|-h|--help)
      printf '%s\n' \
        "usage: flashos check [quick|profile|root|shell|target|python|docs|ci|all]" \
        "" \
        "  quick    helper syntax, product profile, and whitespace" \
        "  root     root Rust workspace formatting and tests" \
        "  shell    Flash formatting, Clippy, and host tests" \
        "  target   Flash Redox target build" \
        "  python   lint FlashOS-owned Python" \
        "  docs     private documentation drift check when available" \
        "  ci       local equivalent of the host CI quality jobs" \
        "  all      CI gates plus the private documentation drift check"
      ;;
    *)
      _flashos_error "unknown check scope: $scope"
      return 1
      ;;
  esac
}

# -- Development environment and version state -----------------------------

flashos-podman() {
  local action="${1:-status}"
  [ "$#" -eq 0 ] || shift

  if ! command -v podman >/dev/null 2>&1; then
    _flashos_error "podman is not installed"
    return 1
  fi

  case "$action" in
    status)      command podman machine list "$@" ;;
    start)       command podman machine start "$@" ;;
    stop)        command podman machine stop "$@" ;;
    info)        command podman info "$@" ;;
    help|-h|--help)
      printf '%s\n' "usage: flashos podman [status|start|stop|info]"
      ;;
    *)
      _flashos_error "unknown Podman action: $action"
      return 1
      ;;
  esac
}

flashos-doctor() {
  local missing=0 tool label
  _flashos_no_arguments doctor "$@" || return 1

  _flashos_heading "FlashOS development environment"
  for tool in git make python3 cargo podman qemu-system-x86_64; do
    case "$tool" in
      qemu-system-x86_64) label="QEMU x86_64" ;;
      *)                  label="$tool" ;;
    esac
    if command -v "$tool" >/dev/null 2>&1; then
      printf '[ %sOK%s ] %-14s %s\n' \
        "$_FLASHOS_GREEN" "$_FLASHOS_RESET" "$label" "$(command -v "$tool")"
    else
      printf '[ %sMISS%s ] %s\n' \
        "$_FLASHOS_RED" "$_FLASHOS_RESET" "$label"
      missing=1
    fi
  done

  if command -v redoxer >/dev/null 2>&1; then
    printf '[ %sOK%s ] %-14s %s\n' \
      "$_FLASHOS_GREEN" "$_FLASHOS_RESET" redoxer "$(command -v redoxer)"
  else
    printf '[ %sOPT%s ] %-14s needed only for Flash target builds\n' \
      "$_FLASHOS_YELLOW" "$_FLASHOS_RESET" redoxer
  fi

  if [ -f "$_FLASHOS_DIR/.config" ]; then
    printf '[ %sOK%s ] %-14s %s\n' \
      "$_FLASHOS_GREEN" "$_FLASHOS_RESET" configuration .config
  else
    printf '[ %sMISS%s ] %-14s copy the template from SETUP.md\n' \
      "$_FLASHOS_RED" "$_FLASHOS_RESET" configuration
    missing=1
  fi

  if [ -f /usr/share/OVMF/OVMF_CODE.fd ] ||
     [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] ||
     [ -f /usr/share/edk2/ovmf/OVMF_CODE.fd ] ||
     [ -f /opt/homebrew/opt/qemu/share/qemu/edk2-x86_64-code.fd ]; then
    printf '[ %sOK%s ] %-14s found\n' \
      "$_FLASHOS_GREEN" "$_FLASHOS_RESET" OVMF/edk2
  else
    printf '[ %sMISS%s ] %-14s x86_64 firmware not found\n' \
      "$_FLASHOS_RED" "$_FLASHOS_RESET" OVMF/edk2
    missing=1
  fi

  if [ "$missing" -eq 0 ]; then
    _flashos_ok "Environment ready"
  else
    _flashos_error "environment is incomplete; see SETUP.md"
    return 1
  fi
}

flashos-versions() {
  local action="${1:-show}" version expected_tag newest_tag description distance
  [ "$#" -eq 0 ] || shift

  case "$action" in
    show)
      [ "$#" -eq 0 ] || {
        _flashos_error "flashos versions show accepts no arguments"
        return 1
      }
      version="$(flashos-version)" || return 1
      expected_tag="v$version"
      newest_tag="$(_flashos_root command git describe --tags --abbrev=0 2>/dev/null || true)"
      description="$(_flashos_root command git describe --tags --always --dirty 2>/dev/null || true)"
      printf '%s\n' "product version: $version"
      printf '%s\n' "release tag:     $expected_tag"
      printf '%s\n' "checkout:        ${description:-unknown}"
      if [ -n "$newest_tag" ]; then
        distance="$(_flashos_root command git rev-list --count "$newest_tag"..HEAD)" || return 1
        printf '%s\n' "newest tag:      $newest_tag ($distance commits behind HEAD)"
      else
        printf '%s\n' "newest tag:      none"
      fi
      ;;
    check)
      [ "$#" -eq 0 ] || {
        _flashos_error "flashos versions check accepts no arguments"
        return 1
      }
      _flashos_root command python3 ci/check_profile.py
      ;;
    help|-h|--help)
      printf '%s\n' "usage: flashos versions [show|check]"
      ;;
    *)
      _flashos_error "unknown versions action: $action"
      return 1
      ;;
  esac
}

# -- Recipe development -----------------------------------------------------

_flashos_recipe_name() {
  case "$1" in
    "")
      _flashos_error "a recipe name is required"
      return 1
      ;;
    *[!A-Za-z0-9_+.,-]*)
      _flashos_error "invalid recipe list: $1"
      return 1
      ;;
  esac
}

flashos-recipe() {
  local action="${1:-help}" recipes="${2:-}"
  [ "$#" -eq 0 ] || shift
  [ "$#" -eq 0 ] || shift

  case "$action" in
    tree)
      if [ -n "$recipes" ]; then
        _flashos_recipe_name "$recipes" || return 1
        _flashos_make "rt.$recipes" "$@"
      else
        _flashos_make repo-tree "$@"
      fi
      ;;
    image-tree)
      if [ -n "$recipes" ]; then
        _flashos_recipe_name "$recipes" || return 1
        _flashos_make "pt.$recipes" "$@"
      else
        _flashos_make image-tree "$@"
      fi
      ;;
    find|fetch|build|rebuild|clean|unfetch|push|build-push|rebuild-push)
      _flashos_recipe_name "$recipes" || return 1
      case "$action" in
        find)         _flashos_make "find.$recipes" "$@" ;;
        fetch)        _flashos_make "f.$recipes" "$@" ;;
        build)        _flashos_make "r.$recipes" "$@" ;;
        rebuild)      _flashos_make "cr.$recipes" "$@" ;;
        clean)        _flashos_make "c.$recipes" "$@" ;;
        unfetch)      _flashos_make "u.$recipes" "$@" ;;
        push)
          _flashos_warn "stop QEMU before modifying an image"
          _flashos_make "p.$recipes" "$@"
          ;;
        build-push)
          _flashos_warn "stop QEMU before modifying an image"
          _flashos_make "rp.$recipes" "$@"
          ;;
        rebuild-push)
          _flashos_warn "stop QEMU before modifying an image"
          _flashos_make "crp.$recipes" "$@"
          ;;
      esac
      ;;
    help|-h|--help)
      printf '%s\n' \
        "usage: flashos recipe <action> [recipe[,recipe...]] [make arguments]" \
        "" \
        "  find NAME          locate a recipe" \
        "  tree [NAME]        show the configured cook tree" \
        "  image-tree [NAME]  show the image push tree" \
        "  fetch NAME         fetch recipe sources" \
        "  build NAME         cook a recipe" \
        "  rebuild NAME       clean and cook a recipe" \
        "  clean NAME         clean recipe outputs" \
        "  unfetch NAME       remove fetched recipe sources" \
        "  push NAME          push a built package into the image" \
        "  build-push NAME    cook and push a package" \
        "  rebuild-push NAME  clean, cook, and push a package"
      ;;
    *)
      _flashos_error "unknown recipe action: $action"
      return 1
      ;;
  esac
}

# -- Artifacts, logs, and source inspection --------------------------------

_flashos_artifact_path() {
  local build_dir
  build_dir="$(_flashos_build_dir)"
  case "$1" in
    disk) printf '%s\n' "$build_dir/harddrive.img" ;;
    live) printf '%s\n' "$build_dir/redox-live.iso" ;;
    *)
      _flashos_error "unknown artifact: $1 (expected disk or live)"
      return 1
      ;;
  esac
}

_flashos_hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    command sha256sum "$1"
  elif command -v shasum >/dev/null 2>&1; then
    command shasum -a 256 "$1"
  else
    _flashos_error "sha256sum or shasum is required"
    return 1
  fi
}

flashos-artifacts() {
  local action="${1:-list}" artifact path build_dir size
  [ "$#" -eq 0 ] || shift
  build_dir="$(_flashos_build_dir)"

  case "$action" in
    list)
      [ "$#" -eq 0 ] || {
        _flashos_error "flashos artifacts list accepts no arguments"
        return 1
      }
      for artifact in disk live; do
        path="$(_flashos_artifact_path "$artifact")" || return 1
        if [ -f "$path" ]; then
          size="$(command du -h "$path" | awk '{print $1}')"
          printf '%-5s  %-6s  %s\n' "$artifact" "$size" "${path#"$_FLASHOS_DIR/"}"
        else
          printf '%-5s  %-6s  %s\n' "$artifact" missing "${path#"$_FLASHOS_DIR/"}"
        fi
      done
      ;;
    path)
      artifact="${1:-disk}"
      _flashos_artifact_path "$artifact"
      ;;
    hash)
      artifact="${1:-all}"
      case "$artifact" in
        all)
          for artifact in disk live; do
            path="$(_flashos_artifact_path "$artifact")" || return 1
            _flashos_require_file "$path" || return 1
            _flashos_hash_file "$path" || return 1
          done
          ;;
        disk|live)
          path="$(_flashos_artifact_path "$artifact")" || return 1
          _flashos_require_file "$path" || return 1
          _flashos_hash_file "$path"
          ;;
        *)
          _flashos_error "unknown artifact: $artifact"
          return 1
          ;;
      esac
      ;;
    help|-h|--help)
      printf '%s\n' "usage: flashos artifacts [list|path|hash] [disk|live|all]"
      ;;
    *)
      _flashos_error "unknown artifacts action: $action"
      return 1
      ;;
  esac
}

_flashos_log_path() {
  local build_dir
  build_dir="$(_flashos_build_dir)"
  case "$1" in
    disk) printf '%s\n' "$build_dir/qemu-harddrive-smoke.log" ;;
    live) printf '%s\n' "$build_dir/qemu-live-usb-smoke.log" ;;
    *)
      _flashos_error "unknown log: $1 (expected disk or live)"
      return 1
      ;;
  esac
}

flashos-logs() {
  local action="${1:-list}" mode="${2:-disk}" path build_dir
  [ "$#" -eq 0 ] || shift
  [ "$#" -eq 0 ] || shift
  build_dir="$(_flashos_build_dir)"

  case "$action" in
    list)
      command find "$build_dir" -maxdepth 1 -type f -name '*.log' -print 2>/dev/null | command sort
      ;;
    disk|live)
      path="$(_flashos_log_path "$action")" || return 1
      _flashos_require_file "$path" || return 1
      command tail -n "${FLASHOS_LOG_LINES:-80}" "$path"
      ;;
    follow)
      path="$(_flashos_log_path "$mode")" || return 1
      _flashos_require_file "$path" || return 1
      command tail -n "${FLASHOS_LOG_LINES:-80}" -f "$path"
      ;;
    help|-h|--help)
      printf '%s\n' "usage: flashos logs [list|disk|live|follow] [disk|live]"
      printf '%s\n' "set FLASHOS_LOG_LINES to change the default tail length (80)"
      ;;
    *)
      _flashos_error "unknown logs action: $action"
      return 1
      ;;
  esac
}

flashos-changes() {
  local action="${1:-status}"
  [ "$#" -eq 0 ] || shift

  case "$action" in
    status) _flashos_root command git status --short --branch "$@" ;;
    diff)   _flashos_root command git diff "$@" ;;
    stat)   _flashos_root command git diff --stat "$@" ;;
    staged) _flashos_root command git diff --cached "$@" ;;
    recent) _flashos_root command git log --oneline --decorate -n "${1:-12}" ;;
    help|-h|--help)
      printf '%s\n' "usage: flashos changes [status|diff|stat|staged|recent]"
      printf '%s\n' "this interface is read-only; it never commits, pushes, or tags"
      ;;
    *)
      _flashos_error "unknown changes action: $action"
      return 1
      ;;
  esac
}

# -- Maintenance and end-to-end qualification ------------------------------

flashos-clean() {
  local scope="${1:-help}"
  [ "$#" -eq 0 ] || shift

  case "$scope" in
    build)
      _flashos_warn "removing generated build, prefix, repository, and fstools state"
      _flashos_make clean "$@"
      ;;
    recipes)  _flashos_make repo_clean "$@" ;;
    fetches)  _flashos_make fetch_clean "$@" ;;
    container)
      _flashos_warn "removing the local FlashOS container image and state"
      _flashos_make container_clean "$@"
      ;;
    dist)
      _flashos_warn "removing all fetched and generated build state"
      _flashos_make distclean "$@"
      ;;
    help|-h|--help)
      printf '%s\n' \
        "usage: flashos clean <build|recipes|fetches|container|dist>" \
        "" \
        "No cleanup runs without an explicit scope. 'dist' is the broadest."
      ;;
    *)
      _flashos_error "unknown clean scope: $scope"
      return 1
      ;;
  esac
}

_flashos_check_docs() {
  local _drift_dir="${FLASHOS_PRIVATE_DIR:-${_FLASHOS_DIR}/.private}"
  local _drift_script="$_drift_dir/scripts/check_drift.sh"
  if [ -x "$_drift_script" ]; then
    _flashos_root command "$_drift_script"
  else
    _flashos_warn "private documentation drift checker is not present"
  fi
}

flashos-qualify() {
  local mode="${1:-all}"
  [ "$#" -le 1 ] || {
    _flashos_error "flashos qualify accepts one mode"
    return 1
  }

  case "$mode" in
    disk|live|all) ;;
    help|-h|--help)
      printf '%s\n' "usage: flashos qualify [disk|live|all]"
      printf '%s\n' "runs all local quality gates, builds, then smokes exact artifacts"
      return 0
      ;;
    *)
      _flashos_error "unknown qualification mode: $mode"
      return 1
      ;;
  esac

  _flashos_heading "Quality gates"
  flashos-check all || return 1
  _flashos_heading "Image build ($mode)"
  if [ "$mode" = all ]; then
    flashos-build both || return 1
  else
    flashos-build "$mode" || return 1
  fi
  _flashos_heading "Exact-artifact runtime ($mode)"
  flashos-smoke "$mode" || return 1
  _flashos_ok "FlashOS $mode qualification passed"
}

# -- Status, discovery, and dispatcher -------------------------------------

flashos-status() {
  local build_dir version artifact size
  _flashos_no_arguments status "$@" || return 1
  build_dir="$(_flashos_build_dir)"
  version="$(flashos-version)" || return 1

  printf '%s\n' "repository: $_FLASHOS_DIR"
  printf '%s\n' "version:    $version"
  printf '%s\n' "profile:    $FLASHOS_CONFIG_NAME"
  printf '%s\n' "arch:       $FLASHOS_ARCH"
  printf '%s\n\n' "build dir:  ${build_dir#"$_FLASHOS_DIR/"}"
  _flashos_root command git status --short --branch

  for artifact in "$build_dir/harddrive.img" "$build_dir/redox-live.iso"; do
    if [ -f "$artifact" ]; then
      size="$(command du -h "$artifact" | awk '{print $1}')"
      printf '%s\n' "artifact:   ${artifact#"$_FLASHOS_DIR/"}  $size"
    else
      printf '%s\n' "artifact:   ${artifact#"$_FLASHOS_DIR/"}  (not built)"
    fi
  done
}

flashos-list() {
  _flashos_no_arguments list "$@" || return 1
  _flashos_usage
  _flashos_heading "Direct helper functions"
  command grep -E '^(flashos(-[[:alnum:]-]+)?|flash-check|fos)\(\)' \
    "$_FLASHOS_DIR/flashos.sh" | command sed 's/().*//' | command sort -u
}

_flashos_usage() {
  printf '%s\n' \
    "usage: flashos <command> [arguments]" \
    "" \
    "Orientation" \
    "  status                    show repository, profile, and artifacts" \
    "  doctor                    validate the development environment" \
    "  version                   print the product version" \
    "  versions [show|check]     show release and tag state or check drift" \
    "  profile [dev|release]     show or select the image profile" \
    "  env [make arguments]      print the selected Make environment" \
    "" \
    "Build and runtime" \
    "  build [disk|live|both]    build one or both images" \
    "  run [disk|live]           run interactive QEMU" \
    "  smoke [disk|live|all]     smoke-test already built artifacts" \
    "  qualify [disk|live|all]   check, build, and smoke end to end" \
    "  recipe <action> [name]    find, cook, rebuild, or push recipes" \
    "" \
    "Inspection and quality" \
    "  artifacts [action]        list, locate, or hash image artifacts" \
    "  logs [action]             inspect or follow QEMU smoke logs" \
    "  changes [action]          inspect Git state without writing it" \
    "  check [scope]             run repository checks" \
    "  shell [scope]             run Flash host/target checks" \
    "" \
    "Maintenance" \
    "  podman [action]           inspect or control the Podman machine" \
    "  clean <scope>             remove an explicit generated-data scope" \
    "  root                      change to the repository root" \
    "  list                      show commands and direct helper functions" \
    "  help                      show this overview" \
    "" \
    "Commands with modes, actions, or scopes accept command-specific help."
}

flashos() {
  local command_name="${1:-help}"
  [ "$#" -eq 0 ] || shift

  case "$command_name" in
    status)           flashos-status "$@" ;;
    doctor)           flashos-doctor "$@" ;;
    version)          flashos-version "$@" ;;
    versions)         flashos-versions "$@" ;;
    profile)          flashos-profile "$@" ;;
    env)              flashos-env "$@" ;;
    build)            flashos-build "$@" ;;
    run)              flashos-run "$@" ;;
    smoke)            flashos-smoke "$@" ;;
    qualify)          flashos-qualify "$@" ;;
    recipe)           flashos-recipe "$@" ;;
    artifacts)        flashos-artifacts "$@" ;;
    logs)             flashos-logs "$@" ;;
    changes)          flashos-changes "$@" ;;
    check)            flashos-check "$@" ;;
    shell)            flash-check "$@" ;;
    podman)           flashos-podman "$@" ;;
    clean)            flashos-clean "$@" ;;
    root)
      _flashos_no_arguments root "$@" || return 1
      builtin cd -- "$_FLASHOS_DIR" || return 1
      ;;
    list)             flashos-list "$@" ;;
    help|-h|--help)
      _flashos_no_arguments help "$@" || return 1
      _flashos_usage
      ;;
    *)
      _flashos_error "unknown command: $command_name"
      _flashos_usage >&2
      return 1
      ;;
  esac
}

fos() {
  flashos "$@"
}

if [ -n "${BASH_VERSION:-}" ] && command -v complete >/dev/null 2>&1; then
  _flashos_bash_completion() {
    local current previous choices
    current="${COMP_WORDS[COMP_CWORD]}"
    previous="${COMP_WORDS[COMP_CWORD-1]}"

    if [ "$COMP_CWORD" -eq 1 ]; then
      choices="status doctor version versions profile env build run smoke qualify recipe artifacts logs changes check shell podman clean root list help"
    else
      case "$previous" in
        profile) choices="dev release" ;;
        versions) choices="show check" ;;
        build)   choices="disk live both rebuild" ;;
        run)     choices="disk live" ;;
        smoke)   choices="disk live all" ;;
        qualify) choices="disk live all" ;;
        recipe) choices="find tree image-tree fetch build rebuild clean unfetch push build-push rebuild-push" ;;
        artifacts) choices="list path hash" ;;
        logs) choices="list disk live follow" ;;
        changes) choices="status diff stat staged recent" ;;
        check)   choices="quick profile root shell target python docs ci all" ;;
        shell)   choices="fmt clippy test target all" ;;
        podman)  choices="status start stop info" ;;
        clean) choices="build recipes fetches container dist" ;;
        *)       choices="" ;;
      esac
    fi

    # Word splitting is intentional: compgen consumes the choice list. This
    # stays compatible with the Bash 3.2 still shipped by macOS.
    # shellcheck disable=SC2207
    COMPREPLY=($(compgen -W "$choices" -- "$current"))
  }
  complete -F _flashos_bash_completion flashos fos
fi
