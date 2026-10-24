#!/bin/sh
# y700 power tweaks (2026-10-15: the simple changes the measurements point to, first). Run as root on the tablet.
#   1. memlat devfreq read-back polled every 1 s instead of 2 ms (udev rule, applied now and at boot)
#   2. panel idle refresh: 60 Hz after 0.5 s and 30 Hz after 2 s without a frame (helper preset
#      power-saver, stored in the helper's own config; input still restores 120 Hz at once)
# Undo: rm /etc/udev/rules.d/90-y700-memlat-poll.rules; tb323fu-ctl refresh preset balanced;
#       systemctl disable --now y700-dumpmode-off.timer; echo full > /sys/module/qcom_scm/parameters/download_mode
set -e
SRC=$(cd "$(dirname "$0")" && pwd)
install -m 644 "$SRC/90-y700-memlat-poll.rules" /etc/udev/rules.d/90-y700-memlat-poll.rules
udevadm control --reload
udevadm trigger --subsystem-match=devfreq --action=change
udevadm settle     # the rule is applied asynchronously: without this the first read can still say 2
for d in ddr llcc ddr-qos; do
	[ -e /sys/class/devfreq/$d/polling_interval ] && echo "$d polling_interval $(cat /sys/class/devfreq/$d/polling_interval)"
done
#   3. (only with --dumpmode-off, the owner's call) leave Qualcomm crash-dump mode 3 min after boot
#   4. TEO idle governor via tmpfiles (see below)
#   5. USB controller allowed to runtime-suspend (90-y700-usb-rpm.rules)
if [ "$1" = --dumpmode-off ]; then
	install -m 644 "$SRC/y700-dumpmode-off.service" "$SRC/y700-dumpmode-off.timer" /etc/systemd/system/
	systemctl daemon-reload
	systemctl enable --now y700-dumpmode-off.timer
	systemctl start y700-dumpmode-off.service       # this boot too (uptime is already past 3 min)
	echo "download_mode now: $(cat /sys/module/qcom_scm/parameters/download_mode)"
fi
#   4. TEO cpuidle governor (y8+ kernels have it; a no-op where only menu exists)
if grep -q teo /sys/devices/system/cpu/cpuidle/available_governors 2>/dev/null; then
	install -m 644 "$SRC/y700-cpuidle.conf" /etc/tmpfiles.d/y700-cpuidle.conf
	systemd-tmpfiles --create /etc/tmpfiles.d/y700-cpuidle.conf
	echo "cpuidle governor: $(cat /sys/devices/system/cpu/cpuidle/current_governor)"
fi
#   5. USB controller runtime PM (udev rule; applied now too)
install -m 644 "$SRC/90-y700-usb-rpm.rules" /etc/udev/rules.d/90-y700-usb-rpm.rules
udevadm control --reload; echo auto > /sys/bus/platform/devices/a600000.usb/power/control
echo "usb controller control: $(cat /sys/bus/platform/devices/a600000.usb/power/control)"
tb323fu-ctl refresh preset power-saver
tb323fu-ctl --json status | python3 -c 'import json,sys; r=json.load(sys.stdin)["Refresh"]; print("refresh idle", r.get("IdleMs60"), r.get("IdleMs30"), r.get("Policy"))'
echo POWER_OK
