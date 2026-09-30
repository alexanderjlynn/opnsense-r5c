#!/bin/sh

set -eu

# Installs the custom extras.conf into the tools tree and selects the Realtek
# driver proven by the original R5S build.  The 1102.01 driver recognizes the
# RTL8125 PCI ID on the R5C but rejects the chip during attach as an unknown
# device.  Keep the 198.00 package/plugin pair until 1102.xx works on RK3568.
# The build never writes generated snapshots back into this Git checkout, so
# a later git pull --ff-only remains safe.

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"
. ./env.sh

pwd

# Pin both the package build and its OPNsense plugin to the original driver's
# 198.00 flavor.  Match complete origins so rerunning this script is harmless.
sed -i '' \
    -e 's|^net/realtek-re-kmod$|net/realtek-re-kmod198|' \
    "${ROOTDIR}/tools/config/${VERSION}/ports.conf"
sed -i '' \
    -e 's|^net/realtek-re$|net/realtek-re198|' \
    "${ROOTDIR}/tools/config/${VERSION}/plugins.conf"

# Copy extras.conf file
echo "cp ${SRC_DIR}/extras.conf ${ROOTDIR}/tools/config/${VERSION}/"
cp "${SRC_DIR}/extras.conf" "${ROOTDIR}/tools/config/${VERSION}/"

exit 0
