#!/bin/sh

set -eu

# Script to build an image for a device. Logs time it starts and finishes.

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"
. ./env.sh

if [ -n "${1:-}" ]; then
	DEVICE=$1
fi

log_print "${TAG_SRC}" "${LOG}" "${DATE}" Start

make -C "${ROOTDIR}/tools" VERSION="${TAG_SRC}" DEVICE="${DEVICE}" "arm-${IMAGE_SIZE}"

log_print "${TAG_SRC}" "${LOG}" "${DATE}" Complete
