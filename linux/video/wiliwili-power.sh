#!/bin/bash
# wiliwili-power.sh [SECONDS]: while the owner watches a video in wiliwili, sample (ROOT, read-only, no UI action)
#   - which hwdec libmpv picked (last "Using hardware decoding" line of ~/.cache/wiliwili-mpv.log),
#   - wiliwili's CPU (% of one core, /proc/PID/stat utime+stime delta over the window),
#   - battery power (power_now, or current_now x voltage_now; only meaningful on battery - while charging it is the
#     charge power, so the script warns) and the backlight,
#   once per 5 s, then the averages. Written 2026-10-16 for the zero-copy check (wiliwili-vaapi-zero-copy.patch).
set -u
T=${1:-120}
H=/home/user
pid=${WPID:-$(pgrep -x wiliwili | head -1)}   # WPID: test against another process
[ -z "$pid" ] && { echo "wiliwili is not running"; exit 1; }
echo "wiliwili pid $pid, started $(ps -o lstart= -p "$pid"), binary $(ls -l --time-style=+%F_%T /proc/"$pid"/exe | awk '{print $NF}') ($(stat -c %y /usr/local/bin/wiliwili | cut -c1-19))"
grep -E "Using hardware decoding|Could not create a VA display|Trying hardware decoding" $H/.cache/wiliwili-mpv.log 2>/dev/null | tail -3
grep -E "VO: |\[vo/libmpv\].*(vaapi|nv12|p010)" $H/.cache/wiliwili-mpv.log 2>/dev/null | tail -2
BAT=$(ls -d /sys/class/power_supply/*/ | while read -r d; do [ "$(cat "$d/type" 2>/dev/null)" = Battery ] && echo "$d" && break; done)
BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
watts() {   # instantaneous battery power in W (positive = discharging)
	if [ -r "$BAT/power_now" ]; then awk '{printf "%.2f", ($1 < 0 ? -$1 : $1) / 1e6}' "$BAT/power_now"
	else awk -v v="$(cat "$BAT/voltage_now")" '{printf "%.2f", ($1 < 0 ? -$1 : $1) * v / 1e12}' "$BAT/current_now"; fi; }
ticks() { awk '{print $14 + $15}' /proc/"$pid"/stat; }
hz=$(getconf CLK_TCK)
echo "battery $BAT: $(cat "$BAT/status") $(cat "$BAT/capacity")%, backlight $(cat "$BL/brightness")/$(cat "$BL/max_brightness")"
grep -q "^Discharging" "$BAT/status" || echo "WARNING: battery is $(cat "$BAT/status") - the W figures below are not the consumption; unplug for a power number"
t0=$(date +%s.%N); c0=$(ticks); n=0; sum=0
while :; do
	sleep 5
	kill -0 "$pid" 2>/dev/null || { echo "wiliwili exited"; break; }
	w=$(watts); n=$((n + 1)); sum=$(awk -v s="$sum" -v w="$w" 'BEGIN{print s + w}')
	echo "$(date +%T) battery ${w} W, backlight $(cat "$BL/brightness"), status $(cat "$BAT/status")"
	[ $((n * 5)) -ge "$T" ] && break
done
t1=$(date +%s.%N); c1=$(ticks 2>/dev/null || echo "$c0")
awk -v c0="$c0" -v c1="$c1" -v t0="$t0" -v t1="$t1" -v hz="$hz" -v s="$sum" -v n="$n" \
	'BEGIN{printf "== %d samples: battery mean %.2f W; wiliwili CPU %.1f %% of one core\n", n, (n ? s / n : 0), (c1 - c0) / hz / (t1 - t0) * 100}'
