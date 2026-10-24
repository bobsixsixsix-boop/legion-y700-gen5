#!/bin/bash
# test-refresh-auto-2.sh: edge cases from the 10-16 reviews (VISIBLE, ~3 min, muted test clips; the 164 Hz step is a
# full modeset: the screen blanks for a moment twice). ROOT.
#   speed 1.5x on 30 fps (45 fps) -> base | 2x (60 fps) -> 60 | 1x -> 30
#   screen off by kscreen-doctor while at 30 -> base within 2.5 s (the 1 Hz screen-off guard)
#   a foreign switch to 30 is not taken as the base | a foreign 120 -> 60 while a 60 fps video wants 60 (the display
#   watchdog's "back to the current mode") is not taken as the base either
#   systemctl --user restart while at 30 -> base first (stop() / ExecStopPost), then down again
#   base 164 (a foreign switch) -> a 30 fps video is NOT lowered (164 <-> 30 would be a full modeset) -> base back to 120;
#   a mode the owner picks while a video plays is respected until the player state changes (manual)
set -u
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 HOME=/home/user)
SOCK=/tmp/y700-ra-test2.sock; C30=/tmp/y700-ra-30.mp4; C60=/tmp/y700-ra-60.mp4
cp /root/vt/hevc.mp4 $C30; cp /root/vt/h264-60.mp4 $C60; chmod 644 $C30 $C60
hz() { python3 -c 'import json; print([round(o["mode"]["refreshRate"]/1000) for b in json.load(open("/home/user/.config/kwinoutputconfig.json")) if b.get("name")=="outputs" for o in b["data"] if o.get("connectorName","").startswith("DSI")][0])'; }
base() { python3 -c 'import json; print(json.load(open("/home/user/.config/y700-refresh-auto.json"))["base_hz"])'; }
st() { "${U[@]}" gdbus call --session -d fyi.y700.RefreshAuto -o /RefreshAuto -m fyi.y700.RefreshAuto.status 2>/dev/null | sed "s/^('//; s/',)$//"; }
kd() { "${U[@]}" kscreen-doctor "$@" >/dev/null 2>&1; }
ipc() { python3 - "$SOCK" "$@" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect(sys.argv[1])
args = [json.loads(a) if a[:1] in "0123456789" else a for a in sys.argv[2:]]
s.send((json.dumps({"command": args}) + "\n").encode()); s.recv(4096)
PY
}
touches() { awk '/NVT-ts/ {s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break; print s; exit}' /proc/interrupts; }
fail=0; MPV=
cleanup() { [ -n "$MPV" ] && kill $MPV 2>/dev/null; [ "$(base)" != 120 ] && kd output.DSI-1.mode.1904x3040@120; }
trap cleanup EXIT
ok() { printf 'PASS  %s\n' "$1"; }; ko() { printf 'FAIL  %s; daemon: %s\n' "$1" "$(st)"; fail=1; }
expect() {   # label hz [timeout_s]
	local s=$(date +%s.%N) h n=$(( ${3:-8} * 10 ))
	for i in $(seq $n); do h=$(hz); [ "$h" = "$2" ] && break; sleep 0.1; done
	[ $(( $(touches) - t0 )) -ge 3 ] && { echo "owner touched the screen - stopping"; exit 4; }
	t0=$(touches)
	[ "$h" = "$2" ] && ok "$(printf '%-44s %s Hz after %.1f s' "$1" "$h" "$(awk -v a=$s -v b=$(date +%s.%N) 'BEGIN{print b-a}')")" || ko "$1: now $h Hz, wanted $2"
}
steady() {   # label hz seconds: stays at hz the whole time
	local bad=""
	for i in $(seq $(( $3 * 10 ))); do h=$(hz); [ "$h" != "$2" ] && bad="$bad $h"; sleep 0.1; done
	t0=$(touches)
	[ -z "$bad" ] && ok "$(printf '%-44s stayed %s Hz for %s s' "$1" "$2" "$3")" || ko "$1: left $2 Hz ($bad)"
}
[ "$(base)" = 120 ] || { echo "base is $(base), expected 120 before the test"; exit 2; }
kd --dpms on; sleep 3; t0=$(touches)
rm -f $SOCK
"${U[@]}" mpv --fs --ao=null --hwdec=vaapi --loop-file=inf --input-ipc-server=$SOCK $C30 >/dev/null 2>&1 &
sleep 2; MPV=$(pgrep -u user -f "input-ipc-server=$SOCK" | head -1)
expect "30 fps fullscreen" 30
ipc set_property speed 1.5;            expect "speed 1.5x (45 fps)" 120
ipc set_property speed 2.0;            expect "speed 2x (60 fps)" 60
ipc set_property speed 1.0;            expect "speed 1x" 30
kd --dpms off;                         expect "screen off by kscreen-doctor at 30" 120 4
kd --dpms on; sleep 3; t0=$(touches)
ipc set_property pause yes; sleep 0.5; ipc set_property pause no
expect "screen on + a state change -> down again" 30
ipc set_property pause yes;            expect "paused" 120
kd output.DSI-1.mode.1904x3040@30;     sleep 2
[ "$(base)" = 120 ] && ok "foreign switch to 30: base stays $(base)" || ko "foreign switch to 30 made base $(base)"
expect "  ... and the daemon goes back to the base" 120
ipc set_property pause no;             expect "resumed" 30
"${U[@]}" systemctl --user restart y700-refresh-auto & RJ=$!
saw=""; for i in $(seq 40); do h=$(hz); [ "$h" = 120 ] && saw=1 && break; sleep 0.1; done
[ -n "$saw" ] && ok "daemon restart at 30: back to 120 while stopping" || ko "daemon restart at 30: never saw 120"
wait $RJ; t0=$(touches)   # only the restart job: a bare wait would wait for mpv too
expect "  ... new instance lowers again" 30 10
ipc loadfile $C60;                     expect "60 fps clip" 60
kd output.DSI-1.mode.1904x3040@120; sleep 1; kd output.DSI-1.mode.1904x3040@60; sleep 2
[ "$(base)" = 120 ] && ok "watchdog-style 60 -> 120 -> 60: base stays $(base)" || ko "watchdog-style switch made base $(base)"
t0=$(touches)
ipc set_property pause yes;            expect "paused (60 fps)" 120
kd output.DSI-1.mode.1904x3040@164;    sleep 3; t0=$(touches)
[ "$(base)" = 164 ] && ok "foreign switch to 164 (tile): new base 164" || ko "164 not taken as base ($(base))"
ipc loadfile $C30; ipc set_property pause no
steady "base 164: 30 fps video is not lowered" 164 5
kd output.DSI-1.mode.1904x3040@120;    sleep 3; t0=$(touches)
[ "$(base)" = 120 ] && ok "back to base 120" || ko "base is $(base) after switching to 120"
steady "owner picked 120 during the video: respected (manual)" 120 3
ipc set_property pause yes; sleep 0.5; ipc set_property pause no
expect "  ... until the state changes: lowered again" 30
ipc quit; MPV=;                        expect "mpv quit" 120
echo "daemon: $(st)"
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
