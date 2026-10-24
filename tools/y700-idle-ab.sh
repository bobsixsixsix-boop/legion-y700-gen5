#!/bin/bash
# y700-idle-ab.sh: screen-off A/B of the runtime-switchable y8/y9 power knobs (2026-10-15 night). ON BATTERY.
#   0 baseline (menu governor, uclamp RT default as installed)    1 cpuidle governor teo
#   2 kernel.sched_util_clamp_min_rt_default=64                    3 baseline again (drift)
#   then y700-whoawake 30 --off (IRQ / wakeup rates for the lazy-RCU comparison with y8: 383 IRQ/s, 436 ctxt/s)
# Every knob is restored after its state and in the exit trap. Log: /var/log/y700-offbench.txt
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
LOG=/var/log/y700-offbench.txt; SETTLE=${SETTLE:-12}; SECS=${SECS:-75}
GOV=/sys/devices/system/cpu/cpuidle/current_governor
gov0=$(cat $GOV); ucl0=$(cat /proc/sys/kernel/sched_util_clamp_min_rt_default)
sample() { sleep "$1"; /usr/local/libexec/y700-powersample.py "$2" "$3" >> $LOG 2>&1; }
restore() { echo "$gov0" > $GOV; sysctl -q -w kernel.sched_util_clamp_min_rt_default="$ucl0"; "${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; [ -n "$INH" ] && { pkill -P $INH 2>/dev/null; kill $INH 2>/dev/null; }; echo "$(date +%T) restored: governor $(cat $GOV), uclamp rt $(cat /proc/sys/kernel/sched_util_clamp_min_rt_default)" >> $LOG; }
trap restore EXIT; trap 'exit 1' INT TERM
"${U[@]}" kde-inhibit --power --screenSaver sleep 900 >/dev/null 2>&1 </dev/null & INH=$!
{ echo; echo "=== $(date '+%F %T') idle-ab on $(uname -r): governor $gov0 (available: $(cat /sys/devices/system/cpu/cpuidle/available_governors)), uclamp rt $ucl0, $(cat /sys/class/power_supply/qcom-battmgr-bat/status) $(cat /sys/class/power_supply/qcom-battmgr-bat/capacity)%, $(iw dev wlp1s0 link | grep SSID | tr -d '\t')"; } >> $LOG
"${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1
sample 20 "$SECS" "0 baseline (screen off)"
echo teo > $GOV;                                   sample "$SETTLE" "$SECS" "1 cpuidle teo"
echo "$gov0" > $GOV
sysctl -q -w kernel.sched_util_clamp_min_rt_default=64; sample "$SETTLE" "$SECS" "2 uclamp rt 64"
sysctl -q -w kernel.sched_util_clamp_min_rt_default="$ucl0"
sample "$SETTLE" "$SECS" "3 baseline again"
echo "-- whoawake 30 s screen off ($(uname -r)):" >> $LOG
/usr/local/bin/y700-whoawake 30 --off >> $LOG 2>&1
