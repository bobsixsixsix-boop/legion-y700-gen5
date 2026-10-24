#!/bin/sh
# real-look.sh STAGE [OUT] [GX GY]: the vivo-style shell on the LIVE session (phase 3, 10-22): screenshots of each
# state into OUT (default /home/user/sb-real), a fake finger through y700-ftouch (the fake_input grant the
# control centre's install.sh puts in place). Run as root; takes the screen for a few seconds, so not while the
# tablet is in use. Turns the screen on if it is off (and leaves it on, for whoever checks the result).
#   1          r3 desktop (status bar + dock), r4 two banners, r5 the top one swiped away
#   2 GX GY    r6 the app grid (GX GY = the all-apps button, read off r3), r7 after a back swipe from the left
#              edge (KWin's edge -> y700-edge -> the control centre's fake Esc to the active window: the grid
#              must be gone), r8 the notification centre (left half pulled over two fresh banners: the pull
#              expires them into the centre), r9 the controls (right half)
#   3 [DX DY [CLASS]]  r10 an app launched from the dock, then closed again. DX DY = its icon (default Dolphin's
#              with nothing but the pinned six in the dock; the dock is centred, so a recent app shifts every
#              icon 40 px left: read it off r3), CLASS = its resourceClass (org.kde.dolphin). A Qt app on
#              purpose: our own environment carries QT_WAYLAND_SHELL_INTEGRATION=layer-shell (LayerShellQt), and
#              a child inheriting it is a layer-shell surface, or in a flatpak no window at all (Telegram from
#              the dock did not open, 10-22; apps.cpp drops it now). This stage judges: the scope the shellbar
#              made has a live process, its environment has no QT_WAYLAND_SHELL_INTEGRATION and carries
#              XDG_ACTIVATION_TOKEN, and KWin has an active normal window of that class. REAL_LAUNCH_OK or
#              REAL_FAIL.
# Prints REAL_DONE; look at the pictures (there is no judge here: this is for eyes; stage 3 is the exception).
# Each stage sends its own two notifications and closes them at the end (notify-send -p gives the ids,
# CloseNotification on the server revokes them: the notification centre drops the cards). Without that they stay
# in the centre as expired history - a pile of them was left after the 10-22 runs.
#
# One finger only. A fresh ftouch loses its first touch, so every gesture starts with a throwaway sideways drag
# at the top of the screen (status bar: a touch that does not move down is no pull; the open grid covers the
# status bar, and there a drag is not the tap that would close it). Not the bed's holding finger (sb-bed.sh): on
# the live screen that one would rest on plasmashell's desktop, and plasmashell asks KWin for the focus about
# 0.8 s after a touch on it (it is plasmashell asking: frozen with SIGSTOP, the activation waited for it, 10-22),
# which took the keyboard off the open grid and sent the back key to the desktop - the rig's doing, not the
# shell's. Nor can it rest on a shellbar window: Qt hands all of one client's touch points to the window of the
# latest touch down, so a second finger on the status bar swallows a tap on the dock.
set -u
U=user
STAGE=${1:-1}; OUT=${2:-/home/$U/sb-real}; GX=${3:-560}; GY=${4:-938}
RUN="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 HOME=/home/$U"
FT=/usr/local/bin/y700-ftouch
[ -x $FT ] || { echo "REAL_FAIL: $FT missing (sh linux/controlpanel/y700-control-center/install.sh)"; exit 1; }
mkdir -p "$OUT"; chown $U:$U "$OUT"
shot() { sleep 0.2; $RUN spectacle -b -n -f -o "$OUT/$1.png" >/dev/null 2>&1 || echo "SHOT_FAIL $1"; }
PRIME='swipe 800 10 840 10 60\ns 400\n'
tap() { printf "${PRIME}d 0 %s %s\ns 70\nu 0\n" "$1" "$2" | $RUN $FT; }
swipe() { printf "${PRIME}swipe %s %s %s %s %s\n" "$1" "$2" "$3" "$4" "$5" | $RUN $FT; }
cchide() { $RUN busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter hide >/dev/null 2>&1; }
# the test pair: a chat message and a power warning; prints the ids (one per line)
notify2() {
    $RUN notify-send -p -a Telegram "张三" "晚上吃火锅吗？我订了七点的位子。"
    sleep 0.3
    $RUN notify-send -p -a "电源管理" "电量低" "剩余 15%，请连接充电器"
}
# revoke what we sent (ids as arguments): the server tells every watcher NotificationClosed(id, 3), and
# libnotificationmanager's watcher model removes the card on any reason but "expired"
unnotify() {
    for i in "$@"; do
        $RUN busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications CloseNotification u "$i" >/dev/null 2>&1 || echo "UNNOTIFY_FAIL $i"
    done
}
# KWin's stacking order, one line "live wins: class/caption@x,y+wxh [ACT]..." (a script run in KWin; its print
# lands in the journal, read back as root)
kwins() {
    cat > /tmp/real-wins.js <<'EOF'
print("live wins: " + workspace.stackingOrder.map(w => w.resourceClass + "/" + w.caption + "@" + Math.round(w.x) + "," + Math.round(w.y) + "+" + Math.round(w.width) + "x" + Math.round(w.height) + (w.minimized ? " MIN" : "") + (w.active ? " ACT" : "")).join(" | "));
EOF
    chmod 644 /tmp/real-wins.js
    local id; id=$($RUN qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript /tmp/real-wins.js "real-wins-$$" 2>/dev/null)
    $RUN qdbus6 "org.kde.KWin" "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null 2>&1
    sleep 0.6
    $RUN qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "real-wins-$$" >/dev/null 2>&1
    journalctl -b -o cat --since "-20s" 2>/dev/null | grep "live wins: " | tail -1
}
if $RUN kscreen-doctor --dpms show 2>/dev/null | grep -q 'off$'; then $RUN kscreen-doctor --dpms on >/dev/null 2>&1; sleep 2.5; fi
cchide; sleep 0.5

case $STAGE in
1)
    shot r3-desktop
    IDS=$(notify2)
    sleep 0.9
    shot r4-banners
    swipe 800 100 800 20 150
    sleep 0.7
    shot r5-banner-swiped
    unnotify $IDS
    ;;
2)
    tap "$GX" "$GY"
    sleep 0.9
    shot r6-grid
    swipe 2 500 180 500 250
    sleep 0.9
    shot r7-grid-after-back
    # two banners up, then the curtain: it expires them into the notification centre (Banners.qml)
    IDS=$(notify2)
    sleep 0.9
    # a held pull is the bed's way; on the live screen a plain swipe past the open point leaves the curtain open
    swipe 300 2 300 560 600
    sleep 1.3
    shot r8-notes
    cchide; sleep 0.6
    swipe 1200 2 1200 560 600
    sleep 1.3
    shot r9-controls
    cchide
    unnotify $IDS
    ;;
3)
    DX=${3:-1040}; DY=${4:-938}; CLASS=${5:-org.kde.dolphin}
    tap "$DX" "$DY"
    sleep 2.5
    shot r10-launched
    fail=
    # the scope the shellbar made for it (apps.cpp): app-y700-<id>-<shellbar pid>-<n>.scope, the app is its process
    unit=$($RUN systemctl --user list-units --no-legend --plain "app-y700-$CLASS-*.scope" 2>/dev/null | awk '{print $1}' | tail -1)
    [ -n "$unit" ] || { echo "REAL_FAIL: no app-y700-$CLASS-*.scope (the icon at $DX,$DY? journalctl --user -u y700-shellbar)"; exit 1; }
    cg=$($RUN systemctl --user show "$unit" -p ControlGroup --value)
    pid=$(head -1 "/sys/fs/cgroup$cg/cgroup.procs" 2>/dev/null)
    [ -n "$pid" ] || { echo "REAL_FAIL: $unit has no process left (it died: journalctl --user -u y700-shellbar shows its stderr)"; exit 1; }
    cenv=$(tr '\0' '\n' < "/proc/$pid/environ")
    echo "$cenv" | grep -q '^QT_WAYLAND_SHELL_INTEGRATION=' && { echo "REAL_FAIL: the child inherited QT_WAYLAND_SHELL_INTEGRATION"; fail=1; }
    echo "$cenv" | grep -q '^XDG_ACTIVATION_TOKEN=' || { echo "REAL_FAIL: no XDG_ACTIVATION_TOKEN in the child"; fail=1; }
    wins=$(kwins)
    echo "$wins" | grep -q "$CLASS/[^|]*ACT" || { echo "REAL_FAIL: no active $CLASS window: $wins"; fail=1; }
    # close it the polite way, the scope the blunt way if it is still there
    cat > /tmp/real-close.js <<EOF
workspace.stackingOrder.filter(w => w.resourceClass == "$CLASS").forEach(w => w.closeWindow());
EOF
    chmod 644 /tmp/real-close.js
    id=$($RUN qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript /tmp/real-close.js "real-close-$$" 2>/dev/null)
    $RUN qdbus6 "org.kde.KWin" "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null 2>&1
    sleep 1.5
    $RUN qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "real-close-$$" >/dev/null 2>&1
    $RUN systemctl --user stop "$unit" >/dev/null 2>&1
    [ -n "$fail" ] && { echo "REAL_FAIL: stage 3"; exit 1; }
    echo REAL_LAUNCH_OK
    ;;
*)  echo "REAL_FAIL: stage $STAGE?"; exit 1 ;;
esac
chown -R $U:$U "$OUT"
echo REAL_DONE
