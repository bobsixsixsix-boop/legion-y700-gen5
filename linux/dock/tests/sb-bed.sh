#!/bin/sh
# sb-bed.sh SCENARIO OUT: the status bar / dock (y700-shellbar) in a throwaway headless KWin, 1600x1002 like the
# tablet (SB_SIZE=WxH for another size, say 1002x1600 = the tablet upright; the scenario reads it as SB_W / SB_H),
# with a wallpaper (sb-wall.py), the control centre and the installed task switcher effect (so the B+ hook
# runs as the next login will run it). Plays SCENARIO and leaves screenshots, the KWin log and the shellbar log in
# OUT. Nothing touches the real session (own D-Bus, config, data and runtime dirs), so it can run while the tablet
# is in use. Built after linux/gesture/tests/ts-bed.sh; SCENARIO gets the same helpers:
#   app NAME COLOR [CLASS] [--fullscreen|--small]   a test window (ts-app.py)
#   touch <<EOF ... EOF    fake touch (ftouch: d/m/u, swipe X0 Y0 X1 Y1 MS [HOLD], s MS)
#   tap X Y / pull X Y0 Y1 MS   a tap / a pull down on a client surface (see the note at tap() why not touch)
#   shot NAME              screenshot to OUT/NAME.png        mark TEXT / expect TEXT   as in ts-bed.sh
#   reject TEXT            TEXT must NOT be in the KWin log since the mark
#   sbexpect / sbreject TEXT   the same in the shellbar's log (reveal, hideDock, onDesktop ... lines)
#   sbcall METHOD          call fyi.y700.Shellbar METHOD (reveal, hideDock)
#   eval_js JS / wins      a KWin script (print() goes to the log) / list every window into the log
#   notify SUMMARY [BODY] [APP]   a notification (notify-send) to y700-shellbar's own notification server (phase 2,
#                          10-22: it owns org.freedesktop.Notifications on the bed's bus; a banner comes up, and the
#                          control centre's notification centre watches the same server)
# fake-sni.py (10-23, tray.sh: a StatusNotifierWatcher and fake tray items on the bed's bus) is copied along into
# $T/bin when it is there, not started: a scenario starts it itself (python3 "$T/bin/fake-sni.py" >> "$LOG" 2>&1 &)
# fake-osk.py (10-30, kbtile.sh: the keyboard's D-Bus name on the bed's bus) likewise. A scenario that taps the 「键盘」
# tile must start it first: the bed's XDG_DATA_DIRS reach ~user/.local/share, so a call to the keyboard's name with
# nobody owning it would start the real y700-osk inside the bed (D-Bus activation)
# kbzone.py (11-09, stagestrip.sh: a bottom band with a layer-shell exclusive zone, as the docked keyboard reserves)
# likewise; it needs LD_PRELOAD=libgtk4-layer-shell.so.0
# SB_BAR=PATH: another build of y700-shellbar (its QML comes from its prefix: cmake -DCMAKE_INSTALL_PREFIX=/opt/y700-next),
# so a new bar is tried here before the live one is replaced.
# SB_CC=PATH: another build of y700-control-center (say one installed with -DCMAKE_INSTALL_PREFIX=/opt/y700-next;
# its QML comes from that prefix), so a new control centre is tried here before the live one is replaced.
# Y700_BATTERY_REPORT=FILE (10-30, batpage.sh): a canned report the battery page shows instead of running the real
# one, passed to the scenario and so to the control centre and the page its battery pill opens (see env -i below).
# Do not tap app icons in a scenario: y700-shellbar starts apps in the REAL user manager (systemd-run --user).
# Prints SBBED_OK or SBBED_FAIL. Run as root (switches to user).
set -u
SCEN=$(readlink -f "$1"); OUT=$(readlink -m "$2"); U=user
HERE=$(cd "$(dirname "$0")" && pwd)
GT=${GESTURE_SRC:-/usr/local/src/y700-gesture}
FX=${SB_FX:-/home/$U/.local/share/kwin/effects/y700-taskswitcher}   # SB_FX: another build of the effect
WALL=${SB_WALL:-/usr/share/wallpapers/Next/contents/images/5120x2880.png}
CC=${SB_CC:-/usr/local/bin/y700-control-center}
BAR=${SB_BAR:-/usr/local/bin/y700-shellbar}
[ -x "$BAR" ] || { echo "SBBED_FAIL: $BAR not installed"; exit 1; }
SIZE=${SB_SIZE:-1600x1002}
case $SIZE in
    [1-9]*x[1-9]*) case $SIZE in *[!0-9x]* | *x*x*) SIZE=bad ;; esac ;;
    *) SIZE=bad ;;
esac
[ "$SIZE" != bad ] || { echo "SBBED_FAIL: SB_SIZE=${SB_SIZE:-} is not WxH"; exit 1; }
SBW=${SIZE%x*}; SBH=${SIZE#*x}
mkdir -p "$OUT"; rm -f "$OUT"/*.png "$OUT"/log "$OUT"/shellbar.log
T=$(mktemp -d /tmp/y700-sbbed-XXXXXX)
mkdir -p "$T/config" "$T/data/kwin/effects" "$T/run" "$T/bin" "$T/cache" "$T/state"
# XDG_CACHE_HOME / XDG_STATE_HOME are the bed's own (10-30, the battery page): a page the scenario or the control
# centre's battery pill opens (batpage.sh, battcap.sh c4-c6) must neither read the owner's ledger
# (~/.local/state/y700-battery) nor write its last.json into the owner's cache. Every other entry of the owner's
# cache and state is linked in, so what the bed's programs found there before (the shellbar's and the control
# centre's QML caches, Mesa's shader cache, KDE's state files) is as warm as before: a cold shader cache would change
# the first frames dock-glass.sh measures. Only y700-battery stays out, both ways.
for d in cache:.cache state:.local/state; do
    for e in "/home/$U/${d#*:}"/* "/home/$U/${d#*:}"/.[!.]* "/home/$U/${d#*:}"/..?*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        [ "${e##*/}" = y700-battery ] || ln -s "$e" "$T/${d%%:*}/"
    done
done
[ -f "$FX/contents/ui/main.qml" ] && cp -r "$FX" "$T/data/kwin/effects/y700-taskswitcher"
# as the real session (taskswitcher/install.sh): y700-home (installed system-wide, so it loads here too) gives up
# the bottom edge. Without this its own edge minimizes the app on a short swipe before the task switcher sees it.
# KWin's blur as the real session has it ([Effect-blur] BlurStrength 12 / NoiseStrength 4, README「控制中心」10-22
# 01:41): without it the bed blurred at KWin's default strength, and the dock glass calibrated against that bed
# dock came out far lighter than the real one (10-22 13:10: a light blur turning into the heavy one)
blur=$(awk '/^\[Effect-blur\]/{p=1; print; next} /^\[/{p=0} p && /^[A-Za-z]+=/' /home/$U/.config/kwinrc 2>/dev/null)
[ -n "$blur" ] || blur=$(printf '[Effect-blur]\nBlurStrength=12\nNoiseStrength=4')
printf '[Plugins]\ny700-taskswitcherEnabled=true\nblurEnabled=true\n\n%s\n\n[Script-y700-home]\nBottomEdge=false\n' "$blur" > "$T/config/kwinrc"
printf '[General]\nnavigationPanelEnabled=false\nconvergenceModeEnabled=true\n' > "$T/config/plasmamobilerc"
( cd "$GT/tests/ftouch" && wayland-scanner client-header fake-input.xml "$T/bin/fake-input.h" \
  && wayland-scanner private-code fake-input.xml "$T/bin/fake-input.c" \
  && cc -O2 -I"$T/bin" -o "$T/bin/ftouch" ftouch.c "$T/bin/fake-input.c" -lwayland-client -lm ) \
  || { echo "SBBED_FAIL: could not build ftouch"; rm -rf "$T"; exit 1; }
cp "$GT/tests/ts-app.py" "$HERE/sb-wall.py" "$HERE/sb-notifyd.py" "$T/bin/"
[ -f "$HERE/fake-sni.py" ] && cp "$HERE/fake-sni.py" "$T/bin/"
[ -f "$HERE/fake-osk.py" ] && cp "$HERE/fake-osk.py" "$T/bin/"
[ -f "$HERE/kbzone.py" ] && cp "$HERE/kbzone.py" "$T/bin/"
cp "$SCEN" "$T/scenario.sh"
cp "$WALL" "$T/wall.png"
chmod 700 "$T/run"
cat > "$T/inner.sh" <<'IN'
set -u
T=$1; OUT=$2; CC=$3; BAR=$4; SB_W=${5:-1600}; SB_H=${6:-1002}; SOCK=y700-sbbed-$$; LOG=$OUT/log
KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1 \
    kwin_wayland --virtual --no-lockscreen --width $SB_W --height $SB_H --socket $SOCK >> "$LOG" 2>&1 &
KPID=$!
echo $KPID > "$T/kwin.pid"
trap 'kill $KPID 2>/dev/null; pkill -P $$ 2>/dev/null' EXIT
i=0
while [ ! -S "$XDG_RUNTIME_DIR/$SOCK" ]; do
    i=$((i + 1)); [ $i -gt 80 ] && { echo "SBBED_FAIL: KWin not up within 20 s"; exit 1; }
    kill -0 $KPID 2>/dev/null || { echo "SBBED_FAIL: test KWin exited"; exit 1; }
    sleep 0.25
done
sleep 1.5
export WAYLAND_DISPLAY=$SOCK GDK_BACKEND=wayland QT_QPA_PLATFORM=wayland
LD_PRELOAD=libgtk4-layer-shell.so python3 "$T/bin/sb-wall.py" "$T/wall.png" >> "$LOG" 2>&1 &
# the shellbar first: it is the notification server the control centre's notification centre registers with.
# sb-notifyd.py (the stand-in server of 10-22, before the shellbar had one) is copied along but not started: a
# scenario that wants it instead starts it itself, before the shellbar is up, and must not expect banners
"$BAR" >> "$OUT/shellbar.log" 2>&1 &
sleep 1
"$CC" >> "$LOG" 2>&1 &
sleep 3
FAIL=0; MARK=0; SBMARK=0; SBLOG=$OUT/shellbar.log
mark() { echo "SBBED-MARK $*" >> "$LOG"; MARK=$(wc -l < "$LOG"); SBMARK=$(wc -l < "$SBLOG"); }
# expect / reject: TEXT in the KWin log since the last mark (wins lines land there too) / not in it;
# sbexpect / sbreject: the same in y700-shellbar's own log (its shell.log() lines: reveal, hideDock, ...)
since() { tail -n +$(($2 + 1)) "$1" | grep -qF -- "$3"; }
expect() { since "$LOG" $MARK "$*" || { echo "SBBED_EXPECT_FAIL: $*"; FAIL=1; }; }
reject() { since "$LOG" $MARK "$*" && { echo "SBBED_REJECT_FAIL: $*"; FAIL=1; }; true; }
sbexpect() { since "$SBLOG" $SBMARK "$*" || { echo "SBBED_EXPECT_FAIL (shellbar): $*"; FAIL=1; }; }
sbreject() { since "$SBLOG" $SBMARK "$*" && { echo "SBBED_REJECT_FAIL (shellbar): $*"; FAIL=1; }; true; }
app() { python3 "$T/bin/ts-app.py" "$@" >> "$LOG" 2>&1 & sleep 1.5; }
touch() { "$T/bin/ftouch"; }
# A client misses the first touch of a fresh ftouch: the fake device (and the seat's touch capability) only appears
# with its first down, and the client binds wl_touch after that down went out (WAYLAND_DEBUG: motion and up arrive,
# down never). So a second finger goes down first on a harmless spot (HOLD_AT, the wallpaper or the app's middle)
# and stays down until the real one is up. Not for the bottom edge: the task switcher wants one finger.
# Over the control centre's full-screen curtain that finger is itself a tap on the empty curtain (which closes
# it): set HOLD_AT to a spot off the panes and HOLD_MS long (1000), so it is a long press there, not a tap.
HOLD_AT=${HOLD_AT:-300 560}
HOLD_MS=${HOLD_MS:-150}
tap() { printf 'd 1 %s\ns %s\nd 0 %s %s\ns 70\nu 0\ns 30\nu 1\n' "$HOLD_AT" "$HOLD_MS" "$1" "$2" | "$T/bin/ftouch"; }
# pull X Y0 Y1 MS: one finger from (X,Y0) straight down to (X,Y1) in MS
pull() { printf 'd 1 %s\ns %s\nswipe %s %s %s %s %s\ns 30\nu 1\n' "$HOLD_AT" "$HOLD_MS" "$1" "$2" "$1" "$3" "$4" | "$T/bin/ftouch"; }
# swipe X0 Y0 X1 Y1 MS: one finger in a straight line
swipe() { printf 'd 1 %s\ns %s\nswipe %s %s %s %s %s\ns 30\nu 1\n' "$HOLD_AT" "$HOLD_MS" "$1" "$2" "$3" "$4" "$5" | "$T/bin/ftouch"; }
notify() { notify-send -a "${3:-测试}" "$1" "${2:-}" >> "$LOG" 2>&1; sleep 0.3; }
shot() { spectacle -b -n -f -o "$OUT/$1.png" >/dev/null 2>&1 || echo "SBBED_SHOT_FAIL $1"; }
eval_js() {
    f=$T/run/eval-$$.js; printf '%s\n' "$*" > "$f"
    id=$(qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$f" "sbbed-$$-$(date +%s%N)" 2>/dev/null)
    [ -n "$id" ] && qdbus6 org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null 2>&1
    sleep 0.3
}
# every window KWin has, bottom to top: class, caption, geometry, flags (into the log)
wins() { eval_js 'print("sbbed wins: " + workspace.stackingOrder.map(w => w.resourceClass + "/" + w.caption + "@" + Math.round(w.x) + "," + Math.round(w.y) + "+" + Math.round(w.width) + "x" + Math.round(w.height) + (w.minimized ? " MIN" : "") + (w.hidden ? " HID" : "") + (w.active ? " ACT" : "")).join(" | "))'; }
sbcall() { busctl --user call fyi.y700.Shellbar /Shellbar fyi.y700.Shellbar "$1" >/dev/null 2>&1 || echo "sbcall $1 failed" >> "$LOG"; }
. "$T/scenario.sh"
sleep 0.5
kill -0 $KPID 2>/dev/null || { echo "SBBED_FAIL: test KWin died during the scenario"; FAIL=1; }
exit $FAIL
IN
chown -R $U:$U "$T" "$OUT"
# env -i: the scenario sees nothing of the caller's environment but what is listed. GLASS_FRAMES / CAPSEQ are
# dock-glass.sh's knobs (empty = its defaults); a new scenario knob goes here too, or it is silently dead.
# SB_STAGE (11-09, stagestrip.sh): a checkout of the stage script to run instead of the installed one.
# SB_SPLIT (11-10, splittile.sh): a checkout of the split screen script (linux/split/y700-split) for the bed's KWin.
# Y700_BATTERY_REPORT (batpage-run.sh): the control centre inherits it, so the page its pill opens (batpage.sh p8)
# reads the canned report too instead of running the real one against the bed. Passed only when set and not empty:
# an empty one would still be "set" to the page (fixture mode on a file named ""). XDG_CACHE_HOME / XDG_STATE_HOME:
# see above
sudo -u $U env -i HOME=/home/$U PATH=/usr/bin:/bin LANG=zh_CN.UTF-8 XDG_RUNTIME_DIR="$T/run" \
    XDG_CONFIG_HOME="$T/config" XDG_DATA_HOME="$T/data" GLASS_FRAMES="${GLASS_FRAMES:-}" CAPSEQ="${CAPSEQ:-}" \
    SB_STAGE="${SB_STAGE:-}" SB_SPLIT="${SB_SPLIT:-}" \
    XDG_CACHE_HOME="$T/cache" XDG_STATE_HOME="$T/state" \
    ${Y700_BATTERY_REPORT:+"Y700_BATTERY_REPORT=$Y700_BATTERY_REPORT"} \
    XDG_DATA_DIRS=/home/$U/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share:/home/$U/.local/share \
    timeout 180 dbus-run-session -- sh "$T/inner.sh" "$T" "$OUT" "$CC" "$BAR" "$SBW" "$SBH"
rc=$?
if [ -f "$T/kwin.pid" ]; then
    kp=$(cat "$T/kwin.pid")
    if kill -0 "$kp" 2>/dev/null && grep -q 'y700-sbbed-' /proc/"$kp"/cmdline 2>/dev/null; then
        kill "$kp"; sleep 1; kill -9 "$kp" 2>/dev/null
        echo "sb-bed: test KWin $kp was still running, killed" >> "$OUT/log"
    fi
fi
err=$( (grep -E 'y700-shellbar/qml/[A-Za-z]+\.qml:[0-9]+' "$OUT/shellbar.log";        grep -E 'y700-control-center/qml/[A-Za-z]+\.qml:[0-9]+' "$OUT/log") | head -8)
if [ -n "$err" ]; then echo "SBBED_FAIL: QML messages:"; echo "$err" | sed 's/^/  | /'; rc=1; fi
rm -rf "$T"
[ $rc = 0 ] && echo "SBBED_OK $OUT" || echo "SBBED_FAIL (rc $rc), log: $OUT/log"
exit $rc
