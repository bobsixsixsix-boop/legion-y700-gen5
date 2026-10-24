#!/bin/bash
# video-gpu-tune2.sh [WINDOW_S]: second GPU-DVFS / refresh test during fullscreen video (VISIBLE: lights the screen,
# muted test clip). ROOT, run with systemd-run. ~11 min at the default 75 s windows. 2026-10-16.
# Fixes the first run's blind spot: every window also counts KWin's composites per second (kprobe hits on
# msm_fence_set_deadline, which KWin's SYNC_IOC_SET_DEADLINE reaches once per composited frame; read from
# kprobe_profile with tracing_on=0, so nothing is written to the ring buffer). A threshold that saves power only
# because KWin slipped to 30 composites/s (the missed-vblank trap) shows up as composites/s ~30 instead of ~60.
#   conditions (env CONDS, default "up50 up80 fast fast up80 m30 m30 m60", see the comment above the loop):
#   upthreshold 50 vs 80, mpv default vs profile=fast, KWin 60 vs 30 Hz mode (~11 min at 75 s windows)
# Per second: battery power, backlight, GPU cur_freq; per window: composites/s, mpv frame-drop / vo-delayed deltas,
# the panel's live refresh, wiliwili CPU if it runs underneath. Aborts (exit 4, screen left on) on owner touch.
# Restores threshold, mode, kprobe, GPU profile, brightness, auto-brightness and DPMS on any exit.
# Results: /root/video-gpu-tune2/{samples.tsv,windows.txt}; analyze with video-gpu-ab-analyze.sh DIR.
set -u
WIN=${1:-75}
BL_TEST=${BL_TEST:-800}
O=/root/video-gpu-tune2; mkdir -p $O; rm -f $O/*
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
hits() { awk '$1 == "msmdl" {print $2; f = 1} END {if (!f) print 0}' $T/kprobe_profile; }
ticks() { [ -n "$1" ] && awk '{print $14 + $15}' /proc/$1/stat 2>/dev/null || echo 0; }
mode_now() { "${U[@]}" kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oE '[0-9]+:[0-9]+x[0-9]+@[0-9.]+\*' | head -1 | cut -d: -f1; }
mode_id() { "${U[@]}" kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oE "[0-9]+:1904x3040@$1\.00" | head -1 | cut -d: -f1; }
set_mode() { "${U[@]}" kscreen-doctor output.DSI-1.mode.$1 >/dev/null 2>&1; }

prof0=$(tb323fu-ctl gpu 2>/dev/null | awk '/^  Profile:/ {print $2}'); [ -z "$prof0" ] && prof0=balanced
up0=$(cat $DF/upthreshold); mode0=$(mode_now); M60=$(mode_id 60); M30=$(mode_id 30)
bl0=$(gb); dpms0=$(cat $DPMS 2>/dev/null); ab0=$("${U[@]}" systemctl --user is-active y700-autobright.service)
owner=0; MPV=
restore() {
	trap - EXIT
	[ -n "$MPV" ] && kill $MPV 2>/dev/null; pkill -u user -f "input-ipc-server=$SOCK" 2>/dev/null
	echo "$up0" > $DF/upthreshold
	[ -n "$mode0" ] && [ "$(mode_now)" != "$mode0" ] && set_mode "$mode0"
	[ -e $T/events/kprobes/msmdl/enable ] && echo 0 > $T/events/kprobes/msmdl/enable
	grep -q ":kprobes/msmdl " $T/kprobe_events && echo "-:msmdl" >> $T/kprobe_events
	tb323fu-ctl gpu profile "$prof0" >/dev/null 2>&1
	[ -n "$bl0" ] && sb "$bl0"
	[ "$ab0" = active ] && "${U[@]}" systemctl --user start y700-autobright.service
	if [ "$owner" -eq 0 ] && [ "$dpms0" = Off ]; then sleep 1; "${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1; sleep 3; fi
	log "restored: upthreshold $(cat $DF/upthreshold) (was $up0), mode $(mode_now) (was $mode0), kprobes left $(grep -c msm $T/kprobe_events), GPU profile $prof0 ($(cat $GPU/min_freq)-$(cat $GPU/max_freq)), brightness $(gb) (was $bl0), autobright $("${U[@]}" systemctl --user is-active y700-autobright.service) (was $ab0), dpms $(cat $DPMS) (was $dpms0), owner input $owner"
}
trap restore EXIT; trap 'exit 1' INT TERM
log "start: kernel $(uname -r), profile $prof0, upthreshold $up0, mode $mode0 (60 Hz = $M60, 30 Hz = $M30), brightness $bl0, dpms $dpms0, autobright $ab0, battery $(cat $BAT/status) $(cat $BAT/capacity)%, wiliwili $(pgrep -x wiliwili >/dev/null && echo running || echo 'not running')"
grep -q Discharging $BAT/status || log "WARNING: not on battery - W figures are not the consumption"
[ -z "$M60" ] || [ -z "$M30" ] && { log "could not find the 60/30 Hz mode ids"; exit 2; }

cp /root/vt/hevc.mp4 $CLIP; chmod 644 $CLIP
[ "$ab0" = active ] && "${U[@]}" systemctl --user stop y700-autobright.service
tb323fu-ctl gpu profile balanced >/dev/null 2>&1
"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 4   # 4 s, not 1: waking the screen, PowerDevil restores its own brightness and overwrote ours (10-16 18:56 run: sysfs 329 instead of 99)
[ "$(mode_now)" != "$M60" ] && set_mode $M60 && sleep 3
sb "$BL_TEST"
BL_SYS=$(cat $BL/brightness)   # every window re-asserts this sysfs value (see the 18:56 lesson above)
rm -f $SOCK
"${U[@]}" mpv --fs --ao=null --hwdec=vaapi --vo=gpu --gpu-api=opengl --loop-file=inf --no-osc --osd-level=0 \
	--input-ipc-server=$SOCK $CLIP >/dev/null 2>&1 &
sleep 8
MPV=$(pgrep -u user -f "input-ipc-server=$SOCK" | head -1)
[ -z "$MPV" ] && { log "mpv did not start"; exit 2; }
WW=$(pgrep -x wiliwili | head -1)
log "mpv $MPV: hwdec $(ipc get_property hwdec-current), display-fps $(ipc get_property display-fps), container-fps $(ipc get_property container-fps)"
echo 'p:msmdl msm_fence_set_deadline' >> $T/kprobe_events
echo 1 > $T/events/kprobes/msmdl/enable      # armed; tracing_on stays as found, the trace buffer is not read

echo -e "time\twindow\tprofile\tW\tbacklight\tgpu_mhz\tstatus" > $O/samples.tsv
declare -a ring=()
i=0
fast=0
# mpv's builtin [fast] profile (etc/builtin.conf), set property by property: "apply-profile fast restore" only works for
# profiles with profile-restore set, which [fast] does not have, so the defaults are read first and written back
FASTP="scale=bilinear dscale=bilinear dither=no correct-downscaling=no linear-downscaling=no sigmoid-upscaling=no hdr-compute-peak=no allow-delayed-peak-detect=yes"
declare -A Q0; for kv in $FASTP; do Q0[${kv%%=*}]=$(ipc get_property "${kv%%=*}"); done
log "mpv quality defaults: $(for k in "${!Q0[@]}"; do printf '%s=%s ' "$k" "${Q0[$k]}"; done)"
set_fast() { for kv in $FASTP; do ipc set_property "${kv%%=*}" "${kv#*=}" >/dev/null; done; }
unset_fast() { for k in "${!Q0[@]}"; do ipc set_property "$k" "${Q0[$k]}" >/dev/null; done; }
# 10-16 18:3x plan (README "视频播放功耗"; the threshold itself was settled live at 80): every condition is relative to
# the new baseline (upthreshold 80, 60 Hz, mpv default quality = what wiliwili does with player_low_quality=false):
#   up50          kernel comparison with y10's 17:19/17:43 windows (same clip, backlight, quality)
#   up80          baseline (twice, around the quality pair)
#   fast          mpv profile=fast (= wiliwili player_low_quality=true: bilinear, no sigmoid/dither, single pass)
#   m30 / m60     KWin mode 30 Hz vs 60 Hz at the baseline (VFP-only switch on this kernel, patches 0065/0066)
for cond in ${CONDS:-up50 up80 fast fast up80 m30 m30 m60}; do
	i=$((i + 1))
	want_fast=0; up=80; mode=$M60
	case $cond in
	up*) up=${cond#up} ;;
	fast) want_fast=1 ;;
	m30) mode=$M30 ;;
	m60) ;;
	esac
	echo $up > $DF/upthreshold
	[ "$(mode_now)" != "$mode" ] && set_mode $mode && sleep 3
	if [ $want_fast = 1 ] && [ $fast = 0 ]; then set_fast; fast=1
	elif [ $want_fast = 0 ] && [ $fast = 1 ]; then unset_fast; fast=0; fi
	[ "$(cat $BL/brightness)" != "$BL_SYS" ] && { sb "$BL_TEST"; sleep 1; log "window $i: backlight had drifted to $(cat $BL/brightness), re-set"; }
	sleep 4
	d0=$(ipc get_property frame-drop-count); v0=$(ipc get_property vo-delayed-frame-count)
	h0=$(hits); w0=$(ticks "$WW"); t0=$(date +%s.%N)
	for s in $(seq $WIN); do
		echo -e "$(date +%T)\t$i\t$cond\t$(awk '{printf "%.3f", ($1 < 0 ? -$1 : $1) / 1e6}' $BAT/power_now)\t$(cat $BL/brightness)\t$(( $(cat $GPU/cur_freq) / 1000000 ))\t$(cat $BAT/status)" >> $O/samples.tsv
		ring+=("$(touches)"); [ ${#ring[@]} -gt 10 ] && ring=("${ring[@]:1}")
		if [ $(( ${ring[-1]} - ${ring[0]} )) -ge 3 ]; then owner=1; log "owner touched the screen - stopping, screen stays on"; exit 4; fi
		kill -0 $MPV 2>/dev/null || { log "mpv exited"; exit 3; }
		sleep 1
	done
	t1=$(date +%s.%N); h1=$(hits); w1=$(ticks "$WW")
	d1=$(ipc get_property frame-drop-count); v1=$(ipc get_property vo-delayed-frame-count)
	stats=$(awk -F'\t' -v w=$i 'NR>1 && $2==w {n++; s+=$4; b+=$5; g+=$6; if ($6 >= 1200) h++} END{printf "%.2f W mean, backlight %.0f, GPU %.0f MHz, at 1200 %d%%, %d s", s/n, b/n, g/n, h*100/n, n}' $O/samples.tsv)
	extra=$(awk -v a=$h0 -v b=$h1 -v c=$w0 -v d=$w1 -v t0=$t0 -v t1=$t1 -v hz=$(getconf CLK_TCK) 'BEGIN{printf "composites %.1f/s, wiliwili CPU %.1f %%", (b-a)/(t1-t0), (d-c)/hz/(t1-t0)*100}')
	log "window $i $cond: $stats; $extra; drops ${d0}->${d1}, vo-delayed ${v0}->${v1}; upthreshold $(cat $DF/upthreshold), scale $(ipc get_property scale), sigmoid $(ipc get_property sigmoid-upscaling), mode $(mode_now), panel $(grep -oE 'hz [0-9]+' /sys/module/msm/parameters/idle_refresh_state)"
done
