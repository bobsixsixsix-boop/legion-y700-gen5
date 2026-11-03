#!/bin/sh
# Install the phone-style task switcher on the tablet (run as root; everything goes to user's session).
#
#   apt: plasma-mobile (--no-install-recommends)  ships the effect "mobiletaskswitcher" (QML, in
#       /usr/share/kwin/effects/) and its C++ QML plugin (registerRealtimeTouchBorder on the bottom edge)
#   ~user/.local/share/kwin/effects/y700-taskswitcher   = the package's main.qml +
#       y700-taskswitcher.patch (edge off while the keyboard / control centre is up; own shortcut name;
#       the shortcut dismisses when the cards are up) + our own view ui/*.qml, ui/stack.js (the stacked
#       cards, replacing upstream's TaskSwitcher / Task / TaskList / FlickContainer /
#       TaskSwitcherHelpers) + our metadata.json. main.qml is taken from the INSTALLED package each time,
#       so an apt upgrade followed by a rerun picks up upstream fixes; if the patch no longer applies this
#       stops (rerun after fixing the patch; until then the old copy stays). The C++ side we rely on
#       (TaskFilterModel, the touch border, deactivate/hideAnimation) is listed in the README.
#   plasmamobilerc [General] navigationPanelEnabled=false   the switcher's gesture is only on without the
#       mobile button bar; convergenceModeEnabled=true      opening a card does not force-maximize it
#       (a fullscreen game comes back fullscreen)
#   kwinrc [Script-y700-home] BottomEdge=false   y700-home gives up the bottom edge, keeps its shortcut
#   kwinrc [Plugins] y700-taskswitcherEnabled=true
#   /usr/local/libexec/y700-taskswitcher-aptcheck + /etc/apt/apt.conf.d/99y700-taskswitcher   after every dpkg run
#       that changed KWin / plasma-mobile / Qt: the installed build in a headless test KWin; off for the next
#       login if it does not start (10-23)
#   /usr/local/libexec/y700-appquit (appquit.py) + ~user/.config/systemd/user/y700-appquit@.service   a card
#       swiped away quits its app, not only its window (10-31; ui/AppQuit.qml starts the unit)
# --build DIR only assembles the effect into DIR (for linux/gesture/tests/ts-bed.sh) and stops.
# --remove undoes the last five (the apt package stays; it does nothing in the desktop session by itself).
#
# KWin caches compiled QML in memory by file URL: unloadEffect + loadEffect brings back the OLD code.
# The first install takes effect at once; a changed patch or upgraded package only after the next
# login (or reboot). main.qml logs "y700-taskswitcher: loaded <build>" and the build (plasma-mobile
# version + patch hash) is written into the installed main.qml, so y700-checklist can tell the two
# apart. 2026-10-21 lesson: a reinstall looked fine while the running "close all" was still upstream's.
# Second lesson the same day: so the live session never tested the new QML before the next login, and a
# broken one crash-looped it. Before replacing anything, smoke.sh starts the build in a headless KWin.
set -e
SRC=$(cd "$(dirname "$0")" && pwd); U=user; H=/home/$U
UP=/usr/share/kwin/effects/mobiletaskswitcher; DST=$H/.local/share/kwin/effects/y700-taskswitcher
RUN="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
fx() { $RUN busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects "$@"; }
home() {   # y700-home rereads BottomEdge only when (re)loaded
    $RUN busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s y700-home >/dev/null 2>&1 || true
    $RUN qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
}

if [ "$1" = "--remove" ]; then
    fx unloadEffect s y700-taskswitcher >/dev/null 2>&1 || true
    rm -rf "$DST"
    rm -f /etc/apt/apt.conf.d/99y700-taskswitcher /usr/local/libexec/y700-taskswitcher-aptcheck
    rm -f /usr/local/libexec/y700-appquit "$H/.config/systemd/user/y700-appquit@.service"
    $RUN systemctl --user daemon-reload || true
    $RUN kwriteconfig6 --file kwinrc --group Plugins --key y700-taskswitcherEnabled --delete
    $RUN kwriteconfig6 --file kwinrc --group Script-y700-home --key BottomEdge --delete
    $RUN kwriteconfig6 --file plasmamobilerc --group General --key navigationPanelEnabled --delete
    $RUN kwriteconfig6 --file plasmamobilerc --group General --key convergenceModeEnabled --delete
    home
    echo REMOVE_OK
    exit 0
fi

dpkg -s plasma-mobile >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends plasma-mobile
[ -f $UP/contents/ui/main.qml ] || { echo "INSTALL_FAIL: $UP missing (plasma-mobile changed layout?)" >&2; exit 1; }
echo "upstream: plasma-mobile $(dpkg-query -W -f '${Version}' plasma-mobile)"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp -r $UP/contents "$T/"
( cd "$T" && patch -p1 --no-backup-if-mismatch < "$SRC/y700-taskswitcher.patch" ) \
    || { echo "INSTALL_FAIL: y700-taskswitcher.patch does not apply to this plasma-mobile" >&2; exit 1; }
for f in TaskSwitcher.qml Task.qml TaskList.qml FlickContainer.qml TaskSwitcherHelpers.qml; do rm -f "$T/contents/ui/$f"; done
cp "$SRC"/ui/TaskSwitcher.qml "$SRC"/ui/StackCard.qml "$SRC"/ui/stack.js "$SRC"/ui/AppQuit.qml "$T/contents/ui/"
cp "$SRC/metadata.json" "$T/"
BUILD="$(dpkg-query -W -f '${Version}' plasma-mobile)+$(cat "$SRC/y700-taskswitcher.patch" "$SRC"/ui/TaskSwitcher.qml "$SRC"/ui/StackCard.qml "$SRC"/ui/stack.js "$SRC"/ui/AppQuit.qml | sha256sum | cut -c1-12)"
sed -i "s/@Y700_BUILD@/$BUILD/" "$T/contents/ui/main.qml"
grep -q "\"$BUILD\"" "$T/contents/ui/main.qml" || { echo "INSTALL_FAIL: build marker not written" >&2; exit 1; }
if [ "$1" = "--build" ]; then
    rm -rf "$2"; cp -r "$T" "$2"; chmod -R a+rX "$2"
    echo "BUILD_OK $BUILD -> $2"
    exit 0
fi
# the new QML in a throwaway headless KWin first: the live one would only run it at the next login
# (2026-10-21: a build that dereferenced null at load crash-looped the login). Y700_SKIP_SMOKE=1 skips
# it when the test KWin itself cannot start (say after a KWin upgrade): then re-login right away and watch.
if [ "${Y700_SKIP_SMOKE:-}" != 1 ]; then
    sh "$SRC/smoke.sh" "$T" \
        || { echo "INSTALL_FAIL: the new build does not survive a test KWin (above); nothing replaced" >&2; exit 1; }
fi
WAS=$(fx isEffectLoaded s y700-taskswitcher 2>/dev/null | grep -q true && echo yes || echo no)

fx unloadEffect s y700-taskswitcher >/dev/null 2>&1 || true
rm -rf "$DST"; mkdir -p "$(dirname "$DST")"; cp -r "$T" "$DST"; chmod 755 "$DST"
chown -R $U:$U $H/.local/share/kwin/effects

$RUN kwriteconfig6 --file plasmamobilerc --group General --key navigationPanelEnabled false
$RUN kwriteconfig6 --file plasmamobilerc --group General --key convergenceModeEnabled true
$RUN kwriteconfig6 --file kwinrc --group Script-y700-home --key BottomEdge false
$RUN kwriteconfig6 --file kwinrc --group Plugins --key y700-taskswitcherEnabled true
home
# after every dpkg run: does the installed build still start under the new KWin / plasma-mobile / Qt? (10-23; a
# headless test KWin, never the live session; switches it off for the next login if not - see the script's header)
install -D -m 755 "$SRC/y700-taskswitcher-aptcheck" /usr/local/libexec/y700-taskswitcher-aptcheck
echo 'DPkg::Post-Invoke { "/usr/local/libexec/y700-taskswitcher-aptcheck || true"; };' > /etc/apt/apt.conf.d/99y700-taskswitcher
[ "${Y700_SKIP_SMOKE:-}" = 1 ] || /usr/local/libexec/y700-taskswitcher-aptcheck --stamp >/dev/null
# what a swiped-away card starts (ui/AppQuit.qml -> StartUnit y700-appquit@PID_WINPIDS.service -> appquit.py)
install -D -m 755 "$SRC/appquit.py" /usr/local/libexec/y700-appquit
install -D -o $U -g $U -m 644 "$SRC/y700-appquit@.service" "$H/.config/systemd/user/y700-appquit@.service"
$RUN systemctl --user daemon-reload
fx loadEffect s y700-taskswitcher >/dev/null 2>&1 || true
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    if fx isEffectLoaded s y700-taskswitcher 2>/dev/null | grep -q true; then
        echo "INSTALL_OK build $BUILD"
        [ $WAS = no ] || echo "NOTE: KWin still runs the QML it loaded first; the new build takes effect after the next login or reboot"
        exit 0
    fi
done
echo "INSTALL_FAIL: y700-taskswitcher not loaded (journalctl --user -b | grep -iE 'taskswitcher|qml')" >&2
exit 1
