#!/bin/sh
# Build and install the Y700 keyboard on the tablet. Run as root from the source dir.
#   /usr/local/bin/y700-osk, /usr/local/share/y700-osk/{qml,icons.json}
#   /usr/local/libexec/y700-osk-dispatch, /usr/local/bin/y700-osk-ctl
#   fcitx5 addon y700osk: /usr/lib/aarch64-linux-gnu/fcitx5/liby700osk.so, /usr/share/fcitx5/addon/y700osk.conf
#   KWin effect y700_oskgate: /usr/lib/aarch64-linux-gnu/qt6/plugins/kwin/effects/plugins/y700_oskgate.so
#   ~user/.local/share/dbus-1/services/fyi.fortime.Fcitx5Osk.service  (takes over the desktop keyboard)
#   ~user/.config/fcitx5/config [Behavior] PreeditEnabledByDefault=False  (pinyin shows in the keyboard)
#                                    [Behavior] ShareInputState=All          (中/英 shared by every field)
# Options: --no-switch  build and install files but keep fcitx5-osk active (no service file, no restarts)
set -e
SRC=$(cd "$(dirname "$0")" && pwd); U=user; H=/home/$U
RUN="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
SWITCH=1; [ "$1" = "--no-switch" ] && SWITCH=0

dpkg -s fcitx5-modules-dev >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y fcitx5-modules-dev >/dev/null
# Japanese romaji input (the 中英日 key's 日): Mozc, from the Ubuntu archive
dpkg -s fcitx5-mozc >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y fcitx5-mozc >/dev/null

cmake -S "$SRC" -B "$SRC/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local >/dev/null
cmake --build "$SRC/build"
cmake --install "$SRC/build" >/dev/null
cmake -S "$SRC/fcitx5-addon" -B "$SRC/build-addon" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr >/dev/null
cmake --build "$SRC/build-addon"
cmake --install "$SRC/build-addon" >/dev/null
install -D -m 755 "$SRC/y700-osk-dispatch" /usr/local/libexec/y700-osk-dispatch
install -D -m 755 "$SRC/y700-osk-ctl" /usr/local/bin/y700-osk-ctl
# KWin effect y700_oskgate (watch-only: touches + text-input requests over D-Bus, so the keyboard comes
# up only for taps on text fields). Built against the installed kwin-dev: must match the running KWin,
# rebuild after every KWin upgrade. The keyboard loads it on demand (org.kde.KWin /Effects loadEffect)
# and falls back to the old focus-driven behaviour without it. Plugins load lazily: an unresolved symbol
# would abort kwin_wayland (the whole session) on first call, so refuse to install one.
dpkg -s kwin-dev >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y kwin-dev >/dev/null
cmake -S "$SRC/kwin-gate" -B "$SRC/build-gate" -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null
cmake --build "$SRC/build-gate"
GATE_SO="$SRC/build-gate/bin/kwin/effects/plugins/y700_oskgate.so"
if LD_BIND_NOW=1 ldd -r "$GATE_SO" 2>&1 | grep -qiE 'undefined symbol|not found'; then
    echo "y700_oskgate.so has unresolved symbols (built against another KWin?): NOT installed" >&2
else
    install -D -m 644 "$GATE_SO" /usr/lib/aarch64-linux-gnu/qt6/plugins/kwin/effects/plugins/y700_oskgate.so
    mkdir -p /usr/local/share/y700-osk
    dpkg-query -W -f '${Version}' kwin-wayland > /usr/local/share/y700-osk/oskgate.kwin-version
fi
# and keep it built for whatever KWin apt installs next (the obligation, automated: cheap no-op
# unless kwin-wayland changed; never fails the apt run)
install -D -m 755 "$SRC/y700-oskgate-rebuild" /usr/local/libexec/y700-oskgate-rebuild
echo 'DPkg::Post-Invoke { "/usr/local/libexec/y700-oskgate-rebuild || true"; };' > /etc/apt/apt.conf.d/99y700-oskgate

[ "$SWITCH" = 1 ] || { echo "INSTALL_OK (no switch)"; exit 0; }

install -d -o $U -g $U $H/.local/share/dbus-1/services
cat > $H/.local/share/dbus-1/services/fyi.fortime.Fcitx5Osk.service <<EOF
[D-BUS Service]
Name=fyi.fortime.Fcitx5Osk
Exec=/usr/local/libexec/y700-osk-dispatch
EOF
chown $U:$U $H/.local/share/dbus-1/services/fyi.fortime.Fcitx5Osk.service
# KWin loads the gate effect itself at start and after every compositor restart (a GPU reset unloads
# all effects and reloads only the enabled ones); the keyboard also loads it on demand
[ -f /usr/lib/aarch64-linux-gnu/qt6/plugins/kwin/effects/plugins/y700_oskgate.so ] &&
    $RUN kwriteconfig6 --file $H/.config/kwinrc --group Plugins --key y700_oskgateEnabled true
# pinyin in the keyboard's band (vivo), not inline in the app; delete the key to undo
install -d -o $U -g $U $H/.config/fcitx5
$RUN kwriteconfig6 --file $H/.config/fcitx5/config --group Behavior --key PreeditEnabledByDefault False
# 中/英 is one state for every field (the owner: "whatever I set last time stays"); y700-osk also
# remembers the owner's last switch and restores it after fcitx5 restarts
$RUN kwriteconfig6 --file $H/.config/fcitx5/config --group Behavior --key ShareInputState All
chown $U:$U $H/.config/fcitx5/config
$RUN busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig >/dev/null
# fcitx5 picks up the addon and the preedit setting on restart; then rebuild the launcher chain
$RUN busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 Restart >/dev/null 2>&1 || true
sleep 2
# the input method group: English, rime, mozc (fcitx5 needs a moment after the restart to list mozc)
for i in 1 2 3 4 5 6 7 8 9 10; do
    $RUN busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 AvailableInputMethods 2>/dev/null | grep -q '"mozc"' && break
    sleep 1
done
if ! $RUN busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 InputMethodGroupInfo s Default | grep -q '"mozc"'; then
    $RUN busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetInputMethodGroupInfo "ssa(ss)" Default us 3 keyboard-us "" rime "" mozc ""
    $RUN busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 Save
fi
$RUN /usr/local/bin/y700-osk-ctl on
echo INSTALL_OK
