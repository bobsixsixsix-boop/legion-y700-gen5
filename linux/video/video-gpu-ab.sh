#!/bin/bash
# video-gpu-ab.sh [WINDOW_S]: while the owner watches a video, alternate the GPU frequency ceiling
# balanced (160-1200 MHz) / power-saver (160-726 MHz) via the helper (tb323fu-ctl gpu profile), A B A B,
# WINDOW_S each (default 120), sampling once per second: battery power, backlight, GPU cur_freq; per window the
# GPU time-in-state, wiliwili's CPU and any decoder reopen (a new video) in the mpv log. ROOT; run it with
# systemd-run so a dropped ssh does not leave the cap on. Restores the profile it found on any exit.
# Results: /root/video-gpu-ab/{samples.tsv,windows.txt}. Written 2026-10-16 (in-use power during video).
set -u
WIN=${1:-120}
O=/root/video-gpu-ab; mkdir -p $O; rm -f $O/*
GPU=/sys/class/devfreq/3d00000.gpu
BAT=/sys/class/power_supply/qcom-battmgr-bat
BL=$(ls -d /sys/class/backlight/*/ | head -1)
LOG=/home/user/.cache/wiliwili-mpv.log
prof0=$(tb323fu-ctl gpu 2>/dev/null | awk '/^  Profile:/ {print $2}')
[ -z "$prof0" ] && prof0=balanced
restore() { trap - EXIT; tb323fu-ctl gpu profile "$prof0" >/dev/null 2>&1; echo "$(date +%T) restored GPU profile $prof0 (now $(cat $GPU/min_freq)-$(cat $GPU/max_freq))" >> $O/windows.txt; }
trap restore EXIT; trap 'exit 1' INT TERM
hz=$(getconf CLK_TCK)
echo -e "time\twindow\tprofile\tW\tbacklight\tgpu_mhz\tstatus" > $O/samples.tsv
i=0
for prof in balanced power-saver balanced power-saver; do
	i=$((i + 1))
	tb323fu-ctl gpu profile $prof >/dev/null 2>&1
	sleep 2      # let the ceiling apply before the window starts
	pid=$(pgrep -x wiliwili | head -1)
	c0=$([ -n "$pid" ] && awk '{print $14 + $15}' /proc/$pid/stat || echo 0)
	cp $GPU/trans_stat $O/ts0; l0=$(wc -l < $LOG 2>/dev/null || echo 0); t0=$(date +%s.%N)
	for s in $(seq $WIN); do
		echo -e "$(date +%T)\t$i\t$prof\t$(awk '{printf "%.3f", ($1 < 0 ? -$1 : $1) / 1e6}' $BAT/power_now)\t$(cat $BL/brightness)\t$(( $(cat $GPU/cur_freq) / 1000000 ))\t$(cat $BAT/status)" >> $O/samples.tsv
		sleep 1
	done
	t1=$(date +%s.%N)
	c1=$([ -n "$pid" ] && awk '{print $14 + $15}' /proc/$pid/stat 2>/dev/null || echo "$c0")
	res=$(awk 'function row(l,  n,f){ n=split(l,x," "); f=x[1]; if(f=="*") f=x[2]; sub(":","",f); return f" "x[n] }
		FNR==NR { if ($0 ~ /^[ *]*[0-9]+:/) { split(row($0),r," "); a[r[1]]=r[2] } next }
		$0 ~ /^[ *]*[0-9]+:/ { split(row($0),r," "); d=r[2]-a[r[1]]; if (d>0) {t+=d; f[r[1]]=d; m+=d*r[1]} }
		END { printf "mean %d MHz;", m/t/1e6; for (k in f) if (f[k]*100/t >= 3) printf " %d:%d%%", k/1e6, f[k]*100/t }' $O/ts0 $GPU/trans_stat)
	reopen=$(tail -n +$((l0 + 1)) $LOG 2>/dev/null | grep -c "Opening decoder hevc\|Opening decoder h264\|Opening decoder av1")
	cpu=$(awk -v a=$c0 -v b=$c1 -v t0=$t0 -v t1=$t1 -v hz=$hz 'BEGIN{printf "%.1f", (b-a)/hz/(t1-t0)*100}')
	stats=$(awk -F'\t' -v w=$i 'NR>1 && $2==w {n++; s+=$4; b+=$5} END{printf "%.2f W mean, backlight mean %.0f, %d s", s/n, b/n, n}' $O/samples.tsv)
	echo "$(date +%T) window $i $prof: $stats; wiliwili CPU $cpu %; GPU $res; decoder reopens $reopen" >> $O/windows.txt
done
