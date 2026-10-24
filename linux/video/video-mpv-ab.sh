#!/bin/bash
# video-mpv-ab.sh [WINDOW_S]: controlled in-use video power test (VISIBLE: lights the screen, plays a muted
# test clip fullscreen). ROOT, run with systemd-run. 2026-10-16.
# 2 x 2 factorial, counterbalanced (A-bal B-bal A-ps B-ps, then reversed), WINDOW_S each (default 90):
#   A = mpv presents at the video rate (video-sync=audio, default: one Wayland commit per video frame, 30/s)
#   B = mpv presents on every vsync (video-sync=display-resample: a commit per display refresh, like wiliwili,
#       which redraws its whole UI at the panel rate)
#   bal = GPU 160-1200 MHz (helper profile balanced), ps = 160-726 MHz (power-saver)
# Same clip (1080p30 HEVC, looped, hwdec=vaapi, vo=gpu/OpenGL like wiliwili's libmpv), no audio (ao=null),
# backlight fixed (y700-autobright stopped, KDE's ScreenBrightness API, no OSD), landscape as found.
# Per second: battery power, backlight, GPU cur_freq; per window: mpv / kwin_wayland CPU, mpv's frame counters,
# the panel refresh state. Aborts (exit 4, screen left on) if the owner touches the screen (>= 3 touch IRQs in
# 10 s). Restores GPU profile, brightness, auto-brightness and DPMS on any exit.
# Results: /root/video-mpv-ab/{samples.tsv,windows.txt,mpv.log}; analyze with video-gpu-ab-analyze.sh DIR.
set -u
WIN=${1:-90}
BL_TEST=${BL_TEST:-800}
O=/root/video-mpv-ab; mkdir -p $O; rm -f $O/*
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0)
GPU=/sys/class/devfreq/3d00000.gpu
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
ticks() { [ -n "$1" ] && awk '{print $14 + $15}' /proc/$1/stat 2>/dev/null || echo 0; }

prof0=$(tb323fu-ctl gpu 2>/dev/null | awk '/^  Profile:/ {print $2}'); [ -z "$prof0" ] && prof0=balanced
bl0=$(gb); dpms0=$(cat $DPMS 2>/dev/null); ab0=$("${U[@]}" systemctl --user is-active y700-autobright.service)
owner=0; MPV=
restore() {
	trap - EXIT
	[ -n "$MPV" ] && kill $MPV 2>/dev/null; pkill -u user -f "input-ipc-server=$SOCK" 2>/dev/null
	tb323fu-ctl gpu profile "$prof0" >/dev/null 2>&1
	[ -n "$bl0" ] && sb "$bl0"
	[ "$ab0" = active ] && "${U[@]}" systemctl --user start y700-autobright.service
	if [ "$owner" -eq 0 ] && [ "$dpms0" = Off ]; then sleep 1; "${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1; sleep 3; fi   # dpms off applies asynchronously
	log "restored: GPU profile $prof0 ($(cat $GPU/min_freq)-$(cat $GPU/max_freq)), brightness $(gb) (was $bl0), autobright $("${U[@]}" systemctl --user is-active y700-autobright.service) (was $ab0), dpms $(cat $DPMS) (was $dpms0), owner input $owner"
}
trap restore EXIT; trap 'exit 1' INT TERM
log "start: profile $prof0, brightness $bl0, dpms $dpms0, autobright $ab0, battery $(cat $BAT/status) $(cat $BAT/capacity)%, panel: $(cat /sys/module/msm/parameters/idle_refresh_state)"
grep -q Discharging $BAT/status || log "WARNING: not on battery - W figures are not the consumption"

cp /root/vt/hevc.mp4 $CLIP; chmod 644 $CLIP
[ "$ab0" = active ] && "${U[@]}" systemctl --user stop y700-autobright.service
"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 4   # 4 s, not 1: waking the screen, PowerDevil restores its own brightness and overwrote ours (10-16 18:56 run: sysfs 329 instead of 99); whether PowerDevil does the same after a dim -> off -> on blink (cx-auto T1) is unverified - PLAN DSP-5 (:233): uncertain, to be observed in the N2' nights
sb "$BL_TEST"
rm -f $SOCK
"${U[@]}" mpv --fs --ao=null --hwdec=vaapi --vo=gpu --gpu-api=opengl --loop-file=inf --no-osc --osd-level=0 \
	--input-ipc-server=$SOCK --log-file=$O/mpv.log --msg-level=all=info,vd=v,vo=v $CLIP >/dev/null 2>&1 &
sleep 6
MPV=$(pgrep -u user -f "input-ipc-server=$SOCK" | head -1)
[ -z "$MPV" ] && { log "mpv did not start"; exit 2; }
KW=$(pgrep -x kwin_wayland | head -1)
log "mpv $MPV: hwdec $(ipc get_property hwdec-current), vo $(ipc get_property current-vo), display-fps $(ipc get_property display-fps), container-fps $(ipc get_property container-fps)"
hz=$(getconf CLK_TCK)
echo -e "time\twindow\tprofile\tW\tbacklight\tgpu_mhz\tstatus" > $O/samples.tsv
declare -a ring=()
i=0
for cfg in A-bal B-bal A-ps B-ps B-ps A-ps B-bal A-bal; do
	i=$((i + 1))
	case $cfg in *bal) tb323fu-ctl gpu profile balanced >/dev/null 2>&1 ;; *ps) tb323fu-ctl gpu profile power-saver >/dev/null 2>&1 ;; esac
	case $cfg in A-*) ipc set_property video-sync audio >/dev/null ;; B-*) ipc set_property video-sync display-resample >/dev/null ;; esac
	sleep 4
	d0=$(ipc get_property frame-drop-count); v0=$(ipc get_property vo-delayed-frame-count)
	m0=$(ticks $MPV); k0=$(ticks $KW); t0=$(date +%s.%N); r0=$(cat /sys/module/msm/parameters/idle_refresh_state)
	for s in $(seq $WIN); do
		echo -e "$(date +%T)\t$i\t$cfg\t$(awk '{printf "%.3f", ($1 < 0 ? -$1 : $1) / 1e6}' $BAT/power_now)\t$(cat $BL/brightness)\t$(( $(cat $GPU/cur_freq) / 1000000 ))\t$(cat $BAT/status)" >> $O/samples.tsv
		ring+=("$(touches)"); [ ${#ring[@]} -gt 10 ] && ring=("${ring[@]:1}")
		if [ $(( ${ring[-1]} - ${ring[0]} )) -ge 3 ]; then owner=1; log "owner touched the screen ($(( ${ring[-1]} - ${ring[0]} )) touch IRQs in 10 s) - stopping, screen stays on"; exit 4; fi
		kill -0 $MPV 2>/dev/null || { log "mpv exited"; exit 3; }
		sleep 1
	done
	t1=$(date +%s.%N); m1=$(ticks $MPV); k1=$(ticks $KW)
	d1=$(ipc get_property frame-drop-count); v1=$(ipc get_property vo-delayed-frame-count)
	stats=$(awk -F'\t' -v w=$i 'NR>1 && $2==w {n++; s+=$4; b+=$5; g+=$6} END{printf "%.2f W mean, backlight %.0f, GPU sample mean %.0f MHz, %d s", s/n, b/n, g/n, n}' $O/samples.tsv)
	cpu=$(awk -v a=$m0 -v b=$m1 -v c=$k0 -v d=$k1 -v t0=$t0 -v t1=$t1 -v hz=$hz 'BEGIN{printf "mpv %.1f %%, kwin %.1f %%", (b-a)/hz/(t1-t0)*100, (d-c)/hz/(t1-t0)*100}')
	log "window $i $cfg: $stats; $cpu; video-sync $(ipc get_property video-sync), drops ${d0}->${d1}, vo-delayed ${v0}->${v1}; panel $(cat /sys/module/msm/parameters/idle_refresh_state | grep -oE 'hz [0-9]+')"
done
