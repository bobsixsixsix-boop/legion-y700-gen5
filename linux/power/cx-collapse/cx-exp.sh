#!/bin/bash
# cx-exp.sh STEP [MINUTES]: one rung of the CX-collapse ladder (linux/power/cx-collapse/PROTOCOL.md section 3).
# ROOT, and ALWAYS through systemd-run, so a dropped ssh session cannot take the restore path down with it:
#   systemd-run --unit y700-cx-exp --collect /usr/local/libexec/cx-exp.sh E1 30
# STEP  E0   nothing opened: the same harness, screen off, as the baseline arm of an A/B (2026-10-16)
#       E1   allow_cluster_off=1, screen off                 (patch 0118 undone; upstream saw 2 resets in 78 min)
#       E2   E1 + dczva-stress on every CPU                  (the DC ZVA hypothesis probe)
#       E3a  + allow_system_off=1 (y10 knob) with the AOP told to keep CX and DDR up -> APSS power collapse only
#       E3b  E3a but CX may collapse (DDR still kept)        E3c  everything may collapse (= s2idle depth)
#       E4   level + display on/off every 20 s               (patch 0106's trigger)
#       E5   level + Wi-Fi traffic (ping the gateway; IPERF_SERVER=host adds iperf3 rounds)
#       E4/E5 open the system state at the level CX_LEVEL=E3a|E3b|E3c, default E3a = the deepest level that has
#       passed so far (until 2026-10-16 they always ran at E3c, a level that had never been tried).
# Preconditions enforced: download_mode=off, uptime >= 240 s, on battery and >= 40 % (CX_ALLOW_CHARGING=1 waives
# the battery test for a pure soak), y700-flightrec active, the y10 knob present for E3+. Everything is restored
# by the EXIT trap; a reset restores it too (module parameters only, the cmdline keeps allow_cluster_off=0).
# Abort watchdog, every 10 s: journal -k scanned for the known trouble signatures -> restore, exit 3; and the
# owner's hands: >= 3 touch-panel / power / volume key interrupts in 10 s -> restore (display back on), exit 4.
# Do not ssh into the tablet while a step runs: every login starts root's systemd user manager (and its failing
# pipewire/wireplumber units) and stops it again, which shows up as cgroup churn, static-key IPIs and power.
# Log: /var/log/y700-cx-exp.txt (power lines in y700-powersample's format, comparable with offbench).
set -u
STEP=${1:?STEP (E0 E1 E2 E3a E3b E3c E4 E5)}; MIN=${2:-30}
case $STEP in E3a|E3b|E3c) LVL=$STEP ;; E4|E5) LVL=${CX_LEVEL:-E3a} ;; *) LVL=- ;; esac
LOG=/var/log/y700-cx-exp.txt
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
ACO=/sys/module/cpuidle_psci_domain/parameters/allow_cluster_off
ASO=/sys/module/cpuidle_psci_domain/parameters/allow_system_off
AOSS=/sys/kernel/debug/qcom_aoss
# Rust since 2026-10-17; before its deploy (or if the deploy gave up) only the Python one exists under .py; after it
# the .py path is a symlink to the Rust binary - so either name works
FR=/usr/local/libexec/y700-flightrec; [ -x $FR ] || FR=/usr/local/libexec/y700-flightrec.py
PS=/usr/local/libexec/y700-powersample.py
STRESS=/usr/local/libexec/dczva-stress
BAT=/sys/class/power_supply/qcom-battmgr-bat
note() { echo "$(date +%T) $*" | tee -a "$LOG"; }
mark() { $FR --mark "$*" >/dev/null 2>&1 || note "WARN: $FR --mark failed ($?): the recorder has no MARK for this"; note "MARK $*"; }
die() { note "ABORT: $1"; exit "${2:-3}"; }
knob() { echo "$2" > "$1" 2>/dev/null || note "WARN: write $2 > $1 failed ($?)"; }
pd_snapshot() {
	for d in power-domain-cluster power-domain-cluster1 power-domain-system; do
		printf '%s[%s] ' "${d#power-domain-}" "$(sed -n 2p /sys/kernel/debug/pm_genpd/$d/idle_states 2>/dev/null | awk '{print "use="$3" rej="$4}')"
	done
	for s in apss cxsd aosd ddr; do
		printf '%s=%s ' "$s" "$(awk -F': *' '/^Count/{c=$2} /^Accumulated/{d=$2} END{printf "%s/%dms", c, d/19200}' /sys/kernel/debug/qcom_stats/$s 2>/dev/null)"
	done
	echo
}

# ---- preconditions
dm=$(cat /sys/module/qcom_scm/parameters/download_mode 2>/dev/null)
[ "$dm" = off ] || die "download_mode is '$dm', not off: a reset would park the SoC in dump mode" 2
up=$(cut -d. -f1 /proc/uptime)
[ "$up" -ge 240 ] || die "uptime ${up}s < 240 s (y700-dumpmode-off.timer fires at 180 s)" 2
st=$(cat $BAT/status); cap=$(cat $BAT/capacity)
if [ "$st" != Discharging ] && [ "${CX_ALLOW_CHARGING:-0}" != 1 ]; then
	die "charger connected ($st): battery power unreadable; CX_ALLOW_CHARGING=1 for a pure soak" 2
fi
[ "$cap" -ge 40 ] || die "battery $cap % < 40 %" 2
systemctl is-active -q y700-flightrec || die "y700-flightrec is not running (systemctl enable --now y700-flightrec)" 2
[ -x $FR ] || die "no flight recorder CLI ($FR): exp-collect.sh would find no start/end MARKs" 2
case $STEP in
	E0|E1|E2) ;;
	E3a|E3b|E3c|E4|E5) [ -e $ASO ] || die "$ASO missing: this kernel has no y10 allow_system_off knob" 2 ;;
	*) die "unknown step $STEP" 2 ;;
esac
case $LVL in -|E3a|E3b|E3c) ;; *) die "CX_LEVEL '$LVL' is not E3a, E3b or E3c" 2 ;; esac
[ "$STEP" = E2 ] && { [ -x $STRESS ] || die "$STRESS missing (cc -O2 -pthread -o dczva-stress dczva-stress.c)" 2; }
case $LVL in E3a|E3b) [ -d $AOSS ] || die "$AOSS missing (qcom_aoss debugfs): run E3c with 15 min instead" 2 ;; esac

# ---- restore (EXIT trap)
STRESS_PID=; PING_PID=; IPERF_PID=; CYCLE_PID=; WD_PID=; INH=; AOSS_SET=0; RC=0
BL=$(ls -d /sys/class/backlight/* 2>/dev/null | head -1); BL0=$([ -n "$BL" ] && cat $BL/brightness)
DPMS0=$(cat /sys/class/drm/card*-DSI-*/dpms 2>/dev/null | head -1)   # display state before the step
restore() {
	trap - EXIT
	knob $ACO 0
	[ -e $ASO ] && knob $ASO 0
	if [ "$AOSS_SET" = 1 ]; then knob $AOSS/prevent_cx_collapse 0; knob $AOSS/prevent_ddr_collapse 0; fi
	for p in $STRESS_PID $PING_PID $IPERF_PID $CYCLE_PID $WD_PID; do [ -n "$p" ] && { pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; }; done
	[ -n "$BL" ] && [ -n "$BL0" ] && echo "$BL0" > $BL/brightness 2>/dev/null      # E4 dims the panel
	# Display back on only if the owner touched the tablet (exit 4) or it was on before the step: an unattended
	# run on an idle tablet should not light the screen up at the end (owner, 2026-10-16 daytime / night runs).
	if [ "$RC" = 4 ] || [ "$DPMS0" = On ]; then
		"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 2
		[ "$(cat /sys/class/drm/card*-DSI-*/dpms 2>/dev/null | head -1)" = On ] || note "WARN: display did not come back on"
	elif [ "$(cat /sys/class/drm/card*-DSI-*/dpms 2>/dev/null | head -1)" = On ]; then
		# E4's cycle can be stopped in its "on" half: put the panel back off as it was (2026-10-17 06:05, the 3 min
		# E4 check ended with the screen on at full brightness)
		"${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1
	fi
	[ -n "$INH" ] && { pkill -P "$INH" 2>/dev/null; kill "$INH" 2>/dev/null; }
	rm -f $WAKE
	note "after:  $(pd_snapshot)"
	mark "$STEP end aco=$(cat $ACO) aso=$([ -e $ASO ] && cat $ASO || echo -)"
}
trap restore EXIT
trap 'RC=1; exit 1' INT TERM
trap 'RC=4; exit 4' USR1

# touch panel (NVT-ts-spi) and power / volume keys: the sums of their interrupt counts over all CPUs
touches() { awk '$NF ~ /NVT-ts/ {for (i = 2; i <= 9; i++) s += $i} END {print s + 0}' /proc/interrupts; }
keys() { awk '$NF ~ /pwrkey|resin|volume|gpio-keys/ {for (i = 2; i <= 9; i++) s += $i} END {print s + 0}' /proc/interrupts; }
# E4 switches the panel itself, and a panel wake fires ~3 touch interrupts on its own: all four E4 attempts of the
# 2026-10-17 night stopped 30 s in ("the owner is using the tablet") right after their first display-on. The cycle
# writes the epoch second of each switch here; touches in a window within 15 s of one do not count (keys always do,
# and a real touch shows up again in the next window)
WAKE=/run/cx-exp.panel-switch
OWNER=0
watchdog() {
	local t0 t1 k0 k1 dt w
	t0=$(touches); k0=$(keys)
	while sleep 10; do
		n=$(journalctl -k --since "-12s" -o cat 2>/dev/null | grep -cE 'vblank timeout|failed to flush transmit queue|timed out in resp|TCS Busy|rpmh.*(timeout|fail)|Unhandled fault|SError|NoC|BUG:|WARNING:')
		if [ "${n:-0}" -ge 5 ]; then
			note "watchdog: $n trouble lines in 12 s:"
			journalctl -k --since "-12s" -o cat 2>/dev/null | tail -5 | tee -a "$LOG"
			kill -TERM $$
			exit 0
		fi
		t1=$(touches); k1=$(keys)
		dt=$((t1 - t0)); w=$(cat $WAKE 2>/dev/null || echo 0)
		[ $(( $(date +%s) - w )) -le 15 ] && dt=0          # our own panel switch, not the owner
		if [ $((dt + k1 - k0)) -ge 3 ]; then
			note "watchdog: $((t1 - t0)) touch + $((k1 - k0)) key interrupts in 10 s - the owner is using the tablet, stopping"
			kill -USR1 $$
			exit 0
		fi
		t0=$t1; k0=$k1
	done
}
open_level() {
	case $1 in
	E3a) echo 1 > $AOSS/prevent_cx_collapse || die "AOP refused {class: cx_mol} (write failed): use E3c, 15 min"
	     AOSS_SET=1
	     echo 1 > $AOSS/prevent_ddr_collapse || die "AOP refused {class: ddr_mol}"
	     knob $ACO 1; knob $ASO 1 ;;
	E3b) echo 1 > $AOSS/prevent_ddr_collapse || die "AOP refused {class: ddr_mol}"
	     AOSS_SET=1
	     knob $ACO 1; knob $ASO 1 ;;
	E3c) knob $ACO 1; knob $ASO 1 ;;
	esac
}

# ---- run
{ echo; echo "=== $(date '+%F %T') cx-exp $STEP ${MIN} min (level $LVL) on $(uname -r), battery $st $cap %, aco=$(cat $ACO) aso=$([ -e $ASO ] && cat $ASO || echo -) dl=$dm"; } | tee -a "$LOG"
"${U[@]}" kde-inhibit --power --screenSaver sleep $((MIN * 60 + 900)) >/dev/null 2>&1 </dev/null & INH=$!
"${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1
sleep 15
# the display must really be off (kscreen-doctor runs as user with fixed bus paths and its errors are dropped)
dpms=$(cat /sys/class/drm/card*-DSI-*/dpms 2>/dev/null | head -1)
[ "$dpms" = Off ] || die "display is '$dpms', not Off after 15 s (kscreen-doctor failed? someone using the tablet?)" 2
note "before: $(pd_snapshot)"
watchdog & WD_PID=$!
mark "$STEP start ${MIN}min"
case $STEP in
	E0) ;;
	E1) knob $ACO 1 ;;
	E2) knob $ACO 1
	    $STRESS -t $((MIN * 60)) >> "$LOG" 2>&1 & STRESS_PID=$! ;;
	E3a|E3b|E3c) open_level $LVL ;;
	E4)  open_level $LVL
	     [ -n "$BL" ] && echo 1 > $BL/brightness 2>/dev/null   # lowest backlight while the panel blinks (night runs)
	     ( while :; do
			sleep 20; date +%s > $WAKE; "${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; date +%s > $WAKE
			sleep 20; date +%s > $WAKE; "${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1; date +%s > $WAKE
		done ) & CYCLE_PID=$! ;;
	E5)  open_level $LVL
	     gw=$(ip -4 route show default | awk '{print $3; exit}')
	     [ -n "$gw" ] && { ping -i 0.2 -s 1000 -q "$gw" >> "$LOG" 2>&1 & PING_PID=$!; }
	     [ -n "${IPERF_SERVER:-}" ] && { ( while :; do iperf3 -c "$IPERF_SERVER" -t 30 -b 20M >/dev/null 2>&1; sleep 30; done ) & IPERF_PID=$!; } ;;
esac
note "knobs: aco=$(cat $ACO) aso=$([ -e $ASO ] && cat $ASO || echo -) aoss_set=$AOSS_SET"

end=$((SECONDS + MIN * 60)); next_ps=$((SECONDS + 60)); n=0
while [ $SECONDS -lt $end ]; do
	sleep 5
	if [ $SECONDS -ge $next_ps ]; then
		n=$((n + 1))
		[ "$STEP" = E2 ] || $PS 75 "$STEP t+$(( (SECONDS) / 60 ))m" >> "$LOG" 2>&1
		note "t+$((SECONDS / 60))m: $(pd_snapshot)"
		next_ps=$((SECONDS + 600))
	fi
	[ -n "$STRESS_PID" ] && ! kill -0 "$STRESS_PID" 2>/dev/null && { note "dczva-stress exited early (see log)"; STRESS_PID=; }
done
note "done $STEP ${MIN} min without a reset"
exit 0
