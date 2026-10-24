#!/bin/bash
# 2026-10-18: the same check as bfstest.sh for the Claude desktop app (Electron 44.7 = Chromium 152, which lacks
# the 08-19 / 09-08 BeginFrameSourceWayland fixes): started straight from /usr/lib (default) and through the new
# /usr/local/bin/claude-desktop wrapper (--enable-features=WaylandExternalBeginFrameSource). Screen OFF, as root via
# systemd-run. Per run: start it in the owner's systemd user manager (like a menu launch), SETTLE s, WIN s of
# per-thread context switches + per-process CPU, whether the GPU process got the feature, then SIGTERM the main
# process (SIGKILL leftovers after 15 s). Claude must not be running at the start. Output: /root/bfsclaude-HHMM.txt
export LC_ALL=C
SETTLE=${SETTLE:-45}; WIN=${WIN:-60}
OUT=/root/bfsclaude-$(date +%H%M).txt
BIN=/usr/lib/claude-desktop/claude-desktop
UENV="XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"

dpms() { for c in /sys/class/drm/card*-*; do [ "$(cat $c/status 2>/dev/null)" = connected ] && cat $c/dpms; done | head -1; }
procs() { for p in /proc/[0-9]*; do [ "$(readlink $p/exe 2>/dev/null)" = $BIN ] && echo ${p#/proc/}; done; }
# Chromium rewrites its process title, so cmdline is one space-joined string
ptype() { tr '\0' ' ' < /proc/$1/cmdline 2>/dev/null | grep -o -m1 -e '--type=[a-z-]*' | head -1 | cut -d= -f2; }
cpu() { awk '{print $14 + $15}' /proc/$1/stat 2>/dev/null; }
snap() {  # P pid type cputicks / T pid tid comm switches
	for p in $(procs); do
		t=$(ptype $p); echo "P $p ${t:-browser} $(cpu $p)"
		for th in /proc/$p/task/*; do echo "T $p ${th##*/} $(cat $th/comm | tr ' ' _) $(awk '/_ctxt_switches/ {s += $2} END {print s + 0}' $th/status 2>/dev/null)"; done
	done
}

{
echo "bfsclaude $(date '+%F %T')  claude $(cat /usr/lib/claude-desktop/version)  dpms=$(dpms)  SETTLE=$SETTLE WIN=$WIN"
if [ -n "$(procs)" ]; then echo "Claude already running - abort"; exit 1; fi
for run in default:$BIN bfs:/usr/local/bin/claude-desktop; do
	v=${run%%:*}; cmd=${run#*:}
	sudo -u user env $UENV systemd-run --user --quiet --collect --unit=y700-bfsclaude-$v $cmd
	sleep $SETTLE
	g=""; for p in $(procs); do [ "$(ptype $p)" = gpu-process ] && g=$p; done
	echo; echo "== $v ($cmd)  dpms=$(dpms)  gpu=$g  gpu-args: $(tr '\0' ' ' < /proc/$g/cmdline 2>/dev/null | grep -o -e '--ozone-platform=[a-z]*' -e 'WaylandExternalBeginFrameSource' | sort -u | tr '\n' ' ')"
	snap > /tmp/bfsc-a; t0=$(date +%s.%N)
	sleep $WIN
	snap > /tmp/bfsc-b; t1=$(date +%s.%N)
	awk -v S=$(awk -v a=$t0 -v b=$t1 'BEGIN {print b - a}') 'FNR == NR {a[$1" "$2" "$3] = $NF; next}
		$1 == "P" {k = $1" "$2" "$3; if (k in a) printf "  proc %-8s %-14s cpu %5.1f %%\n", $2, $3, ($4 - a[k]) / S}
		$1 == "T" {k = $1" "$2" "$3; if (k in a) {d = $5 - a[k]; if (d / S >= 2) printf "    thread %-8s %-18s %6.1f wakeups/s\n", $2, $4, d / S}}' \
		/tmp/bfsc-a /tmp/bfsc-b
	main=$(procs | while read p; do [ -z "$(ptype $p)" ] && echo $p; done | head -1)
	kill -TERM $main 2>/dev/null
	for i in $(seq 15); do [ -z "$(procs)" ] && break; sleep 1; done
	if [ -n "$(procs)" ]; then echo "  still running after 15 s: SIGKILL"; kill -KILL $(procs) 2>/dev/null; pkill -KILL -x cowork-linux-he; fi
	echo "  stopped after ${i} s"; sleep 3
done
echo; echo "done $(date '+%T')  dpms=$(dpms)  claude left: $(procs | wc -l)"
rm -f /tmp/bfsc-a /tmp/bfsc-b
} > $OUT 2>&1
