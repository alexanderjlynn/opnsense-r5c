#!/bin/sh

set -eu

# Script to sign tar files if it has not yet been done. Logs time it starts and finishes.

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"
. ./env.sh

log_print "${TAG_SRC}" "${LOG}" "${DATE}" Start

make -C "${ROOTDIR}/tools" VERSION="${TAG_CORE}" DEVICE="${DEVICE}" \
    sign-base,kernel,packages

log_print "${TAG_SRC}" "${LOG}" "${DATE}" Complete
