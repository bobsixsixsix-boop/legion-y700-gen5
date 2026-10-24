#!/bin/bash
# One measured Moonlight run on the Y700 (root; start it with systemd-run so no
# ssh session is open during the measurement).
#
# usage: ml-run.sh LABEL CODEC WxH FPS KBPS SECS PS [extra moonlight stream flags...]
#   CODEC  H.264 | HEVC | AV1      PS  on | off | keep (Wi-Fi power save during the run)
# Results: /root/streaming/runs/LABEL/{meta.txt,probe.csv,rtt.csv,moonlight.log,done}
# The previous power-save state is restored on exit (trap), also on failure.
set -u
LABEL=$1 CODEC=$2 RES=$3 FPS=$4 KBPS=$5 SECS=$6 PS=$7; shift 7
EXTRA=("$@")
HOST=${ML_HOST:-192.168.0.94} GW=${ML_GW:-192.168.0.1} IF=${ML_IF:-wlp1s0} APP=${ML_APP:-Virtual Display}
HERE=$(cd "$(dirname "$0")" && pwd)
D=/root/streaming/runs/$LABEL
mkdir -p "$D"; rm -f "$D"/*
U=(sudo -u user env LANG=C.UTF-8 XDG_RUNTIME_DIR=/run/user/1000
   DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0)
ML=(flatpak run com.moonlight_stream.Moonlight)
# ML_UCLAMP=N: start Moonlight under a uclamp.min of N (0..1024), inherited by every thread it makes, as the
# desktop launcher does (linux/streaming/y700-moonlight); the quit command stays plain
MLS=("${ML[@]}"); [ -n "${ML_UCLAMP:-}" ] && MLS=(uclampset -m "$ML_UCLAMP" -- "${ML[@]}")
# ML_LAUNCHER=path: stream through the owner's launcher instead (it takes Moonlight's arguments)
[ -n "${ML_LAUNCHER:-}" ] && MLS=("$ML_LAUNCHER")
# ML_UCLAMP_KWIN=N: the compositor's threads get the same floor for the run (back to 0 in cleanup)
KWIN=$(pgrep -x -u user kwin_wayland | head -n 1)
[ -n "${ML_UCLAMP_KWIN:-}" ] && [ -n "$KWIN" ] && uclampset -a -m "$ML_UCLAMP_KWIN" -p "$KWIN"
log() { echo "$(date +%T.%3N) @$(date +%s.%3N) $*" >>"$D/meta.txt"; }

PS0=$(iw dev "$IF" get power_save | awk '{print $3}')
PIDS=()
cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
    "${U[@]}" flatpak kill com.moonlight_stream.Moonlight 2>/dev/null
    # interrupted (systemctl stop): without a quit Apollo only pauses the session and
    # keeps its virtual display, and the next run's host-run would not see a new one
    [ -n "${QUIT_SENT:-}" ] || timeout 20 "${U[@]}" "${ML[@]}" quit "$HOST" >/dev/null 2>&1
    [ -n "${ML_UCLAMP_KWIN:-}" ] && [ -n "$KWIN" ] && uclampset -a -m 0 -p "$KWIN"
    [ -n "$PS0" ] && iw dev "$IF" set power_save "$PS0"
    log "cleanup: power_save restored to $PS0"
}
trap cleanup EXIT

{
    echo "label=$LABEL codec=$CODEC res=$RES fps=$FPS kbps=$KBPS secs=$SECS ps=$PS uclamp_min=${ML_UCLAMP:-} kwin=${ML_UCLAMP_KWIN:-} launcher=${ML_LAUNCHER:-} extra=${EXTRA[*]:-}"
    echo "kernel=$(uname -r) moonlight=$(LC_ALL=C flatpak info com.moonlight_stream.Moonlight | awk '/Version:/{print $2}')"
    iw dev "$IF" link | grep -E 'SSID|freq|signal|bitrate'
    echo "power_save_before=$PS0 battery=$(cat /sys/class/power_supply/qcom-battmgr-bat/capacity)% $(cat /sys/class/power_supply/qcom-battmgr-bat/status)"
    echo "backlight=$(cat /sys/class/backlight/*/brightness 2>/dev/null | head -1) profile=$(powerprofilesctl get 2>/dev/null)"
} >"$D/meta.txt"

case $PS in on|off) iw dev "$IF" set power_save "$PS";; esac
log "power_save now $(iw dev "$IF" get power_save | awk '{print $3}')"

"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1
python3 "$HERE/ml-probe.py" "$D/probe.csv" "$IF" & PIDS+=($!)
python3 "$HERE/ml-rtt.py" "$D/rtt.csv" "$GW" "$HOST" & PIDS+=($!)
sleep 3

log "stream start"
"${U[@]}" "${MLS[@]}" stream "$HOST" "$APP" --resolution "$RES" --fps "$FPS" --bitrate "$KBPS" \
    --video-codec "$CODEC" --video-decoder hardware --display-mode fullscreen \
    --performance-overlay --no-audio-on-host --keep-awake --no-quit-after "${EXTRA[@]}" \
    >"$D/moonlight.log" 2>&1 </dev/null &
MLPID=$!
for _ in $(seq 60); do
    grep -q 'Received first video packet' "$D/moonlight.log" && break
    kill -0 $MLPID 2>/dev/null || break
    sleep 0.5
done
if ! grep -q 'Received first video packet' "$D/moonlight.log"; then
    log "FAILED: no video"; echo failed >"$D/done"; exit 1
fi
log "T0 first video packet"
log "uclamp: $(uclampset -p "$(pgrep -x kwin_wayland | head -n 1)" 2>&1) / $(uclampset -p "$(pgrep -x moonlight | head -n 1)" 2>&1)"
# what reaches the panel: page flips vs decoded frames, from T0+15 s to T1-5 s
( sleep 15; python3 "$HERE/ml-flips.py" $((SECS - 20)) "$D/flips.txt" >/dev/null 2>&1 ) & PIDS+=($!)
# what the HUD's top-left line said, once a second (its cache file; FPS via ml-hud-fps.sh)
( while sleep 1; do echo "$(date +%T) $(cat /run/user/1000/y700-hud.txt 2>/dev/null)"; done >"$D/hud.txt" ) & PIDS+=($!)
sleep "$SECS"
log "T1 quit"
timeout 20 "${U[@]}" "${ML[@]}" quit "$HOST" >/dev/null 2>&1
QUIT_SENT=1
for _ in $(seq 40); do
    grep -q 'Average rendering time' "$D/moonlight.log" && break
    sleep 0.5
done
sleep 1
"${U[@]}" flatpak kill com.moonlight_stream.Moonlight 2>/dev/null
sleep 3
log "end"
echo ok >"$D/done"
