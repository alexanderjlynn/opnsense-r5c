#!/bin/sh

# Script to clone opnsense git and fire up the tools update.
# Builds the pkg version featured on opnsense ports repo
# Copies R5C device conf files and custom config files

. env.sh

# Create LOGDIR
mkdir -p $LOGDIR

# clone the opnsense/tools
git clone --depth=1 https://github.com/opnsense/tools.git /usr/tools

# fetch all source codes
make -C /usr/tools update

# Save current dir for future references
CURRENT_DIR=`pwd`

# make and install the old version of pkg used by opnsense
cd /usr/ports/ports-mgmt/pkg/
make -j4
pkg unlock -y pkg
#make deinstall
make reinstall
pkg lock -y pkg

# Back to initial dir
cd $CURRENT_DIR

echo "Copy R5C conf files"
cp $SRC_DIR/R5C_UBOOT.conf $SRC_DIR/R5C_USB.conf /usr/tools/device

# Legacy R5S/OP5P targets, uncomment if still needed
#cp $SRC_DIR/R5S_USB.conf $SRC_DIR/R5S_UBOOT.conf $SRC_DIR/R5S_EDK2.conf $SRC_DIR/OP5P_MBR.conf /usr/tools/device

echo "Copy custom rc file"
cp $SRC_DIR/usr-core-src-etc-rc /usr/core/src/etc/rc

#echo "Copy custom .conf files"
#cp $SRC_DIR/extras.conf $SRC_DIR/plugins.conf $SRC_DIR/ports.conf /usr/tools/config/$VERSION/

# There is no u-boot-nanopi-r5c port upstream (only r5s), so create a local
# slave port of sysutils/u-boot-master and build it from the ports tree
echo "Create and install local sysutils/u-boot-nanopi-r5c port"
cp -Rv u-boot-nanopi-r5c /usr/ports/sysutils/
make -C /usr/ports/sysutils/u-boot-nanopi-r5c install clean

# Legacy R5S boot bits, uncomment if still needed
#pkg install u-boot-nanopi-r5s
#mkdir -p /usr/local/share/edk2/
#cp -Rv edk2-nanopi-r5s /usr/local/share/edk2/

echo "==> About custom .conf build files"
echo " As in every new version there can be new lines on the files, they are not copied by default anymore. As a hint, compare files to the ones from this repository and adjust as needed."
