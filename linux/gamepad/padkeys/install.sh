#!/bin/sh
# Build and install y700-padkeys on the tablet (run as root from this directory).
#   /usr/local/bin/y700-padkeys
#   /etc/systemd/system/y700-padkeys@.service
#   /etc/udev/rules.d/69-y700-padkeys.rules
# The double tap needs the y700-taskswitcher KWin effect's "y700-taskswitcher" shortcut
# (linux/gesture/taskswitcher/install.sh). --remove undoes it all and gives the plain pad back to apps.
set -e
cd "$(dirname "$0")"
# first version (2026-10-20 morning): a passive user unit; gone
rm -f /etc/systemd/user/y700-padkeys@.service /etc/udev/rules.d/71-y700-padkeys.rules
pad_retrigger() {
    for d in /sys/class/input/event* /sys/class/input/js*; do
        grep -qx 3537 "$d/device/id/vendor" 2>/dev/null || continue
        grep -qx 1136 "$d/device/id/product" 2>/dev/null || continue
        udevadm trigger --action=add "$d"
    done
}
if [ "$1" = "--remove" ]; then
    systemctl stop 'y700-padkeys@*' 2>/dev/null || true
    rm -f /usr/local/bin/y700-padkeys /etc/systemd/system/y700-padkeys@.service /etc/udev/rules.d/69-y700-padkeys.rules
    systemctl daemon-reload
    udevadm control --reload
    pad_retrigger
    echo REMOVE_OK
    exit 0
fi
cargo build --release --offline
systemctl stop 'y700-padkeys@*' 2>/dev/null || true
install -Dm755 target/release/y700-padkeys /usr/local/bin/y700-padkeys
install -Dm644 y700-padkeys@.service /etc/systemd/system/y700-padkeys@.service
install -Dm644 69-y700-padkeys.rules /etc/udev/rules.d/69-y700-padkeys.rules
systemctl daemon-reload
udevadm control --reload
# a pad that is already on: replay its add events (hides the real nodes, starts the unit)
pad_retrigger
echo INSTALL_OK
