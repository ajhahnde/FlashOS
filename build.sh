#! /usr/bin/env bash
# Two-pass kernel build orchestrator. Wraps `zig build` so we can:
#   1. link an initial kernel ELF,
#   2. regenerate src/symbol_area.S from its symbol table,
#   3. relink with the populated table,
#   4. verify both passes produced the same symbol layout,
#   5. optionally deploy to the SD card.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

KERNEL_ELF="zig-out/bin/kernel8.elf"
NM_BIN="aarch64-elf-nm"

# Pre-flight: Zig version must match the pin. The hard lock lives in
# build.zig (comptime check); this is the friendly early-exit so users
# don't see a Zig compile error from build.zig itself.
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

echo "link kernel8.elf first pass"
zig build

echo "save first pass symbols"
"$NM_BIN" -n "$KERNEL_ELF" | sort | grep -v '\$' > nmfirstpass

echo "generate symbol area and overwrite src/symbol_area.S"
zig build populate-syms

echo "compile symbol area and link kernel8.elf second pass"
zig build

echo "save second pass symbols"
"$NM_BIN" -n "$KERNEL_ELF" | sort | grep -v '\$' > nmsecondpass

echo "show diff of symbols (should be nothing):"
diff nmfirstpass nmsecondpass
rm nmfirstpass nmsecondpass

echo -e "${YELLOW}deploy to sd card?${NC}"
select yn in "yes" "no"; do
    case $yn in
        yes ) zig build deploy; break;;
        no ) exit;;
    esac
done
