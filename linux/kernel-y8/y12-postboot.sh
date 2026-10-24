#!/bin/bash
# y12-postboot.sh: everything to check / redo after the first y12 boot (2026-10-16). ROOT. Prints a summary.
#  1. y12-verify.sh (y10 checks + GMU vote-table checks)
#  2. the items that were waiting for "the next boot": boot-race waits (KWin sensor proxy, plasmashell tuned sink),
#     raw speaker sink no longer HARDWARE (61-y700-speaker-raw-virtual.conf), tuned sink HARDWARE, GPU thresholds 80/10
#  3. re-create the transient night ladder timer the reboot dropped (same unit name and arguments as 10-16 12:3x)
set -u
export LC_ALL=C
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus LC_ALL=C)
echo "=== 1. y12-verify"
Y10_NO_TOGGLE=${Y10_NO_TOGGLE:-0} bash /root/y12-verify.sh 2>&1 | grep -E "^(FAIL|INFO)|^      |ALL PASS|SOME FAILED"
echo "=== 2. waiting-for-reboot items"
"${U[@]}" journalctl --user -b -u plasma-kwin_wayland -u plasma-plasmashell --no-pager -o cat 2>/dev/null | grep -iE "sensor proxy|tuned sink|y700-wait" | tail -4
"${U[@]}" pactl list sinks 2>/dev/null | awk '/^\tName:/ {n = $2} /^\tFlags:/ {print "  " n ": " $0}' | sed 's/\tFlags: //'
echo "  default sink: $("${U[@]}" pactl get-default-sink 2>/dev/null)"
for d in /sys/kernel/debug/dri/1/devfreq; do echo "  GPU thresholds: $(cat $d/upthreshold)/$(cat $d/downdifferential) (want 80/10); unit $(systemctl is-active y700-gpu-dvfs)"; done
echo "  speaker gain: $(amixer -c0 cget name=aw_dev_0_volume 2>/dev/null | grep -oE 'values=[0-9]+' | tail -1)"
echo "=== 3. night ladder timer"
# not while y12 is an unconfirmed trial (10-16 review): a reset in the night (E3a/E5 power domains, E4 screen cycles that
# restart the GMU with the new vote tables) could not be told apart from a y12 fault, and every reset uses up one of the
# two trial starts - the next morning would silently run y10 again. Keep (or roll back) first, then re-run this script.
if tb323fu-ctl kernel 2>/dev/null | grep -qE "^trial .*start [0-9]+ of [0-9]+"; then
	echo "  y12 is still on trial ($(tb323fu-ctl kernel 2>/dev/null | grep -oE 'start [0-9]+ of [0-9]+')): night ladder NOT re-created; keep or roll back first"
elif systemctl list-timers --all --no-legend 2>/dev/null | grep -q y700-cx-night.timer; then
	echo "  already there: $(systemctl list-timers --all --no-legend y700-cx-night.timer)"
elif [ "$(date +%s)" -lt "$(date -d '2026-10-17 00:30:00' +%s)" ]; then
	systemd-run --unit=y700-cx-night --collect -p KillMode=mixed --on-calendar="2026-10-17 00:30:00" \
		--timer-property=RemainAfterElapse=no \
		/usr/local/libexec/cx-when-idle.sh --idle 30 --until 06:00 E3a:30 E5:30 E4:40 2>&1 | tail -1
	systemctl list-timers --all --no-legend y700-cx-night.timer
else
	echo "  00:30 already passed: not re-created"
fi
echo "=== kernel"; tb323fu-ctl kernel 2>&1 | sed -n 1,5p
