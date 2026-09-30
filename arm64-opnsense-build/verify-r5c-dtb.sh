#!/bin/sh

set -eu

usage()
{
	echo "Usage: sh verify-r5c-dtb.sh set KERNEL_SET.txz | image IMAGE.img" >&2
	exit 2
}

[ "$#" -eq 2 ] || usage
MODE=$1
ARTIFACT=$2
DTB_PATH=boot/dtb/rockchip/rk3568-nanopi-r5c.dtb
TMP_DIR=
MD_DEVICE=
MOUNT_DIR=

cleanup()
{
	if [ -n "${MOUNT_DIR:-}" ]; then
		umount "${MOUNT_DIR}" >/dev/null 2>&1 || true
	fi
	if [ -n "${MD_DEVICE:-}" ]; then
		mdconfig -d -u "${MD_DEVICE#md}" >/dev/null 2>&1 || true
	fi
	if [ -n "${TMP_DIR:-}" ] && [ -d "${TMP_DIR}" ]; then
		rm -r "${TMP_DIR}"
	fi
}
trap cleanup EXIT HUP INT TERM

[ -s "${ARTIFACT}" ] || {
	echo "R5C verification artifact is missing or empty: ${ARTIFACT}" >&2
	exit 1
}
command -v dtc >/dev/null 2>&1 || {
	echo "dtc is required to verify the packaged R5C device tree." >&2
	exit 1
}

TMP_DIR=$(mktemp -d /tmp/r5c-dtb-verify.XXXXXX)
DTB="${TMP_DIR}/rk3568-nanopi-r5c.dtb"
DTS="${TMP_DIR}/rk3568-nanopi-r5c.dts"

case "${MODE}" in
set)
	tar -xOf "${ARTIFACT}" "./${DTB_PATH}" > "${DTB}" || {
		echo "Could not extract ${DTB_PATH} from ${ARTIFACT}." >&2
		exit 1
	}
	;;
image)
	[ "$(uname -s)" = FreeBSD ] || {
		echo "Whole-image DTB verification must run on FreeBSD." >&2
		exit 1
	}
	MD_DEVICE=$(mdconfig -a -t vnode -f "${ARTIFACT}" -o readonly)
	MOUNT_DIR="${TMP_DIR}/root"
	mkdir "${MOUNT_DIR}"
	mount -o ro "/dev/${MD_DEVICE}s2a" "${MOUNT_DIR}" || {
		echo "Could not mount the FreeBSD root partition in ${ARTIFACT}." >&2
		exit 1
	}
	cp "${MOUNT_DIR}/${DTB_PATH}" "${DTB}" || {
		echo "The final image does not contain ${DTB_PATH}." >&2
		exit 1
	}
	;;
*)
	usage
	;;
esac

dtc -q -I dtb -O dts "${DTB}" > "${DTS}"
if ! grep -Fq \
    '0x3000000 0x3 0x40000000 0x3 0x40000000 0x0 0x40000000' \
    "${DTS}" || \
    ! grep -Fq \
    '0x3000000 0x3 0x80000000 0x3 0x80000000 0x0 0x40000000' \
    "${DTS}"; then
	echo "FATAL: ${ARTIFACT} contains a stale R5C DTB." >&2
	echo "Expected identity-mapped PCIe windows 0x340000000 and 0x380000000." >&2
	exit 1
fi

echo "Verified current NanoPi R5C PCIe ranges in ${ARTIFACT}."
