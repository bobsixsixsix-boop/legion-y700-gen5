#!/bin/bash
# y700-hud-cost.sh [WINDOW_S] [game]: what the game overlay (y700-hud-overlay and its sampler) costs on an idle
# desktop (VISIBLE: lights the screen, shows the overlay). ROOT, run with systemd-run. 2026-10-16.
# Windows: off, full, mini, off, full, mini (WINDOW_S each, default 90). Auto-brightness paused, backlight fixed.
# "game": a game instead of the still picture - vkcube under MangoHud (it logs fps to ~/.cache/y700-hud like the
# Steam games do), so the overlay samples every second; windows off, full, off, full, and the overlay's own
# fps/gpu readings are logged per second (it must find vkcube's log). vkcube keeps the panel at 120 Hz.
# Per second: battery power, the panel's live refresh (idle_refresh_state "hz N"). Per window: CPU of the overlay's
# cgroup (the sampler and every process it spawns run in it), processes forked in it per minute (cgroup pids.events
# is not a counter, so: ftrace sched_process_fork filtered on the cgroup's pids at the end of each second - children
# that live < 1 s are caught through their parent), KWin composites/s (kprobe msm_fence_set_deadline hits).
# Aborts on owner touch (>= 3 touch IRQs in a window after the wake baseline). Restores HUD mode, brightness,
# auto-brightness, DPMS.
set -u
WIN=${1:-90}; PROF=${2:-idle}
O=/root/y700-hud-cost; mkdir -p $O; rm -f $O/*
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0)
CG=/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/y700-hud-overlay.service
T=/sys/kernel/tracing
BAT=/sys/class/power_supply/qcom-battmgr-bat
BL=$(ls -d /sys/class/backlight/*/ | head -1)
DPMS=$(ls /sys/class/drm/card*-DSI-1/dpms | head -1)
log() { echo "$(date +%T) $*" >> $O/windows.txt; }
sb() { "${U[@]}" qdbus6 org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0 org.kde.ScreenBrightness.Display.SetBrightness "$1" 1 >/dev/null 2>&1; }
gb() { "${U[@]}" qdbus6 org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0 org.freedesktop.DBus.Properties.Get org.kde.ScreenBrightness.Display Brightness 2>/dev/null; }
touches() { awk '/NVT-ts/ {s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break; print s; exit}' /proc/interrupts; }
hits() { awk '$1 == "msmdl" {print $2; f = 1} END {if (!f) print 0}' $T/kprobe_profile; }
usage() { awk '/^usage_usec/ {print $2}' $CG/cpu.stat 2>/dev/null || echo 0; }
# per thread of the overlay's cgroup: "tid comm ns_on_cpu context_switches" (/proc/.../sched: this kernel has no
# CONFIG_SCHEDSTATS, so no schedstat file; the shell sampler's children come and go, so only threads alive at
# both ends of a window show up - the cgroup total above is the real total)
threads() { local p t; for p in $(cat $CG/cgroup.procs 2>/dev/null); do for t in /proc/$p/task/*; do
	echo "${t##*/} $(tr -c 'A-Za-z0-9_.\n-' _ < $t/comm 2>/dev/null) $(awk '/^se.sum_exec_runtime/ {r = $3}
		/^nr_switches/ {n = $3} END {printf "%.0f %d", r * 1e6, n}' $t/sched 2>/dev/null)"; done; done; }
hud() { "${U[@]}" ~user/.local/bin/y700-hud-toggle "$1" >/dev/null 2>&1; }
mode0=$("${U[@]}" ~user/.local/bin/y700-hud-toggle status 2>/dev/null | head -1)
bl0=$(gb); dpms0=$(cat $DPMS); ab0=$("${U[@]}" systemctl --user is-active y700-autobright.service); owner=0
BG=
restore() {
	trap - EXIT
	[ -n "$BG" ] && kill $BG 2>/dev/null
	echo 0 > $T/events/sched/sched_process_fork/enable 2>/dev/null
	[ -e $T/events/kprobes/msmdl/enable ] && echo 0 > $T/events/kprobes/msmdl/enable
	grep -q ":kprobes/msmdl " $T/kprobe_events && echo "-:msmdl" >> $T/kprobe_events
	case "$mode0" in full|mini) hud "$mode0" ;; *) hud off ;; esac
	[ -n "$bl0" ] && sb "$bl0"
	[ "$ab0" = active ] && "${U[@]}" systemctl --user start y700-autobright.service
	if [ $owner = 0 ] && [ "$dpms0" = Off ]; then "${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1; sleep 3; fi
	log "restored: hud $("${U[@]}" ~user/.local/bin/y700-hud-toggle status 2>/dev/null | head -1) (was $mode0), brightness $(gb) (was $bl0), autobright $ab0, dpms $(cat $DPMS) (was $dpms0)"
}
trap restore EXIT; trap 'exit 1' INT TERM
log "start: kernel $(uname -r), profile $PROF, hud $mode0, brightness $bl0, battery $(cat $BAT/status) $(cat $BAT/capacity)%"
[ "$ab0" = active ] && "${U[@]}" systemctl --user stop y700-autobright.service
"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 4
# a static, fullscreen black picture under the overlay: nothing else on screen animates (the first run had another
# app redrawing at ~117 composites/s with the HUD off), and mpv keeps the screen from idling off (it did, at 5 min)
if [ "$PROF" = game ]; then
	# kde-inhibit: vkcube does not inhibit idle (mpv does), and the screen went off 5 min into the first run
	"${U[@]}" MANGOHUD=1 kde-inhibit --power --screenSaver vkcube --wsi wayland >/dev/null 2>&1 &
	sleep 4; BG=$(pgrep -u user -x vkcube | head -1); MODES="off full off full"
else
	[ -s /tmp/y700-black.png ] || ffmpeg -loglevel error -f lavfi -i color=black:s=1904x3040 -frames:v 1 /tmp/y700-black.png
	chmod 644 /tmp/y700-black.png
	"${U[@]}" mpv --fs --image-display-duration=inf --no-osc --osd-level=0 --input-ipc-server=/tmp/y700-hudcost.sock /tmp/y700-black.png >/dev/null 2>&1 &
	sleep 4; BG=$(pgrep -u user -f y700-hudcost.sock | head -1); MODES="off full mini off full mini"
fi
[ -n "$BG" ] || { log "the background program did not start"; exit 3; }
KVF=/run/user/1000/y700-hud.txt.kv
sb 800; sleep 1; BLS=$(cat $BL/brightness)
echo 'p:msmdl msm_fence_set_deadline' >> $T/kprobe_events; echo 1 > $T/events/kprobes/msmdl/enable
echo -e "time\twindow\tprofile\tW\tbacklight\thz\tstatus\thud_fps\thud_gpu" > $O/samples.tsv
t0=$(touches); i=0
for m in $MODES; do
	i=$((i + 1)); hud $m; sleep 8                     # let the overlay map and its sampler settle
	[ "$(cat $BL/brightness)" != "$BLS" ] && sb 800
	u0=$(usage); h0=$(hits); s0=$(date +%s.%N); threads > $O/thr0
	echo 0 > $T/tracing_on; echo > $T/trace; echo 1 > $T/events/sched/sched_process_fork/enable; echo 1 > $T/tracing_on
	declare -A seen=(); forks=0
	for s in $(seq $WIN); do
		hz=$(grep -oE 'hz [0-9]+' /sys/module/msm/parameters/idle_refresh_state | cut -d' ' -f2)
		echo -e "$(date +%T)\t$i\t$m\t$(awk '{printf "%.3f", ($1 < 0 ? -$1 : $1) / 1e6}' $BAT/power_now)\t$(cat $BL/brightness)\t$hz\t$(cat $BAT/status)\t$(sed -n 's/^fps=//p' $KVF 2>/dev/null)\t$(sed -n 's/^gpu=//p' $KVF 2>/dev/null)" >> $O/samples.tsv
		for p in $(cat $CG/cgroup.procs 2>/dev/null); do seen[$p]=1; done
		sleep 1
	done
	echo 0 > $T/tracing_on; echo 0 > $T/events/sched/sched_process_fork/enable
	for p in "${!seen[@]}"; do forks=$((forks + $(grep -c "sched_process_fork: comm=.* pid=$p child_comm" $T/trace))); done
	u1=$(usage); h1=$(hits); s1=$(date +%s.%N); threads > $O/thr1
	[ $(( $(touches) - t0 )) -ge 3 ] && { owner=1; log "owner touched the screen - stopping"; exit 4; }
	t0=$(touches)
	stats=$(awk -F'\t' -v w=$i 'NR>1 && $2==w {n++; s+=$4; h[$6]++} END{printf "%.2f W mean, panel", s/n; for (k in h) printf " %s Hz %d%%", k, h[k]*100/n}' $O/samples.tsv)
	log "window $i hud $m: $stats; overlay CPU $(awk -v a=$u0 -v b=$u1 -v t0=$s0 -v t1=$s1 'BEGIN{printf "%.2f", (b-a)/(t1-t0)/1e4}') % of a core, forks $(awk -v f=$forks -v t0=$s0 -v t1=$s1 'BEGIN{printf "%.1f", f*60/(t1-t0)}')/min, composites $(awk -v a=$h0 -v b=$h1 -v t0=$s0 -v t1=$s1 'BEGIN{printf "%.1f", (b-a)/(t1-t0)}')/s"
	thr=$(awk 'NR == FNR {a[$1] = $3; r[$1] = $4; next} ($1 in a) {ms[$2] += ($3 - a[$1]) / 1e6; n[$2] += $4 - r[$1]}
		END {for (k in ms) if (ms[k] >= 1) printf " %s %.0fms/%d", k, ms[k], n[k]}' $O/thr0 $O/thr1)
	[ -n "$thr" ] && log "  threads alive the whole window (ms on CPU / context switches):$thr"
	[ $m != off ] && log "  memory: $(for p in $(cat $CG/cgroup.procs 2>/dev/null); do awk -v c="$(cat /proc/$p/comm)" '/^VmRSS/ {printf "%s rss %.1f MB; ", c, $2 / 1024}' /proc/$p/status; done)cgroup $(awk '{printf "%.1f", $1 / 1048576}' $CG/memory.current 2>/dev/null) MB"
	[ "$PROF" = game ] && [ $m != off ] && log "  the overlay's FPS: $(awk -F'\t' -v w=$i 'NR > 1 && $2 == w {n++; if ($8 != "") {k++; s += $8}}
		END {printf "%d of %d s had one, mean %.0f", k, n, k ? s / k : 0}' $O/samples.tsv)"
	echo > $T/trace
done
echo 1 > $T/tracing_on
