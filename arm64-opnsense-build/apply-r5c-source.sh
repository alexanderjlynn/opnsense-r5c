#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${SCRIPT_DIR}/env.sh"

SOURCE_DTS="${SCRIPT_DIR}/freebsd-r5c/rk3568-nanopi-r5c.dts"
PCI_DW_PATCH="${SCRIPT_DIR}/freebsd-r5c/pci-dw-mem64.patch"
TARGET_DTS_DIR="${ROOTDIR}/src/sys/contrib/device-tree/src/arm64/rockchip"
TARGET_DTS="${TARGET_DTS_DIR}/rk3568-nanopi-r5c.dts"
DTB_MAKEFILE="${ROOTDIR}/src/sys/modules/dtb/rockchip/Makefile"
PCI_DW_SOURCE="${ROOTDIR}/src/sys/dev/pci/pci_dw.c"

if [ "${1:-}" = "--clean" ]; then
	if [ -d "${ROOTDIR}/src/.git" ]; then
		for SOURCE_PATH in \
		    sys/modules/dtb/rockchip/Makefile \
		    sys/contrib/device-tree/src/arm64/rockchip/rk3568-nanopi-r5c.dts \
		    sys/dev/pci/pci_dw.c; do
			if git -C "${ROOTDIR}/src" ls-files --error-unmatch \
			    "${SOURCE_PATH}" >/dev/null 2>&1; then
				git -C "${ROOTDIR}/src" checkout -- "${SOURCE_PATH}"
			else
				rm -f "${ROOTDIR}/src/${SOURCE_PATH}"
			fi
		done
	fi
	exit 0
fi

[ "$#" -eq 0 ] || {
	echo "Usage: sh apply-r5c-source.sh [--clean]" >&2
	exit 2
}

[ -f "${SOURCE_DTS}" ] || {
	echo "R5C device tree is missing: ${SOURCE_DTS}" >&2
	exit 1
}
[ -f "${PCI_DW_PATCH}" ] || {
	echo "R5C PCIe MEM64 patch is missing: ${PCI_DW_PATCH}" >&2
	exit 1
}
[ -f "${TARGET_DTS_DIR}/rk3568-nanopi-r5s.dtsi" ] || {
	echo "The selected OPNsense source does not contain rk3568-nanopi-r5s.dtsi." >&2
	echo "Its device-tree layout must be reviewed before this R5C patch can be used." >&2
	exit 1
}
[ -f "${DTB_MAKEFILE}" ] || {
	echo "Rockchip DTB Makefile is missing: ${DTB_MAKEFILE}" >&2
	exit 1
}
[ -f "${PCI_DW_SOURCE}" ] || {
	echo "DesignWare PCIe source is missing: ${PCI_DW_SOURCE}" >&2
	exit 1
}

install -m 0644 "${SOURCE_DTS}" "${TARGET_DTS}"

if ! grep -Fq 'rockchip/rk3568-nanopi-r5c.dts' "${DTB_MAKEFILE}"; then
	DTB_MAKEFILE_NEW="${DTB_MAKEFILE}.r5c.$$"
	awk '
		/rockchip\/rk3568-nanopi-r5s\.dts/ {
			if ($0 !~ /\\[[:space:]]*$/) {
				print "R5S DTB entry is not followed by another item; refusing an unsafe edit" > "/dev/stderr"
				exit 2
			}
			print
			match($0, /^[[:space:]]*/)
			indent = substr($0, RSTART, RLENGTH)
			print indent "rockchip/rk3568-nanopi-r5c.dts \\"
			next
		}
		{ print }
	' "${DTB_MAKEFILE}" > "${DTB_MAKEFILE_NEW}" || {
		RESULT=$?
		rm -f "${DTB_MAKEFILE_NEW}"
		exit "${RESULT}"
	}
	if ! grep -Fq 'rockchip/rk3568-nanopi-r5c.dts' "${DTB_MAKEFILE_NEW}"; then
		rm -f "${DTB_MAKEFILE_NEW}"
		echo "Could not locate the R5S DTB entry in ${DTB_MAKEFILE}" >&2
		exit 1
	fi
	mv "${DTB_MAKEFILE_NEW}" "${DTB_MAKEFILE}"
fi

# FreeBSD's generic DesignWare host bridge currently builds outbound iATU
# windows only for MEM32 ranges.  RK3568 places PCIe endpoint BARs in its
# prefetchable MEM64 ranges.  The R5C DTS above also replaces FreeBSD 15.1's
# stale below-4-GB PCI target addresses with current upstream's identity-mapped
# 0x340000000/0x380000000 bus and CPU addresses.  Configuration-space access
# can work while an incorrect or missing window makes every RTL8125 MMIO read
# return 0xffffffff.  Program MEM64 ranges through the same path as MEM32.
if ! grep -Fq 'RK3568 assigns endpoint BARs from its prefetchable MEM64 range' \
    "${PCI_DW_SOURCE}"; then
	patch -d "${ROOTDIR}/src" -p1 < "${PCI_DW_PATCH}"
fi
if ! grep -Fq 'OFW_PCI_PHYS_HI_SPACE_MEM64' "${PCI_DW_SOURCE}"; then
	echo "R5C PCIe MEM64 patch did not apply to ${PCI_DW_SOURCE}" >&2
	exit 1
fi

if ! grep -Fq '<0x03000000 0x3 0x40000000 0x3 0x40000000' "${TARGET_DTS}" || \
    ! grep -Fq '<0x03000000 0x3 0x80000000 0x3 0x80000000' "${TARGET_DTS}"; then
	echo "R5C DTB does not contain the expected identity-mapped PCIe ranges." >&2
	exit 1
fi

echo "Installed the NanoPi R5C DTB, current PCIe ranges, and MEM64 iATU fix."
