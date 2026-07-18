#!/bin/sh

# Installs the custom extras.conf into the tools config and keeps a snapshot
# of the upstream plugins/ports conf files in this repository.
# Since OPNsense 26.7 (FreeBSD 15.1) the stock net/realtek-re-kmod driver
# works on RK3568 boards, so the old realtek 1.98 pinning is gone.

. env.sh

pwd

# Copy extras.conf file
echo "cp $SRC_DIR/extras.conf /usr/tools/config/$VERSION/"
cp $SRC_DIR/extras.conf /usr/tools/config/$VERSION/

# Snapshot upstream conf files for reference
cp /usr/tools/config/$VERSION/plugins.conf /usr/tools/config/$VERSION/ports.conf $SRC_DIR/

exit 0
