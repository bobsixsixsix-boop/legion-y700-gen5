#!/bin/bash
# 2026-10-18 07:0x: daytime E3a / E3b / E3c, 15 min each (owner's daytime limit), now that the system domain can be
# entered. Claude desktop's GPU-process compositor relapses into 120 Hz ticking after any UI update with the screen off
# (06:50 cleared, 06:57 ticking again - likely the tablet's Claude window following the Win11 session), so: screen on 10 s
# and off first (clears it), the Win11 session stays silent for the whole run, and a cheap once-a-minute logger of the
# compositor threads' context switches and the genpd counters runs alongside. Run as a y700-cx-* unit so cx-auto yields:
#   systemd-run --unit y700-cx-day --collect -p KillMode=mixed --on-active=90 /bin/bash /root/daytest.sh
export LC_ALL=C
G=/sys/kernel/debug/pm_genpd
U="sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
OUT=/root/runs/day-20261018/vizlog.txt
mkdir -p "$(dirname "$OUT")"
VIZ=$(for t in /proc/[0-9]*/task/[0-9]*; do [ "$(cat $t/comm 2>/dev/null)" = VizCompositorTh ] && echo $t; done)
echo "# $(date '+%F %T') columns: time dpms ctxt of [$(echo $VIZ | tr ' ' ',')] then cluster cluster1 system usage" >> $OUT
$U kscreen-doctor --dpms on >/dev/null 2>&1; sleep 10; $U kscreen-doctor --dpms off >/dev/null 2>&1
echo "# $(date +%T) screen cycled" >> $OUT
(
	while :; do
		echo "$(date +%T) $(cat /sys/class/drm/card*-DSI-1/dpms | head -1) $(for t in $VIZ; do awk '/ctxt_switches/ {s += $2} END {printf "%d ", s}' $t/status 2>/dev/null; done)$(for d in cluster cluster1 system; do sed -n 2p $G/power-domain-$d/idle_states | awk '{printf "%s ", $3}'; done)" >> $OUT
		sleep 60
	done
) &
LOGGER=$!
/usr/local/libexec/cx-when-idle.sh --idle 10 --until 08:30 E3a:15 E3b:15 E3c:15
rc=$?
kill $LOGGER 2>/dev/null
echo "# $(date +%T) cx-when-idle exit $rc" >> $OUT
