#!/bin/bash
# video-gpu-tune.sh [WINDOW_S] [UP_TEST]: GPU DVFS during fullscreen video (VISIBLE: lights the screen, muted
# test clip). ROOT, run with systemd-run. 2026-10-16, after the research memo (README "视频播放功耗").
#  1. attribution trace (20 s, balanced, upthreshold 50): who sends the GPU to 1200 MHz?
#     kprobes on msm_fence_set_deadline (KWin's per-frame SYNC_IOC_SET_DEADLINE), deadline_work (msm's timer
#     3 ms before the deadline), msm_devfreq_boost (+ caller stack); tracepoints devfreq_frequency /
#     devfreq_monitor (governor tick, with load). A frequency change right after msmboost = boost,
#     right before a devfreq_monitor line = governor (the monitor event is emitted after update_devfreq).
#  2. upthreshold A/B on balanced: 50 (msm default, any 50 ms window over 50 % busy jumps to max) vs UP_TEST
#     (default 80), ABBAAB, WINDOW_S each (default 90), via debugfs dri/1/devfreq/upthreshold (read live by
#     simple_ondemand). Per second: battery power, backlight, GPU cur_freq; per window mpv frame counters.
# Same clip/settings as video-mpv-ab.sh; aborts (exit 4, screen left on) on owner touch. Restores the
# threshold, GPU profile, tracing state, brightness, auto-brightness and DPMS on any exit.
# Results: /root/video-gpu-tune/{trace.txt,attribution.txt,samples.tsv,windows.txt}.
set -u
WIN=${1:-90}; UPT=${2:-80}
BL_TEST=${BL_TEST:-800}
O=/root/video-gpu-tune; mkdir -p $O; rm -f $O/*
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0)
GPU=/sys/class/devfreq/3d00000.gpu
DF=/sys/kernel/debug/dri/1/devfreq
T=/sys/kernel/tracing
BAT=/sys/class/power_supply/qcom-battmgr-bat
BL=$(ls -d /sys/class/backlight/*/ | head -1)
DPMS=$(ls /sys/class/drm/card*-DSI-1/dpms 2>/dev/null | head -1)
SOCK=/tmp/y700-ab-mpv.sock
CLIP=/tmp/y700-ab-hevc.mp4
log() { echo "$(date +%T) $*" >> $O/windows.txt; }
sb() { "${U[@]}" qdbus6 org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0 org.kde.ScreenBrightness.Display.SetBrightness "$1" 1 >/dev/null 2>&1; }
gb() { "${U[@]}" qdbus6 org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0 org.freedesktop.DBus.Properties.Get org.kde.ScreenBrightness.Display Brightness 2>/dev/null; }
ipc() { python3 - "$SOCK" "$@" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect(sys.argv[1])
s.send((json.dumps({"command": sys.argv[2:]}) + "\n").encode())
buf = b""
while b"\n" not in buf:
    buf += s.recv(4096)
for line in buf.decode().splitlines():
    d = json.loads(line)
    if "error" in d:
        v = d.get("data"); print(("yes" if v else "no") if isinstance(v, bool) else v) if d["error"] == "success" else print("ERR:" + d["error"]); break   # bools as yes/no: mpv rejects "True" on set_property (10-16 bug)
PY
}
touches() { awk '/NVT-ts/ {s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break; print s; exit}' /proc/interrupts; }

prof0=$(tb323fu-ctl gpu 2>/dev/null | awk '/^  Profile:/ {print $2}'); [ -z "$prof0" ] && prof0=balanced
up0=$(cat $DF/upthreshold); ton0=$(cat $T/tracing_on); buf0=$(cat $T/buffer_size_kb)
bl0=$(gb); dpms0=$(cat $DPMS 2>/dev/null); ab0=$("${U[@]}" systemctl --user is-active y700-autobright.service)
owner=0; MPV=
untrace() {
	echo 0 > $T/tracing_on
	for e in kprobes/msmdl kprobes/msmdlwork kprobes/msmboost devfreq/devfreq_frequency devfreq/devfreq_monitor; do
		[ -e $T/events/$e/enable ] && echo 0 > $T/events/$e/enable; done
	[ -e $T/events/kprobes/msmboost/trigger ] && echo '!stacktrace' > $T/events/kprobes/msmboost/trigger 2>/dev/null
	for k in msmdl msmdlwork msmboost; do grep -q ":kprobes/$k " $T/kprobe_events && echo "-:$k" >> $T/kprobe_events; done
	echo "$ton0" > $T/tracing_on; echo "$buf0" > $T/buffer_size_kb
}
restore() {
	trap - EXIT
	[ -n "$MPV" ] && kill $MPV 2>/dev/null; pkill -u user -f "input-ipc-server=$SOCK" 2>/dev/null
	echo "$up0" > $DF/upthreshold
	untrace
	tb323fu-ctl gpu profile "$prof0" >/dev/null 2>&1
	[ -n "$bl0" ] && sb "$bl0"
	[ "$ab0" = active ] && "${U[@]}" systemctl --user start y700-autobright.service
	if [ "$owner" -eq 0 ] && [ "$dpms0" = Off ]; then sleep 1; "${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1; sleep 3; fi
	log "restored: upthreshold $(cat $DF/upthreshold) (was $up0), kprobes left: $(grep -c msm $T/kprobe_events), GPU profile $prof0 ($(cat $GPU/min_freq)-$(cat $GPU/max_freq)), brightness $(gb) (was $bl0), autobright $("${U[@]}" systemctl --user is-active y700-autobright.service) (was $ab0), dpms $(cat $DPMS) (was $dpms0), owner input $owner"
}
trap restore EXIT; trap 'exit 1' INT TERM
log "start: profile $prof0, upthreshold $up0, brightness $bl0, dpms $dpms0, autobright $ab0, battery $(cat $BAT/status) $(cat $BAT/capacity)%"
grep -q Discharging $BAT/status || log "WARNING: not on battery - W figures are not the consumption"

cp /root/vt/hevc.mp4 $CLIP; chmod 644 $CLIP
[ "$ab0" = active ] && "${U[@]}" systemctl --user stop y700-autobright.service
tb323fu-ctl gpu profile balanced >/dev/null 2>&1
"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 4   # 4 s, not 1: waking the screen, PowerDevil restores its own brightness and overwrote ours (10-16 18:56 run: sysfs 329 instead of 99)
sb "$BL_TEST"
rm -f $SOCK
"${U[@]}" mpv --fs --ao=null --hwdec=vaapi --vo=gpu --gpu-api=opengl --loop-file=inf --no-osc --osd-level=0 \
	--input-ipc-server=$SOCK $CLIP >/dev/null 2>&1 &
sleep 8
MPV=$(pgrep -u user -f "input-ipc-server=$SOCK" | head -1)
[ -z "$MPV" ] && { log "mpv did not start"; exit 2; }
log "mpv $MPV: hwdec $(ipc get_property hwdec-current), display-fps $(ipc get_property display-fps), container-fps $(ipc get_property container-fps)"

# --- 1. attribution trace
echo 0 > $T/tracing_on; echo > $T/trace; echo 4096 > $T/buffer_size_kb
echo 'p:msmdl msm_fence_set_deadline' >> $T/kprobe_events
echo 'p:msmdlwork deadline_work' >> $T/kprobe_events
echo 'p:msmboost msm_devfreq_boost factor=%x1:u32' >> $T/kprobe_events
echo 'stacktrace' > $T/events/kprobes/msmboost/trigger
for e in kprobes/msmdl kprobes/msmdlwork kprobes/msmboost devfreq/devfreq_frequency devfreq/devfreq_monitor; do echo 1 > $T/events/$e/enable; done
echo 1 > $T/tracing_on; sleep 20; echo 0 > $T/tracing_on
cp $T/trace $O/trace.txt
untrace
awk '
/^#/ { next }
{ if (match($0, /[0-9]+\.[0-9]+:/)) ts = substr($0, RSTART, RLENGTH - 1) + 0 }
/ msmdl: /     { dl++; next }
/ msmdlwork: / { dw++; next }
/ msmboost: /  { bo++; lastboost = ts; instack = 1; next }
instack && /=>/ { if (/deadline_work/) bdl++; else if (/msm_devfreq_active/) bact++; instack = (/=> *msm_devfreq_boost/ ? 1 : instack); next }
/devfreq_frequency:/ { instack = 0
	match($0, /freq=[0-9]+/); f = substr($0, RSTART + 5, RLENGTH - 5) + 0
	match($0, /prev_freq=[0-9]+/); p = substr($0, RSTART + 10, RLENGTH - 10) + 0
	nchg++; pend_f = f; pend_p = p; pend_ts = ts; pend = 1
	if (f >= 1200000000 && p < 1200000000) { up12++; cls = (lastboost && ts - lastboost < 0.002) ? "boost" : "?" ; if (cls == "boost") up12b++; else up12q[NR] = ts }
	next }
/devfreq_monitor:/ { instack = 0; mon++
	match($0, /load=[0-9]+/); l = substr($0, RSTART + 5, RLENGTH - 5) + 0; if (l > 50) hiload++
	if (pend && ts - pend_ts < 0.002 && pend_f >= 1200000000 && pend_p < 1200000000) up12g++
	pend = 0; next }
{ instack = 0 }
END {
	printf "20 s trace, balanced, upthreshold 50:\n"
	printf "  KWin deadlines set (msm_fence_set_deadline): %d (%.1f/s)\n", dl, dl / 20
	printf "  msm deadline timer fired (deadline_work):    %d (%.1f/s)\n", dw, dw / 20
	printf "  msm_devfreq_boost calls: %d (%.1f/s): from deadline_work %d, from msm_devfreq_active %d\n", bo, bo / 20, bdl, bact
	printf "  governor ticks: %d, with load > 50: %d\n", mon, hiload
	printf "  frequency changes: %d; jumps to 1200 MHz: %d (within 2 ms after a boost: %d, at a governor tick: %d)\n", nchg, up12, up12b, up12g
}' $O/trace.txt > $O/attribution.txt
log "trace: $(tr '\n' ' ' < $O/attribution.txt)"

# --- 2. upthreshold A/B
echo -e "time\twindow\tprofile\tW\tbacklight\tgpu_mhz\tstatus" > $O/samples.tsv
declare -a ring=()
i=0
for up in 50 $UPT $UPT 50 50 $UPT; do
	i=$((i + 1))
	echo $up > $DF/upthreshold
	sleep 4
	d0=$(ipc get_property frame-drop-count); v0=$(ipc get_property vo-delayed-frame-count)
	for s in $(seq $WIN); do
		echo -e "$(date +%T)\t$i\tup$up\t$(awk '{printf "%.3f", ($1 < 0 ? -$1 : $1) / 1e6}' $BAT/power_now)\t$(cat $BL/brightness)\t$(( $(cat $GPU/cur_freq) / 1000000 ))\t$(cat $BAT/status)" >> $O/samples.tsv
		ring+=("$(touches)"); [ ${#ring[@]} -gt 10 ] && ring=("${ring[@]:1}")
		if [ $(( ${ring[-1]} - ${ring[0]} )) -ge 3 ]; then owner=1; log "owner touched the screen - stopping, screen stays on"; exit 4; fi
		kill -0 $MPV 2>/dev/null || { log "mpv exited"; exit 3; }
		sleep 1
	done
	d1=$(ipc get_property frame-drop-count); v1=$(ipc get_property vo-delayed-frame-count)
	stats=$(awk -F'\t' -v w=$i 'NR>1 && $2==w {n++; s+=$4; b+=$5; g+=$6; if ($6 >= 1200) h++} END{printf "%.2f W mean, backlight %.0f, GPU sample mean %.0f MHz, at 1200 %d%%, %d s", s/n, b/n, g/n, h*100/n, n}' $O/samples.tsv)
	log "window $i upthreshold $(cat $DF/upthreshold): $stats; drops ${d0}->${d1}, vo-delayed ${v0}->${v1}"
done
