#!/bin/sh
# ts-bed.sh BUILD SCENARIO OUT: run the task-switcher effect in BUILD (contents/ + metadata.json, what
# taskswitcher/install.sh builds) in a throwaway headless KWin, play SCENARIO in it and leave screenshots
# and the KWin log in OUT. Nothing touches the real session: virtual 1600x1002 output, its own D-Bus,
# config, data and runtime dirs (like taskswitcher/smoke.sh), so it can run while the owner uses the tablet.
#
# SCENARIO is sourced by sh inside the test session with these helpers:
#   app NAME COLOR [CLASS] [--fullscreen|--small|--refuse-close|--tray]   start a test window (ts-app.py) and
#                            wait for it; $! after it is the window's pid
#   touch <<EOF ... EOF     fake touch / keys (ftouch, see ftouch/ftouch.c for the script language)
#   shortcut                 the y700-taskswitcher global shortcut (as the G9 pad's home double tap)
#   shot NAME                screenshot of the whole screen to OUT/NAME.png
#   eval_js JS               run a KWin script, its print() lines go to the log
#   mark TEXT                a line in the log (to find steps); sleep N works as usual
#   expect TEXT              fail unless the log has a line with TEXT (since the last mark)
# $T/bin also has fake-systemd.py (systemd's StartUnit on this bus, for ts-scenarios/appquit.sh).
# Prints TSBED_OK or TSBED_FAIL ... Run as root (switches to user) or as user.
set -u
BUILD=$(readlink -f "$1"); SCEN=$(readlink -f "$2"); OUT=$(readlink -m "$3"); U=user
HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$BUILD/contents/ui/main.qml" ] || { echo "TSBED_FAIL: $BUILD/contents/ui/main.qml missing"; exit 1; }
mkdir -p "$OUT"; rm -f "$OUT"/*.png "$OUT"/log
T=$(mktemp -d /tmp/y700-tsbed-XXXXXX)
mkdir -p "$T/config" "$T/data/kwin/effects" "$T/run" "$T/bin"
cp -r "$BUILD" "$T/data/kwin/effects/y700-taskswitcher"
# as the real session (taskswitcher/install.sh): y700-home gives up the bottom edge. It lives in user's
# ~/.local/share/kwin/scripts, which XDG_DATA_DIRS below leaves out, so today it does not load here (no
# "y700-home:" lines in the log). Once it loads (as in linux/dock/tests/sb-bed.sh) its own edge minimizes the app
# on a short swipe ("y700-home: minimized ...") before the task switcher sees it: tried 10-22, flow, gestures
# and device fail without this line.
printf '[Plugins]\ny700-taskswitcherEnabled=true\n\n[Script-y700-home]\nBottomEdge=false\n' > "$T/config/kwinrc"
printf '[General]\nnavigationPanelEnabled=false\nconvergenceModeEnabled=true\n' > "$T/config/plasmamobilerc"
# the fake finger, built here each time (a few ms) so it always matches the installed libwayland
( cd "$HERE/ftouch" && wayland-scanner client-header fake-input.xml "$T/bin/fake-input.h" \
  && wayland-scanner private-code fake-input.xml "$T/bin/fake-input.c" \
  && cc -O2 -I"$T/bin" -o "$T/bin/ftouch" ftouch.c "$T/bin/fake-input.c" -lwayland-client -lm ) \
  || { echo "TSBED_FAIL: could not build ftouch"; rm -rf "$T"; exit 1; }
cp "$HERE/ts-app.py" "$HERE/fake-systemd.py" "$T/bin/"
cp "$SCEN" "$T/scenario.sh"     # the test user may not be able to read the checkout
chmod 700 "$T/run"
cat > "$T/inner.sh" <<'EOF'
set -u
T=$1; SCEN=$2; OUT=$3; SOCK=y700-tsbed-$$
# TSBED_SCALE=1.9: the tablet's own output, 3040x1904 device px at scale 1.9 (= 1600x1002 logical, set with
# kscreen-doctor once KWin is up: the virtual backend's --scale leaves the logical size at --width x --height)
S=${TSBED_SCALE:-1}
case "$S" in
    1) GEO="--width 1600 --height 1002" ;;
    *) GEO="--width 3040 --height 1904" ;;
esac
LOG=$OUT/log
KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1 \
    kwin_wayland --virtual --no-lockscreen $GEO --socket $SOCK >> "$LOG" 2>&1 &
KPID=$!
echo $KPID > "$T/kwin.pid"
# whatever ends this shell (a scenario tripping set -u did, 10-21: the test KWin lived on for 30 min)
trap 'kill $KPID 2>/dev/null; pkill -P $$ 2>/dev/null' EXIT
i=0
while ! grep -q 'y700-taskswitcher: bottom edge' "$LOG"; do
    i=$((i + 1)); [ $i -gt 80 ] && { echo "TSBED_FAIL: effect not up within 20 s"; kill $KPID; exit 1; }
    kill -0 $KPID 2>/dev/null || { echo "TSBED_FAIL: test KWin exited"; exit 1; }
    sleep 0.25
done
export WAYLAND_DISPLAY=$SOCK GDK_BACKEND=wayland QT_QPA_PLATFORM=wayland
if [ "$S" != 1 ]; then
    kscreen-doctor output.Virtual-0.scale.$S >> "$LOG" 2>&1 || echo "TSBED_SCALE_FAIL $S" >> "$LOG"
    sleep 1
fi
FAIL=0; MARK=0
mark() { echo "TSBED-MARK $*" >> "$LOG"; MARK=$(wc -l < "$LOG"); }
expect() {
    tail -n +$((MARK + 1)) "$LOG" | grep -qF -- "$*" || { echo "TSBED_EXPECT_FAIL: $*"; FAIL=1; }
}
app() {
    python3 "$T/bin/ts-app.py" "$@" >/dev/null 2>&1 &
    sleep 1.5
}
touch() { "$T/bin/ftouch"; }
shortcut() { qdbus6 org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component.invokeShortcut y700-taskswitcher >/dev/null 2>&1 || echo "shortcut call failed" >> "$LOG"; }
shot() { spectacle -b -n -f -o "$OUT/$1.png" >/dev/null 2>&1 || echo "TSBED_SHOT_FAIL $1"; }
eval_js() {
    f=$T/run/eval-$$.js; printf '%s\n' "$*" > "$f"
    id=$(qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$f" "tsbed-$$-$(date +%s%N)" 2>/dev/null)
    [ -n "$id" ] && qdbus6 org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null 2>&1
    sleep 0.3
}
. "$SCEN"
sleep 0.5
kill -0 $KPID 2>/dev/null || { echo "TSBED_FAIL: test KWin died during the scenario"; FAIL=1; }
kill $KPID 2>/dev/null; sleep 0.5; pkill -P $$ 2>/dev/null
exit $FAIL
EOF
[ "$(id -u)" = 0 ] && chown -R $U:$U "$T" "$OUT"
as_user() { if [ "$(id -u)" = 0 ]; then sudo -u $U "$@"; else "$@"; fi; }
as_user env -i HOME=/home/$U PATH=/usr/bin:/bin LANG=C.UTF-8 XDG_RUNTIME_DIR="$T/run" \
    XDG_CONFIG_HOME="$T/config" XDG_DATA_HOME="$T/data" XDG_DATA_DIRS=/usr/local/share:/usr/share KDE_DEBUG=1 \
    TSBED_SCALE="${TSBED_SCALE:-1}" timeout 180 dbus-run-session -- sh "$T/inner.sh" "$T" "$T/scenario.sh" "$OUT"
rc=$?
# belt and braces: the test KWin must not outlive the run (timeout, killed shell, ...)
if [ -f "$T/kwin.pid" ]; then
    kp=$(cat "$T/kwin.pid")
    if kill -0 "$kp" 2>/dev/null && grep -q 'y700-tsbed-' /proc/"$kp"/cmdline 2>/dev/null; then
        kill "$kp"; sleep 1; kill -9 "$kp" 2>/dev/null
        echo "ts-bed: test KWin $kp was still running, killed" >> "$OUT/log"
    fi
fi
err=$(grep -E 'y700-taskswitcher/contents/ui/[A-Za-z]+\.(qml|js):[0-9]+' "$OUT/log" | grep -vE 'y700-taskswitcher: ' | head -5)
if [ -n "$err" ]; then echo "TSBED_FAIL: QML messages:"; echo "$err" | sed 's/^/  | /'; rc=1; fi
rm -rf "$T"
[ $rc = 0 ] && echo "TSBED_OK $OUT" || echo "TSBED_FAIL (rc $rc), log: $OUT/log"
exit $rc
