#!/bin/bash
# live-ro3.sh [--checklist] [--delta SEC] [--no-user]: read-only live snapshot of the Y700 for the deep-powersave plan
# (linux/power/PLAN-deep-powersave.md CPU-1 "who votes against apps-pc", WK-8, DSP-8, the CPU-6 plasma-nm locate step;
# 2026-10-19). Supersedes and merges the 10-19 live-ro.sh / live-ro2.sh. Root, on the tablet, installed as
# /usr/local/libexec/live-ro3.sh; the same script serves the P1 ssh window (screen on) and a night DIAG step (screen
# off, y700-diag-pack.sh --run calls it with --no-user):
#   systemd-run --unit y700-diag-cx-votes --collect -p KillMode=mixed /usr/local/libexec/live-ro3.sh
# The unit is y700-diag-*, NEVER y700-cx-*: y700-cx-auto treats every y700-cx-* unit (except itself and y700-cx-status*)
# as an experiment and disarms E3a, so a y700-cx-* name would show the knobs-off state (cx-auto/src/main.rs:127-135).
#
# WRITES: its own stdout and the scratch files /tmp/.ro3-<pid>-* (removed by the EXIT trap). Nothing else: no
# systemctl start/stop/restart/enable, no tee into /var/log, no kscreen-doctor --dpms, no tracefs writes, no sysfs
# writes. --checklist is the one exception (see below).
# NEVER opened (register-class debugfs hung the bus on 2026-10-15 03:41; the list of always-on-check.sh:11-12):
#   /sys/kernel/debug/pcie@*, regmap, /sys/kernel/debug/dri/* (the gpu-dvfs thresholds come from
#   /etc/default/y700-gpu-dvfs plus `journalctl -u y700-gpu-dvfs`, which logs what it wrote), clk_summary, *.gpu
#   debugfs, ufshcd*, ath12k and mhi debugfs (only their /sys/module and /sys/bus sysfs files are read), /dev/mem,
#   the qcom_aoss knobs; never lspci -vvv/-vv (wakes runtime-suspended PCI devices): only
#   /sys/bus/pci/devices/0000:01:00.0/link/* and power/* are read.
# Every external command runs under `timeout 8` (T below); wall time <= 4 min without --checklist (the delta window
# plus about one minute of commands). ONE shared delta window (--delta, default 60 s; the tablet is left alone during
# it) serves everything that needs a delta: /proc/interrupts per CPU (arch_timer, IPIs, NVT touch, pwrkey,
# apss_cpucp_mbox, ipcc), cpuidle usage/time per CPU and state, pm_genpd idle_states line 2 of cluster / cluster1 /
# system, qcom_stats apss/cxsd/aosd/ddr, utime+stime ticks per process (top 20) and per THREAD of plasmashell,
# kwin_wayland, y700-osk*, control-center, tailscaled, pipewire, wireplumber (top 15 by CPU delta: the
# plasma-nm locate and the DSP-8 "does KWin really stop compositing" proxy). This kernel has no per-task schedstat
# (`# CONFIG_SCHEDSTATS is not set`, linux/kernel-y8/config-t49-y8:7957 = config-t49-y9:7957, the config y12 is built
# from, kbuild-y12.sh:22; `# CONFIG_TASK_DELAY_ACCT is not set` at :134 is what leaves /proc/<pid>/schedstat out;
# README:1614), so threads are measured by /proc/<pid>/task/<tid>/stat utime+stime (ticks of 1/100 s) plus the ctxt
# switch counters of task/<tid>/status; schedstat (ns) is used automatically when a kernel has it.
# tb323fu-ctl: only forms whose read-only nature is in the helper's own CLI source
# (linux/tb323fu-linux/helper/crates/tb323fu-ctl/src/main.rs): bare `tb323fu-ctl gpu` (:907) and bare
# `tb323fu-ctl refresh` (:885) are `show()` = one D-Bus Properties.GetAll (:165, :150), nothing is set - gpu-floor reads
# `gpu` the same way (gpu-floor/src/main.rs:273/:302, as do linux/video/video-gpu-ab.sh:15 and
# linux/kernel-y8/y12-gpu-stress.sh:11) and README:403 reads `refresh` for `Policy:`; `tb323fu-ctl kernel status`
# (:529 -> kernel_status() :377, used by linux/kernel-y7/y7-verify.sh:19 and README:637/:663); plus the helper's state file
# /var/lib/tb323fu/kernel-state (switcher/device/switch-to-linux.sh:66). The argument forms (`gpu limits|profile`,
# `refresh auto|manual|preset`, `kernel keep|install-local`) are writes and are never run.
# --checklist  also run y700-checklist (NOT read-only: it runs y700-kmsg-watch --selftest, tools/y700-checklist.py:600,
#              which starts the watchdogs); only from the P1 daytime window, never from a night DIAG step. +150 s.
# --delta SEC  the delta window (default 60)
# --no-user    skip every `sudo -u user ...` item (systemctl --user, gdbus, kscreen-doctor, pactl, kreadconfig6)
set -u
export LC_ALL=C
umask 077
CHECKLIST=0; DELTA=60; NOUSER=0
while [ $# -gt 0 ]; do
	case $1 in
	--checklist) CHECKLIST=1 ;;
	--delta) [ $# -ge 2 ] || { echo "--delta needs a value (seconds)" >&2; exit 1; }; DELTA=$2; shift ;;
	--no-user) NOUSER=1 ;;
	*) echo "usage: $0 [--checklist] [--delta SEC] [--no-user]" >&2; exit 1 ;;
	esac
	shift
done
case $DELTA in ''|*[!0-9]*) echo "--delta needs a positive integer" >&2; exit 1 ;; esac
[ "$DELTA" -gt 0 ] || { echo "--delta needs a positive integer" >&2; exit 1; }   # numeric: "00" would reach sleep 00 and awk n/dt
TMP=/tmp/.ro3-$$
CHILD=
trap 'rm -f "$TMP"-*' EXIT
trap '[ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null; exit 1' TERM INT
T() { timeout 8 "$@"; }
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
user() { if [ $NOUSER = 1 ]; then echo "(skipped: --no-user)"; else timeout 8 "${U[@]}" "$@" 2>/dev/null; fi; }
# tb323fu-ctl talks D-Bus to tb323fu-helperd, whose bus name is activatable (helper/data/io.github.joonhoekim.OpenDeviceHelper1.service:
# SystemdService=): on a stopped helper (a bench's "helperd 停" state) the CLI would start the daemon and leave it running
ctl() { if T systemctl is-active --quiet tb323fu-helperd 2>/dev/null; then T tb323fu-ctl "$@" 2>&1; else echo "tb323fu-ctl $*: not run (tb323fu-helperd inactive; the CLI would D-Bus-activate it)"; fi; }
S() { printf '\n===== %s =====\n' "$*"; }
H() { printf -- '--- %s\n' "$*"; }
R() { for f in "$@"; do printf '%s: ' "$f"; cat "$f" 2>/dev/null || echo '(n/a)'; done; }
rd() { cat "$1" 2>/dev/null || echo '-'; }
D=/sys/kernel/debug
P=/sys/bus/platform/devices
BAT=/sys/class/power_supply/qcom-battmgr-bat
TRACE=/sys/kernel/tracing
SYS_UNITS="y700-cx-auto y700-flightrec y700-gpu-floor y700-gpu-dvfs y700-kmsg-watch y700-guestos tb323fu-helperd tailscaled y700-dumpmode-off.timer y700-cx-status.socket bluetooth ModemManager iio-sensor-proxy chrony"
USER_UNITS="y700-refresh-auto y700-autobright y700-speaker-guard y700-control-center y700-wiliwili-proxy y700-hud-overlay y700-screen-off-freeze plasma-plasmashell plasma-kwin_wayland plasma-powerdevil pipewire wireplumber"
# the /proc/interrupts lines of interest (matched on the whole line, so IRQ numbers may change between kernels)
IRQ_RE='arch_timer|^ *IPI[0-9]+:|NVT-ts|pwrkey|resin|volume|gpio-keys|apss_cpucp_mbox|ipcc'
# the per-thread view: the processes the plan names (CPU-1 / CPU-6 / DSP-8 / UP) plus wireplumber (map G)
named_pids() {
	{ pgrep -x plasmashell; pgrep -x kwin_wayland; pgrep -f y700-osk; pgrep -f control-center
	  pgrep -x tailscaled; pgrep -x pipewire; pgrep -x wireplumber; } 2>/dev/null | sort -un
}
# the delta window needs (a) the counters, cheap reads: /proc/interrupts, cpuidle, pm_genpd, qcom_stats, devfreq, and
# (b) the process / thread scans, a fork burst (one awk over every /proc/*/stat, three fork+exec per thread of the
# named set, a few seconds). Snapshot a runs the scans FIRST and the counters LAST, snapshot b the counters first:
# the burst sits outside the [a, b] window instead of at its start, so the script's own forks do not land in the
# IRQ / cpuidle / pm_genpd deltas it exists to attribute (10-19 review). The per-process / per-thread deltas
# therefore span the window plus the two scans (a few seconds more than the delta).
snap_counters() {
	local p=$TMP-$1 c s d q
	date '+%s %T' > "$p.t"
	cat /proc/interrupts > "$p.irq"
	for c in /sys/devices/system/cpu/cpu[0-9]*; do for s in "$c"/cpuidle/state*; do
		[ -f "$s/usage" ] && printf '%s %s %s %s %s\n' "${c##*/}" "${s##*/}" "$(rd "$s/name")" "$(rd "$s/usage")" "$(rd "$s/time")"
	done; done > "$p.idle"
	for d in cluster cluster1 system; do printf '%s %s\n' "$d" "$(sed -n 2p "$D/pm_genpd/power-domain-$d/idle_states" 2>/dev/null)"; done > "$p.pd"
	for q in apss cxsd aosd ddr; do printf '%s %s\n' "$q" "$(tr '\n' ' ' 2>/dev/null < "$D/qcom_stats/$q")"; done > "$p.qs"
	printf 'ddr=%s llcc=%s ddr-qos=%s\n' "$(rd /sys/class/devfreq/ddr/cur_freq)" "$(rd /sys/class/devfreq/llcc/cur_freq)" "$(rd /sys/class/devfreq/ddr-qos/cur_freq)" > "$p.ddr"
}
snap_scans() {
	local p=$TMP-$1 c s pid t tid rt cs comm
	# pid ticks comm: utime+stime are the 14th/15th fields; counted from the end (38/37 of 52) because comm may hold spaces
	for s in /proc/[0-9]*/stat; do read -r c 2>/dev/null < "$s" && echo "$c"; done |
		awk '{n=$0; sub(/^[0-9]+ \(/,"",n); sub(/\).*/,"",n); i=split($0,f," "); print $1, f[i-38]+f[i-37], n}' > "$p.proc"
	# pid tid cpu ctxt comm for every thread of the named processes (cpu = schedstat ns, or stat ticks on this kernel)
	for pid in $(named_pids); do for t in /proc/"$pid"/task/[0-9]*; do
		tid=${t##*/}; comm=$(rd "$t/comm")
		if [ -r "$t/schedstat" ]; then read -r rt _ 2>/dev/null < "$t/schedstat"
		else rt=$(awk '{i=split($0,f," "); print f[i-38]+f[i-37]}' "$t/stat" 2>/dev/null); fi
		cs=$(awk '/ctxt_switches/ {s+=$2} END {print s+0}' "$t/status" 2>/dev/null)
		printf '%s %s %s %s %s\n' "$pid" "$tid" "${rt:-0}" "${cs:-0}" "$comm"
	done; done > "$p.thr" 2>/dev/null
}
snap() { if [ "$1" = a ]; then snap_scans a; snap_counters a; else snap_counters "$1"; snap_scans "$1"; fi; }

S date
date '+%F %T %Z'; echo "uptime $(cut -d' ' -f1 /proc/uptime) s; boot_id $(rd /proc/sys/kernel/random/boot_id); dpms $(cat /sys/class/drm/card*-DSI-1/dpms 2>/dev/null | head -1); delta ${DELTA} s; user items $([ $NOUSER = 1 ] && echo skipped || echo on)"

S "identity / knobs (map A)"
uname -r; cat /proc/cmdline
R /sys/module/cpuidle_psci_domain/parameters/allow_cluster_off /sys/module/cpuidle_psci_domain/parameters/allow_system_off /sys/module/qcom_scm/parameters/download_mode
H "y700-cx-auto --status"; T y700-cx-auto --status 2>&1 | head -6
ls -l /run/y700-cx-auto.armed /var/lib/y700/cx-auto.armed /var/lib/y700/cx-auto.disabled 2>&1 | cut -c1-120
[ -f /var/lib/y700/cx-auto.disabled ] && { printf 'cx-auto.disabled says: '; head -c 200 /var/lib/y700/cx-auto.disabled; echo; }
H "system units"; T systemctl is-active $SYS_UNITS 2>/dev/null | paste -d= <(tr ' ' '\n' <<< "$SYS_UNITS") - | tr '\n' ' '; echo
H "user units (user)"; if [ $NOUSER = 1 ]; then echo "(skipped: --no-user)"; else user systemctl --user is-active $USER_UNITS | paste -d= <(tr ' ' '\n' <<< "$USER_UNITS") - | tr '\n' ' '; echo; fi
H "failed units"; T systemctl --failed --no-pager --no-legend 2>/dev/null; user systemctl --user --failed --no-pager --no-legend
H "linger / sessions (an ssh login starts root's user manager: PROTOCOL.md 3)"
T loginctl show-user root -p Linger 2>&1 | head -1; echo "linger dir: $(ls /var/lib/systemd/linger/ 2>/dev/null | tr '\n' ' ')"
T loginctl list-sessions --no-legend 2>/dev/null | cut -c1-100
echo "u0=$([ -d /run/user/0 ] && echo present || echo absent) ssh_sessions=$(grep -ls '^SERVICE=sshd' /run/systemd/sessions/* 2>/dev/null | wc -l)"
H "kernel slot (tb323fu-ctl kernel status, y7-verify.sh:19; /var/lib/tb323fu/kernel-state, switch-to-linux.sh:66)"
ctl kernel status | head -6 | cut -c1-160
grep -E '^(good|trial|failed)(_sha256)?=' /var/lib/tb323fu/kernel-state 2>/dev/null | cut -c1-90
H "previous boot end"; T journalctl --list-boots -q 2>/dev/null | tail -3; T journalctl -b -1 -n 5 --no-pager -q 2>/dev/null | cut -c1-160
echo "pstore: $(ls /sys/fs/pstore 2>/dev/null | wc -l) files live, $(ls /var/lib/systemd/pstore 2>/dev/null | wc -l) archived"
H "running services (system)"; T systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' '; echo
H "running services (user user)"; if [ $NOUSER = 1 ]; then echo "(skipped: --no-user)"; else user systemctl --user list-units --type=service --state=running --no-pager --no-legend | awk '{print $1}' | tr '\n' ' '; echo; fi
H "y700-* unit cgroups (the y700-cx-status method, no D-Bus)"; ls -d /sys/fs/cgroup/system.slice/y700-*.service 2>/dev/null | sed 's|.*/||' | tr '\n' ' '; echo

S "delta window: ${DELTA} s, the tablet is left alone (only sleep between the two snapshots)"
snap a
sleep "$DELTA" & CHILD=$!; wait "$CHILD"; CHILD=
snap b
A=$TMP-a; B=$TMP-b
echo "t0 $(cat "$A.t")  t1 $(cat "$B.t")"
echo "ddr/llcc at t0: $(cat "$A.ddr")"; echo "ddr/llcc at t1: $(cat "$B.ddr")"

S "CX / DDR voters (map B)"
H "pm_genpd idle_states line 2, t0 / t1 / delta (header: $(sed -n 1p "$D/pm_genpd/power-domain-system/idle_states" 2>/dev/null | tr -s ' '))"
sed 's/^/t0 /' "$A.pd"; sed 's/^/t1 /' "$B.pd"
awk 'NR==FNR {a[$1]=$0; next} ($1 in a) {split(a[$1],x," "); row="d  "$1" "$2; for(i=3;i<=NF;i++) row=row" +"($i-x[i]); print row}' "$A.pd" "$B.pd"
H "qcom_stats apss/cxsd/aosd/ddr, t0 / t1 / delta (Count, Accumulated Duration)"
sed 's/^/t0 /' "$A.qs" | cut -c1-150; sed 's/^/t1 /' "$B.qs" | cut -c1-150
awk 'NR==FNR {c[$1]=$3; d[$1]=$NF; next} {printf "d  %-5s count+%d  accumulated+%d\n", $1, $3-c[$1], $NF-d[$1]}' "$A.qs" "$B.qs"
H "qcom_stats, all files (one line each)"
for f in "$D"/qcom_stats/*; do [ -f "$f" ] && printf '%s: %s\n' "${f##*/}" "$(tr '\n' ' ' 2>/dev/null < "$f" | cut -c1-120)"; done
H "pm_genpd_summary: the plan's domains + every domain not off"
awk 'NR<=2 || /^(cx|mmcx|gcc_pcie_0_gdsc|gcc_ufs_phy_gdsc|gcc_usb3_phy_gdsc|gcc_pcie_0_phy_gdsc|power-domain-cluster|power-domain-cluster1|power-domain-system) / || ($0 !~ /^    / && $2 !~ /^off/)' "$D/pm_genpd/pm_genpd_summary" 2>/dev/null | cut -c1-120 | head -50
H "interconnect_summary: non-zero rows"
awk 'NR<=2 || $(NF-1)>0 || $NF>0' "$D/interconnect/interconnect_summary" 2>/dev/null | cut -c1-120 | head -80
H "devfreq"
for d in /sys/class/devfreq/*; do [ -d "$d" ] && printf '%s gov=%s cur=%s min=%s max=%s polling=%s\n' "${d##*/}" "$(rd "$d/governor")" "$(rd "$d/cur_freq")" "$(rd "$d/min_freq")" "$(rd "$d/max_freq")" "$(rd "$d/polling_interval")"; done
H "qcom_stats ddr_stats"; head -40 "$D/qcom_stats/ddr_stats" 2>/dev/null | cut -c1-120
H "per-CPU IRQ deltas over ${DELTA} s: total rate name cpu0..cpu7 description (arch_timer, IPIs, NVT touch, keys, apss_cpucp_mbox, ipcc)"
awk -v re="$IRQ_RE" -v dt="$DELTA" 'NR==FNR {a[$1]=$0; next}
	FNR>1 && ($1 in a) && $0 ~ re {split(a[$1],x," "); n=0; row=""
		for(i=2;i<=9;i++){d=($i ~ /^[0-9]+$/ && x[i] ~ /^[0-9]+$/) ? $i-x[i] : 0; n+=d; row=row sprintf(" %6d",d)}
		s=$0; sub(/^ *[^ ]+ */,"",s); for(i=1;i<=8;i++) sub(/^[0-9]+ */,"",s); gsub(/ +/," ",s)
		printf "%7d %6.1f/s %-6s%s  %s\n", n, n/dt, $1, row, substr(s,1,60)}' "$A.irq" "$B.irq"
H "all IRQ lines with delta > 10 over ${DELTA} s (top 25)"
awk -v dt="$DELTA" 'NR==FNR {a[$1]=$0; next}
	FNR>1 && ($1 in a) {split(a[$1],x," "); n=0
		for(i=2;i<=9;i++){if($i ~ /^[0-9]+$/ && x[i] ~ /^[0-9]+$/) n+=$i-x[i]}
		if(n>10){s=$0; sub(/^ *[^ ]+ */,"",s); for(i=1;i<=8;i++) sub(/^[0-9]+ */,"",s); gsub(/ +/," ",s)
			printf "%7d %6.1f/s %-6s %s\n", n, n/dt, $1, substr(s,1,80)}}' "$A.irq" "$B.irq" | sort -rn | head -25
H "cpuidle usage / time deltas over ${DELTA} s (time is us in sysfs; % = residency of the window)"
awk -v dt="$DELTA" 'NR==FNR {k=$1" "$2; u[k]=$4; t[k]=$5; next}
	{k=$1" "$2; if(k in u) printf "%-5s %-7s %-12s usage+%-7d time+%9.0f ms (%5.1f %%)\n", $1, $2, $3, $4-u[k], ($5-t[k])/1000, ($5-t[k])/(dt*10000)}' "$A.idle" "$B.idle"
H "per-process utime+stime ticks over ${DELTA} s (top 20; ticks of 1/100 s, so ticks/${DELTA} = % of one core)"
awk 'NR==FNR {a[$1]=$2; nm[$1]=$3; next} ($1 in a) && ($3==nm[$1]) {d=$2-a[$1]; if(d>0){c=$0; sub(/^[^ ]+ [^ ]+ /,"",c); print d, $1, c}}' "$A.proc" "$B.proc" | sort -rn | head -20
if [ -r /proc/self/schedstat ]; then THR_SRC="schedstat ns (column 1 = run time; shown in ms)"; THR_DIV=1000000; else THR_SRC="stat utime+stime ticks of 1/100 s (no schedstat on this kernel; README:1614)"; THR_DIV=1; fi
H "per-thread CPU over ${DELTA} s, top 15 of plasmashell/kwin_wayland/y700-osk*/control-center/tailscaled/pipewire/wireplumber: cpu ctxt pid tid comm (source: $THR_SRC)"
awk -v div="$THR_DIV" 'NR==FNR {k=$1" "$2; rt[k]=$3; cs[k]=$4; next}
	{k=$1" "$2; if(k in rt){d=$3-rt[k]; dc=$4-cs[k]; if(d>0 || dc>0){c=$0; for(i=1;i<=4;i++) sub(/^[^ ]+ /,"",c); printf "%10.1f %7d %6d %6d %s\n", d/div, dc, $1, $2, c}}}' "$A.thr" "$B.thr" | sort -rn | head -15
H "per-process totals of the same set: cpu ctxt pid comm threads"
awk -v div="$THR_DIV" 'NR==FNR {k=$1" "$2; rt[k]=$3; cs[k]=$4; next}
	{k=$1" "$2; if(k in rt){d[$1]+=$3-rt[k]; c[$1]+=$4-cs[k]; n[$1]++}}
	END {for(p in d){nm="?"; cmd="cat /proc/"p"/comm 2>/dev/null"; cmd | getline nm; close(cmd); printf "%10.1f %7d %6d %-16s %d threads\n", d[p]/div, c[p], p, nm, n[p]}}' "$A.thr" "$B.thr" | sort -rn
H "cpufreq"; for p in /sys/devices/system/cpu/cpufreq/policy*; do printf '%s cpus=%s gov=%s min=%s max=%s cur=%s\n' "${p##*/}" "$(rd "$p/affected_cpus")" "$(rd "$p/scaling_governor")" "$(rd "$p/scaling_min_freq")" "$(rd "$p/scaling_max_freq")" "$(rd "$p/scaling_cur_freq")"; done
echo "cpuidle governor: $(rd /sys/devices/system/cpu/cpuidle/current_governor) (available: $(rd /sys/devices/system/cpu/cpuidle/available_governors)); online: $(rd /sys/devices/system/cpu/online); sched_energy_aware=$(rd /proc/sys/kernel/sched_energy_aware)"

S "GPU / shim / floor (map C; dri debugfs replaced by the config + the unit's log)"
H "/etc/default/y700-gpu-dvfs + what y700-gpu-dvfs wrote this boot"; grep -v '^#' /etc/default/y700-gpu-dvfs 2>/dev/null | grep -v '^$'; T journalctl -u y700-gpu-dvfs -b --no-pager -q 2>/dev/null | tail -3 | cut -c1-160
H "/etc/default/y700-gpu-floor + state + log"; grep -v '^#' /etc/default/y700-gpu-floor 2>/dev/null | grep -v '^$'; R /run/y700-gpu-floor.state; T journalctl -u y700-gpu-floor -b --no-pager -q 2>/dev/null | tail -3 | cut -c1-160
H "GPU devfreq (sysfs)"; g=/sys/class/devfreq/3d00000.gpu; echo "gov=$(rd $g/governor) cur=$(rd $g/cur_freq) min=$(rd $g/min_freq) max=$(rd $g/max_freq) polling=$(rd $g/polling_interval)"
H "tb323fu-ctl gpu (bare form = show(), helper tb323fu-ctl/src/main.rs:907: the Profile / Floors lines gpu-floor parses, gpu-floor/src/main.rs:273)"; ctl gpu | head -14 | cut -c1-120
H "waitboost shim (0.4 item 1)"; R /etc/ld.so.preload; ls -l /usr/local/lib/y700-no-waitboost.so 2>&1 | cut -c1-120
echo "sha256 (first 16): $(sha256sum /usr/local/lib/y700-no-waitboost.so 2>/dev/null | cut -c1-16)"
printf 'ctl file first 2 bytes: %s  ' "$(head -c2 /run/user/1000/y700-no-waitboost.ctl 2>/dev/null)"; ls -l /run/user/1000/y700-no-waitboost.ctl 2>&1 | cut -c1-100
echo "chrome processes: $(pgrep -c -x chrome 2>/dev/null); gpu-process mappings of the shim (needs Chrome / Claude desktop running):"
gp=$(pgrep -f -- '--type=gpu-process' 2>/dev/null)
if [ -n "$gp" ]; then for p in $gp; do printf '  pid %s comm=%s maps=%s\n' "$p" "$(rd /proc/$p/comm)" "$(grep -c y700-no-waitboost /proc/$p/maps 2>/dev/null)"; done
else	# Chrome rewrites its own cmdline, so --type=gpu-process may be invisible (README:1614): every chrome pid that maps the shim instead
	for p in $(pgrep -x chrome 2>/dev/null); do m=$(grep -c y700-no-waitboost /proc/$p/maps 2>/dev/null); [ "${m:-0}" -gt 0 ] && printf '  pid %s (cmdline type unknown) maps=%s\n' "$p" "$m"; done
	echo "  (no --type=gpu-process cmdline found; the lines above, if any, are chrome pids with a shim mapping)"
fi
H "WaylandExternalBeginFrameSource in the launchers (count per file)"
grep -c WaylandExternalBeginFrameSource /usr/local/bin/claude-desktop /home/user/.local/share/applications/google-chrome.desktop /home/user/.local/share/applications/com.google.Chrome.desktop /home/user/Desktop/google-chrome.desktop 2>&1 | cut -c1-120
H "helper config (/etc/tb323fu/helper.toml, README:226; non-comment lines)"; grep -vE '^[[:space:]]*(#|$)' /etc/tb323fu/helper.toml 2>/dev/null | cut -c1-120 | head -40

S "display (map D)"
for c in /sys/class/drm/card*-*; do [ -f "$c/status" ] && printf '%s status=%s dpms=%s enabled=%s\n' "${c##*/}" "$(rd "$c/status")" "$(rd "$c/dpms")" "$(rd "$c/enabled")"; done
for b in /sys/class/backlight/*; do [ -d "$b" ] && printf '%s brightness=%s max=%s bl_power=%s\n' "${b##*/}" "$(rd "$b/brightness")" "$(rd "$b/max_brightness")" "$(rd "$b/bl_power")"; done
H "refresh-auto status (D-Bus) + config"; user gdbus call --session -d fyi.y700.RefreshAuto -o /RefreshAuto -m fyi.y700.RefreshAuto.status | cut -c1-300
head -c 1200 /home/user/.config/y700-refresh-auto.json 2>/dev/null; echo
H "kscreen-doctor -o (modes / vrr)"; if [ $NOUSER = 1 ]; then echo "(skipped: --no-user)"; else user kscreen-doctor -o | grep -E 'Output|enabled|Modes|Vrr|@' | head -12 | cut -c1-200; fi
H "panel idle refresh (msm module parameters)"; R /sys/module/msm/parameters/idle_refresh_state /sys/module/msm/parameters/idle_refresh_ms60 /sys/module/msm/parameters/idle_refresh_ms30 /sys/module/msm/parameters/idle_refresh_policy
H "tb323fu-ctl refresh (bare form = show(), helper tb323fu-ctl/src/main.rs:885; README:403 reads Policy: from it)"; ctl refresh | head -12 | cut -c1-120
H "powerdevilrc / audio feedback"; grep -E 'DimDisplayWhenIdle|PowerButtonAction|AutoSuspendAction|TurnOffDisplayIdleTimeoutSec' /home/user/.config/powerdevilrc 2>/dev/null | head -8
printf 'plasmaparc AudioFeedback: '; user kreadconfig6 --file plasmaparc --group General --key AudioFeedback; echo

S "Wi-Fi / Tailscale / PCIe (map E; no lspci)"
T iw dev 2>/dev/null | grep -E 'Interface|type|channel|txpower|ssid'
for i in $(T iw dev 2>/dev/null | awk '/Interface/{print $2}'); do printf '%s power_save: ' "$i"; T iw dev "$i" get power_save 2>/dev/null; T iw dev "$i" link 2>/dev/null | grep -E 'SSID|freq|signal|bitrate'; done
echo "ath12k module: version=$(rd /sys/module/ath12k/version) params: $(for f in /sys/module/ath12k/parameters/*; do [ -f "$f" ] && printf '%s=%s ' "${f##*/}" "$(rd "$f")"; done)"
ko=/usr/local/lib/modules/y700/$(uname -r)/ath12k.ko; [ -f "$ko" ] && echo "ath12k.ko ($ko) version: $(T modinfo -F version "$ko" 2>/dev/null)"
cat /etc/modprobe.d/y700-ath12k.conf 2>/dev/null; cat /etc/NetworkManager/conf.d/*.conf 2>/dev/null | grep -vE '^(#|$)' | head -12
n=$(T nmcli -t -f NAME connection show --active 2>/dev/null | head -1); [ -n "$n" ] && { printf 'nmcli powersave of "%s": ' "$n"; T nmcli -f 802-11-wireless.powersave connection show "$n" 2>/dev/null | tr -s ' '; }
T rfkill list 2>/dev/null | tr '\n' ' '; echo
H "tailscale"; T tailscale status --peers=false 2>/dev/null | head -3; T tailscale status --json 2>/dev/null | grep -m1 '"BackendState"' | tr -d ' ,'
T systemctl show tailscaled -p Environment 2>/dev/null | cut -c1-200
p=$(pgrep -x tailscaled 2>/dev/null | head -1); [ -n "$p" ] && { printf 'tailscaled environ: '; tr '\0' '\n' 2>/dev/null < /proc/$p/environ | grep -E 'TS_PORTLIST|TS_DEBUG' | tr '\n' ' '; echo; }
p=$(pgrep -x org_kde_powerdevil 2>/dev/null | head -1); [ -n "$p" ] && { printf 'powerdevil environ: '; tr '\0' '\n' 2>/dev/null < /proc/$p/environ | grep -E 'NO_DDCUTIL|DDCUTIL' | tr '\n' ' '; echo; }
H "PCIe (sysfs only)"; echo "1c00000.pcie rt=$(rd $P/1c00000.pcie/power/runtime_status) ctl=$(rd $P/1c00000.pcie/power/control); aspm policy: $(rd /sys/module/pcie_aspm/parameters/policy)"
for d in 0000:00:00.0 0000:01:00.0; do s=/sys/bus/pci/devices/$d; [ -d "$s" ] || continue
	printf '%s rt=%s ctl=%s power_state=%s d3cold_allowed=%s active=%sms suspended=%sms' "$d" "$(rd $s/power/runtime_status)" "$(rd $s/power/control)" "$(rd $s/power_state)" "$(rd $s/d3cold_allowed)" "$(rd $s/power/runtime_active_time)" "$(rd $s/power/runtime_suspended_time)"
	for l in "$s"/link/*; do [ -f "$l" ] && printf ' %s=%s' "${l##*/}" "$(rd "$l")"; done; echo; done

S "wakeups / always-on / modem / BT / UFS (map F)"
T sysctl kernel.sched_util_clamp_min_rt_default kernel.watchdog_thresh 2>/dev/null
echo "devfreq polling_interval: ddr=$(rd /sys/class/devfreq/ddr/polling_interval) llcc=$(rd /sys/class/devfreq/llcc/polling_interval) ddr-qos=$(rd /sys/class/devfreq/ddr-qos/polling_interval) ufs=$(rd /sys/class/devfreq/1d84000.ufs/polling_interval) gpu=$(rd /sys/class/devfreq/3d00000.gpu/polling_interval)"
echo "a600000.usb ctl=$(rd $P/a600000.usb/power/control) rt=$(rd $P/a600000.usb/power/runtime_status); typec power_role=$(rd /sys/class/typec/port0/power_role) data_role=$(rd /sys/class/typec/port0/data_role)"
echo "download_mode=$(rd /sys/module/qcom_scm/parameters/download_mode); sleep.target=$(T systemctl is-enabled sleep.target 2>&1 | head -1) suspend.target=$(T systemctl is-enabled suspend.target 2>&1 | head -1)"
H "kernel config"; zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_(RTC_SYSTOHC|PSI|RCU_LAZY|CPU_IDLE_GOV_TEO|UCLAMP_TASK|PCIEASPM|PM_DEBUG|SCHEDSTATS|SCHED_INFO)=' | tr '\n' ' '; echo
H "remoteproc"; for r in /sys/class/remoteproc/remoteproc*; do [ -d "$r" ] && printf '%s %s %s\n' "${r##*/}" "$(rd "$r/name")" "$(rd "$r/state")"; done
echo "rmtfs=$(T systemctl is-enabled rmtfs 2>&1 | head -1) tqftpserv=$(T systemctl is-enabled tqftpserv 2>&1 | head -1)"
H "RTC (WK-4 / ALWAYS-ON.md 5b)"; grep -n rtcsync /etc/chrony/chrony.conf /etc/chrony/conf.d/* 2>/dev/null | cut -c1-120
echo "rtc0: $(rd /sys/class/rtc/rtc0/name); wakealarm='$(rd /sys/class/rtc/rtc0/wakealarm)'"; grep -E 'alrm_time|alrm_date|alarm_IRQ|alrm_pending' /proc/driver/rtc 2>/dev/null | tr '\n' ' '; echo
printf 'rtc_set_time lines in this boot kernel log: '; T journalctl -k -b -q -o cat 2>/dev/null | grep -c rtc_set_time
printf 'chronyc: '; T chronyc -n tracking 2>/dev/null | grep -E 'Leap status|Stratum' | tr '\n' ' '; echo
H "wakeup_sources: rtc / battmgr / keys / touch / pcie / wlan / hci rows + top 10 by event_count"
awk 'NR==1 || /rtc|battmgr|pwrkey|NVT|pcie|wlan|hci|resin|gpio-keys/' "$D/wakeup_sources" 2>/dev/null | cut -c1-140
tail -n +2 "$D/wakeup_sources" 2>/dev/null | sort -k3 -rn | head -10 | cut -c1-140
H "Bluetooth"; printf 'bluetoothctl: '
# bluetoothctl would D-Bus-activate bluetooth.service (org.bluez) when it is stopped but not masked (a bench's BT-off state)
if T systemctl is-active --quiet bluetooth 2>/dev/null; then T bluetoothctl show 2>/dev/null | grep -E 'Powered|Discoverable:' | tr -d '\t' | tr '\n' ' '; echo; T bluetoothctl devices Connected 2>/dev/null | head -5
else echo "not run (bluetooth.service inactive; bluetoothctl would D-Bus-activate it)"; fi
echo "1994000.serial rt=$(rd $P/1994000.serial/power/runtime_status) ctl=$(rd $P/1994000.serial/power/control); hci0 device rt=$(rd /sys/class/bluetooth/hci0/device/power/runtime_status)"
H "modem / MHI (sysfs only; mhi debugfs never)"; echo "mhi devices: $(ls /sys/bus/mhi/devices/ 2>/dev/null | tr '\n' ' '); wwan: $(ls /sys/class/wwan/ 2>/dev/null | tr '\n' ' '); ModemManager=$(T systemctl is-active ModemManager 2>/dev/null)"
# mmcli only while ModemManager already runs: on a stopped-but-not-masked unit it would D-Bus-activate ModemManager.service and leave it running
if T systemctl is-active --quiet ModemManager 2>/dev/null; then T mmcli -L 2>/dev/null | head -3; else echo "mmcli -L: not run (ModemManager inactive; running it would D-Bus-activate the daemon)"; fi
for d in /sys/bus/mhi/devices/*; do [ -f "$d/power/runtime_status" ] && printf '%s rt=%s\n' "${d##*/}" "$(rd "$d/power/runtime_status")"; done
H "UFS"; UF=$P/1d84000.ufs
echo "rt=$(rd $UF/power/runtime_status) ctl=$(rd $UF/power/control) autosuspend_delay_ms=$(rd $UF/power/autosuspend_delay_ms) rpm_lvl=$(rd $UF/rpm_lvl) spm_lvl=$(rd $UF/spm_lvl) clkgate_enable=$(rd $UF/clkgate_enable) clkgate_delay_ms=$(rd $UF/clkgate_delay_ms) auto_hibern8=$(rd $UF/auto_hibern8) clkscale_enable=$(rd $UF/clkscale_enable) devfreq cur=$(rd /sys/class/devfreq/1d84000.ufs/cur_freq)"
for s in /sys/bus/scsi/devices/*/power/runtime_status; do [ -e "$s" ] && printf '  %s %s\n' "$(echo "$s" | cut -d/ -f6)" "$(cat "$s")"; done | head -6
H "iio sensors (SEN-1)"; echo "iio-sensor-proxy=$(T systemctl is-active iio-sensor-proxy 2>/dev/null); triggers: $(ls -d /sys/bus/iio/devices/trigger* 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"
for d in /sys/bus/iio/devices/iio:device*; do [ -d "$d" ] || continue
	printf '%s name=%s rt=%s' "${d##*/}" "$(rd "$d/name")" "$(rd "$d/power/runtime_status")"
	[ -f "$d/buffer/enable" ] && printf ' buffer/enable=%s' "$(rd "$d/buffer/enable")"
	for f in "$d"/sampling_frequency "$d"/in_*sampling_frequency; do [ -f "$f" ] && printf ' %s=%s' "${f##*/}" "$(rd "$f")"; done; echo; done
H "keyhold (WK-6)"; pgrep -a keyhold 2>/dev/null | cut -c1-120; p=$(pgrep -x keyhold 2>/dev/null | head -1); [ -n "$p" ] && echo "exe: $(readlink /proc/$p/exe 2>/dev/null)"
H "system-sleep hooks (SEN-2)"; ls /etc/systemd/system/system-sleep/ /usr/lib/systemd/system-sleep/ 2>&1 | cut -c1-120
H "platform devices runtime status: counts + the active ones"
for d in "$P"/*; do [ -f "$d/power/runtime_status" ] && printf '%s %s\n' "$(cat "$d/power/runtime_status")" "${d##*/}"; done | sort | awk '{c[$1]++; if($1=="active") a=a" "$2} END{for(k in c) printf "%s=%d ", k, c[k]; print ""; print "active:" a}' | cut -c1-1500
H "usb runtime pm"; for d in /sys/bus/usb/devices/*; do [ -f "$d/power/runtime_status" ] && printf '%s %s rt=%s ctl=%s delay=%s\n' "${d##*/}" "$(rd "$d/product")" "$(rd "$d/power/runtime_status")" "$(rd "$d/power/control")" "$(rd "$d/power/autosuspend_delay_ms")"; done | head -12
H "thermal"; for t in /sys/class/thermal/thermal_zone*; do [ -d "$t" ] && printf '%s=%s ' "$(rd "$t/type")" "$(rd "$t/temp")"; done; echo

S "audio (map G)"
H "pactl sinks (user)"; user pactl list short sinks | head -10 | cut -c1-140
H "open PCMs"; for c in /proc/asound/card*/pcm*/sub0/status; do [ -f "$c" ] && printf '%s: %s\n' "$c" "$(head -1 "$c" 2>/dev/null)"; done | head -12
H "wireplumber conf.d (X47: 61-y700-speaker-raw-virtual.conf)"; ls /etc/wireplumber/wireplumber.conf.d/ /home/user/.config/wireplumber/wireplumber.conf.d/ 2>&1 | cut -c1-120
H "codec / soundwire runtime status"; for d in "$P"/*.codec "$P"/*soundwire* /sys/bus/soundwire/devices/*; do [ -f "$d/power/runtime_status" ] && printf '%s rt=%s\n' "${d##*/}" "$(rd "$d/power/runtime_status")"; done

S "plasma-nm locate (CPU-6: read-only, where the BusyIndicator lives; README:1581)"
T dpkg -s plasma-nm 2>/dev/null | grep -E '^(Version|Status):'; T dpkg -s kwin-wayland 2>/dev/null | grep -E '^Version:' | sed 's/^/kwin-wayland /'
T dpkg -L plasma-nm 2>/dev/null | grep -E 'Toolbar\.qml|contents/ui/main\.qml|\.so$' | head -8
for q in $(T dpkg -L plasma-nm 2>/dev/null | grep -E 'Toolbar\.qml$'); do echo "$q:"; grep -nE 'BusyIndicator|running:|scanning' "$q" 2>/dev/null | head -6 | cut -c1-140; done

S "recorder / checklist / leftovers (map H)"
H "flight recorder"; echo "unit: $(T systemctl is-active y700-flightrec 2>/dev/null); process: $(pgrep -af y700-flightrec 2>/dev/null | head -1 | cut -c1-120)"
ls -la /run/y700-flightrec/ 2>/dev/null | tail -n +2 | cut -c1-120
tail -n 3 /run/y700-flightrec/live.log 2>/dev/null | cut -c1-220
grep -E '^(MODE|MARK|HEADER|STOP)' /run/y700-flightrec/live.log 2>/dev/null | tail -5 | cut -c1-160
ls -l /var/log/y700-flightrec/ 2>/dev/null | tail -6 | cut -c1-120
H "timers (y700 / fake-hwclock) + watchdog drop-ins"; T systemctl list-timers --all --no-pager --no-legend 2>/dev/null | grep -E 'y700|fake-hwclock' | cut -c1-160
ls /etc/systemd/system/y700-*watchdog.timer.d/ 2>&1 | cut -c1-120; user systemctl --user list-timers --all --no-pager --no-legend | cut -c1-160 | head -10
H "tracing leftovers"; echo "tracing_on=$(rd $TRACE/tracing_on) instances: $(ls $TRACE/instances/ 2>/dev/null | tr '\n' ' ') kprobe_events: $(wc -l 2>/dev/null < $TRACE/kprobe_events) lines; sched_process_fork enable=$(rd $TRACE/events/sched/sched_process_fork/enable)"
head -5 $TRACE/kprobe_events 2>/dev/null | cut -c1-120
H "leftover files"; ls -d /run/y700-powerbench.* /tmp/.cxa1 /tmp/.cxa2 /root/wk-*.txt /root/chrome-video-power-ab-runs /root/video-gpu-tune2-* /root/y700-cvp /var/log/y700-diag 2>/dev/null
H "kernel trouble lines this boot"; printf 'vblank timeout|fenced register|hangcheck recover: '; T journalctl -k -b -q -o cat 2>/dev/null | grep -cE 'vblank timeout|fenced register|hangcheck recover'
printf 'cx-exp watchdog regex (cx-exp.sh:114): '; T journalctl -k -b -q -o cat 2>/dev/null | grep -cE 'vblank timeout|failed to flush transmit queue|timed out in resp|TCS Busy|rpmh.*(timeout|fail)|Unhandled fault|SError|NoC|BUG:|WARNING:'
H "battery"; for f in status capacity charge_full charge_full_design cycle_count power_now current_now voltage_now temp; do printf '%s=%s ' "$f" "$(rd $BAT/$f)"; done; echo
H "top (one batch sample)"; T top -b -n 1 -w 200 2>/dev/null | sed -n '1,18p' | cut -c1-150
H "processes by CPU time: root / user"; T ps -u root -o pid,etimes,time,pcpu,comm --sort=-time 2>/dev/null | head -8; T ps -u user -o pid,etimes,time,pcpu,comm --sort=-time 2>/dev/null | head -12
H "memory"; free -m 2>/dev/null | head -2
if [ $CHECKLIST = 1 ]; then
	H "y700-checklist (--checklist: NOT read-only, runs y700-kmsg-watch --selftest; timeout 150 s)"
	if command -v y700-checklist >/dev/null 2>&1; then timeout 150 y700-checklist 2>&1 | tail -45 | cut -c1-170; echo "checklist rc=${PIPESTATUS[0]}"; else echo "(y700-checklist not installed)"; fi
fi

S end
date '+%F %T'
