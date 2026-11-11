#!/bin/sh
# Install the Magic Mouse / Magic Keyboard files of linux/owner-devices/ on the tablet (README「Magic 键鼠」). Idempotent;
# run as root in this directory (the repo's linux/owner-devices/ scp'd to the tablet as one directory):  sh install.sh
# - 90-y700-magicmouse.rules -> /etc/udev/rules.d/  : a Magic Mouse hid "add" event runs y700-extra-modules hid-magicmouse
# - y700-extra-modules       -> /usr/local/sbin/    : modprobe the kernel's own module (y20 on: CONFIG_HID_MAGICMOUSE=m), or
#                               insmod the out-of-tree build in /usr/local/lib/y700-extra-modules/<release>/ on a kernel
#                               without it (y19), with the options of /etc/modprobe.d
# - hid_magicmouse.conf      -> /etc/modprobe.d/    : options hid_magicmouse scroll_acceleration=1
# - hid_apple.conf           -> /etc/modprobe.d/    : options hid_apple fnmode=2 (Magic Keyboard: F-keys are F-keys)
# Not installed here: the out-of-tree hid-magicmouse.ko (built on the tablet against the running tree, for y19 alone).
# The options take effect at the module's next load (modprobe -r hid_magicmouse first, or reconnect after a reboot); the
# rule at the next hid add event (udevadm control --reload below).
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
FILES="90-y700-magicmouse.rules y700-extra-modules hid_magicmouse.conf hid_apple.conf"
for f in $FILES; do [ -f "$f" ] || { echo "missing $f in $(pwd)"; exit 1; }; done
install -m 644 90-y700-magicmouse.rules /etc/udev/rules.d/90-y700-magicmouse.rules
install -m 755 y700-extra-modules /usr/local/sbin/y700-extra-modules
install -m 644 hid_magicmouse.conf /etc/modprobe.d/hid_magicmouse.conf
install -m 644 hid_apple.conf /etc/modprobe.d/hid_apple.conf
udevadm control --reload
for f in /etc/udev/rules.d/90-y700-magicmouse.rules /usr/local/sbin/y700-extra-modules /etc/modprobe.d/hid_magicmouse.conf /etc/modprobe.d/hid_apple.conf; do
	cmp -s "$f" "$(basename "$f")" || { echo "$f differs from the file here after install"; exit 1; }
done
echo "installed: /etc/udev/rules.d/90-y700-magicmouse.rules /usr/local/sbin/y700-extra-modules /etc/modprobe.d/hid_magicmouse.conf /etc/modprobe.d/hid_apple.conf"
r=$(uname -r)
if modprobe -q -n hid_magicmouse 2>/dev/null; then echo "hid-magicmouse on $r: the kernel's own module (y700-extra-modules will modprobe it)"
elif [ -e "/usr/local/lib/y700-extra-modules/$r/hid-magicmouse.ko" ]; then echo "hid-magicmouse on $r: not in the kernel, the out-of-tree /usr/local/lib/y700-extra-modules/$r/hid-magicmouse.ko is there"
else echo "WARNING hid-magicmouse on $r: not in the kernel and no /usr/local/lib/y700-extra-modules/$r/hid-magicmouse.ko: the mouse will run on hid-generic (README「Magic 键鼠」)"; fi
