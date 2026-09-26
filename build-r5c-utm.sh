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
SSH_STATE_DIR=
CONTROL_PATH=
PARTIAL_FILE=
CAFFEINATE_PID=

usage()
{
	cat <<EOF
Usage: ./build-r5c-utm.sh [options] [OPNSENSE_RELEASE]

Start a UTM FreeBSD VM, copy this checkout into it, run all R5C build stages,
and copy a compressed image back to macOS.  The default is ${DEFAULT_RELEASE}.

Options:
  --vm NAME          UTM VM name or UUID (default: ${UTM_VM})
  --host ADDRESS     Guest SSH address; otherwise ask UTM for its IP
  --port PORT        Guest SSH port (default: ${UTM_SSH_PORT})
  --user USER        Guest SSH user; it must be root (default: root)
  --identity FILE    SSH private key
  --artifact-dir DIR Store the finished image here
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
		[ -z "${RELEASE}" ] || die "only one OPNsense release may be supplied"
		RELEASE=$1
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
for REQUIRED_COMMAND in awk caffeinate mktemp nc shasum ssh stat tar; do
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
tar -C "${SCRIPT_DIR}" --exclude=.git -czf - . | \
    ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "tar -xzf - -C '${UTM_REMOTE_DIR}'"

echo "==> Starting the complete R5C build for OPNsense ${RELEASE}"
echo "==> The VM will remain running when the build finishes or fails."
ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
    "cd '${UTM_REMOTE_DIR}/arm64-opnsense-build' && exec sh ./build-r5c.sh '${RELEASE}'"

SERIES=$(printf '%s\n' "${RELEASE}" | awk -F. '{ print $1 "." $2 }')
IMAGE_BASENAME="OPNsense-${RELEASE}-arm-aarch64-R5C_UBOOT.img"
REMOTE_IMAGE_DIR="/usr/local/opnsense/build/${SERIES}/aarch64/images"
REMOTE_IMAGE="${REMOTE_IMAGE_DIR}/${IMAGE_BASENAME}"
ARTIFACT_DIR=${UTM_ARTIFACT_DIR:-${SCRIPT_DIR}/build-artifacts/${RELEASE}}
mkdir -p "${ARTIFACT_DIR}"

echo "==> Compressing and copying the R5C image back to macOS"
PARTIAL_FILE="${ARTIFACT_DIR}/${IMAGE_BASENAME}.xz.partial"
ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" \
    "test -s '${REMOTE_IMAGE}' && exec xz -T0 -c '${REMOTE_IMAGE}'" > "${PARTIAL_FILE}"
mv "${PARTIAL_FILE}" "${ARTIFACT_DIR}/${IMAGE_BASENAME}.xz"
PARTIAL_FILE=

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

echo
echo "Build and transfer complete:"
ls -lh "${ARTIFACT_DIR}/${IMAGE_BASENAME}.xz" \
    "${ARTIFACT_DIR}/${IMAGE_BASENAME}.xz.sha256" \
    "${ARTIFACT_DIR}/${IMAGE_BASENAME}.sig"
echo "You can now shut down and delete the UTM VM."
