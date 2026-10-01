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

# Official OPNsense package mirrors do not publish aarch64 packages.  Select a
# repository that does, so the finished image can use System > Firmware to
# install plugins and updates.  Repository trust data is pinned here rather
# than downloaded during a build.
ARM_REPOSITORY=${ARM_REPOSITORY:-walker}
case "${ARM_REPOSITORY}" in
walker)
	case "${VERSION}" in
	26.7)
		ARM_REPOSITORY_URL=https://opnsense-update.walker.earth
		ARM_REPOSITORY_FINGERPRINT_NAME=opnsense-update.walker.earth.20260715
		ARM_REPOSITORY_FINGERPRINT=4a4b07a3e40e06c1c42fe457d065c67734b59a6510d666c69b07ecdbcf615a25
		;;
	*)
		echo "ARM repository 'walker' has no pinned fingerprint for OPNsense ${VERSION}." >&2
		echo "Use ARM_REPOSITORY=none or add a reviewed fingerprint profile." >&2
		return 1 2>/dev/null || exit 1
		;;
	esac
	;;
none)
	ARM_REPOSITORY_URL=
	ARM_REPOSITORY_FINGERPRINT_NAME=
	ARM_REPOSITORY_FINGERPRINT=
	;;
*)
	echo "Invalid ARM_REPOSITORY '${ARM_REPOSITORY}'; expected walker or none." >&2
	return 1 2>/dev/null || exit 1
	;;
esac

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
export ARM_REPOSITORY ARM_REPOSITORY_URL ARM_REPOSITORY_FINGERPRINT_NAME
export ARM_REPOSITORY_FINGERPRINT

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
