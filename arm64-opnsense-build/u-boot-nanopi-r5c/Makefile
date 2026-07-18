MASTERDIR=	${.CURDIR}/../u-boot-master

MODEL=		nanopi-r5c
BOARD_CONFIG=	nanopi-r5c-rk3568_defconfig
FAMILY=		rk356X

# The stock defconfig enables PCIe but not NVMe. Merge it in so u-boot
# exposes an NVMe drive (M.2 Key-E -> M-key adapter) as an EFI block
# device and can boot the system straight from it.
FRAGMENT_NAME=		nvme_fragment
CONFIG_FRAGMENT=	${.CURDIR}/files/${FRAGMENT_NAME}

.include "${MASTERDIR}/Makefile"
