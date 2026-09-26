#!/bin/sh

set -eu

# Checks if there is repo.key, if not it generates one and creates a fingerprint for the package and update repository that may be generated later on

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"
. ./env.sh

cd "${ROOTDIR}/tools"

if [ -f config/$VERSION/repo.key ]; then
 echo "Repository key present"
else
 echo "Needs generate repository key"
 openssl genrsa -out config/$VERSION/repo.key 4096
 openssl rsa -pubout -in config/$VERSION/repo.key -out config/$VERSION/repo.pub
 chmod 600 config/$VERSION/repo.key

fi

echo "Generating fingerprint and installing under ${ROOTDIR}/core"
mkdir -p "${LOGDIR}"
make fingerprint > "${LOGDIR}/apartnet.${OPNSENSE_RELEASE}"
cp "${LOGDIR}/apartnet.${OPNSENSE_RELEASE}" \
    "${ROOTDIR}/core/src/etc/pkg/fingerprints/OPNsense/trusted/apartnet"
