#!/bin/bash
# cx-when-idle.sh [--idle MIN] [--from HH:MM] [--until HH:MM] STEP:MIN ...: run cx-exp.sh steps only while
# nobody uses the tablet (2026-10-16: daytime runs are at most 15 min each so the tablet stays usable, long ones
# at night). ROOT, through systemd-run, e.g.
#   day:   systemd-run --unit y700-cx-idle --collect -p KillMode=mixed /usr/local/libexec/cx-when-idle.sh \
#              --idle 10 --until 18:00 E0:15 E3a:15
#   night: systemd-run --unit y700-cx-night --collect -p KillMode=mixed --on-calendar='2026-10-17 00:30' \
#              /usr/local/libexec/cx-when-idle.sh --idle 30 --until 06:00 E3a:30 E5:30 E4:40
# Before each step it waits until there has been no touch / power / volume key interrupt for --idle minutes, the
# display is off and the tablet is on battery (apps-pc never happens on the charger). A step the owner interrupts
# (cx-exp.sh exit 4) is retried at the next idle window; precondition failures (exit 2) other than "charging"
# and trouble aborts (exit 3) end the run. Nothing starts after --until; --from delays the first wait.
# Waiting costs one /proc/interrupts read every 30 s. Status: curl http://100.64.0.10:8766/ (y700-cx-status).
set -u
LOG=/var/log/y700-cx-exp.txt
D=$(dirname "$(readlink -f "$0")")
IDLE=10; FROM=; UNTIL=
while [ $# -gt 0 ]; do case $1 in
	--idle) IDLE=$2; shift 2 ;; --from) FROM=$2; shift 2 ;; --until) UNTIL=$2; shift 2 ;; *) break ;; esac; done
[ $# -gt 0 ] || { echo "usage: $0 [--idle MIN] [--from HH:MM] [--until HH:MM] STEP:MIN ..." >&2; exit 2; }
note() { echo "$(date +%T) cx-when-idle: $*" >> $LOG; }
inputs() { awk '$NF ~ /NVT-ts|pwrkey|resin|volume|gpio-keys/ {for (i = 2; i <= 9; i++) s += $i} END {print s + 0}' /proc/interrupts; }
deadline=; [ -n "$UNTIL" ] && { deadline=$(date -d "$UNTIL" +%s); [ "$deadline" -le "$(date +%s)" ] && deadline=$(date -d "tomorrow $UNTIL" +%s); }
past_deadline() { [ -n "$deadline" ] && [ "$(date +%s)" -ge "$deadline" ]; }
CHILD=
trap 'note "stop requested"; [ -n "$CHILD" ] && { kill -TERM "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; }; exit 1' TERM INT
echo "=== $(date '+%F %T') cx-when-idle: idle ${IDLE} min, from ${FROM:-now}, until ${UNTIL:-no limit}: $*" >> $LOG
if [ -n "$FROM" ]; then
	t=$(date -d "$FROM" +%s); [ "$t" -gt "$(date +%s)" ] && { note "sleeping until $FROM"; sleep $((t - $(date +%s))) & CHILD=$!; wait $CHILD; CHILD=; }
fi
# wait_idle: returns 0 once idle long enough on battery with the display off, 1 at the deadline
wait_idle() {
	local last since
	last=$(inputs); since=$(date +%s)
	while :; do
		past_deadline && return 1
		sleep 30 & CHILD=$!; wait $CHILD; CHILD=
		local now cur dpms st
		now=$(date +%s); cur=$(inputs)
		dpms=$(cat /sys/class/drm/card*-DSI-*/dpms 2>/dev/null | head -1)
		st=$(cat /sys/class/power_supply/qcom-battmgr-bat/status)
		if [ "$cur" != "$last" ] || [ "$dpms" = On ] || [ "$st" != Discharging ]; then since=$now; last=$cur; continue; fi
		[ $((now - since)) -ge $((IDLE * 60)) ] && return 0
	done
}
for s in "$@"; do
	step=${s%%:*}; min=${s#*:}
	# "E4@E3c:20": E4/E5 at a given system-state level (cx-exp.sh's CX_LEVEL) for this step only (as cx-ladder.sh)
	lvl=; case $step in *@*) lvl=${step#*@}; step=${step%@*} ;; esac
	while :; do
		wait_idle || { note "deadline ${UNTIL} reached before $s - stopping"; exit 0; }
		note "idle ${IDLE} min on battery, display off: starting $s"
		CX_LEVEL=${lvl:-${CX_LEVEL:-}} "$D/cx-exp.sh" "$step" "$min" & CHILD=$!; wait $CHILD; rc=$?; CHILD=
		note "$s exit $rc"
		case $rc in
			0) break ;;
			4) note "the owner used the tablet during $s - retrying it at the next idle window" ;;
			2) st=$(cat /sys/class/power_supply/qcom-battmgr-bat/status)
			   [ "$st" = Discharging ] && { note "precondition failed for $s - stopping"; exit 2; }
			   note "charger connected - waiting" ;;
			*) note "$s ended with $rc - stopping"; exit "$rc" ;;
		esac
	done
done
note "all steps done"
