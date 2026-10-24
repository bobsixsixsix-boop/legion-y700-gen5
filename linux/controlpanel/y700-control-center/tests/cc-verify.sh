#!/bin/bash
# On the tablet, as root: install the control centre from /tmp/ccsrc (a copy of this directory) and check it:
# services, back key (D-Bus + both side edges), the pull-downs from the top edge (right half = the controls, left
# half = the notification centre) and the ways to close the curtain. MOVES THE SCREEN (virtual touchscreen,
# ~40 s): only while the owner is not using the tablet (kscreen-doctor --dpms show: off), and with the screen on
# while it runs (kscreen-doctor --dpms on first; a dark screen fakes failures).
#   scp -r linux/controlpanel/y700-control-center/. root@tablet:/tmp/ccsrc && ssh root@tablet bash /tmp/ccsrc/tests/cc-verify.sh
#   bash cc-verify.sh --no-install       checks only
# Needs /usr/local/libexec/kwin-eval.sh (linux/osk/tests) and y700-vtouch.py (linux/gesture/tests). Ends "N FAILED".
# The pull strip along the top edge is y700-shellbar's (linux/dock, phase 3 of 10-22) when that service is
# enabled, else the old y700-cc-pull's; both deployments are tested the same way (STRIP, strip()).
set -u
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
EVAL=/usr/local/libexec/kwin-eval.sh
FIFO=/run/y700-vtouch.fifo
SRC=/usr/local/src/y700-control-center
# runs as user: copy it out (a directory scp'd from Windows arrives as 0700 root)
KEYLOG=/tmp/y700-keylog.py; install -m 644 "$(dirname "$0")/keylog.py" $KEYLOG
fails=0
ok() { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

if [ "${1:-}" != --no-install ]; then
        rm -rf $SRC/src $SRC/qml $SRC/kwin-script $SRC/protocol $SRC/build
    cp -r /tmp/ccsrc/. $SRC/
    find $SRC -path $SRC/build -prune -o -type f -exec sed -i 's/\r$//' {} +
    sh $SRC/install.sh 2>&1 | grep -vE 'deprecated|useLayerShell|^\s|^In file|note:' | tail -5
    sleep 2
fi
check "control centre running" '"${U[@]}" systemctl --user is-active -q y700-control-center'
# the strip: since phase 3 (10-22) the 8 px band along the top edge is y700-shellbar's and y700-cc-pull is disabled
# by design (two strips would forward every pull twice); a deployment without shellbar still runs y700-cc-pull
if [ "$("${U[@]}" systemctl --user is-enabled y700-shellbar 2>/dev/null)" = enabled ]; then STRIP=y700-shellbar; else STRIP=y700-cc-pull; fi
if [ $STRIP = y700-shellbar ]; then
    check "pull strip running (y700-shellbar active, y700-cc-pull off)" '"${U[@]}" systemctl --user is-active -q y700-shellbar && ! "${U[@]}" systemctl --user is-active -q y700-cc-pull'
else
    check "pull strip running (y700-cc-pull)" '"${U[@]}" systemctl --user is-active -q y700-cc-pull'
fi
check "y700-edge loaded" '"${U[@]}" busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting isScriptLoaded s y700-edge | grep -q true'
# kwin-eval reads print() back from the journal; under load a reading can come back empty: retry
ev() { local r i; for i in 1 2 3 4; do r=$(bash $EVAL); [ -n "$r" ] && { echo "$r"; return; }; sleep 0.5; done; }
evs() { local js=$1 r i; for i in 1 2 3 4; do r=$(echo "$js" | bash $EVAL); [ -n "$r" ] && { echo "$r"; return; }; sleep 0.5; done; }
mapped() { evs 'out(workspace.windowList().filter(function(w){return w.resourceClass=="'"$1"'" && !w.deleted;}).length)'; }
# the strip's window. y700-shellbar's five layer-shell windows all have resourceClass y700-shellbar and no caption
# (KWin gives a layer-shell surface none), so the strip is told by its place: the one along the top edge 8 px high
# (qml/Main.qml stripWin, overlay layer; the status bar under it is 28 px, the dock sits at the bottom, the banners
# and the app grid are taller). It is mapped whenever the curtain is not: `visible: root.ready && !shell.ccOpen`,
# ccOpen following the control centre's openChanged signal - as y700-cc-pull unmapped itself while open.
strip() {
    if [ $STRIP = y700-shellbar ]; then
        evs 'out(workspace.windowList().filter(function(w){return !w.deleted && w.resourceClass=="y700-shellbar" && w.frameGeometry.y==0 && w.frameGeometry.height==8;}).length)'
    else
        mapped y700-cc-pull
    fi
}
check "strip mapped, sheet not" '[ "$(strip)" = 1 ] && [ "$(mapped y700-control-center)" = 0 ]'

# a window that logs keys, active
rm -f /tmp/y700-keylog.txt; touch /tmp/y700-keylog.txt; chmod 666 /tmp/y700-keylog.txt
systemctl stop y700-keylog 2>/dev/null; systemctl reset-failed y700-keylog 2>/dev/null   # a failed run leaves the name taken
systemd-run -q --uid=user --unit=y700-keylog -E XDG_RUNTIME_DIR=/run/user/1000 -E WAYLAND_DISPLAY=wayland-0 \
    -E GDK_BACKEND=wayland python3 "$KEYLOG"
sleep 2
act() { evs 'var w = workspace.windowList().filter(function(w){return String(w.resourceClass).indexOf("keylog")==0;})[0]; if (w) { workspace.activeWindow = w; } out(workspace.activeWindow ? workspace.activeWindow.resourceClass : "none")'; }
echo "active: $(act)"
last() { sleep 0.6; tail -n 1 /tmp/y700-keylog.txt; }
"${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter back sb keylog false
check "D-Bus back for an app: Escape" '[ "$(last)" = Escape ]'
"${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter back sb google-chrome false
check "D-Bus back for a browser: Alt+Left" '[ "$(last)" = Alt+Left ]'
"${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter back sb google-chrome true
check "D-Bus back for a fullscreen browser: Escape" '[ "$(last)" = Escape ]'

# the real path: the side edges, with the virtual touchscreen
systemctl stop y700-vtouch 2>/dev/null
systemd-run -q --unit=y700-vtouch python3 /usr/local/libexec/y700-vtouch.py --rot r270
sleep 2
send() { echo "$*" > $FIFO; }
echo "active: $(act)"; : > /tmp/y700-keylog.txt
send "drag 1599 500 1300 500 200 12"; sleep 1
check "right edge swipe in: Escape to the app" '[ "$(tail -n 1 /tmp/y700-keylog.txt)" = Escape ]'
: > /tmp/y700-keylog.txt
echo "active before the left swipe: $(act)"
send "drag 0 500 300 500 200 12"; sleep 1
echo "active after: $(evs 'out(workspace.activeWindow ? workspace.activeWindow.resourceClass : "none")')"
check "left edge swipe in: Escape to the app" '[ "$(tail -n 1 /tmp/y700-keylog.txt)" = Escape ]'
: > /tmp/y700-keylog.txt
send "drag 800 500 1100 500 200 12"; sleep 1
check "mid-screen swipe: no key" '[ ! -s /tmp/y700-keylog.txt ]'

# pull-down from the right half: the controls
send "drag 1400 1 1400 700 300 20"; sleep 1
check "pull down from the top right: sheet open" '[ "$(mapped y700-control-center)" = 1 ]'
check "strip unmapped while open" '[ "$(strip)" = 0 ]'
: > /tmp/y700-keylog.txt
send "drag 1599 500 1300 500 200 12"; sleep 1
check "side edge off while the sheet is open (no key)" '[ ! -s /tmp/y700-keylog.txt ]'
send "tap 200 500"; sleep 1
check "tap on the dim: sheet closed" '[ "$(mapped y700-control-center)" = 0 ]'
check "strip back" '[ "$(strip)" = 1 ]'
send "drag 1400 1 1400 80 400 20"; sleep 1.2
check "short slow pull: stays closed" '[ "$(mapped y700-control-center)" = 0 ]'

# pull-down from the left half: the notification centre (10-22). The strip sends pullBeginSide("left") by where
# the finger went down (y700-shellbar main.cpp Puller; y700-cc-pull the same), the control centre shows NotesPane
# on the left (qml/Main.qml `notes: backend.side === "left"`) and leaves the right half empty curtain.
# backend.side is not on D-Bus (only scriptable slots and signals are exported), so the page is read from the
# outside two ways: the strip's journal line for the pull, and a tap on the right half, which closes the curtain
# only when it is empty there (Main.qml: a tap off the pane in use closes). With the controls up (1300, 900) is on
# the ctl pane (x 840-1544, down to y 954; under its last tile row, which ends at 826) and does nothing.
since=$(date '+%Y-%m-%d %H:%M:%S')
send "drag 300 1 300 700 300 20"; sleep 1
check "pull in the left half: sheet open" '[ "$(mapped y700-control-center)" = 1 ]'
if [ $STRIP = y700-shellbar ]; then pulled='^pull left:'; else pulled='^pull:'; fi   # y700-cc-pull logs no side
check "strip logged the pull ($pulled)" '"${U[@]}" journalctl --user -u $STRIP --since "$since" --no-pager -o cat | grep -q "$pulled"'
send "tap 1300 900"; sleep 1
check "tap on the empty right half: notification centre closed" '[ "$(mapped y700-control-center)" = 0 ]'

send "drag 1400 1 1400 250 80 6"; sleep 1
check "short fast flick down: opens" '[ "$(mapped y700-control-center)" = 1 ]'
send "drag 1400 50 1400 0 100 8"; sleep 1
check "header pushed up: closed" '[ "$(mapped y700-control-center)" = 0 ]'
"${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter show; sleep 0.8
send "drag 1430 994 1430 600 250 15"; sleep 1
check "bottom handle dragged up: closed" '[ "$(mapped y700-control-center)" = 0 ]'
"${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter show; sleep 0.8
send "drag 1430 994 1430 975 300 6"; sleep 1
check "bottom handle nudged: stays open" '[ "$(mapped y700-control-center)" = 1 ]'
"${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter hide; sleep 0.8
"${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter toggle; sleep 0.8
check "D-Bus toggle (G9 home key): open" '[ "$(mapped y700-control-center)" = 1 ]'
"${U[@]}" busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter toggle; sleep 0.8
check "D-Bus toggle again: closed" '[ "$(mapped y700-control-center)" = 0 ]'

send quit; sleep 0.5; systemctl stop y700-vtouch 2>/dev/null
systemctl stop y700-keylog 2>/dev/null
echo "--- journal"
"${U[@]}" journalctl --user -b --since '-3min' -u y700-control-center -u y700-cc-pull -u y700-shellbar -u plasma-kwin_wayland --no-pager -o cat | grep -E 'back:|^pull|y700-edge|bottom edge|y700-home|error|Error|qml' | tail -24
echo "$fails FAILED"
