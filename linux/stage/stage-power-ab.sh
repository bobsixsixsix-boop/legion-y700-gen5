#!/bin/bash
# stage-power-ab.sh OUT: the stage on/off power comparison on the tablet, done alone (linux/stage README 踩坑 24,
# 「测试」; 11-09). Two test windows in the owner's session: Anim (ts-app.py --frames: draws every frame KWin gives
# it), then Quiet on top, so Anim becomes a card next to the owner's own apps. Then back to back: stage on, off, on
# (as the control centre's tile flips it), each six 10 s chunks of y700-powersample (battery W, CPU busy, panel Hz)
# with Anim's frames, brightness, dpms and /proc/*/stat before and after each chunk. Autobright held, brightness
# fixed. A finger on the screen (NVT-ts) stops it; everything is put back (the window that was active, the screen
# off if it was). Input from other sessions (vtouch, uinput) is not seen: look at OUT/stage-lines for a
# "strip hidden" inside a phase. Root, in a transient unit (no ssh meanwhile); then stage-power-ab.py OUT.
# Only while the screen is off (nobody using it) and on battery, the stage on.
set -u
out=$1; mkdir -p "$out"; L=$out/log; C=$out/chunks
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0)
DPMS=$(ls /sys/class/drm/card*-DSI-1/dpms | head -1); BAT=/sys/class/power_supply/qcom-battmgr-bat
TS=/usr/local/src/y700-gesture/tests/ts-app.py; R=/tmp/y700stself; BL=${BL:-800}
log() { echo "$(date +%T) $*" >> "$L"; }
sb() { "${U[@]}" qdbus6 org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0 org.kde.ScreenBrightness.Display.SetBrightness "$1" 1 >/dev/null 2>&1; }
gb() { "${U[@]}" qdbus6 org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0 org.freedesktop.DBus.Properties.Get org.kde.ScreenBrightness.Display Brightness 2>/dev/null; }
touches() { awk '/NVT-ts/ {s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break; print s; exit}' /proc/interrupts; }
act() { "${U[@]}" kreadconfig6 --file kwinrc --group Script-y700-stage --key Active; }
# the tile's own command (y700-control-center Main.qml)
stage() { "${U[@]}" kwriteconfig6 --file kwinrc --group Script-y700-stage --key Active "$1" && "${U[@]}" busctl --user call org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component invokeShortcut s "y700-stage-$2" >/dev/null; }
js() {
    printf '%s\n' "$*" > $R/e.js; chmod 644 $R/e.js; local n id; n=y700stself-$(date +%s%N)
    id=$("${U[@]}" qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript $R/e.js $n 2>/dev/null)
    [ -n "$id" ] && "${U[@]}" qdbus6 org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null 2>&1
    sleep 0.5; "${U[@]}" qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript $n >/dev/null 2>&1
}
frames() { cat $R/anim.frames 2>/dev/null || echo 0; }
n=0
phase() { # NAME: six 10 s chunks
    local k f0 f1 t0 l
    for k in 1 2 3 4 5 6; do
        n=$((n + 1)); f0=$(frames); t0=$(touches); cat /proc/[0-9]*/stat > "$out/ps.$n.a" 2>/dev/null
        l=$(python3 -I /usr/local/libexec/y700-powersample.py 10 "$1-$k" 2>&1 | tail -1)
        cat /proc/[0-9]*/stat > "$out/ps.$n.b" 2>/dev/null; f1=$(frames)
        echo "$1 $k ps.$n $(date +%T) anim+$((f1 - f0)) bl=$(gb) dpms=$(cat $DPMS) active=$(act) | $l" >> "$C"
        [ "$(touches)" = "$t0" ] || { owner=1; log "the screen was touched in $1-$k: stopping"; exit 1; }
        [ "$(cat $DPMS)" = On ] || { log "the screen went off in $1-$k: stopping"; exit 1; }
    done
}
settle() { # LABEL SECONDS: Anim's frames over a switch's settling time
    local f0; f0=$(frames); sleep "$2"; log "$1: Anim drew $(($(frames) - f0)) frames in $2 s"
}

sleep 15   # the ssh that started this: root's user manager goes ~10 s after it (cx-collapse PROTOCOL.md)
t00=$(date +%s); owner=0; uuid=; act0=$(act)
bl0=$(gb); dpms0=$(cat $DPMS); ab0=$("${U[@]}" systemctl --user is-active y700-autobright.service)
log "start: active $act0, brightness $bl0, dpms $dpms0, autobright $ab0, battery $(cat $BAT/status) $(cat $BAT/capacity)%"
[ "$dpms0" = Off ] || { log "the screen is on (owner using the tablet?): not run"; exit 2; }
grep -q Discharging $BAT/status || { log "not on battery: the W figures would not be the consumption; not run"; exit 2; }
[ "$act0" = true ] || { log "the stage is off: not run"; exit 2; }
[ -r $TS ] && grep -q -- --frames $TS || { log "no ts-app.py with --frames at $TS"; exit 2; }

restore() {
    trap - EXIT
    [ "$(act)" = true ] || { stage true on; sleep 2; }
    # the owner's window back on the stage, then the test windows away (cards by then)
    [ -n "$uuid" ] && js "const w = workspace.windowList().find(x => String(x.internalId) === \"$uuid\"); if (w) { w.minimized = false; workspace.activeWindow = w }"
    sleep 1
    pkill -u user -f '^python3 /usr/local/src/y700-gesture/tests/ts-app\.py (Anim|Quiet) '; sleep 1.5
    [ -n "$bl0" ] && sb "$bl0"
    [ "$ab0" = active ] && "${U[@]}" systemctl --user start y700-autobright.service
    if [ "$owner" -eq 0 ] && [ "$dpms0" = Off ]; then sleep 1; "${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1; sleep 2; fi
    cp $R/anim.frames "$out/" 2>/dev/null; rm -rf $R
    # the stage's own lines (no captions without Debug)
    journalctl --no-hostname _UID=1000 --since "@$t00" -o short | grep -E "y700-stage(corners)?: (strip|on,|off,|loaded|[0-9]+ window)" | cut -c8-200 > "$out/stage-lines"
    log "restored: active $(act) (was $act0), brightness $(gb) (was $bl0), autobright $("${U[@]}" systemctl --user is-active y700-autobright.service) (was $ab0), dpms $(cat $DPMS) (was $dpms0), test windows left $(pgrep -u user -fc '^python3 /usr/local/src/y700-gesture/tests/ts-app\.py '), owner $owner"
    log "done"
}
trap restore EXIT; trap 'exit 1' INT TERM
rm -rf $R; mkdir -p $R; chown user: $R; chmod 755 $R

js 'const a = workspace.activeWindow; print("y700stself active " + (a ? a.internalId + " " + a.resourceClass : "- -"))'
line=$(journalctl --no-hostname _UID=1000 --since "-20s" -o cat | grep -o "y700stself active .*" | tail -1)
uuid=$(echo "$line" | cut -d' ' -f3); [ "$uuid" = - ] && uuid=
log "active window: $(echo "$line" | cut -d' ' -f4) ($([ -n "$uuid" ] && echo id kept || echo none))"

[ "$ab0" = active ] && "${U[@]}" systemctl --user stop y700-autobright.service
"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 3
sb "$BL"; sleep 1
"${U[@]}" python3 $TS Anim '#2c6fd6' --frames $R/anim.frames >/dev/null 2>&1 &
sleep 3; log "Anim on the stage: $(frames) frames in its first 3 s"
"${U[@]}" python3 $TS Quiet '#3a3a3a' >/dev/null 2>&1 &
settle "Quiet up, Anim a card" 8
phase on1
stage false off; settle "off" 8
phase off
stage true on; settle "on again" 8
phase on2
exit 0
