#!/bin/sh
# Install the bottom-edge home gesture on the tablet (run as root; everything goes to user's session).
#   ~user/.local/share/kwin/scripts/y700-home     KWin script: bottom touch edge -> minimize the active window
#   kwinrc [Plugins] y700-homeEnabled=true
#   kwinrc [ScreenEdges] RemainActiveOnFullscreen=true   KWin blocks every screen edge over a fullscreen
#       window without it (Edge::checkBlocking); this also lets the right edge open the control centre there
# No daemon, nothing to build. --remove undoes all three.
set -e
SRC=$(cd "$(dirname "$0")" && pwd); U=user; H=/home/$U; DST=$H/.local/share/kwin/scripts/y700-home
RUN="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
# a loaded script is not reloaded by reconfigure (loadScript refuses a name that is loaded): unload first
$RUN busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s y700-home >/dev/null 2>&1 || true
if [ "$1" = "--remove" ]; then
    rm -rf "$DST"
    $RUN kwriteconfig6 --file kwinrc --group Plugins --key y700-homeEnabled --delete
    $RUN kwriteconfig6 --file kwinrc --group ScreenEdges --key RemainActiveOnFullscreen --delete
    $RUN qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
    echo REMOVE_OK
    exit 0
fi
rm -rf "$DST"
mkdir -p $H/.local/share/kwin/scripts && cp -r "$SRC/kwin-script" "$DST"
chown $U:$U $H/.local/share/kwin/scripts && chown -R $U:$U "$DST"
$RUN kwriteconfig6 --file kwinrc --group Plugins --key y700-homeEnabled true
$RUN kwriteconfig6 --file kwinrc --group ScreenEdges --key RemainActiveOnFullscreen true
# reconfigure: ScreenEdges rereads RemainActiveOnFullscreen, Scripting loads the enabled scripts not loaded
$RUN qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    $RUN busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting isScriptLoaded s y700-home 2>/dev/null | grep -q true && { echo INSTALL_OK; exit 0; }
done
echo "INSTALL_FAIL: y700-home not loaded (journalctl --user -b | grep -i y700-home)" >&2
exit 1
