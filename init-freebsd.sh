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
GUEST_AGENT_READY=yes
if ! pkg install -y qemu-guest-agent; then
	echo "WARNING: qemu-guest-agent installation failed; continuing with SSH." >&2
	GUEST_AGENT_READY=no
fi

echo "==> Enabling SSH"
sysrc sshd_enable=YES
if [ "${GUEST_AGENT_READY}" = yes ]; then
	sysrc qemu_guest_agent_enable=YES
	sysrc qemu_guest_agent_flags="-d -v -l /var/log/qemu-ga.log"
	sysrc -f /boot/loader.conf virtio_console_load=YES
fi

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

if service sshd status >/dev/null 2>&1; then
	service sshd restart
else
	service sshd start
fi
if [ "${GUEST_AGENT_READY}" = yes ]; then
	kldload virtio_console >/dev/null 2>&1 || true
	if service qemu-guest-agent status >/dev/null 2>&1; then
		if ! service qemu-guest-agent restart; then
			echo "WARNING: the UTM guest agent did not restart; use the printed IP address." >&2
		fi
	elif ! service qemu-guest-agent start; then
		echo "WARNING: the UTM guest agent did not start; use the printed IP address." >&2
	fi
fi

echo
echo "FreeBSD VM initialization complete."
echo "Use one of these addresses as the final build-r5c-utm.sh argument:"
ifconfig -a | awk '$1 == "inet" && $2 !~ /^127\./ { print "  " $2 }'
echo
echo "Example on the Mac: ./build-r5c-utm.sh 26.7.4 IP_ADDRESS"
