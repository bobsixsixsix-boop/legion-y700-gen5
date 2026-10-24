#!/bin/bash
# chrome-video-power-ab-when-idle.sh COMMAND...: wait until the owner is not using the tablet, then run COMMAND once.
# ROOT, via systemd-run. The visible Chrome power tests light the screen, so they only start when the screen has been
# off for IDLE_S seconds (default 300) with no touch, and only between 08:00 and 22:30 (HOURS_FROM/HOURS_TO); gives up
# after MAXWAIT_S (default 6 h). State for whoever looks later: /run/y700-cvp-queue.state ("waiting|running|done|gave-up <time>").
# Example: systemd-run --unit=y700-cvp-q --setenv=URL=... --working-directory=/root/y700-cvp \
#          /root/y700-cvp/chrome-video-power-ab-when-idle.sh /bin/bash -c 'CFGS="A W W A" ./chrome-video-power-ab.sh 45; ./wifi-rx-cost.sh'
set -u
IDLE_S=${IDLE_S:-300}; MAXWAIT_S=${MAXWAIT_S:-21600}; HOURS_FROM=${HOURS_FROM:-8}; HOURS_TO=${HOURS_TO:-22}
ST=/run/y700-cvp-queue.state
DPMS=$(ls /sys/class/drm/card*-DSI-1/dpms 2>/dev/null | head -1)
touches() { awk '/NVT-ts/ {s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break; print s; exit}' /proc/interrupts; }
state() { echo "$1 $(date +%F_%T)" > $ST; }
t0=$(date +%s); off=0; last=$(touches)
state waiting
while :; do
	now=$(date +%s); [ $((now - t0)) -gt $MAXWAIT_S ] && { state gave-up; exit 1; }
	cur=$(touches); h=$(date +%H); h=$((10#$h)); m=$(date +%M); m=$((10#$m))
	if [ "$(cat $DPMS 2>/dev/null)" = Off ] && [ "$cur" = "$last" ] && [ -z "$(ls /run/user/1000/y700-video/ 2>/dev/null)" ] \
		&& [ $h -ge $HOURS_FROM ] && { [ $h -lt $HOURS_TO ] || { [ $h -eq $HOURS_TO ] && [ $m -lt 30 ]; }; }; then
		off=$((off + 20))
	else off=0; fi
	last=$cur
	[ $off -ge $IDLE_S ] && break
	sleep 20
done
state running
"$@"; rc=$?
state "done-rc$rc"
exit $rc
