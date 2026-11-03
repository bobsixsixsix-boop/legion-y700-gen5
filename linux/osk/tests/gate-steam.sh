#!/bin/bash
# gate-steam.sh [case...]: keyboard pop-up cases for an X11 client - Steam (CEF on Xwayland with the GTK
# fcitx5 module, no text-input) - driven with the virtual finger. Owner, 2026-10-30: "键盘老是弹出来 ...
# 键盘有的时候还不弹出来"; the rule is Osk::x11Decide() / x11TouchEnded() in osk.cpp.
#  1 a Steam field right after the keyboard (re)started (fcitx5 still in physical-keyboard mode): pops
#  2 keyboard up for the search box: tap the empty header / the page margin -> goes away; the box again -> up
#  3 keyboard down, box still focused: tap the empty header, drag the page -> stays down
#  4 collapse it with the chevron, tap the box again -> up
#  5 TYPES "dota" + Return (debug hook), the results page loads and the box loses the focus: goes away
#    (when fcitx5's Hide fell into key-helper's echo window, x11Verify asked fcitx5); the in-page search
#    box -> up; the blue band -> away
#  6 Steam behind another window: tap its empty header -> nothing; tap its search box -> up
#  7 a key, then at once a tap off the box (its Hides fall into the echo window too) -> goes away
#  8 the box keeps the focus while the probe Chrome is used; a tap there, then Chrome is minimized:
#    Steam gets the box back by itself -> nothing (the tapped window is gone)
#  9 keyboard up for the probe Chrome's field; a slow press (450 ms) on Steam's box -> stays up the
#    whole time (no slide out and back in), and ends up for Steam
# Each step prints the keyboard against what it should be and the keyboard's last decisions (its gate
# log); TRACE=1 adds every fcitx5 input-context call and Show/Hide with the sender's process name - how
# the Steam behaviour in osk.cpp was measured.
# Needs: Steam maximized on a store page at its 10-30 UI scale (check with tablet-shot.sh, adjust the
# coordinates below), another normal window (case 6), the probe Chrome (cases 8, 9: probe-chrome.sh
# start; skipped without it), y700-vtouch running, the keyboard at its 10-30 size (CHEVRON). Run as root
# on the tablet, and only while nobody uses it: it restarts the keyboard (case 1), switches windows,
# taps and types.
K=/usr/local/libexec
D=$(cd "$(dirname "$0")" && pwd)
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
CASES=" ${*:-1 2 3 4 5 6 7 8 9} "
SEARCH="1042 141"; NAV="684 141"; MARGIN="95 400"; CHEVRON="1549 652"; BAND="632 216"; INPAGE="358 288"
# the probe Chrome moved to the left half (x 10..790): its field and grey pad (touchprobe.html)
PFIELD="286 187"; PPAD="283 469"
want() { [[ "$CASES" == *" $1 "* ]]; }
dbg() { "${U[@]}" busctl --user call fyi.y700.Osk /Osk fyi.y700.Osk debug ss "$1" "$2" 2>/dev/null; }
vt() { printf '%s\n' "$1" | tr ';' '\n' > /run/y700-vtouch.fifo; }
steam() {   # Steam's main window to the front, active (no touch)
	echo 'for (const w of workspace.windowList()) if (w.normalWindow && w.resourceClass == "steam" && w.caption == "Steam") workspace.activeWindow = w;' | $K/kwin-eval.sh >/dev/null
	sleep 0.8
}
behind() {   # another window active, Steam raised over it but not active: the next tap on Steam activates it
	# (activating the other one alone would leave it over Steam where the tests tap); prints the active class
	cat <<'EOF' | $K/kwin-eval.sh
let s = null;
for (const w of workspace.windowList()) if (w.normalWindow && w.resourceClass == "steam" && w.caption == "Steam") s = w;
for (const w of workspace.windowList()) if (w.normalWindow && !w.minimized && w.resourceClass != "steam") { workspace.activeWindow = w; break; }
if (s) workspace.raiseWindow(s);
out(workspace.activeWindow ? workspace.activeWindow.resourceClass : "");
EOF
	sleep 0.8
}
probe() {   # the probe Chrome to the left half, active (no touch); prints its class, nothing without it
	cat <<'EOF' | $K/kwin-eval.sh
let p = null;
for (const w of workspace.windowList()) if (w.normalWindow && w.resourceClass == "google-chrome" && w.caption.indexOf("touchprobe") >= 0) p = w;
if (p) { p.minimized = false; p.setMaximize(false, false); p.frameGeometry = { x: 10, y: 28, width: 780, height: 900 }; workspace.activeWindow = p; out(p.resourceClass); }
EOF
	sleep 0.8
}
minimize_probe() {
	echo 'for (const w of workspace.windowList()) if (w.normalWindow && w.resourceClass == "google-chrome" && w.caption.indexOf("touchprobe") >= 0) w.minimized = true;' | $K/kwin-eval.sh >/dev/null
}
pass=0 fail=0
# step NAME WANT 'vtouch lines;...' [SETTLE_S]. Env: NOHIDE=1 keeps the keyboard as it is (default: hide it
# first); KEYS='lang en;tap d;...' are debug-hook commands sent after the touches, 150 ms apart; THEN='vtouch
# lines' are sent after the KEYS; DO='shell' runs after those; MID=S: S seconds after the touches were sent
# the keyboard must be up (a press still held); KEPT=1: WANT 1 only means "still up" (otherwise the
# keyboard's last decision must be a show for a tap on Steam); WHY=regex: one of its last 3 decisions matches
step() {
	local name=$1 want=$2 cmds=$3 settle=${4:-1.5} log=/tmp/gate-steam-$1.log t0 shown mid r k ks s p t rest
	if grep -q Off /sys/class/drm/card*-DSI-1/dpms 2>/dev/null; then "${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 1.2; fi
	[ -n "${NOHIDE:-}" ] || { "${U[@]}" /usr/local/bin/y700-osk hide >/dev/null 2>&1; sleep 0.8; }
	if [ -n "${TRACE:-}" ]; then
		"${U[@]}" timeout 40 dbus-monitor --session \
			"type='signal',interface='org.y700.OskGate'" \
			"type='method_call',interface='org.fcitx.Fcitx.InputContext1'" \
			"type='signal',interface='org.fcitx.Fcitx.InputContext1'" \
			"type='method_call',member='ShowVirtualKeyboard'" "type='method_call',member='HideVirtualKeyboard'" 2>/dev/null |
			python3 -u "$D/im-log.py" > "$log" &
		sleep 0.8
	fi
	t0=$(date +%s.%N)
	vt "$cmds"
	if [ -n "${MID:-}" ]; then sleep "$MID"; mid=$(dbg gate x | grep -o 'shown=[0-9]' | head -1); mid=${mid#shown=}; fi
	if [ -n "${KEYS:-}" ]; then
		IFS=';' read -ra ks <<< "$KEYS"
		for k in "${ks[@]}"; do k=${k# }; dbg "${k%% *}" "${k#* }" >/dev/null; sleep 0.15; done
	fi
	[ -z "${THEN:-}" ] || vt "$THEN"
	[ -z "${DO:-}" ] || eval "$DO"
	sleep "$settle"
	shown=$(dbg gate x | grep -o 'shown=[0-9]' | head -1); shown=${shown#shown=}
	r=PASS; [ "$shown" = "$want" ] || r=FAIL
	if [ "$r" = PASS ] && [ -n "${MID:-}" ] && [ "$mid" != 1 ]; then r="FAIL (down while the press was held)"; fi
	if [ "$r" = PASS ] && [ -n "${WHY:-}" ] && ! dbg gate x | python3 $K/gate-unescape.py 3 | grep -qE "$WHY"; then r="FAIL (no '$WHY')"; fi
	# up must mean Steam's field brought it up (a tap that landed on another window is a wrong pass),
	# except where it only has to stay up (KEPT=1)
	if [ "$r" = PASS ] && [ "$want" = 1 ] && [ -z "${KEPT:-}" ] &&
		! dbg gate x | python3 $K/gate-unescape.py 2 | grep -q 'X11 client: tap on steam|.*: show'; then r="FAIL (not shown for Steam)"; fi
	if [ "$r" = PASS ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
	printf '%-26s keyboard %s, want %s  %s\n' "$name" "${shown:-?}" "$want" "$r"
	dbg gate x | python3 $K/gate-unescape.py "${GATELINES:-2}"
	[ -n "${TRACE:-}" ] || return 0
	pkill -f "^timeout 40 dbus-monitor --session type=.signal.,interface=.org.y700.OskGate" 2>/dev/null; sleep 0.3
	local -A who
	for s in $(awk '$2 ~ /^:1\./ {print $2}' "$log" | sort -u); do
		p=$("${U[@]}" busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetConnectionUnixProcessID s "$s" 2>/dev/null | awk '{print $2}')
		who[$s]="$(cat /proc/$p/comm 2>/dev/null)/$p"
	done
	while read -r t s rest; do
		[[ "$rest" == *VisibilityChanged* ]] && continue
		printf '%s %-22s %s\n' "$(awk -v a="$t" -v b="$t0" 'BEGIN { printf "%+7.3f", a - b }')" "${who[$s]:-$s}" "$rest"
	done < "$log"
}

pgrep -u user -x steam >/dev/null || { echo "Steam is not running"; exit 1; }
steam

if want 1; then
	echo "== 1 a Steam field right after the keyboard started"
	"${U[@]}" y700-osk-ctl restart >/dev/null; sleep 3
	step 1-fresh-search 1 "tap $SEARCH" 2
fi
if want 2; then
	echo "== 2 keyboard up for the search box, tap elsewhere"
	step 2-search 1 "tap $SEARCH"
	NOHIDE=1 step 2-header-kbup 0 "tap $NAV" 2
	step 2-search-again 1 "tap $SEARCH"
	NOHIDE=1 step 2-margin-kbup 0 "tap $MARGIN" 2
fi
if want 3; then
	echo "== 3 keyboard down, the box still focused"
	step 3-search 1 "tap $SEARCH"
	step 3-header 0 "tap $NAV" 2
	step 3-search-again 1 "tap $SEARCH"
	step 3-drag 0 "drag 800 750 800 450 500 15" 2.5
fi
if want 4; then
	echo "== 4 collapsed with the chevron, then the box again"
	step 4-search 1 "tap $SEARCH"
	NOHIDE=1 step 4-chevron 0 "tap $CHEVRON"
	NOHIDE=1 step 4-search-again 1 "tap $SEARCH" 2
fi
if want 5; then
	echo "== 5 type, Return, the results page"
	step 5-search 1 "tap $SEARCH"
	NOHIDE=1 KEYS="lang en;tap d;tap o;tap t;tap a;tap enter" WHY='no field has the focus|the field lost the focus' step 5-type-enter 0 "sleep 10" 3
	NOHIDE=1 step 5-inpage-field 1 "tap $INPAGE" 2
	NOHIDE=1 step 5-band-kbup 0 "tap $BAND" 2
	NOHIDE=1 step 5-inpage-again 1 "tap $INPAGE" 2
fi
if want 6; then
	echo "== 6 Steam behind another window"
	step 6-search 1 "tap $SEARCH"
	a=$(behind)
	if [ -z "$a" ] || [ "$a" = steam ]; then
		echo "   skipped: no other window to put behind Steam (active: ${a:-none})"
	else
		echo "   active: $a, Steam raised over it"
		step 6-activate-header 0 "tap $NAV" 2
		step 6-search-again 1 "tap $SEARCH"
		behind >/dev/null; step 6-activate-search 1 "tap $SEARCH" 2
	fi
	steam
fi
if want 7; then
	echo "== 7 a key, then at once a tap off the box"
	step 7-search 1 "tap $SEARCH"
	NOHIDE=1 KEYS="lang en;tap x;tap del" THEN="tap $NAV" WHY='no field has the focus' step 7-key-then-header 0 "sleep 10" 2
fi
if want 8 || want 9; then
	if [ -z "$(probe)" ]; then echo "   skipped 8, 9: no probe Chrome (probe-chrome.sh start)"; CASES=" "; fi
	steam
fi
if want 8; then
	echo "== 8 the box keeps the focus while Chrome is used; a tap there minimizes Chrome"
	step 8-search 1 "tap $SEARCH"
	probe >/dev/null
	DO="sleep 0.15; minimize_probe" WHY='closed or minimized since' step 8-tap-then-minimize 0 "tap $PPAD" 2.5
	steam; NOHIDE=1 step 8-blur 0 "tap $NAV" 2
fi
if want 9; then
	echo "== 9 keyboard up for Chrome, a slow press on Steam's box"
	step 9-blur-steam 0 "tap $NAV" 2
	probe >/dev/null; KEPT=1 step 9-probe-field 1 "tap $PFIELD" 2
	NOHIDE=1 MID=0.42 step 9-slow-press-steam 1 "down $SEARCH;sleep 450;up" 2
	NOHIDE=1 step 9-blur 0 "tap $NAV" 2
fi
"${U[@]}" /usr/local/bin/y700-osk hide >/dev/null 2>&1
echo "== $pass passed, $fail failed"
