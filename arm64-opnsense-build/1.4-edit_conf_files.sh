#!/bin/sh

set -eu

# Installs the custom extras.conf into the tools config and keeps a snapshot
# of the upstream plugins/ports conf files in this repository.
# Since OPNsense 26.7 (FreeBSD 15.1) the stock net/realtek-re-kmod driver
# works on RK3568 boards, so the old realtek 1.98 pinning is gone.

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"
. ./env.sh

pwd

# Copy extras.conf file
echo "cp ${SRC_DIR}/extras.conf ${ROOTDIR}/tools/config/${VERSION}/"
cp "${SRC_DIR}/extras.conf" "${ROOTDIR}/tools/config/${VERSION}/"

# Snapshot upstream conf files for reference
cp "${ROOTDIR}/tools/config/${VERSION}/plugins.conf" \
    "${ROOTDIR}/tools/config/${VERSION}/ports.conf" "${SRC_DIR}/"

exit 0
