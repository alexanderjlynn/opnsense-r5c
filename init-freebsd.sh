#!/bin/sh

set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "Run this script as root." >&2
	exit 1
fi

if [ "$(uname -s)" != "FreeBSD" ]; then
	echo "This initializer must run inside the FreeBSD VM." >&2
	exit 1
fi

if [ "$(uname -p)" != "aarch64" ]; then
	echo "Expected an aarch64 FreeBSD VM." >&2
	exit 1
fi

case "$(freebsd-version -u)" in
15.1-*) ;;
*)
	echo "Expected FreeBSD 15.1; found $(freebsd-version -u)." >&2
	exit 1
	;;
esac

echo "==> Installing the UTM guest agent"
if ! pkg -N >/dev/null 2>&1; then
	ASSUME_ALWAYS_YES=yes pkg bootstrap -f
fi
pkg install -y qemu-guest-agent

echo "==> Enabling SSH and the UTM guest agent"
sysrc sshd_enable=YES
sysrc qemu_guest_agent_enable=YES
sysrc qemu_guest_agent_flags="-d -v -l /var/log/qemu-ga.log"
sysrc -f /boot/loader.conf virtio_console_load=YES

SSHD_CONFIG=/etc/ssh/sshd_config
SSHD_BACKUP=/etc/ssh/sshd_config.before-r5c-build
if [ ! -f "${SSHD_BACKUP}" ]; then
	cp "${SSHD_CONFIG}" "${SSHD_BACKUP}"
fi

set_sshd_option()
{
	OPTION=$1
	VALUE=$2
	if grep -Eq "^[#[:space:]]*${OPTION}[[:space:]]+" "${SSHD_CONFIG}"; then
		sed -i '' -E \
		    "s|^[#[:space:]]*${OPTION}[[:space:]].*|${OPTION} ${VALUE}|" \
		    "${SSHD_CONFIG}"
	else
		printf '%s %s\n' "${OPTION}" "${VALUE}" >> "${SSHD_CONFIG}"
	fi
}

set_sshd_option PermitRootLogin yes
set_sshd_option PasswordAuthentication yes
/usr/sbin/sshd -t

kldload virtio_console >/dev/null 2>&1 || true
if service sshd status >/dev/null 2>&1; then
	service sshd restart
else
	service sshd start
fi
if service qemu-guest-agent status >/dev/null 2>&1; then
	service qemu-guest-agent restart
else
	service qemu-guest-agent start
fi

echo
echo "FreeBSD VM initialization complete."
echo "UTM should now be able to discover this VM automatically."
echo "If it cannot, pass one of these addresses to build-r5c-utm.sh --host:"
ifconfig -a | awk '$1 == "inet" && $2 !~ /^127\./ { print "  " $2 }'
echo
echo "Keep this VM running, then launch ./build-r5c-utm.sh on the Mac."
