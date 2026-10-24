#!/bin/bash
# 2026-10-18 after the 05:50 reboot: cx-auto armed, screen off, yet the system domain is not entered and arch_timer is
# ~340/s. y700-whoawake put claude-desktop's VizCompositorThread (120 wakeups/s) and Chrome's (60/s) on top. Does it
# settle by itself? Every 120 s, a 60 s window: dpms, armed, cluster/cluster1/system genpd use, apss count, arch_timer/s,
# and wakeups/s (voluntary+involuntary ctxt switches) of every VizCompositorTh thread and of plasmashell. Read-only.
# Run as a transient unit NOT named y700-cx-* / y700-offmeasure* so cx-auto stays armed:
#   systemd-run --unit y700-wakewatch --collect /root/wakewatch.sh 12 /root/runs/postboot-20261018/wakewatch.txt
export LC_ALL=C
N=${1:-12}; OUT=${2:-/root/wakewatch.txt}
mkdir -p "$(dirname "$OUT")"
G=/sys/kernel/debug/pm_genpd
use() { sed -n 2p $G/power-domain-$1/idle_states | awk '{print $3}'; }
timer() { awk '/arch_timer/ {s = 0; for (i = 2; i <= 9; i++) s += $i; print s}' /proc/interrupts; }
apss() { grep -i count /sys/kernel/debug/qcom_stats/apss | awk '{print $NF}'; }
# "pid/tid comm-of-process thread-name ctxt" for the threads we watch
threads() {
	for st in /proc/[0-9]*/task/[0-9]*/status; do
		read -r name < "${st%/status}/comm" 2>/dev/null || continue
		case $name in VizCompositorTh|plasmashell) ;; *) continue ;; esac
		t=${st%/status}; t=${t##*/}; p=${st#/proc/}; p=${p%%/*}
		[ "$name" = plasmashell ] && [ "$t" != "$p" ] && continue
		exe=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | awk '{n = split($1, a, "/"); print a[n]}')
		awk -v id="$p/$t" -v nm="$name" -v exe="$exe" '/ctxt_switches/ {s += $2} END {print id, exe, nm, s}' "$st"
	done
}
for i in $(seq 1 "$N"); do
	d=$(cat /sys/class/drm/card*-DSI-1/dpms | head -1)
	a=$([ -e /run/y700-cx-auto.armed ] && echo Y || echo N)
	c0=$(use cluster); c1=$(use cluster1); sy=$(use system); ap=$(apss); tm=$(timer); th0=$(threads)
	sleep 60
	c0b=$(use cluster); c1b=$(use cluster1); syb=$(use system); apb=$(apss); tmb=$(timer); th1=$(threads)
	db=$(cat /sys/class/drm/card*-DSI-1/dpms | head -1)
	awk -v t="$(date +%T)" -v d="$d/$db" -v a="$a" -v c0="$(( c0b - c0 ))" -v c1="$(( c1b - c1 ))" -v sy="$(( syb - sy ))" -v ap="$(( apb - ap ))" -v tm="$(( tmb - tm ))" \
		'BEGIN {printf "%s dpms=%s armed=%s  cl0 %.1f/s  cl1 %.1f/s  sys %.1f/s  apss %.1f/s  arch_timer %.0f/s  |", t, d, a, c0 / 60, c1 / 60, sy / 60, ap / 60, tm / 60}' >> "$OUT"
	join <(echo "$th0" | sort) <(echo "$th1" | sort) | awk '{printf "  %s %s %.1f/s", $2, $3, ($7 - $4) / 60}' >> "$OUT"
	echo >> "$OUT"
	sleep 60
done
echo "done $(date +%T)" >> "$OUT"
