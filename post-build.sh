#!/bin/sh

set -eu

: "${TARGET_DIR:?Buildroot TARGET_DIR is required}"
: "${HOST_DIR:?Buildroot HOST_DIR is required}"
: "${NERVES_DEFCONFIG_DIR:?Buildroot NERVES_DEFCONFIG_DIR is required}"
: "${BINARIES_DIR:?Buildroot BINARIES_DIR is required}"

# Build the runtime operations archive used by Nerves.Runtime.FwupOps.
mkdir -p "${TARGET_DIR}/usr/share/fwup"
"${HOST_DIR}/usr/bin/fwup" \
    -c \
    -f "${NERVES_DEFCONFIG_DIR}/fwup-ops.conf" \
    -o "${TARGET_DIR}/usr/share/fwup/ops.fw"
ln -sf ops.fw "${TARGET_DIR}/usr/share/fwup/revert.fw"

# Keep burn-time provisioning includes next to the generated fwup.conf in the
# portable System artifact.
rm -rf "${BINARIES_DIR}/fwup_include"
cp -R "${NERVES_DEFCONFIG_DIR}/fwup_include" "${BINARIES_DIR}/fwup_include"
