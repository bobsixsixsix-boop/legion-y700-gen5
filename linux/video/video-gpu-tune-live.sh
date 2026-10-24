#!/bin/bash
# video-gpu-tune-live.sh [WINDOW_S] [UP_TEST]: GPU upthreshold A/B WHILE THE OWNER WATCHES wiliwili (not visible by
# itself: no player, brightness, DPMS or mode change - only the simple_ondemand threshold, read live). ROOT, run with
# systemd-run. 2026-10-16. Windows 50 / UP_TEST alternating, 3 pairs, WINDOW_S each (default 90, ~9.5 min).
# Per second: battery power, backlight (auto-brightness keeps running: windows are compared after correcting to a
# common backlight, video-gpu-ab-analyze.sh), GPU cur_freq; per window: KWin composites/s (kprobe hits on
# msm_fence_set_deadline, tracing_on untouched, no buffer reads), wiliwili CPU, speaker sink state (= playing).
# Composites/s ~60 in both = no missed-vblank trap; ~30 under UP_TEST = the trap (GPU too slow, KWin slips a vblank).
# Stops early if wiliwili exits or the screen goes off. Restores the threshold and removes the kprobe on any exit.
set -u
WIN=${1:-90}; UPT=${2:-80}
O=/root/video-gpu-tune-live; mkdir -p $O; rm -f $O/*
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 LC_ALL=C)
GPU=/sys/class/devfreq/3d00000.gpu
DF=/sys/kernel/debug/dri/1/devfreq
T=/sys/kernel/tracing
BAT=/sys/class/power_supply/qcom-battmgr-bat
BL=$(ls -d /sys/class/backlight/*/ | head -1)
DPMS=$(ls /sys/class/drm/card*-DSI-1/dpms 2>/dev/null | head -1)
log() { echo "$(date +%T) $*" >> $O/windows.txt; }
hits() { awk '$1 == "msmdl" {print $2; f = 1} END {if (!f) print 0}' $T/kprobe_profile; }
ticks() { awk '{print $14 + $15}' /proc/$1/stat 2>/dev/null || echo 0; }
up0=$(cat $DF/upthreshold)
restore() {
	trap - EXIT
	echo "$up0" > $DF/upthreshold
	[ -e $T/events/kprobes/msmdl/enable ] && echo 0 > $T/events/kprobes/msmdl/enable
	grep -q ":kprobes/msmdl " $T/kprobe_events && echo "-:msmdl" >> $T/kprobe_events
	log "restored: upthreshold $(cat $DF/upthreshold) (was $up0), kprobes left $(grep -c msm $T/kprobe_events)"
}
trap restore EXIT; trap 'exit 1' INT TERM
WW=$(pgrep -x wiliwili | head -1); [ -z "$WW" ] && { log "wiliwili not running"; exit 2; }
log "start: kernel $(uname -r), upthreshold $up0, battery $(cat $BAT/status) $(cat $BAT/capacity)%, panel $(grep -oE 'hz [0-9]+' /sys/module/msm/parameters/idle_refresh_state)"
grep -q Discharging $BAT/status || log "WARNING: not on battery - W figures are not the consumption"
echo 'p:msmdl msm_fence_set_deadline' >> $T/kprobe_events
echo 1 > $T/events/kprobes/msmdl/enable
echo -e "time\twindow\tprofile\tW\tbacklight\tgpu_mhz\tstatus" > $O/samples.tsv
i=0
for up in 50 $UPT 50 $UPT 50 $UPT; do
	i=$((i + 1))
	echo $up > $DF/upthreshold
	sleep 3
	h0=$(hits); w0=$(ticks $WW); t0=$(date +%s.%N); play=0
	for s in $(seq $WIN); do
		echo -e "$(date +%T)\t$i\tup$up\t$(awk '{printf "%.3f", ($1 < 0 ? -$1 : $1) / 1e6}' $BAT/power_now)\t$(cat $BL/brightness)\t$(( $(cat $GPU/cur_freq) / 1000000 ))\t$(cat $BAT/status)" >> $O/samples.tsv
		[ $((s % 15)) = 1 ] && "${U[@]}" pactl list short sinks 2>/dev/null | grep -q "y700_lenovo.*RUNNING" && play=$((play + 1))
		kill -0 $WW 2>/dev/null || { log "wiliwili exited - stopping"; exit 3; }
		[ "$(cat $DPMS)" = Off ] && { log "screen went off - stopping"; exit 3; }
		sleep 1
	done
	t1=$(date +%s.%N); h1=$(hits); w1=$(ticks $WW)
	stats=$(awk -F'\t' -v w=$i 'NR>1 && $2==w {n++; s+=$4; b+=$5; g+=$6; if ($6 >= 1200) h++} END{printf "%.2f W mean, backlight %.0f, GPU %.0f MHz, at 1200 %d%%, %d s", s/n, b/n, g/n, h*100/n, n}' $O/samples.tsv)
	extra=$(awk -v a=$h0 -v b=$h1 -v c=$w0 -v d=$w1 -v t0=$t0 -v t1=$t1 -v hz=$(getconf CLK_TCK) 'BEGIN{printf "composites %.1f/s, wiliwili CPU %.1f %%", (b-a)/(t1-t0), (d-c)/hz/(t1-t0)*100}')
	log "window $i up$up: $stats; $extra; audio playing in $play of $(( (WIN + 14) / 15 )) checks; panel $(grep -oE 'hz [0-9]+' /sys/module/msm/parameters/idle_refresh_state)"
done
