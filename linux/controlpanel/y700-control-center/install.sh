#!/bin/sh
# Build and install y700-control-center on the tablet (run as root; the user bits go to user).
#   /usr/local/bin/y700-control-center + /usr/local/share/y700-control-center/qml
#   ~user/.config/systemd/user/y700-control-center.service   (enabled: starts with the session)
#   /usr/local/bin/y700-cc-pull + ~user/.config/systemd/user/y700-cc-pull.service   (the pull-down strip, enabled
#                                                                  unless y700-shellbar.service is: then shellbar's)
#   ~user/.local/share/kwin/scripts/y700-edge                 (left/right touch edge -> D-Bus back)
#   /usr/local/share/applications/y700-control-center.desktop     (hidden; lets KWin give it org_kde_kwin_fake_input
#                                                                  for the back key: X-KDE-Wayland-Interfaces)
#   /usr/local/share/y700-control-center/tests/{capseq.py,detail.py,blur-flicker.sh,blur-trace.sh}   the live-screen
#   /usr/local/bin/y700-capseq + y700-capseq.desktop             blur test (README「下拉模糊闪烁」): a copy of python3
#                                                                  that KWin lets take screenshots (X-KDE-DBUS-Restricted-Interfaces)
#   /usr/local/bin/y700-ftouch + y700-ftouch.desktop             the gesture bed's fake finger, with the fake_input
#                                                                  grant (built from linux/gesture/tests/ftouch if there)
# The tray section (「后台应用」, src/tray.cpp, 10-23) installs nothing beyond the binary and its QML (both from
# cmake --install): it registers as a StatusNotifierItem host with kded6's watcher at run time. Build dependency: the
# KF6WindowSystem headers (KWaylandExtras, the activation token).
set -e
SRC=$(cd "$(dirname "$0")" && pwd); U=user; H=/home/$U
# src/backend.cpp reads the window's wl_surface through Qt's qpa header (10-22, the blur hand-over's frame callback)
dpkg -s qt6-base-private-dev >/dev/null 2>&1 || { echo "install.sh: qt6-base-private-dev missing: apt-get install -y qt6-base-private-dev"; exit 1; }
dpkg -s libkf6windowsystem-dev >/dev/null 2>&1 || { echo "install.sh: libkf6windowsystem-dev missing: apt-get install -y libkf6windowsystem-dev"; exit 1; }
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local >/dev/null
cmake --build "$SRC/build" -j8
cmake --install "$SRC/build" >/dev/null
install -D -m 644 "$SRC/y700-control-center.desktop" /usr/local/share/applications/y700-control-center.desktop
install -D -o $U -g $U -m 644 "$SRC/y700-control-center.service" $H/.config/systemd/user/y700-control-center.service
install -D -o $U -g $U -m 644 "$SRC/y700-cc-pull.service" $H/.config/systemd/user/y700-cc-pull.service
rm -rf $H/.local/share/kwin/scripts/y700-edge
mkdir -p $H/.local/share/kwin/scripts && cp -r "$SRC/kwin-script" $H/.local/share/kwin/scripts/y700-edge
chown -R $U:$U $H/.local/share/kwin/scripts/y700-edge
# the live-screen blur test (tests/blur-flicker.sh). KWin grants ScreenShot2 and fake_input by the client's executable
# (its desktop file's Exec must match /proc/<pid>/exe), so plain python3 and a binary in /tmp get nothing: y700-capseq
# is a COPY of the python3 binary (not a link: that resolves to python3.x), y700-ftouch the gesture bed's ftouch.
install -D -m 644 "$SRC/tests/capseq.py" /usr/local/share/y700-control-center/tests/capseq.py
install -D -m 644 "$SRC/tests/detail.py" /usr/local/share/y700-control-center/tests/detail.py
install -D -m 755 "$SRC/tests/blur-flicker.sh" /usr/local/share/y700-control-center/tests/blur-flicker.sh
install -D -m 755 "$SRC/tests/blur-trace.sh" /usr/local/share/y700-control-center/tests/blur-trace.sh
install -m 755 "$(readlink -f "$(command -v python3)")" /usr/local/bin/y700-capseq
printf '[Desktop Entry]\nType=Application\nName=y700-capseq\nComment=y700 frame-sequence capture (a copy of python3 that KWin lets take screenshots)\nExec=/usr/local/bin/y700-capseq\nNoDisplay=true\nX-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2\n' \
    > /usr/local/share/applications/y700-capseq.desktop
GT=${GESTURE_SRC:-/usr/local/src/y700-gesture}
if [ -f "$GT/tests/ftouch/ftouch.c" ]; then
    FT=$(mktemp -d)
    ( cd "$GT/tests/ftouch" && wayland-scanner client-header fake-input.xml "$FT/fake-input.h" \
      && wayland-scanner private-code fake-input.xml "$FT/fake-input.c" \
      && cc -O2 -I"$FT" -o /usr/local/bin/y700-ftouch ftouch.c "$FT/fake-input.c" -lwayland-client -lm ) \
      || echo "install.sh: y700-ftouch not built (blur-flicker.sh needs it)"
    rm -rf "$FT"
    printf '[Desktop Entry]\nType=Application\nName=y700-ftouch\nComment=y700 fake touch for the live session (org_kde_kwin_fake_input)\nExec=/usr/local/bin/y700-ftouch\nNoDisplay=true\nX-KDE-Wayland-Interfaces=org_kde_kwin_fake_input\n' \
        > /usr/local/share/applications/y700-ftouch.desktop
else
    echo "install.sh: $GT/tests/ftouch not there, y700-ftouch not built (blur-flicker.sh needs it)"
fi
# the parts that were once done by hand (a rebuild from these files must give a working panel):
# the user service runs with the session, the KWin script is enabled in kwinrc, KWin reloads it,
# and a running panel is restarted onto the new binary/QML
RUN="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
# KWin looks the desktop file up through the user's sycoca when the client connects
$RUN kbuildsycoca6 >/dev/null 2>&1 || true
$RUN systemctl --user daemon-reload
$RUN systemctl --user enable y700-control-center.service >/dev/null 2>&1
# the pull strip moved into y700-shellbar (linux/dock, 10-22): with its service enabled, y700-cc-pull stays off
# (not "with its binary there": shellbar is built and installed --no-start long before it goes on screen, and
# that must not take the only pull strip away)
if [ "$($RUN systemctl --user is-enabled y700-shellbar.service 2>/dev/null)" = enabled ]; then PULL=; $RUN systemctl --user disable --now y700-cc-pull.service >/dev/null 2>&1 || true
else PULL=1; $RUN systemctl --user enable y700-cc-pull.service >/dev/null 2>&1; fi
# a loaded script is not reloaded by reconfigure (loadScript refuses a name that is loaded): unload first
$RUN busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s y700-edge >/dev/null 2>&1 || true
$RUN kwriteconfig6 --file kwinrc --group Plugins --key y700-edgeEnabled true
# the curtain's frosted glass is KWin's blur effect; it was found not loaded in the session (10-22). Strength 12 of
# 15 (owner: 「背景明显不够模糊」); set only when the key is missing, so a later tuning by hand is kept
$RUN kwriteconfig6 --file kwinrc --group Plugins --key blurEnabled true
if [ -z "$($RUN kreadconfig6 --file kwinrc --group Effect-blur --key BlurStrength)" ]; then
    $RUN kwriteconfig6 --file kwinrc --group Effect-blur --key BlurStrength 12
    $RUN kwriteconfig6 --file kwinrc --group Effect-blur --key NoiseStrength 4
fi
$RUN busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects loadEffect s blur >/dev/null 2>&1 || true
$RUN qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
$RUN systemctl --user restart y700-control-center.service 2>/dev/null || $RUN systemctl --user start y700-control-center.service
[ -n "$PULL" ] && { $RUN systemctl --user restart y700-cc-pull.service 2>/dev/null || $RUN systemctl --user start y700-cc-pull.service; }
echo INSTALL_OK
