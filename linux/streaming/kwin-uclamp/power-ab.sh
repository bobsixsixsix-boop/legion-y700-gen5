#!/bin/bash
# power-ab.sh [SECS] (ROOT, start with systemd-run so no ssh is open while it measures): what does the KWin floor cost
# while nobody streams? Alternates y700-kwin-uclamp off/on/off/on, SECS (default 60) each after 10 s to settle, and
# logs the mean battery power (current_now x voltage_now, 1 Hz) and the mean clock of both clusters per window.
# Result: /root/streaming/kwin-uclamp-power.txt. Leaves the service running.
S=${1:-60}
OUT=/root/streaming/kwin-uclamp-power.txt
B=/sys/class/power_supply/qcom-battmgr-bat
trap 'systemctl start y700-kwin-uclamp' EXIT
{
    echo "$(date '+%F %T') windows of ${S}s; $(cat $B/status) $(cat $B/capacity)%; backlight $(cat /sys/class/backlight/*/brightness | head -1)"
    for st in off on off on; do
        [ $st = off ] && systemctl stop y700-kwin-uclamp || systemctl start y700-kwin-uclamp
        sleep 10
        w=0 c0=0 c6=0
        for _ in $(seq "$S"); do
            i=$(cat $B/current_now) v=$(cat $B/voltage_now)
            w=$(awk -v w="$w" -v i="$i" -v v="$v" 'BEGIN { if (i < 0) i = -i; print w + i * v / 1e12 }')
            c0=$((c0 + $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq)))
            c6=$((c6 + $(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_cur_freq)))
            sleep 1
        done
        echo "kwin floor $st: $(awk -v w="$w" -v s="$S" 'BEGIN { printf "%.3f W", w / s }'), cpu0 $((c0 / S / 1000)) MHz, cpu6 $((c6 / S / 1000)) MHz"
    done
} > $OUT 2>&1
