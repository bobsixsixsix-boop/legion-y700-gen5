#!/bin/bash
# cx-ladder.sh STEP:MIN ...: run cx-exp.sh steps back to back, unattended. ROOT, through systemd-run:
#   systemd-run --unit y700-cx-ladder --collect -p KillMode=mixed /usr/local/libexec/cx-ladder.sh P E0:20 E3a:30 E5:30 E4:40
#   (a step "E4@E3c:20" runs E4 at the E3c level - CX_LEVEL for that step only)
# Daytime rule (owner, 2026-10-16): at most 15 minutes per run during the day; anything longer runs at night.
# STEP "P" runs cx-wakeprobe.sh (30 s screen-off trace of cgroup churn / exec / static-key IPIs), any other STEP is
# handed to cx-exp.sh with its minutes. Stops at the first step that does not exit 0: 2 precondition, 3 trouble in
# the kernel log, 4 the owner touched the tablet (cx-exp.sh restores everything itself first). A reset ends the
# ladder too - nothing restarts it, and the knobs come back off from the cmdline / C defaults.
# Between steps CX_GAP seconds (default 60) with the display back on, as cx-exp.sh leaves it.
# Rule (2026-10-16): do not ssh into the tablet while it runs - every login starts and stops root's systemd user
# manager, which perturbs exactly what is being measured. Read /var/log/y700-cx-exp.txt once at the end.
set -u
LOG=/var/log/y700-cx-exp.txt
GAP=${CX_GAP:-60}
D=$(dirname "$(readlink -f "$0")")
# `systemctl stop y700-cx-ladder` must let the running step restore everything (AOP prevent_* flags, knobs,
# display) before the unit goes away: forward the TERM to the child and wait for it. The unit needs
# KillMode=mixed (systemd-run -p KillMode=mixed) so that only this script gets the TERM first; with the
# default control-group mode every process (kscreen-doctor, sleep, the child's own restore) is signalled at
# once and the restore can die half-way (seen 2026-10-16 12:3x: no "after:" line).
CHILD=
stop() { echo "$(date +%T) cx-ladder: stop requested, letting the running step restore" >> $LOG
	[ -n "$CHILD" ] && { kill -TERM "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; }
	echo "$(date +%T) cx-ladder: stopped" >> $LOG; exit 1; }
trap stop TERM INT
echo "=== $(date '+%F %T') cx-ladder: $* (gap ${GAP}s)" >> $LOG
for s in "$@"; do
	step=${s%%:*}; min=${s#*:}; [ "$min" = "$s" ] && min=30
	# "E4@E3c:20": E4/E5 at a given system-state level (cx-exp.sh's CX_LEVEL) for this step only (2026-10-17)
	lvl=; case $step in *@*) lvl=${step#*@}; step=${step%@*} ;; esac
	if [ "$step" = P ]; then "$D/cx-wakeprobe.sh" >> $LOG 2>&1 & CHILD=$!
	else CX_LEVEL=${lvl:-${CX_LEVEL:-}} "$D/cx-exp.sh" "$step" "$min" & CHILD=$!
	fi
	wait "$CHILD"; rc=$?; CHILD=
	echo "$(date +%T) cx-ladder: $s exit $rc" >> $LOG
	[ $rc = 0 ] || { echo "$(date +%T) cx-ladder: stopping after $s (exit $rc)" >> $LOG; exit $rc; }
	sleep "$GAP"
done
echo "$(date +%T) cx-ladder: all steps done" >> $LOG
