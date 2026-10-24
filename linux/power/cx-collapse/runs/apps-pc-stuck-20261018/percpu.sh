#!/bin/bash
# 2026-10-18: cluster0 (cpu0-5) stopped powering off after 10-17 18:24 - which CPU stays up? (read-only)
export LC_ALL=C
G=/sys/kernel/debug/pm_genpd
snap() {
	for c in 0 1 2 3 4 5 6 7; do
		printf "cpu%d pd=%s " $c "$(sed -n 2p $G/power-domain-cpu$c/idle_states 2>/dev/null | awk '{print $3"/"$4}')"
		for s in /sys/devices/system/cpu/cpu$c/cpuidle/state*; do printf "%s:%s/%s " "$(cat $s/name)" "$(cat $s/usage)" "$(cat $s/time)"; done
		echo
	done
}
echo "######## $(date '+%F %T') dpms=$(cat /sys/class/drm/card*-DSI-1/dpms | head -1) online=$(cat /sys/devices/system/cpu/online) isolated=$(cat /sys/devices/system/cpu/isolated) nohz_full=$(cat /sys/devices/system/cpu/nohz_full 2>/dev/null)"
echo "######## genpd:0:cpuN runtime_status, 40 samples 0.5 s apart (count of active per cpu)"
for i in $(seq 40); do for c in 0 1 2 3 4 5 6 7; do f=/sys/devices/genpd:0:cpu$c/power/runtime_status; [ -e $f ] || f=$(ls -d /sys/devices/*/genpd:0:cpu$c/power/runtime_status 2>/dev/null | head -1); [ "$(cat $f 2>/dev/null)" = active ] && printf "%d " $c; done; echo; sleep 0.5; done | tr ' ' '\n' | grep . | sort | uniq -c
echo "######## per-cpu idle over 20 s: pd use/rej delta, then per state usage delta / time delta (ms)"
snap > /tmp/pc0; cp /proc/interrupts /tmp/pi0; sleep 20; snap > /tmp/pc1; cp /proc/interrupts /tmp/pi1
paste -d'\n' /tmp/pc0 /tmp/pc1 | awk 'NR % 2 == 1 {split($0, a, " "); next} {n = split($0, b, " "); out = b[1]
  split(a[2], x, "[=/]"); split(b[2], y, "[=/]"); out = out sprintf(" pd use+%d rej+%d |", y[2] - x[2], y[3] - x[3])
  for (i = 3; i <= n; i++) { split(a[i], p, "[:/]"); split(b[i], q, "[:/]"); out = out sprintf(" %s +%d/%.0fms", q[1], q[2] - p[2], (q[3] - p[3]) / 1000) }
  print out}'
echo "######## per-cpu interrupt deltas in those 20 s (per second): arch_timer, IPI0-6, top other"
awk 'NR == FNR {if ($1 ~ /:$/) for (i = 2; i <= 9; i++) a[$1, i] = $i; next}
  $1 ~ /:$/ { n = ""; for (i = 10; i <= NF; i++) n = n " " $i; line = ""; tot = 0
    for (i = 2; i <= 9; i++) { d = ($i - a[$1, i]) / 20; tot += d; line = line sprintf("%7.1f", d) }
    if (tot >= 1) printf "%-8s%s  %s\n", $1, line, substr(n, 1, 40) }' /tmp/pi0 /tmp/pi1 | sort -k1,1 | head -40
echo "######## genpd summary for cpu domains"
grep -A1 -E '^power-domain-(cpu[0-9]|cluster)' $G/pm_genpd_summary
echo "######## journal 10-17 18:12-18:25 without Awinic/sudo json noise"
journalctl --since '2026-10-17 18:12' --until '2026-10-17 18:25' --no-pager -o short | grep -v -E 'Awinic|record_cb|avahi-daemon\[|systemd\[558740\]' | cut -c1-230 | head -120
