#!/bin/sh

set -eu

# Script to build kernel. Logs time it starts and finishes.

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"
. ./env.sh

if [ "$#" -gt 1 ]; then
	echo "Usage: sh 3-kernel.sh [DEVICE]" >&2
	exit 2
fi
if [ -n "${1:-}" ]; then
	DEVICE=$1
fi

log_print "${TAG_SRC}" "${LOG}" "${DATE}" Start

# The R5C source overlay changes both the DTB set and the generic DesignWare
# PCIe host driver.  The upstream kernel target reuses an existing release set
# whenever it is called without an argument, even when /usr/src is dirty.
# A hyphenated target passes "r5c" to build/kernel.sh and deliberately bypasses
# that cache, preventing an apparently successful image from containing the
# previous unpatched kernel.
make -C "${ROOTDIR}/tools" VERSION="${TAG_SRC}" DEVICE="${DEVICE}" kernel-r5c

log_print "${TAG_SRC}" "${LOG}" "${DATE}" Complete
