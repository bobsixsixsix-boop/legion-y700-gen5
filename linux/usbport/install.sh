#!/bin/bash
# Install y700-usb-port over tb323fu-platform's tb323fu-usb-port (run on the tablet as root,
# from the directory holding these files). Backs up nothing in /usr: the package files stay
# untouched and are only shadowed by /etc (udev rule of the same name, service drop-in).
set -e
cd "$(dirname "$0")"
install -Dm755 y700-usb-port /usr/local/libexec/y700-usb-port
install -Dm644 70-tb323fu-usb-port.rules /etc/udev/rules.d/70-tb323fu-usb-port.rules
install -Dm644 tb323fu-usb-port.service.d/y700.conf /etc/systemd/system/tb323fu-usb-port.service.d/y700.conf
systemctl daemon-reload
udevadm control --reload
# warn if the packaged script changed since 0.4.2 (merge it into y700-usb-port then)
if ! cmp -s tb323fu-usb-port.upstream-0.4.2 /usr/libexec/tb323fu/tb323fu-usb-port; then
	echo "WARNING: /usr/libexec/tb323fu/tb323fu-usb-port differs from the 0.4.2 copy" >&2
fi
/usr/local/libexec/y700-usb-port
cat /run/y700-usb-port.state
