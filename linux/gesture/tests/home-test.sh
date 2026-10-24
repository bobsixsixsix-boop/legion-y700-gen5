#!/bin/bash
# home-test.sh: self-test of the bottom-edge home gesture (y700-home) with the virtual touchscreen.
# VISIBLE on the tablet for about a minute (a Konsole goes fullscreen and gets swiped away): tell the
# owner first. Run as root on the tablet, after linux/gesture/install.sh. Needs from linux/osk/tests:
# vtouch.py and kwin-eval.sh, installed as /usr/local/libexec/y700-vtouch.py and kwin-eval.sh.
#
# vtouch is a uinput touchscreen: its events go through libinput and KWin's input filters exactly like
# the panel's, so this exercises the real edge path (unlike CDP-synthesized gestures). What it cannot
# show: whether the real panel reports the first contact inside the 8 px strip - the owner's finger.
#
# Prints one PASS/FAIL line per case and leaves everything as it was (Konsole closed, vtouch stopped,
# keyboard and control centre hidden, RemainActiveOnFullscreen back to true, the front window active again).
set -u
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
EVAL=/usr/local/libexec/kwin-eval.sh
FIFO=/run/y700-vtouch.fifo
fails=0

# rotation -> vtouch's mapping (kscreen: 1 none, 2 left, 4 inverted, 8 right)
rot=$("${U[@]}" kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '/Rotation:/{print $2; exit}')
case "$rot" in
    8) vrot=r270 ;; 2) vrot=r90 ;; 1) vrot=none ;;
    *) echo "unsupported rotation '$rot' (vtouch.py maps 1/2/8)"; exit 1 ;;
esac
read -r W H < <(echo 'out(workspace.virtualScreenSize.width + " " + workspace.virtualScreenSize.height)' | bash $EVAL)
[ -n "${H:-}" ] || { echo "no screen size from KWin"; exit 1; }
X=$((W / 2)); Y0=$((H - 3))          # 3 px above the bottom: inside KWin's 8 px touch strip
echo "screen ${W}x${H}, rotation $rot -> vtouch --rot $vrot"
# the window the owner had in front ("pid class"), activated again at the end
PREV=$(echo 'const a = workspace.activeWindow; out(a && a.normalWindow ? a.pid + " " + a.resourceClass : "")' | bash $EVAL)

# keep the panel on (KWin's DPMS filter swallows the waking touch)
if grep -q Off /sys/class/drm/card*-DSI-1/dpms 2>/dev/null; then "${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 1.2; fi
"${U[@]}" /usr/local/bin/y700-osk hide >/dev/null 2>&1
"${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter hide >/dev/null 2>&1

systemctl stop y700-vtouch 2>/dev/null
systemd-run --unit y700-vtouch --collect python3 /usr/local/libexec/y700-vtouch.py --rot $vrot >/dev/null
for i in $(seq 20); do [ -p $FIFO ] && break; sleep 0.2; done
"${U[@]}" systemd-run --user --unit y700-hometest-win --collect konsole --separate --nofork >/dev/null
sleep 2.5
PID=$("${U[@]}" systemctl --user show -p MainPID --value y700-hometest-win)

cleanup() {
    echo quit > $FIFO 2>/dev/null; sleep 0.3; systemctl stop y700-vtouch 2>/dev/null
    "${U[@]}" systemctl --user stop y700-hometest-win 2>/dev/null
    "${U[@]}" /usr/local/bin/y700-osk hide >/dev/null 2>&1
    "${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter hide >/dev/null 2>&1
    "${U[@]}" kwriteconfig6 --file kwinrc --group ScreenEdges --key RemainActiveOnFullscreen true
    "${U[@]}" qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1
    [ -z "$PREV" ] || printf 'for (const w of workspace.windowList()) if (w.pid == %s && w.resourceClass == "%s" && w.normalWindow && !w.minimized) { workspace.activeWindow = w; break; }\n' $PREV | bash $EVAL
}
trap cleanup EXIT

win() {   # $1 = JS run with w = the test Konsole
    printf 'for (const w of workspace.windowList()) if (w.pid == %s && w.normalWindow) { %s }\n' "$PID" "$1" | bash $EVAL
}
# bring the Konsole back: shown, active, fullscreen or not
prep() { win "w.minimized = false; w.fullScreen = $1; workspace.activeWindow = w;"; sleep 0.6; }
swipe() { printf '%s\n' "$1" > $FIFO; sleep "${2:-0.8}"; }
check() {   # $1 name, $2 expected minimized true|false
    local got; got=$(win 'out(w.minimized)')
    if [ "$got" = "$2" ]; then echo "PASS  $1"; else echo "FAIL  $1 (minimized=$got, expected $2)"; fails=$((fails + 1)); fi
}
edge() { echo "drag $X $Y0 $X $((Y0 - ${1:-160})) ${2:-220} 12"; }

[ -n "$(win 'out(w.resourceClass)')" ] || { echo "test Konsole not found (pid $PID)"; exit 1; }

prep true;  swipe "$(edge)";                       check "fullscreen window, swipe up from the bottom edge" true
win 'out(w.fullScreen)' | grep -q true && echo "PASS  still fullscreen while minimized (owner: only minimize)" \
    || { echo "FAIL  fullscreen state lost"; fails=$((fails + 1)); }
prep false; swipe "$(edge)";                       check "normal window, swipe up from the bottom edge" true
prep true;  swipe "drag $X $((H - 200)) $X $((H - 400)) 220 12"; check "swipe up starting mid-screen does nothing" false
prep true;  swipe "$(edge 30)";                    check "short swipe (30 px < KWin's 44) does nothing" false

prep true; "${U[@]}" /usr/local/bin/y700-osk show >/dev/null 2>&1; sleep 1
swipe "$(edge)";                                   check "keyboard up: edge is off" false
"${U[@]}" /usr/local/bin/y700-osk hide >/dev/null 2>&1; sleep 1.2
prep true; swipe "$(edge)";                        check "keyboard hidden again: edge is back" true

prep true; "${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter show >/dev/null; sleep 0.8
swipe "$(edge)";                                   check "control centre open: edge is off" false
"${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter hide >/dev/null; sleep 0.8
prep true; swipe "$(edge)";                        check "control centre closed: edge is back" true

# the setting is what makes it work over fullscreen (KWin's Edge::checkBlocking)
"${U[@]}" kwriteconfig6 --file kwinrc --group ScreenEdges --key RemainActiveOnFullscreen false
"${U[@]}" qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1; sleep 0.8
prep true;  swipe "$(edge)";                       check "without RemainActiveOnFullscreen KWin blocks it (control)" false

echo "--- journal"
"${U[@]}" journalctl --user --since "-3min" --no-pager -o cat | grep -F 'y700-home:' | tail -12
[ $fails = 0 ] && echo "ALL PASS" || echo "$fails FAILED"
