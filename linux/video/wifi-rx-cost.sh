#!/bin/bash
# wifi-rx-cost.sh [RATE_KB_S] [WINDOW_S]: what receiving a YouTube-sized stream over Wi-Fi costs, screen OFF, nothing else.
# ROOT. Windows: idle, download, idle, download (default 45 s each, 580 KB/s = 4.6 Mbit/s, what 1080p60 VP9 YouTube
# measured in chrome-video-power-ab.sh). Download = curl --limit-rate of a big file over TLS (so the CPU pays the
# decryption too) into /dev/null. The tablet is kept awake with systemd-inhibit so the idle windows are "awake, screen off"
# and not suspend. Refuses if the screen is on. Prints average battery W per window (battery must be discharging).
# Do not ssh in while it runs (each login starts root's user manager and shows up in idle power): start it with
# systemd-run and read /root/wifi-rx-cost.txt afterwards.
# Planned wrapper (linux/power/PLAN-deep-powersave.md SCN-1 :358-359, phase P4; not implemented as of 2026-10-19): the
# scene recorder runs this script as the scene "wifi-rx" through the A/B step syntax `K=wifi-rx:3` (3 min = the four
# 45 s windows), so its windows get the flight recorder's MARKs, the 1 s cadence and the touch guard / NVT-ts-spi
# delta (R15) like any other arm. Until then start it by hand with systemd-run as above.
set -u
RATE=${1:-580}; WIN=${2:-45}
BAT=/sys/class/power_supply/qcom-battmgr-bat
DPMS=$(ls /sys/class/drm/card*-DSI-1/dpms 2>/dev/null | head -1)
OUT=/root/wifi-rx-cost.txt; : > $OUT
log() { echo "$(date +%T) $*" | tee -a $OUT; }
[ "$(cat $DPMS)" = Off ] || { log "screen is on (owner using the tablet?)"; exit 2; }
grep -q Discharging $BAT/status || log "WARNING: not on battery"
WL=$(ls /sys/class/net | grep -m1 '^wl')
URLS=(https://speed.cloudflare.com/__down?bytes=200000000 https://proof.ovh.net/files/1Gb.dat)
avg() { local i; for i in $(seq $WIN); do awk '{print ($1 < 0 ? -$1 : $1) / 1e6}' $BAT/power_now; sleep 1; done | awk '{s += $1; n++} END {printf "%.3f", s / n}'; }
sleep 20   # the owner's last touch / ssh login settle
for w in idle rx idle rx; do
	if [ $w = rx ]; then
		for u in "${URLS[@]}"; do
			curl -sL --max-time $((WIN + 10)) --limit-rate ${RATE}k -o /dev/null "$u" & CP=$!
			sleep 3; kill -0 $CP 2>/dev/null && break   # still downloading after 3 s: this URL works
		done
		rx0=$(cat /sys/class/net/$WL/statistics/rx_bytes)
	fi
	p=$(systemd-inhibit --what=idle:sleep --who=wifi-rx-cost --why=measure bash -c "$(declare -f avg); WIN=$WIN BAT=$BAT; avg")
	if [ $w = rx ]; then rx1=$(cat /sys/class/net/$WL/statistics/rx_bytes); kill $CP 2>/dev/null; wait $CP 2>/dev/null
		log "window $w: $p W, Wi-Fi rx $(( (rx1 - rx0) * 8 / 1000 / WIN )) kbit/s"
	else log "window $w: $p W"; fi
done
