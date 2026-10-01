#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"

usage()
{
	cat <<'EOF'
Usage: sh rebuild-r5c-boot.sh [--diagnostic] [--arm-repository walker|none] [OPNSENSE_RELEASE]

Rebuild the R5C bootloader, R5C device tree/kernel set, signatures, and disk
image from a completed same-release build.  OPNsense revalidates base and
kernel as image prerequisites, but BARE mode skips ports/plugins/core/package
targets.  Use build-r5c.sh for a new VM or a new OPNsense release.

The ARM repository selection is applied when the disk image is reassembled.
EOF
}

R5C_DIAGNOSTIC=${R5C_DIAGNOSTIC:-no}
ARM_REPOSITORY=${ARM_REPOSITORY:-walker}
OPNSENSE_RELEASE_ARG=
while [ "$#" -gt 0 ]; do
	case "$1" in
	--diagnostic) R5C_DIAGNOSTIC=yes ;;
	--arm-repository)
		[ "$#" -ge 2 ] || {
			echo "--arm-repository requires walker or none" >&2
			exit 2
		}
		ARM_REPOSITORY=$2
		shift
		;;
	-h|--help) usage; exit 0 ;;
	-*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
	*)
		[ -z "${OPNSENSE_RELEASE_ARG}" ] || {
			usage >&2
			exit 2
		}
		OPNSENSE_RELEASE_ARG=$1
		;;
	esac
	shift
done

case "${R5C_DIAGNOSTIC}" in
yes) R5C_DEVICE=R5C_DIAG ;;
no) R5C_DEVICE=R5C_UBOOT ;;
*) echo "R5C_DIAGNOSTIC must be yes or no." >&2; exit 2 ;;
esac

OPNSENSE_RELEASE=${OPNSENSE_RELEASE_ARG:-${OPNSENSE_RELEASE:-}}
export OPNSENSE_RELEASE R5C_DIAGNOSTIC ARM_REPOSITORY
. ./env.sh

[ "$(id -u)" -eq 0 ] || {
	echo "This rebuild must run as root." >&2
	exit 1
}
[ "$(uname -s)" = FreeBSD ] && [ "$(uname -p)" = aarch64 ] || {
	echo "This rebuild must run in the aarch64 FreeBSD build VM." >&2
	exit 1
}
[ -d "${ROOTDIR}/tools/.git" ] || {
	echo "No prior build tree was found. Run sh build-r5c.sh ${OPNSENSE_RELEASE} first." >&2
	exit 1
}

SERIES=$(printf '%s\n' "${OPNSENSE_RELEASE}" | awk -F. '{ print $1 "." $2 }')
SETS_DIR="/usr/local/opnsense/build/${SERIES}/aarch64/sets"
for REQUIRED_SET in base kernel packages; do
	if ! find "${SETS_DIR}" -type f -name "${REQUIRED_SET}-*" -print -quit 2>/dev/null | \
	    grep -q .; then
		echo "The ${REQUIRED_SET} set for ${OPNSENSE_RELEASE} is missing under ${SETS_DIR}." >&2
		echo "Run the full build instead: sh build-r5c.sh ${OPNSENSE_RELEASE}" >&2
		exit 1
	fi
done

LOGDIR=${LOGDIR:-/root/opnsense-dev}
mkdir -p "${LOGDIR}"
STATUS_FILE="${LOGDIR}/rebuild-boot.${OPNSENSE_RELEASE}.status"
CURRENT_STAGE=preflight

run_stage()
{
	CURRENT_STAGE=$1
	shift
	printf 'running %s\n' "${CURRENT_STAGE}" > "${STATUS_FILE}"
	echo
	echo "================================================================"
	echo "==> ${CURRENT_STAGE} (${R5C_DEVICE}, OPNsense ${OPNSENSE_RELEASE})"
	echo "================================================================"
	if "$@"; then
		printf 'complete %s\n' "${CURRENT_STAGE}" > "${STATUS_FILE}"
	else
		RESULT=$?
		printf 'failed %s exit=%s\n' "${CURRENT_STAGE}" "${RESULT}" > "${STATUS_FILE}"
		echo "Boot rebuild stopped: ${CURRENT_STAGE} failed with exit ${RESULT}." >&2
		exit "${RESULT}"
	fi
}

verify_realtek_package()
{
	REALTEK_PACKAGE=realtek-re-kmod198

	PACKAGE_SET=
	for CANDIDATE in \
	    "${SETS_DIR}/packages-${OPNSENSE_RELEASE}-local-aarch64.tar" \
	    "${SETS_DIR}/packages-${OPNSENSE_RELEASE}-aarch64.tar"; do
		if [ -s "${CANDIDATE}" ]; then
			PACKAGE_SET=${CANDIDATE}
			break
		fi
	done
	[ -n "${PACKAGE_SET}" ] || {
		echo "No package archive for ${OPNSENSE_RELEASE} was found in ${SETS_DIR}." >&2
		return 1
	}

	if ! tar -tf "${PACKAGE_SET}" | \
	    grep -Eq "(^|/)${REALTEK_PACKAGE}-[^/]+\\.pkg$"; then
		echo "${REALTEK_PACKAGE} is missing from ${PACKAGE_SET}." >&2
		echo "Run the full build instead: sh build-r5c.sh ${OPNSENSE_RELEASE}" >&2
		return 1
	fi
	echo "Verified ${REALTEK_PACKAGE} in ${PACKAGE_SET}."
}

# Stage 1.1 pins source checkouts, reapplies the R5C source patch, and rebuilds
# the selected U-Boot fragment.  Existing same-release sets remain in place.
run_stage 1.1-fetch_update sh ./1.1-fetch_update.sh
run_stage 1.4-edit_conf_files sh ./1.4-edit_conf_files.sh
# A boot-only run must not invoke the ports target: doing so mutates the build
# host and can reinstall mutually exclusive plugin flavors.  The full build
# already placed the selected NIC driver in the packages set, so validate that
# immutable input before reassembling the image.
run_stage verify-realtek-package verify_realtek_package
run_stage 3-kernel sh ./3-kernel.sh "${R5C_DEVICE}"
KERNEL_SET="${SETS_DIR}/kernel-${OPNSENSE_RELEASE}-aarch64-${R5C_DEVICE}.txz"
run_stage verify-kernel-set sh ./verify-r5c-dtb.sh set "${KERNEL_SET}"
run_stage 8-sign sh ./8-sign.sh
# The upstream image target depends on base and kernel even when those sets
# already exist.  BARE is the upstream switch that prevents the image target
# from also walking the ports -> plugins -> core/package dependency chain.
run_stage 9-arm env BARE=1 sh ./9-arm.sh "${R5C_DEVICE}"

IMAGE="/usr/local/opnsense/build/${SERIES}/aarch64/images/OPNsense-${OPNSENSE_RELEASE}-arm-aarch64-${R5C_DEVICE}.img"
[ -s "${IMAGE}" ] || {
	echo "Expected image was not created: ${IMAGE}" >&2
	exit 1
}
run_stage verify-image sh ./verify-r5c-dtb.sh image "${IMAGE}"
printf 'complete all\n' > "${STATUS_FILE}"
echo
echo "R5C boot-chain rebuild completed: ${IMAGE}"
