#!/bin/bash
# y700-memlat-ab.sh: does the memlat firmware behave as intended on this kernel? Run as root, on battery
# for the power lines (the latency lines do not need it). Same script on y8 (RFC ceilings) and y9 (1042):
#   1. pointer chase (tools/memlat-ab/chase.c) at 32 KiB .. 512 MiB on a gold core (cpu2) and the prime
#      core (cpu7): ns per dependent load, and the highest DDR/LLCC vote the CPUCP made meanwhile.
#      Memory-bound code MUST still raise DDR on y9; if 512 MiB on cpu7 stays at 547 MHz, 1042 is wrong.
#   2. compute bursts (burst.c, 30 ms every 100 ms, 60 s, cpu2): average power + how long the DDR vote
#      sat at each level. This is where 1042 should save: cpufreq goes up, DDR should not follow.
# The devfreq read-back is polled at 100 ms only while sampling (restored to 1000 ms by the trap).
# Log: /var/log/y700-memlat-ab.txt
LOG=/var/log/y700-memlat-ab.txt; D=/usr/local/src/memlat-ab
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
restore() { for d in ddr llcc; do echo 1000 > /sys/class/devfreq/$d/polling_interval; done; [ -n "$INH" ] && { pkill -P $INH 2>/dev/null; kill $INH 2>/dev/null; }; }
trap restore EXIT; trap 'exit 1' INT TERM
cd $D && cc -O2 -o chase chase.c && cc -O2 -o burst burst.c || exit 1
for d in ddr llcc; do echo 100 > /sys/class/devfreq/$d/polling_interval; done
"${U[@]}" kde-inhibit --power --screenSaver sleep 600 >/dev/null 2>&1 </dev/null & INH=$!
votes() {   # $1 seconds: DDR vote histogram (MHz: share) over the window, sampled every 100 ms
	local -A h; local n=0 end=$((SECONDS + $1))
	while [ $SECONDS -lt $end ]; do f=$(( $(cat /sys/class/devfreq/ddr/cur_freq) / 1000000 )); h[$f]=$(( ${h[$f]:-0} + 1 )); n=$((n + 1)); sleep 0.1; done
	for k in $(printf '%s\n' "${!h[@]}" | sort -n); do printf '%s:%d%% ' "$k" $(( 100 * h[$k] / n )); done
}
{
echo; echo "=== $(date '+%F %T') memlat-ab on $(uname -r), $(cat /sys/class/power_supply/qcom-battmgr-bat/status) $(cat /sys/class/power_supply/qcom-battmgr-bat/capacity)%, memlat sample: $(dmesg | grep -o 'memlat started.*' | head -1)"
echo "-- 1. pointer chase (ns per load | DDR vote share during the run)"
for cpu in 2 7; do
	for mib in 1 8 64 512; do
		res=$(taskset -c $cpu ./chase $mib 3 & pid=$!; v=$(votes 3); wait $pid; echo "$v")
		# the chase prints first, votes second (stdout order of the subshell)
		echo "   cpu$cpu $(echo "$res" | head -1) | votes: $(echo "$res" | tail -1)"
	done
done
echo "-- 2. compute bursts on cpu2 (30 ms / 100 ms, 60 s): power + DDR vote share"
taskset -c 2 ./burst 60 30 100 > /tmp/burst.out & bp=$!
/usr/local/libexec/y700-powersample.py 55 "bursts cpu2" | cut -c1-120
wait $bp; cat /tmp/burst.out
echo "   (second 60 s, DDR vote share only)"
taskset -c 2 ./burst 20 30 100 >/dev/null & bp=$!; echo "   votes: $(votes 20)"; wait $bp
echo "-- 3. idle 30 s for reference"; /usr/local/libexec/y700-powersample.py 30 "idle ref" | cut -c1-120
} >> $LOG 2>&1
tail -22 $LOG
