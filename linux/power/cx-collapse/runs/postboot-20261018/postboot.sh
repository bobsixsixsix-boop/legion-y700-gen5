#!/bin/bash
# 2026-10-18 after the reboot: wait (max 20 min) until y700-cx-auto arms E3a (screen off >= 30 s on battery, download
# mode off), settle 20 s, then 60 s of cluster/system/apss counters, arch_timer, plasmashell context switches
export LC_ALL=C
G=/sys/kernel/debug/pm_genpd
end=$(( $(date +%s) + 1200 ))
until /usr/local/libexec/y700-cx-auto --status 2>/dev/null | grep -q 'armed now: yes'; do
	[ $(date +%s) -ge $end ] && { echo "not armed within 20 min: $(/usr/local/libexec/y700-cx-auto --status 2>&1 | tr '\n' ' ')"; exit 1; }
	sleep 5
done
echo "armed at $(date +%T) (uptime $(cut -d. -f1 /proc/uptime) s) dpms=$(cat /sys/class/drm/card*-DSI-1/dpms | head -1)"
sleep 20
P=$(pgrep -x plasmashell | head -1)
pd() { for d in cluster cluster1 system; do printf "%s=%s " $d "$(sed -n 2p $G/power-domain-$d/idle_states | awk '{print $3"/"$4}')"; done
	printf "apss=%s timer=%s ps=%s\n" "$(grep -i count /sys/kernel/debug/qcom_stats/apss | awk '{print $NF}')" "$(awk '/arch_timer/ {s = 0; for (i = 2; i <= 9; i++) s += $i; print s}' /proc/interrupts)" "$(awk '/ctxt_switches/ {s += $2} END {print s}' /proc/$P/status)"; }
a=$(pd); sleep 60; b=$(pd)
echo "t0 $a"; echo "t1 $b"
echo "$a" "$b" | awk '{for (i = 1; i <= 6; i++) {split($i, x, "[=/]"); split($(i + 6), y, "[=/]"); v[x[1]] = y[2] - x[2]}
  printf "60 s: cluster0 +%d  cluster1 +%d  system +%d (%.1f/s)  apss +%d  arch_timer %.0f/s  plasmashell %.1f wakeups/s\n", v["cluster"], v["cluster1"], v["system"], v["system"] / 60, v["apss"], v["timer"] / 60, v["ps"] / 60}'
echo "dpms=$(cat /sys/class/drm/card*-DSI-1/dpms | head -1) bat=$(cat /sys/class/power_supply/qcom-battmgr-bat/status)"
