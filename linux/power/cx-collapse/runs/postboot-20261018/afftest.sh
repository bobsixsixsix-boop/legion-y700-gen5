#!/bin/bash
# 2026-10-18: are Chrome / Claude desktop what keeps cluster0 (cpu0-5) from collapsing? Screen off, cx-auto armed.
# 60 s baseline; then pin every thread of every chrome / claude-desktop process to cpu6-7 (cluster1) for 60 s; then put
# them back on 0-7 and measure 60 s again. Scheduling only - no process is stopped. If cluster0 starts collapsing while
# they are pinned away, they are the cause (the system domain still needs cluster1 too, so it may stay 0 then).
export LC_ALL=C
G=/sys/kernel/debug/pm_genpd
pids() { for p in /proc/[0-9]*; do case "$(cat $p/comm 2>/dev/null)" in chrome|claude-desktop|chrome_crashpad) echo ${p#/proc/};; esac; done; }
snap() {
	printf "%s %s %s" "$(sed -n 2p $G/power-domain-cluster/idle_states | awk '{print $3}')" "$(sed -n 2p $G/power-domain-cluster1/idle_states | awk '{print $3}')" \
		"$(sed -n 2p $G/power-domain-system/idle_states | awk '{print $3}')"
	awk '/arch_timer/ {for (i = 2; i <= 9; i++) printf " %s", $i}' /proc/interrupts
	echo
}
win() {
	local a b; a=$(snap); sleep 60; b=$(snap)
	echo "$a" "$b" | awk -v t="$(date +%T)" -v w="$1" -v d="$(cat /sys/class/drm/card*-DSI-1/dpms | head -1)" -v ar="$([ -e /run/y700-cx-auto.armed ] && echo Y || echo N)" '{
		printf "%s %-8s dpms=%s armed=%s  cl0 %.1f/s  cl1 %.1f/s  sys %.1f/s  | arch_timer/s per cpu", t, w, d, ar, ($12-$1)/60, ($13-$2)/60, ($14-$3)/60
		for (i = 4; i <= 11; i++) printf " %d", ($(i+11)-$i)/60
		print "" }'
}
P=$(pids)
echo "processes: $(echo $P | wc -w); affinity before: $(for p in $P; do taskset -p $p 2>/dev/null | awk '{print $NF}'; done | sort | uniq -c | tr '\n' ' ')"
win baseline
for p in $P; do taskset -a -p -c 6,7 $p >/dev/null 2>&1; done
sleep 10
win pinned67
for p in $(pids); do taskset -a -p -c 0-7 $p >/dev/null 2>&1; done
echo "affinity after restore: $(for p in $(pids); do for t in /proc/$p/task/*; do awk '/Cpus_allowed_list/ {print $2}' $t/status; done; done | sort | uniq -c | tr '\n' ' ')"
sleep 10
win restored
