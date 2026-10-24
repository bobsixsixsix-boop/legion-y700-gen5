#!/bin/sh
# blur-trace.sh [BIN] [OUT]: run a build of the control centre on the LIVE session with its blur trace on
# (Y700_CC_TRACE=1: one stderr line per blur hand-over / frame callback / surface change, plus Qt's
# qt.qpa.wayland.backingstore debug log, which shows every UpdateRequest and its "called twice" path), put
# tests/blur-flicker.sh through it, then put the installed service back. Root; takes the screen for about 5 s like
# blur-flicker.sh does (do not run it while the owner is using the tablet). README「下拉模糊闪烁」says how to read it.
#   BIN  the binary to run; default the "next" tree /opt/y700-next/bin/y700-control-center, built without touching
#        /usr/local:  cd /usr/local/src/y700-control-center && cmake -S . -B build-next -DCMAKE_BUILD_TYPE=Release
#        -DCMAKE_INSTALL_PREFIX=/opt/y700-next && cmake --build build-next -j8 && cmake --install build-next
#   OUT  blur-flicker.sh's frames and sheet.png, plus trace.log; default /home/user/cc-blur-trace
# QSG_RENDER_LOOP=basic in the environment runs the build with Qt Quick's basic render loop (the comparison of 10-22).
set -u
U=user
BIN=${1:-/opt/y700-next/bin/y700-control-center}
OUT=${2:-/home/$U/cc-blur-trace}
LOG=$OUT/trace.log
TESTS=$(cd "$(dirname "$0")" && pwd)
RUN="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 HOME=/home/$U"
[ -x "$BIN" ] || { echo "blur-trace.sh: $BIN is not there"; exit 2; }
mkdir -p "$OUT"
$RUN systemctl --user stop y700-control-center.service
sleep 0.5
$RUN env Y700_CC_TRACE=1 ${QSG_RENDER_LOOP:+QSG_RENDER_LOOP=$QSG_RENDER_LOOP} QT_LOGGING_RULES='qt.qpa.wayland.backingstore.debug=true' \
    setsid "$BIN" > "$LOG" 2>&1 &
sleep 2
$RUN busctl --user status fyi.y700.ControlCenter >/dev/null 2>&1 || { echo "blur-trace.sh: $BIN did not come up on the bus:"; tail -5 "$LOG"; }
sh "$TESTS/blur-flicker.sh" "$OUT"; rc=$?
sleep 0.5
# anchored: a bare `pkill -f "$BIN"` also matches this script's own command line when BIN was passed as an argument
# (and the ssh shell that ran it), killing both before the service is put back (10-22, it happened)
pkill -f "^$BIN"; sleep 0.6
$RUN systemctl --user start y700-control-center.service
chown -R $U:$U "$OUT"
echo "=== trace: applies=$(grep -c 'cc-trace apply' "$LOG") done=$(grep -c 'cc-trace done' "$LOG") surface=$(grep -c 'cc-trace surface' "$LOG") update_requests=$(grep -c 'deliverUpdateRequest' "$LOG") called_twice=$(grep -c 'called twice' "$LOG")"
# frames swapped between consecutive hand-overs. [0] = two in one frame: Qt's second UpdateRequest while the hand-over
# was the GUI thread's (until 10-23); since it is in beforeSynchronizing only the first one, counted from the start, is 0
awk '/cc-trace/ { split($3,a,"="); acc += a[2]; if ($2=="apply") { n++; h[acc]++; acc=0 } } END { printf "    swaps between hand-overs:"; for (k in h) printf " [%s]x%d", k, h[k]; print "" }' "$LOG"
echo "=== the first hand-overs (show) and the ones around the finger's release:"
grep -n 'cc-trace' "$LOG" | head -8
grep -n 'cc-trace' "$LOG" | grep -B2 -A8 'pullEnd' | head -24
exit $rc
