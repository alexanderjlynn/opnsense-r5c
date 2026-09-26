#!/bin/sh

set -eu

# Script to clone opnsense git and fire up the tools update.
# Builds the pkg version featured on opnsense ports repo
# Copies R5C device conf files and custom config files

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"
. ./env.sh

# Create LOGDIR
mkdir -p "${LOGDIR}"

# clone the opnsense/tools
if [ -d "${ROOTDIR}/tools/.git" ]; then
	echo "Reusing existing ${ROOTDIR}/tools checkout"
elif [ -e "${ROOTDIR}/tools" ]; then
	echo "${ROOTDIR}/tools exists but is not a Git checkout; refusing to overwrite it" >&2
	exit 1
else
	git clone --depth=1 https://github.com/opnsense/tools.git "${ROOTDIR}/tools"
fi

# fetch all source codes
make -C "${ROOTDIR}/tools" update

# Save current dir for future references
CURRENT_DIR=$(pwd)

# make and install the old version of pkg used by opnsense
PKG_PORT="${ROOTDIR}/ports/ports-mgmt/pkg"
if [ ! -d "${PKG_PORT}" ]; then
	PKG_PORT="${ROOTDIR}/ports/opnsense/pkg"
fi
if [ ! -d "${PKG_PORT}" ]; then
	echo "Could not locate the OPNsense pkg port under ${ROOTDIR}/ports" >&2
	exit 1
fi
BUILD_JOBS=${BUILD_JOBS:-$(sysctl -n hw.ncpu)}
make -C "${PKG_PORT}" -j"${BUILD_JOBS}"
pkg unlock -y pkg >/dev/null 2>&1 || true
#make deinstall
make -C "${PKG_PORT}" reinstall
pkg lock -y pkg

# Back to initial dir
cd "${CURRENT_DIR}"

echo "Copy R5C conf files"
cp "${SRC_DIR}/R5C_UBOOT.conf" "${SRC_DIR}/R5C_USB.conf" "${ROOTDIR}/tools/device"

# Legacy R5S/OP5P targets, uncomment if still needed
#cp $SRC_DIR/R5S_USB.conf $SRC_DIR/R5S_UBOOT.conf $SRC_DIR/R5S_EDK2.conf $SRC_DIR/OP5P_MBR.conf /usr/tools/device

#echo "Copy custom .conf files"
#cp $SRC_DIR/extras.conf $SRC_DIR/plugins.conf $SRC_DIR/ports.conf /usr/tools/config/$VERSION/

# There is no u-boot-nanopi-r5c port upstream (only r5s), so create a local
# slave port of sysutils/u-boot-master and build it from the ports tree
echo "Create and install local sysutils/u-boot-nanopi-r5c port"
mkdir -p "${ROOTDIR}/ports/sysutils/u-boot-nanopi-r5c"
cp -R u-boot-nanopi-r5c/. "${ROOTDIR}/ports/sysutils/u-boot-nanopi-r5c/"
if pkg info -e u-boot-nanopi-r5c; then
	make -C "${ROOTDIR}/ports/sysutils/u-boot-nanopi-r5c" reinstall clean
else
	make -C "${ROOTDIR}/ports/sysutils/u-boot-nanopi-r5c" install clean
fi

# Legacy R5S boot bits, uncomment if still needed
#pkg install u-boot-nanopi-r5s
#mkdir -p /usr/local/share/edk2/
#cp -Rv edk2-nanopi-r5s /usr/local/share/edk2/

echo "==> About custom .conf build files"
echo " As in every new version there can be new lines on the files, they are not copied by default anymore. As a hint, compare files to the ones from this repository and adjust as needed."
