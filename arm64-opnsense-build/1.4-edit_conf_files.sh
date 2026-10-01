#!/bin/sh

set -eu

# Installs the custom extras.conf into the tools tree and ensures both Realtek
# driver packages are available.  Both R5C images use the physically validated
# 198.00 package.  The current package remains in the repository for controlled
# experiments, but its first post-PCIe-fix test blocked during interface setup.
# The build never writes generated snapshots back into this Git checkout, so
# a later git pull --ff-only remains safe.

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"
. ./env.sh

pwd

# Use the release configuration reviewed with this R5C build.  The upstream
# generated ports list omitted service packages still referenced by its plugin
# list (for example zabbix7-agent), causing a complete build to fail only after
# ports had finished.  Keeping both lists as a matched pair lets stage 4 build
# every dependency that stage 5 is allowed to request.
cp "${SRC_DIR}/ports.conf" "${ROOTDIR}/tools/config/${VERSION}/ports.conf"
cp "${SRC_DIR}/plugins.conf" "${ROOTDIR}/tools/config/${VERSION}/plugins.conf"

# Keep the current package listed by OPNsense and add the 198.00 compatibility
# package as a second origin.  Match complete lines so reruns remain harmless.
if ! grep -qx 'net/realtek-re-kmod198' \
    "${ROOTDIR}/tools/config/${VERSION}/ports.conf"; then
	printf '%s\n' 'net/realtek-re-kmod198' >> \
	    "${ROOTDIR}/tools/config/${VERSION}/ports.conf"
fi

# Continue building the 1.98 GUI plugin used by both R5C image variants.
sed -i '' \
    -e 's|^net/realtek-re$|net/realtek-re198|' \
    "${ROOTDIR}/tools/config/${VERSION}/plugins.conf"

# Copy extras.conf file
echo "cp ${SRC_DIR}/ports.conf ${SRC_DIR}/plugins.conf ${SRC_DIR}/extras.conf ${ROOTDIR}/tools/config/${VERSION}/"
cp "${SRC_DIR}/extras.conf" "${ROOTDIR}/tools/config/${VERSION}/"

exit 0
