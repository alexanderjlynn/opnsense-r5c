#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"

usage()
{
	cat <<'EOF'
Usage: sh build-r5c.sh [OPNSENSE_RELEASE]

Run every R5C build stage in order without interactive confirmations.
The default release is defined in env.sh.  Example:

    sh build-r5c.sh 26.7.4
EOF
}

case "${1:-}" in
-h|--help)
	usage
	exit 0
	;;
esac

if [ "$#" -gt 1 ]; then
	usage >&2
	exit 2
fi

OPNSENSE_RELEASE=${1:-${OPNSENSE_RELEASE:-}}
export OPNSENSE_RELEASE
. ./env.sh

if [ "$(id -u)" -ne 0 ]; then
	echo "This build must run as root." >&2
	exit 1
fi

if [ "$(uname -s)" != "FreeBSD" ]; then
	echo "This build must run in the FreeBSD guest, not on the macOS host." >&2
	exit 1
fi

if [ "$(uname -p)" != "aarch64" ]; then
	echo "The R5C image requires an aarch64 FreeBSD build guest." >&2
	exit 1
fi

for REQUIRED_COMMAND in awk git make openssl pkg sysctl; do
	if ! command -v "${REQUIRED_COMMAND}" >/dev/null 2>&1; then
		echo "Required command is missing: ${REQUIRED_COMMAND}" >&2
		exit 1
	fi
done

if [ "${SKIP_RELEASE_CHECK:-no}" != "yes" ]; then
	echo "==> Verifying OPNsense ${OPNSENSE_RELEASE} source tags"
	for REPOSITORY in src core plugins ports; do
		if ! git ls-remote --exit-code --tags \
		    "https://github.com/opnsense/${REPOSITORY}.git" \
		    "refs/tags/${OPNSENSE_RELEASE}" >/dev/null 2>&1; then
			echo "Release ${OPNSENSE_RELEASE} is not tagged in opnsense/${REPOSITORY}." >&2
			exit 1
		fi
	done
fi

AVAILABLE_KB=$(df -Pk "${ROOTDIR}" | awk 'NR == 2 { print $4 }')
if [ -n "${AVAILABLE_KB}" ] && [ "${AVAILABLE_KB}" -lt 52428800 ]; then
	echo "WARNING: less than 50 GiB is free under ${ROOTDIR}; a full build may run out of space." >&2
fi

mkdir -p "${LOGDIR}"
STATUS_FILE="${LOGDIR}/build.${OPNSENSE_RELEASE}.status"
CURRENT_STAGE=preflight

handle_signal()
{
	printf 'interrupted %s\n' "${CURRENT_STAGE}" > "${STATUS_FILE}"
	echo "Build interrupted during ${CURRENT_STAGE}." >&2
	exit 130
}

trap handle_signal HUP INT TERM

run_stage()
{
	CURRENT_STAGE=$1
	shift
	printf 'running %s\n' "${CURRENT_STAGE}" > "${STATUS_FILE}"
	echo
	echo "================================================================"
	echo "==> ${CURRENT_STAGE} (OPNsense ${OPNSENSE_RELEASE})"
	echo "================================================================"
	if "$@"; then
		printf 'complete %s\n' "${CURRENT_STAGE}" > "${STATUS_FILE}"
	else
		RESULT=$?
		printf 'failed %s exit=%s\n' "${CURRENT_STAGE}" "${RESULT}" > "${STATUS_FILE}"
		echo "Build stopped: ${CURRENT_STAGE} failed with exit ${RESULT}." >&2
		exit "${RESULT}"
	fi
}

run_stage 1.1-fetch_update sh ./1.1-fetch_update.sh
run_stage 1.2-fingerprint sh ./1.2-fingerprint.sh
run_stage 1.3-git_local_files sh ./1.3-git_local_files.sh
run_stage 1.4-edit_conf_files sh ./1.4-edit_conf_files.sh
run_stage 2-base sh ./2-base.sh
run_stage 3-kernel sh ./3-kernel.sh
run_stage 4-ports sh ./4-ports.sh
run_stage 5-plugins sh ./5-plugins.sh
run_stage 6-core sh ./6-core.sh
run_stage 7-packages sh ./7-packages.sh
run_stage 8-sign sh ./8-sign.sh
run_stage 9-arm sh ./9-arm.sh R5C_UBOOT

CURRENT_STAGE=complete
printf 'complete all\n' > "${STATUS_FILE}"
echo
echo "R5C build completed for OPNsense ${OPNSENSE_RELEASE}."

