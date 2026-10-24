#!/bin/bash
# y700-diag-pack.sh --check | --run [--idle MIN]: the night diagnostics pack of linux/power/PLAN-deep-powersave.md M-5
# (the ExecCondition form of the M-4 DIAG: step), 2026-10-19. Root, on the tablet, as
# /usr/local/libexec/y700-diag-pack.sh, unit y700-diag-pack (y700-diag-*, NEVER y700-cx-*: y700-cx-auto disarms E3a
# for any y700-cx-* unit, cx-auto/src/main.rs:127-135, and the pack would then see the knobs-off state).
#
# --check  the ExecCondition (reads only, writes nothing). Exit 0 only when ALL of:
#            1. the panel is dpms Off (/sys/class/drm/card*-DSI-1/dpms, as y700-cx-status:31);
#            2. the battery is Discharging (apps-pc never happens on the charger, PROTOCOL.md:93);
#            3. no y700-cx-* / y700-scn-rec* unit has a cgroup directory under /sys/fs/cgroup/system.slice/ (the
#               y700-cx-status:22 method, no systemctl; y700-cx-auto and y700-cx-status* are excluded exactly as
#               experiment_running() excludes them - cx-auto is a daemon and always has one);
#            4. the touch / power / volume key interrupt sum (inputs() of cx-collapse/cx-when-idle.sh:22) did not
#               change over --idle minutes (default 10): the check samples it, sleeps --idle minutes, samples again,
#               and re-checks 1-3 after the sleep (a precondition can change while it waits). So --check itself takes
#               --idle minutes of wall time; TimeoutStartSec in the unit covers that.
#          Any failure prints the reason and exits 1: systemd then SKIPS the unit (ExecCondition exit 1..254 = skip,
#          not a failure). The flight recorder's state is reported but is not a condition (plan 3.1 item 7 belongs to
#          the night plan's own self-check).
# --run    the pack, into OUT=/var/log/y700-diag/<YYYYMMDD-HHMM>-pack/ (one file per tool + index.txt):
#            y700-flightrec --mark "DIAG:pack start"
#            always-on-check.sh --rtc 90 --no-clk   (NO --off: the screen is already off; --rtc creates the tracefs
#                                                    instance instances/y700-always-on, its only write, and removes it)
#            y700-whoawake 60                       (NO --off)
#            MHI_SECS=0 y700-l1ss-probe.sh          (PCI config space + sysfs only)
#            live-ro3.sh --no-user                  (one 60 s delta window, no sudo -u user items)
#            y700-flightrec --mark "DIAG:pack end"
#          each under its own timeout; afterwards /sys/kernel/tracing/instances/y700-always-on is checked and, if
#          always-on-check.sh left it behind, removed (reported in index.txt). Exit 0 whatever the tools returned (a
#          failing tool is recorded in index.txt, not fatal); exit 1 only when OUT cannot be created. ~10 min.
# Launch (no timer, no [Install] in the unit: it is started on purpose, one night at a time):
#   a) unit file installed (/etc/systemd/system/y700-diag-pack.service, Type=oneshot with the ExecCondition):
#        systemd-run --unit y700-diag-pack-at --collect --on-calendar='2026-10-21 02:30' \
#            systemctl start --no-block y700-diag-pack.service
#   b) transient, no unit file:
#        systemd-run --unit y700-diag-pack --collect -p KillMode=mixed -p Type=oneshot \
#            -p 'ExecCondition=/usr/local/libexec/y700-diag-pack.sh --check' \
#            --on-calendar='2026-10-21 02:30' /usr/local/libexec/y700-diag-pack.sh --run
#   c) a DIAG: step of /etc/y700/night-plan (M-4 / TL-1, plan appendix D): cx-when-idle.sh has already waited for
#      idle, dpms Off and battery, so it runs `y700-diag-pack.sh --run` directly, without --check.
# WRITES (--run only): mkdir OUT and the files in it (tool outputs, index.txt), the two MARK lines through
# y700-flightrec (pmsg + live.log + the UFS log; a stop while running sends "DIAG:pack end aborted" instead, so the
# recorder's fast cadence ends with the pack, flightrec/src/run.rs:191-201), and on the cleanup path - normal end and
# the stop path alike - `echo 0 > <instance>/tracing_on` + rmdir of a left-over tracefs instance (the same two steps as
# always-on-check.sh:43). Nothing else.
set -u
LIBEXEC=/usr/local/libexec
BIN=/usr/local/bin
# where the repo installs each tool (the other directory is the fallback, as cx-exp.sh:32 / tools/y700-l1ssbench.sh:21 do)
ALWAYS_ON=$LIBEXEC/always-on-check.sh      # ALWAYS-ON.md:232, PLAN-deep-powersave.md:462
LIVE_RO3=$LIBEXEC/live-ro3.sh              # PLAN-deep-powersave.md:462
WHOAWAKE=$BIN/y700-whoawake                # README:1421, tools/y700-idle-ab.sh:24
L1SS=$LIBEXEC/y700-l1ss-probe.sh           # PCIE-L1SS.md:137, tools/y700-l1ssbench.sh:21
FLIGHTREC=$LIBEXEC/y700-flightrec          # cx-collapse/y700-flightrec.service:15, flightrec/deploy.sh:9, cx-exp.sh:32
[ -x "$WHOAWAKE" ] || WHOAWAKE=$LIBEXEC/y700-whoawake
[ -x "$L1SS" ] || L1SS=$BIN/y700-l1ss-probe.sh
[ -x "$FLIGHTREC" ] || FLIGHTREC=$BIN/y700-flightrec
TRACE=/sys/kernel/tracing/instances/y700-always-on
CG=/sys/fs/cgroup/system.slice
BAT=/sys/class/power_supply/qcom-battmgr-bat/status
MODE=; IDLE=10
while [ $# -gt 0 ]; do
	case $1 in
	--check|--run) MODE=${1#--} ;;
	--idle) [ $# -ge 2 ] || { echo "--idle needs a value (minutes)" >&2; exit 1; }; IDLE=$2; shift ;;
	*) echo "usage: $0 --check | --run [--idle MIN]" >&2; exit 1 ;;
	esac
	shift
done
[ -n "$MODE" ] || { echo "usage: $0 --check | --run [--idle MIN]" >&2; exit 1; }
case $IDLE in ''|*[!0-9]*) echo "--idle needs a whole number of minutes" >&2; exit 1 ;; esac

# the three state readers (y700-cx-status:22 / :31, cx-when-idle.sh:22)
dpms() { cat /sys/class/drm/card*-DSI-1/dpms 2>/dev/null | head -1; }
bat() { cat $BAT 2>/dev/null; }
inputs() { awk '$NF ~ /NVT-ts|pwrkey|resin|volume|gpio-keys/ {for (i = 2; i <= 9; i++) s += $i} END {print s + 0}' /proc/interrupts; }
units() { # the experiment / scene units with a cgroup directory, cx-auto and the status page excluded
	local d n
	for d in "$CG"/y700-cx-*.service "$CG"/y700-scn-rec*.service; do
		[ -d "$d" ] || continue
		n=${d##*/}; n=${n%.service}
		case $n in y700-cx-auto|y700-cx-status*) continue ;; esac
		printf '%s ' "$n"
	done
}
# the instantaneous conditions 1-3; prints the reason and returns 1 on the first failing one
conditions() {
	local d b u
	d=$(dpms); [ "$d" = Off ] || { echo "skip: panel dpms=${d:-unreadable} (need Off)"; return 1; }
	b=$(bat); [ "$b" = Discharging ] || { echo "skip: battery ${b:-unreadable} (need Discharging)"; return 1; }
	u=$(units); [ -z "$u" ] || { echo "skip: experiment / scene unit running: $u"; return 1; }
	return 0
}

CHILD=; IDX=
log() { if [ -n "$IDX" ]; then echo "$(date '+%F %T') $*" | tee -a "$IDX"; else echo "$(date '+%F %T') $*"; fi; }
# always-on-check.sh --rtc creates $TRACE and its EXIT trap removes it (always-on-check.sh:43); if it is still there,
# do the same two steps and say so in index.txt. Called at the normal end and on the stop path.
trace_leftover() {
	if [ -d "$TRACE" ]; then
		echo 0 > "$TRACE/tracing_on" 2>/dev/null
		if rmdir "$TRACE" 2>/dev/null; then log "WARN: $TRACE was left behind by always-on-check.sh; removed"
		else log "WARN: $TRACE left behind and rmdir failed (check_trace_leftovers will report it)"; fi
	else
		log "tracefs instance $TRACE: clean"
	fi
}
# stop (KillMode=mixed sends TERM to this process only): end the running tool, wait for it, close the MARK pair, exit 1
on_term() {
	trap '' TERM INT
	if [ -n "$CHILD" ]; then
		kill -TERM "$CHILD" 2>/dev/null
		# systemd SIGKILLs the rest of the cgroup as soon as this process is gone (KillMode=mixed), so give the tool's
		# own EXIT trap (always-on-check.sh:43 removes the tracefs instance) up to 10 s before leaving
		for _ in $(seq 50); do kill -0 "$CHILD" 2>/dev/null || break; sleep 0.2; done
		kill -KILL "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null
	fi
	if [ "$MODE" = run ]; then
		[ -x "$FLIGHTREC" ] && "$FLIGHTREC" --mark "DIAG:pack end aborted" >/dev/null 2>&1
		[ -n "$IDX" ] && { log "aborted (TERM/INT)"; trace_leftover; }
	fi
	exit 1
}
trap on_term TERM INT

if [ "$MODE" = check ]; then
	conditions || exit 1
	i0=$(inputs)
	echo "$(date '+%F %T') dpms Off, Discharging, no experiment unit; inputs=$i0, waiting $IDLE min for them to stay put"
	sleep $((IDLE * 60)) & CHILD=$!; wait "$CHILD"; CHILD=
	i1=$(inputs)
	[ "$i1" = "$i0" ] || { echo "skip: touch / key interrupts $i0 -> $i1 within $IDLE min (the owner is using the tablet)"; exit 1; }
	conditions || exit 1
	echo "$(date '+%F %T') ok: idle $IDLE min, dpms Off, Discharging, no experiment unit; flightrec $([ -d $CG/y700-flightrec.service ] && echo running || echo NOT running)"
	exit 0
fi

# --run
OUT=/var/log/y700-diag/$(date +%Y%m%d-%H%M)-pack
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 1; }
IDX=$OUT/index.txt
step() { # name timeout command...: one tool into its own file, its exit code and duration into index.txt
	local n=$1 t=$2 t0 rc; shift 2
	[ -x "$1" ] || { log "$n: $1 missing or not executable, skipped"; return; }
	t0=$(date +%s)
	timeout "$t" "$@" > "$OUT/$n.txt" 2>&1 & CHILD=$!; wait "$CHILD"; rc=$?; CHILD=
	log "$n rc=$rc after $(( $(date +%s) - t0 )) s -> $n.txt"
}
log "diag pack start: dpms=$(dpms) battery=$(bat) inputs=$(inputs) units='$(units)' kernel=$(uname -r)"
if [ -x "$FLIGHTREC" ]; then "$FLIGHTREC" --mark "DIAG:pack start" >/dev/null 2>&1 || log "WARN: flightrec mark failed"; else log "WARN: $FLIGHTREC missing, no MARK lines"; fi
step always-on-check 300 "$ALWAYS_ON" --rtc 90 --no-clk
step whoawake 180 "$WHOAWAKE" 60
export MHI_SECS=0; step l1ss-probe 60 "$L1SS"; unset MHI_SECS
step live-ro3 360 "$LIVE_RO3" --no-user
[ -x "$FLIGHTREC" ] && { "$FLIGHTREC" --mark "DIAG:pack end" >/dev/null 2>&1 || log "WARN: flightrec mark failed"; }
trace_leftover
log "diag pack end: dpms=$(dpms) battery=$(bat) inputs=$(inputs); output in $OUT"
exit 0
