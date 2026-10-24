#!/bin/bash
# HUD CPU per mode on the live desktop (no screen takeover): full/mini/full/mini, WIN s each.
# Per window: overlay cgroup CPU, kwin_wayland CPU, touch IRQs, panel hz at the end. ROOT via systemd-run.
WIN=${1:-120}
O=/root/y700-hud-cpu; mkdir -p $O; : > $O/windows.txt
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0)
CG=/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/y700-hud-overlay.service
MODE=/run/user/1000/y700-hud.mode
mode0=$(cat $MODE)
usage() { awk '/^usage_usec/ {print $2}' $CG/cpu.stat; }
kw() { local p; p=$(pgrep -x kwin_wayland | head -1); awk '{print $14 + $15}' /proc/$p/stat; }  # clock ticks
touches() { awk '/NVT-ts/ {s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break; print s; exit}' /proc/interrupts; }
TCK=$(getconf CLK_TCK)
for m in full mini full mini; do
	echo $m > $MODE; chown user: $MODE; sleep 5
	u0=$(usage); k0=$(kw); t0=$(touches); s0=$(date +%s.%N)
	sleep $WIN
	u1=$(usage); k1=$(kw); t1=$(touches); s1=$(date +%s.%N)
	hz=$(grep -oE 'hz [0-9]+' /sys/module/msm/parameters/idle_refresh_state | cut -d' ' -f2)
	awk -v m=$m -v u=$((u1 - u0)) -v k=$((k1 - k0)) -v t=$((t1 - t0)) -v d0=$s0 -v d1=$s1 -v tck=$TCK -v hz=$hz -v bat="$(cat /sys/class/power_supply/qcom-battmgr-bat/status)" \
		'BEGIN {d = d1 - d0; printf "%s %s  hud %.3f%%  kwin %.2f%%  touches %d  hz %s  %s  (%.0f s)\n", strftime("%T"), m, u / d / 1e4, k / tck / d * 100, t, hz, bat, d}' >> $O/windows.txt
done
echo $mode0 > $MODE; chown user: $MODE
echo "$(date +%T) restored mode $(cat $MODE)" >> $O/windows.txt
