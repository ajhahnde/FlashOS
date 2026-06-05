#! /usr/bin/env bash
# Two-pass kernel build orchestrator. Wraps `zig build` to:
#   1. link an initial kernel ELF,
#   2. regenerate src/symbol_area.S from its symbol table,
#   3. relink with the populated table,
#   4. verify both passes produced the same symbol layout,
#   5. optionally deploy to the SD card (rpi4b, interactive runs only).
#
# Env overrides:
#   BOARD=virt ./build.sh    build the virt board (default: rpi4b)
#   NM=llvm-nm ./build.sh    use a different nm binary

set -euo pipefail

BOARD="${BOARD:-rpi4b}"
echo "BOARD: $BOARD"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

KERNEL_ELF="zig-out/bin/kernel8.elf"
NM_BIN="${NM:-aarch64-elf-nm}"

if ! command -v "$NM_BIN" >/dev/null 2>&1; then
    echo -e "${RED}error: $NM_BIN not found in PATH (set \$NM to override).${NC}"
    exit 1
fi

# Pre-flight: Zig version must match the pin. The hard lock lives in
# build.zig (comptime check); this is the early-exit so users don't
# hit a raw Zig compile error from build.zig itself.
if [ ! -f .zigversion ]; then
    echo -e "${RED}error: .zigversion not found — build.sh must run from the project root.${NC}"
    exit 1
fi
REQUIRED_ZIG_VERSION="$(cat .zigversion)"
ACTUAL_ZIG_VERSION="$(zig version)"
if [ "$ACTUAL_ZIG_VERSION" != "$REQUIRED_ZIG_VERSION" ]; then
    echo -e "${RED}error: flashos requires zig ${REQUIRED_ZIG_VERSION} (found ${ACTUAL_ZIG_VERSION}).${NC}"
    echo -e "${YELLOW}switch with one of:${NC}"
    echo -e "  zigup ${REQUIRED_ZIG_VERSION}"
    echo -e "  zvm use ${REQUIRED_ZIG_VERSION}"
    echo -e "  anyzig use ${REQUIRED_ZIG_VERSION}"
    echo -e "${YELLOW}pin lives in .zigversion and build.zig (REQUIRED_ZIG_VERSION).${NC}"
    exit 1
fi

echo "clean"
rm -rf .zig-cache zig-out

# Stage the nm dumps in a per-run tempdir so Ctrl-C / set -e aborts
# don't leak nmfirstpass / nmsecondpass into the repo root.
NM_TMPDIR=$(mktemp -d -t flashos_buildsh.XXXXXX)
trap 'rm -rf "$NM_TMPDIR"' EXIT

echo "link kernel8.elf first pass"
zig build -Dboard="$BOARD"

echo "save first pass symbols"
"$NM_BIN" -n "$KERNEL_ELF" | sort | grep -v '\$' > "$NM_TMPDIR/nmfirstpass"

echo "generate symbol area and overwrite src/symbol_area.S"
zig build populate-syms -Dboard="$BOARD"

echo "compile symbol area and link kernel8.elf second pass"
zig build -Dboard="$BOARD"

echo "save second pass symbols"
"$NM_BIN" -n "$KERNEL_ELF" | sort | grep -v '\$' > "$NM_TMPDIR/nmsecondpass"

echo "show diff of symbols (should be nothing):"
if ! diff "$NM_TMPDIR/nmfirstpass" "$NM_TMPDIR/nmsecondpass"; then
    echo -e "${RED}error: symbol layout changed between passes.${NC}"
    exit 1
fi

# Deploy targets the rpi4b SD-card layout; skip for other boards and for
# non-interactive runs (CI, pipes) where `select` would hang.
if [ "$BOARD" != "rpi4b" ]; then
    echo "deploy skipped (board=$BOARD, deploy is rpi4b-only)"
    exit 0
fi
if [ ! -t 0 ]; then
    echo "deploy skipped (non-interactive)"
    exit 0
fi
echo -e "${YELLOW}deploy to sd card?${NC}"
select yn in "yes" "no"; do
    case $yn in
        yes ) zig build deploy -Dboard="$BOARD"; break;;
        no ) exit;;
        * ) echo "please choose 1 or 2.";;
    esac
done
