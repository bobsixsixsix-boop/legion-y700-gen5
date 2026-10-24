#!/bin/bash
# 2026-10-18 07:5x: second daytime try. In the first one (daytest.sh) Claude desktop's compositor relapsed by itself at
# 07:17:55, 18 min after the screen cycle, with the Win11 session silent - so E3a got 7 good minutes and E3b none. Now:
# screen on 10 s / off right before EACH step, then cx-when-idle with --idle 1 so the step starts ~1 min later.
# Same once-a-minute logger. Run as a y700-cx-* unit so cx-auto yields:
#   systemd-run --unit y700-cx-day2 --collect -p KillMode=mixed /bin/bash /root/daytest2.sh E3b:15 E3c:15
export LC_ALL=C
G=/sys/kernel/debug/pm_genpd
U="sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
OUT=/root/runs/day-20261018/vizlog2.txt
mkdir -p "$(dirname "$OUT")"
VIZ=$(for t in /proc/[0-9]*/task/[0-9]*; do [ "$(cat $t/comm 2>/dev/null)" = VizCompositorTh ] && echo $t; done)
echo "# $(date '+%F %T') columns: time dpms ctxt of [$(echo $VIZ | tr ' ' ',')] then cluster cluster1 system usage" >> $OUT
(
	while :; do
		echo "$(date +%T) $(cat /sys/class/drm/card*-DSI-1/dpms | head -1) $(for t in $VIZ; do awk '/ctxt_switches/ {s += $2} END {printf "%d ", s}' $t/status 2>/dev/null; done)$(for d in cluster cluster1 system; do sed -n 2p $G/power-domain-$d/idle_states | awk '{printf "%s ", $3}'; done)" >> $OUT
		sleep 60
	done
) &
LOGGER=$!
for step in "$@"; do
	$U kscreen-doctor --dpms on >/dev/null 2>&1; sleep 10; $U kscreen-doctor --dpms off >/dev/null 2>&1
	echo "# $(date +%T) screen cycled before $step" >> $OUT
	/usr/local/libexec/cx-when-idle.sh --idle 1 --until 09:00 "$step"
	rc=$?
	echo "# $(date +%T) $step: cx-when-idle exit $rc" >> $OUT
	[ $rc -eq 0 ] || break
done
kill $LOGGER 2>/dev/null
