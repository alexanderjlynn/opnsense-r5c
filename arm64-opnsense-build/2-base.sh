#!/bin/sh

set -eu

# Script to build base. Logs time it starts and finishes.

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"
. ./env.sh

log_print "${TAG_SRC}" "${LOG}" "${DATE}" Start

make -C "${ROOTDIR}/tools" VERSION="${TAG_SRC}" DEVICE="${DEVICE}" base

log_print "${TAG_SRC}" "${LOG}" "${DATE}" Complete
