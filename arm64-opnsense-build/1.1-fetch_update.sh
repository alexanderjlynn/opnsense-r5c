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

# Remove only this repository's prior generated source edits before the
# upstream updater checks out the exact tag.  No unrelated source changes are
# touched.
sh ./apply-r5c-source.sh --clean
for TOOLS_PATH in build/arm.sh "config/${VERSION}/extras.conf"; do
	if git -C "${ROOTDIR}/tools" ls-files --error-unmatch \
	    "${TOOLS_PATH}" >/dev/null 2>&1; then
		git -C "${ROOTDIR}/tools" checkout -- "${TOOLS_PATH}"
	fi
done

# Fetch every source tree at the requested point release.  Passing VERSION is
# essential: without it, update follows the release branches (for example the
# initial 26.7 tag) while the later stages label the output as 26.7.4.  A
# boot-only rebuild may run after a temporary VM loses Internet access.  Allow
# the existing exact-tag verification below to decide whether cached sources
# are safe in that case; it still rejects any missing tag or mismatched HEAD.
if ! make -C "${ROOTDIR}/tools" VERSION="${TAG_SRC}" DEVICE="${DEVICE}" update; then
	echo "Source update failed; checking whether every local checkout is already at exact tag ${TAG_SRC}." >&2
fi

# Fail here, before an hours-long build, if any checkout does not match the
# exact tag selected by the user.
SOURCE_MANIFEST="${LOGDIR}/sources.${TAG_SRC}.manifest"
SOURCE_MANIFEST_NEW="${SOURCE_MANIFEST}.new.$$"
: > "${SOURCE_MANIFEST_NEW}"
for REPOSITORY in tools src core plugins ports; do
	REPOSITORY_DIR="${ROOTDIR}/${REPOSITORY}"
	EXPECTED_COMMIT=$(git -C "${REPOSITORY_DIR}" rev-list -n 1 \
	    "refs/tags/${TAG_SRC}" 2>/dev/null || true)
	ACTUAL_COMMIT=$(git -C "${REPOSITORY_DIR}" rev-parse HEAD 2>/dev/null || true)
	if [ -z "${EXPECTED_COMMIT}" ] || [ "${ACTUAL_COMMIT}" != "${EXPECTED_COMMIT}" ]; then
		echo "${REPOSITORY_DIR} is not checked out at exact tag ${TAG_SRC}." >&2
		exit 1
	fi
	echo "Verified ${REPOSITORY} at ${TAG_SRC} (${ACTUAL_COMMIT})"
	printf '%s=%s\n' "${REPOSITORY}" "${ACTUAL_COMMIT}" >> "${SOURCE_MANIFEST_NEW}"
done

# Generated sets are safe to reuse only when their recorded source commits
# match.  Older versions of this script did not write a manifest and could
# accidentally label branch-tip (for example 26.7) output as a point release
# (for example 26.7.4), so invalidate unverified cached output as well.
SETS_DIR="/usr/local/opnsense/build/${VERSION}/aarch64/sets"
STALE_OUTPUT=no
if [ -f "${SOURCE_MANIFEST}" ]; then
	if ! cmp -s "${SOURCE_MANIFEST}" "${SOURCE_MANIFEST_NEW}"; then
		STALE_OUTPUT=yes
	fi
elif [ -d "${SETS_DIR}" ] && [ -n "$(find "${SETS_DIR}" -type f -print -quit)" ]; then
	STALE_OUTPUT=yes
fi

if [ "${STALE_OUTPUT}" = yes ]; then
	echo "Source provenance changed or is unknown; removing stale generated build output."
	make -C "${ROOTDIR}/tools" VERSION="${TAG_SRC}" DEVICE="${DEVICE}" \
	    clean-sets,images,obj
fi
mv "${SOURCE_MANIFEST_NEW}" "${SOURCE_MANIFEST}"

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
# Do not parallelize the ports framework targets themselves.  It manages
# parallelism for the port's vendor build; top-level -j can race fetch/extract
# cookie targets on newer bmake versions.
make -C "${PKG_PORT}" clean
make -C "${PKG_PORT}"
pkg unlock -y pkg >/dev/null 2>&1 || true
#make deinstall
make -C "${PKG_PORT}" reinstall
pkg lock -y pkg

# The FreeBSD host package repository can contain a newer Perl patch release
# than this tagged OPNsense ports tree.  Its broad package dependency is then
# satisfied, but ports still invoke the tag's exact versioned interpreter.
# Install that exact version from the checked-out tree when it is absent.
PERL_PROBE_PORT="${ROOTDIR}/ports/devel/p5-Locale-gettext"
if [ -d "${PERL_PROBE_PORT}" ]; then
	PERL_BIN=$(make -C "${PERL_PROBE_PORT}" -V PERL5)
	PERL_PORT=$(make -C "${PERL_PROBE_PORT}" -V PERL_PORT)
	if [ -z "${PERL_BIN}" ] || [ -z "${PERL_PORT}" ]; then
		echo "Could not determine the tagged ports tree's Perl version" >&2
		exit 1
	fi
	echo "Checking tagged Perl interpreter: ${PERL_BIN}"
	if [ ! -x "${PERL_BIN}" ]; then
		case "${PERL_PORT}" in
		perl5.*|perl5-devel) ;;
		*)
			echo "Unexpected Perl port name: ${PERL_PORT}" >&2
			exit 1
			;;
		esac
		PERL_PORT_DIR="${ROOTDIR}/ports/lang/${PERL_PORT}"
		[ -d "${PERL_PORT_DIR}" ] || {
			echo "Tagged Perl port is missing: ${PERL_PORT_DIR}" >&2
			exit 1
		}
		echo "Installing tagged ${PERL_PORT}; missing ${PERL_BIN}"
		pkg unlock -y perl5 >/dev/null 2>&1 || true
		make -C "${PERL_PORT_DIR}" clean
		make -C "${PERL_PORT_DIR}" reinstall
	fi
	if [ ! -x "${PERL_BIN}" ]; then
		echo "Tagged Perl installation did not restore ${PERL_BIN}" >&2
		exit 1
	fi
fi

# Back to initial dir
cd "${CURRENT_DIR}"

echo "Copy R5C conf files"
cp "${SRC_DIR}/R5C_UBOOT.conf" "${SRC_DIR}/R5C_DIAG.conf" \
    "${SRC_DIR}/R5C_USB.conf" "${ROOTDIR}/tools/device"

# FreeBSD 15.1 ships the R5S DTB but omits the closely related R5C DTB.
# Install the upstream R5C description and register it in the Rockchip DTB
# module.  The local copy intentionally disables only the optional M.2 lane;
# both PCIe controllers used by the onboard RTL8125B NICs remain enabled.
sh ./apply-r5c-source.sh

# Add a more useful failure message to the original R5S-compatible Realtek
# driver.  If a future RTL8125 revision is not recognized, the SD diagnostic
# log will include the TXCFG value needed to identify it rather than only
# saying "unknown device".
echo "Install R5C diagnostics for net/realtek-re-kmod198"
cp -R realtek-re-kmod198/. "${ROOTDIR}/ports/net/realtek-re-kmod198/"

# Legacy R5S/OP5P targets, uncomment if still needed
#cp $SRC_DIR/R5S_USB.conf $SRC_DIR/R5S_UBOOT.conf $SRC_DIR/R5S_EDK2.conf $SRC_DIR/OP5P_MBR.conf /usr/tools/device

#echo "Copy custom .conf files"
#cp $SRC_DIR/extras.conf $SRC_DIR/plugins.conf $SRC_DIR/ports.conf /usr/tools/config/$VERSION/

# There is no u-boot-nanopi-r5c port upstream (only r5s), so create a local
# slave port of sysutils/u-boot-master and build it from the ports tree
echo "Create and install local sysutils/u-boot-nanopi-r5c port"
mkdir -p "${ROOTDIR}/ports/sysutils/u-boot-nanopi-r5c"
cp -R u-boot-nanopi-r5c/. "${ROOTDIR}/ports/sysutils/u-boot-nanopi-r5c/"

# A reused build VM may still contain automatic Python build dependencies from
# the previous ports snapshot.  Python-flavored ports install some unsuffixed
# command links, so an old flavor (for example py311-build) conflicts with the
# current tree's flavor (for example py312-build).  Derive the U-Boot dependency
# closure and remove only automatic, alternate Python flavors from that closure.
# The current dependencies are then installed normally by the ports framework.
UBOOT_PORT="${ROOTDIR}/ports/sysutils/u-boot-nanopi-r5c"
PYTHON_PREFIX=$(make -C "${UBOOT_PORT}" -V PYTHON_PKGNAMEPREFIX)
case "${PYTHON_PREFIX}" in
py[0-9][0-9][0-9]-) ;;
*)
	echo "Unexpected U-Boot Python package prefix: ${PYTHON_PREFIX}" >&2
	exit 1
	;;
esac

DEPENDENCY_ORIGINS=$(mktemp -t r5c-dependency-origins)
STALE_PYTHON_PACKAGES=$(mktemp -t r5c-stale-python)
cleanup_dependency_files()
{
	rm -f "${DEPENDENCY_ORIGINS}" "${STALE_PYTHON_PACKAGES}"
}
trap cleanup_dependency_files 0 1 2 15

make -C "${UBOOT_PORT}" all-depends-list | \
    sed "s#^${ROOTDIR}/ports/##" | sort -u > "${DEPENDENCY_ORIGINS}"
pkg query '%n %o %a' | while read -r PACKAGE ORIGIN AUTOMATIC; do
	case "${PACKAGE}" in
	py[0-9][0-9][0-9]-*)
		case "${PACKAGE}" in
		"${PYTHON_PREFIX}"*) continue ;;
		esac
		if [ "${AUTOMATIC}" = 1 ] && \
		    grep -Fqx "${ORIGIN}" "${DEPENDENCY_ORIGINS}"; then
			printf '%s\n' "${PACKAGE}" >> "${STALE_PYTHON_PACKAGES}"
		fi
		;;
	esac
done

if [ -s "${STALE_PYTHON_PACKAGES}" ]; then
	echo "Removing obsolete automatic Python build flavors:"
	sed 's/^/  /' "${STALE_PYTHON_PACKAGES}"
	# Package names cannot contain whitespace; intentional field splitting
	# passes the generated list as individual pkg-delete arguments.
	# shellcheck disable=SC2046
	pkg delete -y $(cat "${STALE_PYTHON_PACKAGES}")
fi
cleanup_dependency_files
trap - 0 1 2 15

if pkg info -e u-boot-nanopi-r5c; then
	make -C "${UBOOT_PORT}" reinstall clean
else
	make -C "${UBOOT_PORT}" install clean
fi

# Legacy R5S boot bits, uncomment if still needed
#pkg install u-boot-nanopi-r5s
#mkdir -p /usr/local/share/edk2/
#cp -Rv edk2-nanopi-r5s /usr/local/share/edk2/

echo "==> About custom .conf build files"
echo " As in every new version there can be new lines on the files, they are not copied by default anymore. As a hint, compare files to the ones from this repository and adjust as needed."
