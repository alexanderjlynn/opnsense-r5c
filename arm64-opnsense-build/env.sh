#!/bin/sh

DEFAULT_OPNSENSE_RELEASE=26.7.4
OPNSENSE_RELEASE=${OPNSENSE_RELEASE:-${DEFAULT_OPNSENSE_RELEASE}}

case "${OPNSENSE_RELEASE}" in
*[!0-9.]*|.*|*..*|*.)
	echo "Invalid OPNsense release: ${OPNSENSE_RELEASE}" >&2
	return 1 2>/dev/null || exit 1
	;;
esac

VERSION=$(printf '%s\n' "${OPNSENSE_RELEASE}" | awk -F. 'NF >= 2 { print $1 "." $2 }')
if [ -z "${VERSION}" ]; then
	echo "OPNsense release must contain at least major and minor numbers" >&2
	return 1 2>/dev/null || exit 1
fi

TAG=ARM64
TAG_SRC=${OPNSENSE_RELEASE}
TAG_CORE=${OPNSENSE_RELEASE}-local
TAG_PLUGINS=${OPNSENSE_RELEASE}
TAG_PORTS=${OPNSENSE_RELEASE}

SRC_DIR=${SRC_DIR:-opnsense-confs}

ROOTDIR=${ROOTDIR:-/usr}
DATE="+%Y-%m-%d_%H:%M:%S"
DEVICE=ARM64
HOST=$(hostname)
IMAGE_SIZE=${IMAGE_SIZE:-4G}
LOGDIR=${LOGDIR:-/root/opnsense-dev}
LOG=${LOGDIR}/log.${HOST}.${TAG}

# Keep ports, pkg, Git, and the OPNsense build tools unattended.  BATCH is
# honored by the ports framework; ASSUME_ALWAYS_YES is honored by pkg(8).
BATCH=yes
ASSUME_ALWAYS_YES=yes
DISABLE_VULNERABILITIES=yes
GIT_TERMINAL_PROMPT=0
PAGER=cat
export BATCH ASSUME_ALWAYS_YES DISABLE_VULNERABILITIES GIT_TERMINAL_PROMPT PAGER
export OPNSENSE_RELEASE VERSION TAG_SRC TAG_CORE TAG_PLUGINS TAG_PORTS

# Functions used

log_print () {
 SCRIPT=$0
 TAG_SRC_FUNC=$1
 LOG_FILE=$2
 DATE_FUNC=$3
 STATE=$4

	mkdir -p "$(dirname "${LOG_FILE}")"
	printf '%s %s %s %s %s:\t' \
	    "${SCRIPT}" "${TAG_SRC_FUNC}" "${DEVICE}" "${IMAGE_SIZE}" "${STATE}" >> "${LOG_FILE}"
	date "${DATE_FUNC}" >> "${LOG_FILE}"
}
