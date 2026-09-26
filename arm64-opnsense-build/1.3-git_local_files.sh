#!/bin/sh

set -eu

# Creates the release-local core branch and commits the R5C rc/fingerprint.

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"
. ./env.sh

cd "${ROOTDIR}/core"

git checkout -f -B "${TAG_SRC}-local" "${TAG_SRC}"
git config user.name >/dev/null 2>&1 || git config user.name "OPNsense R5C Builder"
git config user.email >/dev/null 2>&1 || git config user.email "builder@localhost"

# Apply the R5C changes only after selecting the requested release tag.  This
# avoids a checkout conflict when the VM is reused for another point release.
cp "${SCRIPT_DIR}/${SRC_DIR}/usr-core-src-etc-rc" src/etc/rc
cp "${LOGDIR}/apartnet.${OPNSENSE_RELEASE}" \
    src/etc/pkg/fingerprints/OPNsense/trusted/apartnet
git add -f src/etc/pkg/fingerprints/OPNsense/trusted/apartnet
git add src/etc/rc
if ! git diff --cached --quiet; then
	git commit -m "Updating code: adding custom rc and fingerprint"
fi
make plist-fix
git add -A
if ! git diff --cached --quiet; then
	git commit -m "Commit after make plist-fix"
fi

echo "==> Remember to use the custom branch created here on make core. env.sh checked already has this"
