#!/bin/bash
# test-refresh-auto.sh: end-to-end check of y700-refresh-auto with standalone mpv (VISIBLE, ~2 min, muted test clips).
# ROOT. 2026-10-16. Each step waits up to 8 s for KWin's mode (kwinoutputconfig.json) to reach the expected rate:
#   30 fps clip fullscreen -> 30 | pause -> base | resume -> 30 | 60 fps clip -> 60 | leave fullscreen -> base |
#   fullscreen again -> 60 | quit mpv -> base
# Aborts on owner touch (>= 3 touch IRQs in 10 s): a touch sends the panel to the base rate by design anyway.
set -u
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 HOME=/home/user)
SOCK=/tmp/y700-ra-test.sock
C30=/tmp/y700-ra-30.mp4; C60=/tmp/y700-ra-60.mp4
cp /root/vt/hevc.mp4 $C30
[ -s /root/vt/h264-60.mp4 ] || ffmpeg -loglevel error -f lavfi -i testsrc2=size=1920x1080:rate=60 -t 10 -c:v libx264 -preset veryfast -pix_fmt yuv420p /root/vt/h264-60.mp4
cp /root/vt/h264-60.mp4 $C60; chmod 644 $C30 $C60
hz() { python3 -c 'import json; print([round(o["mode"]["refreshRate"]/1000) for b in json.load(open("/home/user/.config/kwinoutputconfig.json")) if b.get("name")=="outputs" for o in b["data"] if o.get("connectorName","").startswith("DSI")][0])'; }
st() { "${U[@]}" gdbus call --session -d fyi.y700.RefreshAuto -o /RefreshAuto -m fyi.y700.RefreshAuto.status 2>/dev/null | sed "s/^('//; s/',)$//"; }
ipc() { python3 - "$SOCK" "$@" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect(sys.argv[1])
s.send((json.dumps({"command": sys.argv[2:]}) + "\n").encode()); s.recv(4096)
PY
}
touches() { awk '/NVT-ts/ {s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break; print s; exit}' /proc/interrupts; }
t0=$(touches); fail=0; MPV=
cleanup() { [ -n "$MPV" ] && kill $MPV 2>/dev/null; }
trap cleanup EXIT
base=$(st | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["base_hz"])' 2>/dev/null)
[ -z "$base" ] && { echo "daemon not answering on D-Bus"; exit 2; }
expect() {   # $1 = label, $2 = Hz
	local s=$(date +%s.%N) h
	for i in $(seq 80); do h=$(hz); [ "$h" = "$2" ] && break; sleep 0.1; done
	[ $(( $(touches) - t0 )) -ge 3 ] && { echo "owner touched the screen - stopping"; exit 4; }
	t0=$(touches)   # per step (waking the screen alone gives 3 touch IRQs: the baseline is taken after it)
	if [ "$h" = "$2" ]; then printf 'PASS  %-34s %s Hz after %.1f s\n' "$1" "$h" "$(awk -v a=$s -v b=$(date +%s.%N) 'BEGIN{print b-a}')"
	else printf 'FAIL  %-34s now %s Hz, wanted %s; daemon: %s\n' "$1" "$h" "$2" "$(st)"; fail=1; fi
}
echo "base $base Hz, start $(hz) Hz"
"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 3; t0=$(touches)   # the touch controller fires 3 IRQs on wake
rm -f $SOCK
"${U[@]}" mpv --fs --ao=null --hwdec=vaapi --loop-file=inf --input-ipc-server=$SOCK $C30 >/dev/null 2>&1 &
sleep 2; MPV=$(pgrep -u user -f "input-ipc-server=$SOCK" | head -1)
expect "30 fps fullscreen" 30
ipc set_property pause yes;      expect "paused" "$base"
ipc set_property pause no;       expect "resumed" 30
ipc loadfile $C60;               expect "60 fps clip" 60
ipc set_property fullscreen no;  expect "left fullscreen" "$base"
ipc set_property fullscreen yes; expect "fullscreen again" 60
ipc quit; MPV=;                  expect "mpv quit" "$base"
echo "daemon: $(st)"
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
