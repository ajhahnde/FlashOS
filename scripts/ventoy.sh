#!/usr/bin/env bash

# This script creates and copies the FlashOS bootable image to a Ventoy-formatted device

set -e

ARCHS=(
    x86_64
)
CONFIGS=(
    flashos
)

VENTOY="/media/${USER}/Ventoy"
if [ ! -d "${VENTOY}" ]
then
    echo "Ventoy not mounted" >&2
    exit 1
fi

for ARCH in "${ARCHS[@]}"
do
    for CONFIG_NAME in "${CONFIGS[@]}"
    do
        IMAGE="build/${ARCH}/${CONFIG_NAME}/redox-live.iso"
        make ARCH="${ARCH}" CONFIG_NAME="${CONFIG_NAME}" "${IMAGE}"
        cp -v "${IMAGE}" "${VENTOY}/${CONFIG_NAME}-${ARCH}.iso"
    done
done

sync

echo "Finished copying configs (${CONFIGS[@]}) for archs (${ARCHS[@]})"
