#!/bin/sh
# Install the Stage Manager KWin script on the tablet (run as root; everything goes to user's session).
#   ~user/.local/share/kwin/scripts/y700-stage   metadata.json, contents/ui/main.qml (a Loader that never
#       changes) and contents/build-<id>/ui/{Stage,Card}.qml (this install's code)
#   kwinrc [Plugins] y700-stageEnabled=true, [Script-y700-stage] BuildId=<id>
#   KWin effect y700_stagecorners (the stage's round corners, kwin-corners/): built here against kwin-dev,
#   /usr/lib/aarch64-linux-gnu/qt6/plugins/kwin/effects/plugins/y700_stagecorners.so, kwinrc
#   [Plugins] y700_stagecornersEnabled=true, the apt hook /etc/apt/apt.conf.d/99y700-stagecorners ->
#   /usr/local/libexec/y700-stagecorners-rebuild (rebuilds it after every KWin upgrade). A build that fails or
#   does not match the running KWin is not installed; the script works without it (square corners).
# KWin caches a script's QML by URL for the life of the process: a file replaced in place keeps the old code
# running until a re-login. A new folder per install is a new URL, loaded by unload + reconfigure.
# [Script-y700-stage] Active (on / off) is left alone: off until the control centre's 「台前调度」 tile turns
# it on. Loading it does nothing to the windows while it is off. --remove undoes all of it.
# ts-bed (linux/gesture/tests/ts-scenarios/stage.sh) takes y700-stage/ as it is (no BuildId: contents/ui/Stage.qml).
set -e
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$HERE/y700-stage; U=user; H=/home/$U; DST=$H/.local/share/kwin/scripts/y700-stage
RUN="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
since=$(date '+%Y-%m-%d %H:%M:%S')
FX=/usr/lib/aarch64-linux-gnu/qt6/plugins/kwin/effects/plugins/y700_stagecorners.so
# unload first: loadScript refuses a name that is loaded, so reconfigure would keep the old build
$RUN busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s y700-stage >/dev/null 2>&1 || true
if [ "${1:-}" = "--remove" ]; then
    rm -rf "$DST"
    $RUN kwriteconfig6 --file kwinrc --group Plugins --key y700-stageEnabled --delete
    $RUN kwriteconfig6 --file kwinrc --group Script-y700-stage --key BuildId --delete
    $RUN kwriteconfig6 --file kwinrc --group Script-y700-stage --key Active --delete
    $RUN busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects unloadEffect s y700_stagecorners >/dev/null 2>&1 || true
    $RUN kwriteconfig6 --file kwinrc --group Plugins --key y700_stagecornersEnabled --delete
    rm -f "$FX" /etc/apt/apt.conf.d/99y700-stagecorners /usr/local/libexec/y700-stagecorners-rebuild
    rm -rf /usr/local/share/y700-stage
    $RUN qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
    echo REMOVE_OK
    exit 0
fi
# the corner effect. Plugins load lazily: an unresolved symbol would abort kwin_wayland (the whole session) on
# first call, so one built against another KWin is refused. A loaded one keeps its old code until the next login
# (the library stays mapped); the first install loads it at once (the script asks for it too, at its start).
if dpkg -s kwin-dev >/dev/null 2>&1; then
    rm -rf "$HERE/build-corners"
    if cmake -S "$HERE/kwin-corners" -B "$HERE/build-corners" -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null && cmake --build "$HERE/build-corners" >/dev/null; then
        so="$HERE/build-corners/bin/kwin/effects/plugins/y700_stagecorners.so"
        if LD_BIND_NOW=1 ldd -r "$so" 2>&1 | grep -qiE 'undefined symbol|not found'; then
            echo "y700_stagecorners.so has unresolved symbols (built against another KWin?): NOT installed" >&2
        else
            install -D -m 644 "$so" "$FX"
            mkdir -p /usr/local/share/y700-stage
            dpkg-query -W -f '${Version}' kwin-wayland > /usr/local/share/y700-stage/stagecorners.kwin-version
            $RUN kwriteconfig6 --file kwinrc --group Plugins --key y700_stagecornersEnabled true
            echo "corners effect installed"
        fi
    else
        echo "y700_stagecorners build FAILED: NOT installed (square corners)" >&2
    fi
    install -D -m 755 "$HERE/y700-stagecorners-rebuild" /usr/local/libexec/y700-stagecorners-rebuild
    echo 'DPkg::Post-Invoke { "/usr/local/libexec/y700-stagecorners-rebuild || true"; };' > /etc/apt/apt.conf.d/99y700-stagecorners
else
    echo "no kwin-dev: the corners effect is not built (square corners)" >&2
fi
ID=$(date +%Y%m%d%H%M%S)
rm -rf "$DST"
mkdir -p "$DST/contents/ui" "$DST/contents/build-$ID/ui"
cp "$SRC/metadata.json" "$DST/"
cp "$SRC/contents/ui/main.qml" "$DST/contents/ui/"
cp "$SRC/contents/ui/Stage.qml" "$SRC/contents/ui/Card.qml" "$DST/contents/build-$ID/ui/"
chown $U:$U $H/.local/share/kwin/scripts && chown -R $U:$U "$DST"
$RUN kwriteconfig6 --file kwinrc --group Plugins --key y700-stageEnabled true
$RUN kwriteconfig6 --file kwinrc --group Script-y700-stage --key BuildId "$ID"
$RUN qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    if $RUN busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting isScriptLoaded s y700-stage 2>/dev/null | grep -q true; then
        sleep 1
        # a QML error still leaves the script "loaded": the journal tells
        err=$($RUN journalctl --user --no-hostname --since "$since" --no-pager -o cat | grep -E "y700-stage/contents/build-$ID/ui/[A-Za-z]+\.qml:[0-9]+" | head -3)
        [ -z "$err" ] || { echo "INSTALL_FAIL: QML errors:"; echo "$err"; exit 1; }
        echo "INSTALL_OK build $ID"
        exit 0
    fi
done
echo "INSTALL_FAIL: y700-stage not loaded (journalctl --user -b | grep -i y700-stage)" >&2
exit 1
