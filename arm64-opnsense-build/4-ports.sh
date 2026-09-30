#!/bin/sh

set -eu

# Script to build ports. Logs time it starts and finishes.

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"
. ./env.sh

log_print "${TAG_SRC}" "${LOG}" "${DATE}" Start

PORTS_TARGET=ports
if [ "$#" -gt 0 ]; then
	# OPNsense uses target arguments to invalidate selected packages, but its
	# ports step still walks every origin in ports.conf.  For a boot-only
	# package refresh, temporarily narrow that list to the requested origins.
	# The complete existing package repository is still extracted and bundled;
	# only the build loop is restricted.  Always restore the release config,
	# including when make fails or this script is interrupted.
	PORTS_CONF="${ROOTDIR}/tools/config/${VERSION}/ports.conf"
	PORTS_CONF_BACKUP=$(mktemp "${PORTS_CONF}.r5c.XXXXXX")
	cp -p "${PORTS_CONF}" "${PORTS_CONF_BACKUP}"
	restore_ports_conf()
	{
		if [ -f "${PORTS_CONF_BACKUP}" ]; then
			cp -p "${PORTS_CONF_BACKUP}" "${PORTS_CONF}"
			rm -f "${PORTS_CONF_BACKUP}"
		fi
	}
	trap 'restore_ports_conf' 0 1 2 15
	: > "${PORTS_CONF}"
	for PORT_ORIGIN in "$@"; do
		printf '%s\n' "${PORT_ORIGIN}" >> "${PORTS_CONF}"
	done

	# Encode the arguments in the make target so the selected package is
	# removed from the extracted repository before it is rebuilt.
	PORTS_ARGUMENTS=$(IFS=,; echo "$*")
	PORTS_TARGET="ports-${PORTS_ARGUMENTS}"
fi
if [ "$#" -gt 0 ]; then
	# DEPEND=yes also invalidates the core and plugin packages whenever a port
	# is refreshed.  That is correct for a normal release pipeline, but a
	# boot-only driver refresh must retain the already-built opnsense package.
	make -C "${ROOTDIR}/tools" VERSION="${TAG_PORTS}" DEVICE="${DEVICE}" \
	    PORTSENV="DEPEND=no" "${PORTS_TARGET}"
else
	make -C "${ROOTDIR}/tools" VERSION="${TAG_PORTS}" DEVICE="${DEVICE}" \
	    "${PORTS_TARGET}"
fi

if [ "$#" -gt 0 ]; then
	restore_ports_conf
	trap - 0 1 2 15
fi

log_print "${TAG_SRC}" "${LOG}" "${DATE}" Complete
