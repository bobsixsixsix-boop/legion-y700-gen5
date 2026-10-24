#!/bin/bash
# burst-ab.sh: the compute-burst scenario under identical conditions on two kernels (2026-10-15, y8 vs y9):
# screen off, 60 s of 30 ms/100 ms ALU bursts on cpu2 with battery power + cpu2 clock histogram, then a
# 30 s idle reference. Run as root on battery. Log: /var/log/y700-memlat-ab.txt
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
LOG=/var/log/y700-memlat-ab.txt; D=/usr/local/src/memlat-ab
restore() { "${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; [ -n "$INH" ] && { pkill -P $INH 2>/dev/null; kill $INH 2>/dev/null; }; }
trap restore EXIT; trap 'exit 1' INT TERM
cd $D && [ -x burst ] || cc -O2 -o burst burst.c || exit 1
# stdio to /dev/null: the inhibitor and its sleep must not hold an ssh pipe open after the script ends
"${U[@]}" kde-inhibit --power --screenSaver sleep 600 >/dev/null 2>&1 </dev/null & INH=$!
"${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1; sleep 15
{
echo; echo "=== $(date '+%F %T') burst-ab on $(uname -r), screen off, $(cat /sys/class/power_supply/qcom-battmgr-bat/status) $(cat /sys/class/power_supply/qcom-battmgr-bat/capacity)%, skin $(cat /sys/class/thermal/thermal_zone*/temp | sort -n | tail -1) mC"
taskset -c 2 ./burst 60 30 100 > /tmp/burst.out & bp=$!
declare -A h; n=0
( /usr/local/libexec/y700-powersample.py 55 "bursts cpu2 (screen off)" | cut -c1-110 ) & ps=$!
while kill -0 $bp 2>/dev/null; do f=$(( $(cat /sys/devices/system/cpu/cpu2/cpufreq/scaling_cur_freq) / 100000 )); h[$f]=$(( ${h[$f]:-0} + 1 )); n=$((n+1)); sleep 0.05; done
wait $ps; wait $bp; cat /tmp/burst.out
echo -n "   cpu2 clock (x100 MHz): "; for k in $(printf '%s\n' "${!h[@]}" | sort -n); do printf '%s:%d%% ' "$k" $(( 100 * h[$k] / n )); done; echo
/usr/local/libexec/y700-powersample.py 30 "idle ref (screen off)" | cut -c1-110
} >> $LOG 2>&1
sed -n "/burst-ab on $(uname -r)/,\$p" $LOG | tail -6
