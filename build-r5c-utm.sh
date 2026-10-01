#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
BUILD_DIR="${SCRIPT_DIR}/arm64-opnsense-build"
DEFAULT_RELEASE=$(awk -F= '/^DEFAULT_OPNSENSE_RELEASE=/{print $2; exit}' "${BUILD_DIR}/env.sh")

UTM_VM=${UTM_VM:-FreeBSD}
UTM_GUEST_HOST=${UTM_GUEST_HOST:-}
UTM_GUEST_USER=${UTM_GUEST_USER:-root}
UTM_SSH_PORT=${UTM_SSH_PORT:-22}
UTM_SSH_IDENTITY=${UTM_SSH_IDENTITY:-}
UTM_REMOTE_DIR=${UTM_REMOTE_DIR:-/root/opnsense-r5c-build}
UTM_ARTIFACT_DIR=${UTM_ARTIFACT_DIR:-}
UTMCTL=${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}
RELEASE=
KEEP_RAW=no
EMMC_IMAGE=no
BOOT_ONLY=no
DIAGNOSTIC=no
ARM_REPOSITORY=${ARM_REPOSITORY:-walker}
SSH_STATE_DIR=
CONTROL_PATH=
PARTIAL_FILE=
CAFFEINATE_PID=

usage()
{
	cat <<EOF
Usage: ./build-r5c-utm.sh [options] [OPNSENSE_RELEASE [GUEST_IP]]

Start a UTM FreeBSD VM, copy this checkout into it, run a full or cached R5C
build, and copy a compressed image back to macOS.  The default is ${DEFAULT_RELEASE}.

The simplest reliable form when the VM prints its address is:

  ./build-r5c-utm.sh ${DEFAULT_RELEASE} 192.168.65.3

Options:
  --vm NAME          UTM VM name or UUID (default: ${UTM_VM})
  --host ADDRESS     Guest SSH address; otherwise ask UTM for its IP
  --port PORT        Guest SSH port (default: ${UTM_SSH_PORT})
  --user USER        Guest SSH user; it must be root (default: root)
  --identity FILE    SSH private key
  --artifact-dir DIR Store the finished image here
  --keep-raw         Also copy the uncompressed .img (useful for flashing)
  --emmc-image       Also create an eMMC Tools-compatible .img.gz
  --boot-only        Reuse a completed same-release build; rebuild boot chain
  --diagnostic       Build R5C_DIAG with pre-EFI LED/FAT markers
  --arm-repository R Runtime package/update repository: walker or none
                     (default: ${ARM_REPOSITORY})
  -h, --help         Show this help

Environment variables with the same names as the defaults above are also
supported.  For a forwarded SSH port, for example:

  UTM_GUEST_HOST=127.0.0.1 UTM_SSH_PORT=2222 ./build-r5c-utm.sh ${DEFAULT_RELEASE}
EOF
}

die()
{
	echo "ERROR: $*" >&2
	exit 1
}

cleanup()
{
	if [ -n "${CONTROL_PATH:-}" ] && [ -S "${CONTROL_PATH}" ]; then
		ssh -p "${UTM_SSH_PORT}" -o "ControlPath=${CONTROL_PATH}" \
		    -O exit "${SSH_TARGET:-root@127.0.0.1}" >/dev/null 2>&1 || true
	fi
	if [ -n "${PARTIAL_FILE:-}" ] && [ -f "${PARTIAL_FILE}" ]; then
		rm -f "${PARTIAL_FILE}"
	fi
	if [ -n "${SSH_STATE_DIR:-}" ] && [ -d "${SSH_STATE_DIR}" ]; then
		rm -r "${SSH_STATE_DIR}"
	fi
	if [ -n "${CAFFEINATE_PID:-}" ]; then
		kill "${CAFFEINATE_PID}" >/dev/null 2>&1 || true
	fi
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

while [ "$#" -gt 0 ]; do
	case "$1" in
	--vm)
		[ "$#" -ge 2 ] || die "--vm requires a value"
		UTM_VM=$2
		shift 2
		;;
	--host)
		[ "$#" -ge 2 ] || die "--host requires a value"
		UTM_GUEST_HOST=$2
		shift 2
		;;
	--port)
		[ "$#" -ge 2 ] || die "--port requires a value"
		UTM_SSH_PORT=$2
		shift 2
		;;
	--user)
		[ "$#" -ge 2 ] || die "--user requires a value"
		UTM_GUEST_USER=$2
		shift 2
		;;
	--identity)
		[ "$#" -ge 2 ] || die "--identity requires a value"
		UTM_SSH_IDENTITY=$2
		shift 2
		;;
	--artifact-dir)
		[ "$#" -ge 2 ] || die "--artifact-dir requires a value"
		UTM_ARTIFACT_DIR=$2
		shift 2
		;;
	--keep-raw)
		KEEP_RAW=yes
		shift
		;;
	--emmc-image)
		EMMC_IMAGE=yes
		shift
		;;
	--boot-only)
		BOOT_ONLY=yes
		shift
		;;
	--diagnostic)
		DIAGNOSTIC=yes
		shift
		;;
	--arm-repository)
		[ "$#" -ge 2 ] || die "--arm-repository requires walker or none"
		ARM_REPOSITORY=$2
		shift 2
		;;
	-h|--help)
		usage
		exit 0
		;;
	--)
		shift
		break
		;;
	-*)
		die "unknown option: $1"
		;;
	*)
		if [ -z "${RELEASE}" ]; then
			RELEASE=$1
		elif [ -z "${UTM_GUEST_HOST}" ]; then
			UTM_GUEST_HOST=$1
		else
			die "unexpected argument: $1"
		fi
		shift
		;;
	esac
done

[ "$#" -eq 0 ] || die "unexpected argument: $1"
RELEASE=${RELEASE:-${DEFAULT_RELEASE}}

case "${RELEASE}" in
*[!0-9.]*|.*|*..*|*.) die "invalid OPNsense release: ${RELEASE}" ;;
esac
case "${RELEASE}" in
*.*) ;;
*) die "OPNsense release must contain at least major and minor numbers" ;;
esac
case "${UTM_SSH_PORT}" in
''|*[!0-9]*) die "invalid SSH port: ${UTM_SSH_PORT}" ;;
esac
case "${ARM_REPOSITORY}" in
walker|none) ;;
*) die "invalid ARM repository '${ARM_REPOSITORY}'; expected walker or none" ;;
esac
[ "${UTM_GUEST_USER}" = root ] || die "the OPNsense tools require root; use --user root"
case "${UTM_REMOTE_DIR}" in
/root/*) ;;
*) die "UTM_REMOTE_DIR must be an absolute directory below /root" ;;
esac
case "${UTM_REMOTE_DIR}" in
*[!A-Za-z0-9_./-]*) die "UTM_REMOTE_DIR contains unsupported characters" ;;
esac
if [ -n "${UTM_GUEST_HOST}" ]; then
	case "${UTM_GUEST_HOST}" in
	*[!A-Za-z0-9.:-]*) die "guest host contains unsupported characters" ;;
	esac
fi

[ "$(uname -s)" = Darwin ] || die "run this launcher on the macOS host"
[ "$(uname -m)" = arm64 ] || die "this launcher expects an Apple-silicon Mac"
[ -x "${UTMCTL}" ] || die "utmctl was not found at ${UTMCTL}"
[ -d "${BUILD_DIR}" ] || die "arm64-opnsense-build was not found beside this script"
for REQUIRED_COMMAND in awk caffeinate gzip mktemp nc shasum ssh stat tar tee; do
	command -v "${REQUIRED_COMMAND}" >/dev/null 2>&1 || die "required macOS command is missing: ${REQUIRED_COMMAND}"
done

# A full ARM build can run for many hours.  Keep the host awake without
# changing any persistent macOS setting.
caffeinate -dimsu -w $$ &
CAFFEINATE_PID=$!

echo "==> Checking UTM VM '${UTM_VM}'"
VM_STATUS=$("${UTMCTL}" status "${UTM_VM}" 2>&1) || die "cannot query UTM VM '${UTM_VM}': ${VM_STATUS}"
case "${VM_STATUS}" in
started) ;;
stopped|paused)
	echo "==> Starting UTM VM '${UTM_VM}'"
	"${UTMCTL}" start "${UTM_VM}"
	;;
starting|resuming) ;;
*) die "unexpected UTM status '${VM_STATUS}' for '${UTM_VM}'" ;;
esac

ATTEMPT=1
while [ "${ATTEMPT}" -le 60 ]; do
	VM_STATUS=$("${UTMCTL}" status "${UTM_VM}" 2>/dev/null || true)
	[ "${VM_STATUS}" = started ] && break
	sleep 2
	ATTEMPT=$((ATTEMPT + 1))
done
[ "${VM_STATUS}" = started ] || die "UTM VM '${UTM_VM}' did not start within two minutes"

if [ -z "${UTM_GUEST_HOST}" ]; then
	echo "==> Waiting for the UTM guest agent to report an IPv4 address"
	ATTEMPT=1
	while [ "${ATTEMPT}" -le 60 ]; do
		UTM_GUEST_HOST=$("${UTMCTL}" ip-address "${UTM_VM}" 2>/dev/null | \
		    awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $0 !~ /^127\./ { print; exit }' || true)
		[ -n "${UTM_GUEST_HOST}" ] && break
		sleep 2
		ATTEMPT=$((ATTEMPT + 1))
	done
	[ -n "${UTM_GUEST_HOST}" ] || die "UTM did not report a guest IPv4 address; install/start qemu-guest-agent or pass --host"
fi

SSH_OPTIONS=(
	-p "${UTM_SSH_PORT}"
	-o ConnectTimeout=5
	-o StrictHostKeyChecking=accept-new
	-o ServerAliveInterval=30
	-o ServerAliveCountMax=6
	-o NumberOfPasswordPrompts=3
)
if [ -n "${UTM_SSH_IDENTITY}" ]; then
	[ -f "${UTM_SSH_IDENTITY}" ] || die "SSH identity does not exist: ${UTM_SSH_IDENTITY}"
	SSH_OPTIONS+=( -i "${UTM_SSH_IDENTITY}" )
fi
SSH_TARGET="${UTM_GUEST_USER}@${UTM_GUEST_HOST}"

echo "==> Waiting for SSH at ${UTM_GUEST_HOST}:${UTM_SSH_PORT}"
SSH_READY=no
ATTEMPT=1
while [ "${ATTEMPT}" -le 60 ]; do
	if nc -z -w 2 "${UTM_GUEST_HOST}" "${UTM_SSH_PORT}" >/dev/null 2>&1; then
		SSH_READY=yes
		break
	fi
	sleep 3
	ATTEMPT=$((ATTEMPT + 1))
done
[ "${SSH_READY}" = yes ] || die "SSH did not become reachable within three minutes"

# Keep host keys and the multiplexed connection in /tmp.  Password users are
# prompted once here; every later SSH operation reuses this connection.
SSH_STATE_DIR=$(mktemp -d /tmp/opnsense-r5c-ssh.XXXXXX)
CONTROL_PATH="${SSH_STATE_DIR}/control"
SSH_OPTIONS+=(
	-o "ControlPath=${CONTROL_PATH}"
	-o "UserKnownHostsFile=${SSH_STATE_DIR}/known_hosts"
)

echo "==> Opening a temporary SSH connection (enter the VM root password once)"
if ! ssh "${SSH_OPTIONS[@]}" -o ControlMaster=yes -o ControlPersist=yes \
    -Nf "${SSH_TARGET}"; then
	die "SSH login failed; verify the root password and PermitRootLogin setting"
fi

GUEST_INFO=$(ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" 'printf "%s %s uid=%s\n" "$(uname -sr)" "$(uname -p)" "$(id -u)"')
case "${GUEST_INFO}" in
FreeBSD\ 15.1-*\ aarch64\ uid=0) ;;
*) die "guest must be FreeBSD 15.1 aarch64 running as root; found: ${GUEST_INFO}" ;;
esac

echo "==> Copying build files to ${SSH_TARGET}:${UTM_REMOTE_DIR}"
ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "mkdir -p '${UTM_REMOTE_DIR}'"
# Never send prior multi-gigabyte results back into the VM on a retry.
COPYFILE_DISABLE=1 tar -C "${SCRIPT_DIR}" --exclude=.git \
    --exclude=build-artifacts \
    --no-acls --no-fflags --no-mac-metadata --no-xattrs -czf - . | \
    ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "tar -xzf - -C '${UTM_REMOTE_DIR}'"

# Create the local artifact directory before starting the long build.  tee and
# pipefail preserve the complete diagnostic output on macOS without hiding the
# remote build's exit status, so a failed unattended run remains actionable.
SERIES=$(printf '%s\n' "${RELEASE}" | awk -F. '{ print $1 "." $2 }')
if [ "${DIAGNOSTIC}" = yes ]; then
	R5C_DEVICE=R5C_DIAG
	DIAGNOSTIC_OPTION="--diagnostic "
else
	R5C_DEVICE=R5C_UBOOT
	DIAGNOSTIC_OPTION=
fi
if [ "${BOOT_ONLY}" = yes ]; then
	REMOTE_RUNNER=rebuild-r5c-boot.sh
	BUILD_KIND=boot-only
else
	REMOTE_RUNNER=build-r5c.sh
	BUILD_KIND=full
fi
IMAGE_BASENAME="OPNsense-${RELEASE}-arm-aarch64-${R5C_DEVICE}.img"
REMOTE_IMAGE_DIR="/usr/local/opnsense/build/${SERIES}/aarch64/images"
REMOTE_IMAGE="${REMOTE_IMAGE_DIR}/${IMAGE_BASENAME}"
ARTIFACT_DIR=${UTM_ARTIFACT_DIR:-${SCRIPT_DIR}/build-artifacts/${RELEASE}}
BUILD_LOG="${ARTIFACT_DIR}/build-${RELEASE}-${R5C_DEVICE}-${BUILD_KIND}.log"
mkdir -p "${ARTIFACT_DIR}"

echo "==> Starting the ${BUILD_KIND} ${R5C_DEVICE} build for OPNsense ${RELEASE}"
echo "==> The VM will remain running when the build finishes or fails."
ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
    "cd '${UTM_REMOTE_DIR}/arm64-opnsense-build' && exec sh './${REMOTE_RUNNER}' ${DIAGNOSTIC_OPTION}--arm-repository '${ARM_REPOSITORY}' '${RELEASE}'" \
    2>&1 | tee "${BUILD_LOG}"

if [ "${KEEP_RAW}" = yes ]; then
	echo "==> Copying the uncompressed R5C image back to macOS"
	PARTIAL_FILE="${ARTIFACT_DIR}/${IMAGE_BASENAME}.partial"
	ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
	    "test -s '${REMOTE_IMAGE}' && cat '${REMOTE_IMAGE}'" > "${PARTIAL_FILE}"
	mv "${PARTIAL_FILE}" "${ARTIFACT_DIR}/${IMAGE_BASENAME}"
	PARTIAL_FILE=
fi

echo "==> Compressing and copying the R5C image back to macOS"
PARTIAL_FILE="${ARTIFACT_DIR}/${IMAGE_BASENAME}.xz.partial"
ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
    "test -s '${REMOTE_IMAGE}' && exec xz -T0 -c '${REMOTE_IMAGE}'" > "${PARTIAL_FILE}"
mv "${PARTIAL_FILE}" "${ARTIFACT_DIR}/${IMAGE_BASENAME}.xz"
PARTIAL_FILE=

# FriendlyWrt's eMMC Tools recognizes a gzip-compressed whole-disk image by
# its .img.gz suffix.  A normal ZIP archive takes a different code path that
# expects a FriendlyELEC partition bundle containing parameter.txt/partmap.txt.
if [ "${EMMC_IMAGE}" = yes ]; then
	echo "==> Creating the FriendlyWrt eMMC Tools image"
	PARTIAL_FILE="${ARTIFACT_DIR}/${IMAGE_BASENAME}.gz.partial"
	ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
	    "test -s '${REMOTE_IMAGE}' && exec gzip -9 -c '${REMOTE_IMAGE}'" \
	    > "${PARTIAL_FILE}"
	gzip -t "${PARTIAL_FILE}"
	mv "${PARTIAL_FILE}" "${ARTIFACT_DIR}/${IMAGE_BASENAME}.gz"
	PARTIAL_FILE=
	(
		cd "${ARTIFACT_DIR}"
		shasum -a 256 "${IMAGE_BASENAME}.gz" > "${IMAGE_BASENAME}.gz.sha256"
	)
fi

PARTIAL_FILE="${ARTIFACT_DIR}/${IMAGE_BASENAME}.sig.partial"
ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
    "test -s '${REMOTE_IMAGE}.sig' && cat '${REMOTE_IMAGE}.sig'" \
    > "${PARTIAL_FILE}"
mv "${PARTIAL_FILE}" "${ARTIFACT_DIR}/${IMAGE_BASENAME}.sig"
PARTIAL_FILE=
(
	cd "${ARTIFACT_DIR}"
	shasum -a 256 "${IMAGE_BASENAME}.xz" > "${IMAGE_BASENAME}.xz.sha256"
)

ASSET_SIZE=$(stat -f %z "${ARTIFACT_DIR}/${IMAGE_BASENAME}.xz")
if [ "${ASSET_SIZE}" -ge 2147483648 ]; then
	echo "WARNING: the compressed image is at least 2 GiB and cannot be uploaded as one GitHub release asset." >&2
fi
if [ "${EMMC_IMAGE}" = yes ]; then
	EMMC_ASSET_SIZE=$(stat -f %z "${ARTIFACT_DIR}/${IMAGE_BASENAME}.gz")
	if [ "${EMMC_ASSET_SIZE}" -ge 2000000000 ]; then
		echo "WARNING: the .img.gz is at least 2,000,000,000 bytes and may exceed the eMMC Tools upload limit." >&2
	fi
fi

echo
echo "Build and transfer complete:"
OUTPUT_FILES=(
	"${ARTIFACT_DIR}/${IMAGE_BASENAME}.xz"
	"${ARTIFACT_DIR}/${IMAGE_BASENAME}.xz.sha256"
	"${ARTIFACT_DIR}/${IMAGE_BASENAME}.sig"
)
if [ "${KEEP_RAW}" = yes ]; then
	OUTPUT_FILES+=("${ARTIFACT_DIR}/${IMAGE_BASENAME}")
fi
if [ "${EMMC_IMAGE}" = yes ]; then
	OUTPUT_FILES+=(
		"${ARTIFACT_DIR}/${IMAGE_BASENAME}.gz"
		"${ARTIFACT_DIR}/${IMAGE_BASENAME}.gz.sha256"
	)
fi
ls -lh "${OUTPUT_FILES[@]}"
echo "Build log: ${BUILD_LOG}"
echo "You can now shut down and delete the UTM VM."
