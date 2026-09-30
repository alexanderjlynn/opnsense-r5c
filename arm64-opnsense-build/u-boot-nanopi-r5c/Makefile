MASTERDIR=	${.CURDIR}/../u-boot-master

MODEL=		nanopi-r5c
BOARD_CONFIG=	nanopi-r5c-rk3568_defconfig
FAMILY=		rk356X

# Keep the first R5C port deliberately close to the known-working R5S boot
# path: removable SD and onboard eMMC only.  R5C_DIAGNOSTIC=yes selects a
# temporary build that leaves pre-EFI evidence without requiring UART.
R5C_DIAGNOSTIC?=	no
.if ${R5C_DIAGNOSTIC:tl} == "yes"
FRAGMENT_NAME=		sd_emmc_diagnostic_fragment
.else
FRAGMENT_NAME=		sd_emmc_fragment
.endif
CONFIG_FRAGMENT=	${.CURDIR}/files/${FRAGMENT_NAME}

.include "${MASTERDIR}/Makefile"
