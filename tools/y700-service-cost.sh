#!/bin/bash
# y700-service-cost.sh [SECONDS] [OUT]: what every systemd unit costs over a window (ROOT; read-only apart from one
# ftrace tracepoint; run it with systemd-run and do not ssh in during a screen-off window). 2026-10-16.
# Per unit cgroup (system.slice, the user manager's app/session/background slices):
#   CPU    cpu.stat usage_usec delta, % of one core - includes every child it spawned during the window
#   wake/s voluntary + involuntary context switches of the processes alive at both ends, per second (a wakeup proxy)
#   fork/m processes forked per minute by the unit's processes (ftrace sched_process_fork, parent mapped to its unit)
#   MB     memory.current at the end
# Our own units (y700-*, tb323fu-*) are marked "*". Also: total CPU busy % and the battery power mean (5 s samples).
set -u
T=${1:-300}; OUT=${2:-/root/y700-service-cost.txt}
TR=/sys/kernel/tracing
units() { find /sys/fs/cgroup/system.slice /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service \
	-mindepth 1 -maxdepth 2 -type d \( -name "*.service" -o -name "*.scope" \) 2>/dev/null; }
usage() { awk '/^usage_usec/ {print $2}' "$1/cpu.stat" 2>/dev/null || echo 0; }
ctx() { local f=$(sed "s|^|/proc/|; s|$|/status|" "$1/cgroup.procs" 2>/dev/null); [ -z "$f" ] && { echo 0; return; }
	awk '/ctxt_switches/ {s += $2} END {print s + 0}' $f 2>/dev/null || echo 0; }   # one awk for all processes
declare -A U0 C0 P0
for u in $(units); do U0[$u]=$(usage $u); C0[$u]=$(ctx $u); P0[$u]=$(cat $u/cgroup.procs 2>/dev/null | tr '\n' ' '); done
read -r _ a1 a2 a3 a4 a5 a6 a7 _ < /proc/stat; busy0=$((a1 + a2 + a3 + a6 + a7)); tot0=$((busy0 + a4 + a5))
ton0=$(cat $TR/tracing_on); echo 0 > $TR/tracing_on; echo > $TR/trace; echo 1 > $TR/events/sched/sched_process_fork/enable; echo 1 > $TR/tracing_on
dpms0=$(cat /sys/class/drm/card*-DSI-1/dpms 2>/dev/null | head -1)
W=0; n=0
for i in $(seq $((T / 5))); do
	W=$(awk -v w=$W '{printf "%.4f", w + ($1 < 0 ? -$1 : $1) / 1e6}' /sys/class/power_supply/qcom-battmgr-bat/power_now); n=$((n + 1)); sleep 5
done
echo 0 > $TR/tracing_on; echo 0 > $TR/events/sched/sched_process_fork/enable
cp $TR/trace /tmp/y700-cost-forks.txt; echo > $TR/trace; echo "$ton0" > $TR/tracing_on
read -r _ b1 b2 b3 b4 b5 b6 b7 _ < /proc/stat; busy1=$((b1 + b2 + b3 + b6 + b7)); tot1=$((busy1 + b4 + b5))
# forks per parent pid -> unit
declare -A F
while read -r ppid cnt; do
	cg=$(cut -d: -f3 /proc/$ppid/cgroup 2>/dev/null | head -1); [ -z "$cg" ] && continue
	# walk up to the unit (*.service / *.scope); stop at the cgroup root (the 10-16 first run looped on "dirname /")
	d=/sys/fs/cgroup${cg%/}
	while [[ "$d" == /sys/fs/cgroup/* ]] && [[ "$d" != *.service ]] && [[ "$d" != *.scope ]]; do d=${d%/*}; done
	[[ "$d" == *.service || "$d" == *.scope ]] || continue
	F[$d]=$(( ${F[$d]:-0} + cnt ))
done < <(grep -oE "sched_process_fork: comm=.* pid=[0-9]+ child_comm" /tmp/y700-cost-forks.txt | grep -oE "pid=[0-9]+" | cut -d= -f2 | sort | uniq -c | awk '{print $2, $1}')
{
echo "window ${T} s, screen ${dpms0} -> $(cat /sys/class/drm/card*-DSI-1/dpms 2>/dev/null | head -1), kernel $(uname -r), $(date '+%F %T')"
awk -v b0=$busy0 -v b1=$busy1 -v t0=$tot0 -v t1=$tot1 -v w=$W -v n=$n 'BEGIN{printf "total CPU busy %.2f %% of all 8 cores; battery %.3f W mean (%d samples)\n", (b1-b0)*100/(t1-t0), w/n, n}'
printf "%-1s %-44s %7s %8s %7s %7s\n" "" "unit" "CPU%" "wake/s" "fork/m" "MB"
for u in $(units); do
	[ -n "${U0[$u]+x}" ] || continue
	du=$(( $(usage $u) - ${U0[$u]} )); dc=$(( $(ctx $u) - ${C0[$u]} )); [ $dc -lt 0 ] && dc=0
	mb=$(awk '{printf "%.0f", $1/1048576}' $u/memory.current 2>/dev/null || echo 0)
	name=${u##*/}; mark=" "; case $name in y700-*|tb323fu-*) mark="*";; esac
	awk -v m="$mark" -v n="$name" -v du=$du -v dc=$dc -v f=${F[$u]:-0} -v mb=$mb -v T=$T \
		'BEGIN{printf "%.6f\t%-1s %-44s %7.3f %8.2f %7.1f %7s\n", du/T/1e4, m, n, du/T/1e4, dc/T, f*60/T, mb}'
done | sort -t$'\t' -k1,1 -rn | cut -f2-        # by CPU; the sort key column is dropped
} > $OUT 2>&1
