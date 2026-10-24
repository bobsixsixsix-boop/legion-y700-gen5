#!/bin/sh
# Which path gets a modifier combo (Ctrl+Z, Ctrl+A) to a Wayland text field? Types into the focused
# window, so like e2e.sh it runs only with the display off (or --force). Prints the field after each
# variant: "xy" -> undo worked = "", lost modifier = "xyz".
U="sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0"
PROBE=/usr/local/src/y700-osk/tests/probe/build/y700-osk-probe
OUT=/tmp/y700-osk-combo.out
dbg() { $U busctl --user call fyi.y700.Osk /Osk fyi.y700.Osk debug ss "$1" "${2:-x}" >/dev/null 2>&1; }
text() { tail -n 1 "$OUT" | sed 's/^TEXT //'; }
if [ "$1" != "--force" ] && ! grep -q Off /sys/class/drm/card*-DSI-1/dpms 2>/dev/null; then echo "display is on; run with --force to override"; exit 3; fi
: > "$OUT"
# PROTO=zwp_text_input_v3 makes the Qt probe behave like a GTK/Chromium client
$U QT_QPA_PLATFORM=wayland ${PROTO:+QT_WAYLAND_TEXT_INPUT_PROTOCOL=$PROTO} $PROBE 120 > "$OUT" 2>/dev/null &
sleep 2.5
st=$($U busctl --user call fyi.y700.Osk /Osk fyi.y700.Osk debug ss state x 2>&1)
case "$st" in *'\"zh\":true'*) dbg tap lang; sleep 0.7;; esac
fresh() { i=0; while [ $i -lt 8 ]; do dbg tap del; i=$((i+1)); done; sleep 0.3; dbg tap x; dbg tap y; sleep 0.5; }
run() {
	echo "== $1"; fresh; echo "   before: $(text)"
	# the keys type into whatever has focus: stop at once if the probe did not get them
	[ "$(text)" = '["xy"]' ] || { echo "ABORT: the probe field does not read xy (focus is elsewhere?)"; kill %1 2>/dev/null; exit 4; }
	shift; "$@"; sleep 0.8; echo "   after:  $(text)"
}

run "V1 undo as implemented (helper 37d,52d,52u,37u in one go)" dbg undo
v2() { dbg raw 37d; sleep 0.15; dbg raw 52d,52u; sleep 0.05; dbg raw 37u; }
run "V2 helper, Ctrl down, 150 ms, z, Ctrl up" v2
v3() { dbg raw 37d; sleep 0.1; dbg vk 122:52:4:0; dbg vk 122:52:4:1; sleep 0.05; dbg raw 37u; }
run "V3 helper holds Ctrl, z through the VK backend with state 4 (fcitx5-osk's way)" v3
v4() { dbg vk 122:52:4:0; dbg vk 122:52:4:1; }
run "V4 VK backend only, z with state 4" v4
run "V5 clear as implemented (helper Ctrl+A, BackSpace)" dbg clearall
v6() { dbg raw 37d; sleep 0.1; dbg vk 97:38:4:0; dbg vk 97:38:4:1; sleep 0.05; dbg raw 37u; dbg vk 65288:22:0:0; dbg vk 65288:22:0:1; }
run "V6 clear: helper Ctrl + VK a(state 4), then VK BackSpace" v6
v7() { dbg raw 37d; sleep 0.1; dbg vk 0:52:0:0; dbg vk 0:52:0:1; sleep 0.05; dbg raw 37u; }
run "V7 helper holds Ctrl, z through the VK backend as keycode only (keyval 0, state 0: fcitx5's raw key() path)" v7
v8() { dbg raw 37d; sleep 0.1; dbg vk 0:38:0:0; dbg vk 0:38:0:1; sleep 0.05; dbg raw 37u; sleep 0.05; dbg vk 65288:22:0:0; dbg vk 65288:22:0:1; }
run "V8 clear: helper Ctrl + VK a as keycode only, then VK BackSpace" v8
kill %1 2>/dev/null
echo "== key-helper warnings in the last 3 minutes"
$U journalctl --user --since "-3min" --no-pager 2>/dev/null | grep -i "key-helper\|fcitx:" | tail -8
