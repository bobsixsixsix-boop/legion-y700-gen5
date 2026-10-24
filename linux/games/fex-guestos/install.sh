#!/bin/bash
# Install the FEX guest rootfs mount on the tablet (run as root from this directory).
# The image itself: /root/y700-guestos-fetch.sh downloads and verifies ArchLinux.sqsh into /usr/local/share/y700/guestos/.
set -e
cd "$(dirname "$0")"
install -Dm0755 y700-guestos-mount /usr/local/sbin/y700-guestos-mount
install -Dm0644 y700-guestos.service /etc/systemd/system/y700-guestos.service
systemctl daemon-reload
systemctl enable --now y700-guestos.service
systemctl --no-pager status y700-guestos.service | head -5
findmnt /usr/share/guestos/fex-mesa
