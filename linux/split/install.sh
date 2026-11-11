#!/bin/sh
# Install the split screen KWin script on the tablet (run as root; everything goes to user's session).
#   ~user/.local/share/kwin/scripts/y700-split   metadata.json, contents/ui/main.qml (a Loader that never
#       changes) and contents/build-<id>/ui/Split.qml (this install's code)
#   kwinrc [Plugins] y700-splitEnabled=true, [Script-y700-split] BuildId=<id>,
#   [Windows] ElectricBorderTiling=false and ElectricBorderMaximize=false: a title bar dragged to an edge is this
#       script's (its card, its halves); KWin's own quick tiling would take the same drag (and drag to the top =
#       maximize is the portrait split's top edge)
# The gap, the round corners and the finger under a title bar drag come from the y700_stagecorners effect's split
# part (linux/stage/kwin-corners, installed by linux/stage/install.sh; a loaded effect keeps its old code until the
# next login). Without it the script works on: square halves, no #242424 in the gap, the card follows the cursor.
# KWin caches a script's QML by URL for the life of the process: a file replaced in place keeps the old code
# running until a re-login. A new folder per install is a new URL, loaded by unload + reconfigure.
# --remove undoes all of it (the windows it holds stay where they are, as plain windows).
# ts-bed (linux/gesture/tests/ts-scenarios/split.sh) takes y700-split/ as it is (no BuildId: contents/ui/Split.qml).
set -e
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$HERE/y700-split; U=user; H=/home/$U; DST=$H/.local/share/kwin/scripts/y700-split
RUN="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
since=$(date '+%Y-%m-%d %H:%M:%S')
# unload first: loadScript refuses a name that is loaded, so reconfigure would keep the old build
$RUN busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s y700-split >/dev/null 2>&1 || true
if [ "${1:-}" = "--remove" ]; then
    rm -rf "$DST"
    $RUN kwriteconfig6 --file kwinrc --group Plugins --key y700-splitEnabled --delete
    $RUN kwriteconfig6 --file kwinrc --group Script-y700-split --key BuildId --delete
    $RUN kwriteconfig6 --file kwinrc --group Windows --key ElectricBorderTiling --delete
    $RUN kwriteconfig6 --file kwinrc --group Windows --key ElectricBorderMaximize --delete
    $RUN qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
    echo REMOVE_OK
    exit 0
fi
if ! $RUN busctl --user introspect org.kde.KWin /org/y700/StageCorners 2>/dev/null | grep -q setSplitWindows; then
    echo "note: the corner effect in this session has no split part (square halves, the card follows the cursor):" >&2
    echo "      linux/stage/install.sh builds it; it is loaded at the next login" >&2
fi
ID=$(date +%Y%m%d%H%M%S)
rm -rf "$DST"
mkdir -p "$DST/contents/ui" "$DST/contents/build-$ID/ui"
cp "$SRC/metadata.json" "$DST/"
cp "$SRC/contents/ui/main.qml" "$DST/contents/ui/"
cp "$SRC/contents/ui/Split.qml" "$DST/contents/build-$ID/ui/"
mkdir -p $H/.local/share/kwin/scripts && chown $U:$U $H/.local/share/kwin/scripts && chown -R $U:$U "$DST"
$RUN kwriteconfig6 --file kwinrc --group Windows --key ElectricBorderTiling false
$RUN kwriteconfig6 --file kwinrc --group Windows --key ElectricBorderMaximize false
$RUN kwriteconfig6 --file kwinrc --group Plugins --key y700-splitEnabled true
$RUN kwriteconfig6 --file kwinrc --group Script-y700-split --key BuildId "$ID"
$RUN qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
waitloaded() {
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.3
        $RUN busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting isScriptLoaded s y700-split 2>/dev/null | grep -q true && return 0
    done
    return 1
}
if ! waitloaded; then
    # a package this KWin has not seen since it started (the first install): 11-10 in sb-bed, a script copied in
    # after KWin started was not loaded by Enabled + reconfigure, while loadDeclarativeScript by path (under its
    # name, so [Script-y700-split] is its config) loaded it. From the next login on it loads as a plugin
    $RUN busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting loadDeclarativeScript ss "$DST/contents/ui/main.qml" y700-split >/dev/null 2>&1 || true
    $RUN busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting start >/dev/null 2>&1 || true
    waitloaded || { echo "INSTALL_FAIL: y700-split not loaded (journalctl --user -b | grep -i y700-split)" >&2; exit 1; }
    echo "loaded by path (this KWin had not seen the package yet)"
fi
sleep 1
# a QML error still leaves the script "loaded": the journal tells
err=$($RUN journalctl --user --no-hostname --since "$since" --no-pager -o cat | grep -E "y700-split/contents/build-$ID/ui/[A-Za-z]+\.qml:[0-9]+" | head -3)
[ -z "$err" ] || { echo "INSTALL_FAIL: QML errors:"; echo "$err"; exit 1; }
echo "INSTALL_OK build $ID"
