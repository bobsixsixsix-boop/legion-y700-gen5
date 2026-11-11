#!/bin/sh
# Build and install y700-shellbar on the tablet (run as root; the user bits go to user).
#   /usr/local/bin/y700-shellbar + /usr/local/share/y700-shellbar/qml
#   /usr/local/share/applications/y700-shellbar.desktop   (hidden; X-KDE-Wayland-Interfaces lets KWin give it
#                                                          org_kde_plasma_window_management, which the task model needs)
#   ~user/.config/systemd/user/y700-shellbar.service   (enabled: starts with the session)
#   /usr/local/share/applications/y700-dnd-toggle.desktop (hidden; a KDE command shortcut on the Sleep key, which is
#                                                          the Magic Keyboard's fn+F6: do not disturb on / off)
# It takes over the pull-down strip: y700-cc-pull.service (linux/controlpanel) is disabled and stopped here, and
# that project's install.sh leaves it off while /usr/local/bin/y700-shellbar exists.
# Needs the control centre's sources for the blur code (CMakeLists.txt WLBLUR_DIR: /usr/local/src/y700-control-center
# on the tablet, where linux/controlpanel's install.sh is run from) and qt6-base-private-dev.
# Once started, y700-shellbar is the session's notification server: it takes org.freedesktop.Notifications over
# from plasmashell's applet (banners come from it from then on; README「Dock 与状态栏」第 2 阶段).
#   --no-start   install only (the service is not enabled, started or restarted)
set -e
SRC=$(cd "$(dirname "$0")" && pwd); U=user; H=/home/$U
dpkg -s qt6-base-private-dev >/dev/null 2>&1 || { echo "INSTALL_FAIL: apt install qt6-base-private-dev (the blur code needs Qt's qpa headers)"; exit 1; }
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local >/dev/null
cmake --build "$SRC/build" -j8
cmake --install "$SRC/build" >/dev/null
install -D -m 644 "$SRC/y700-shellbar.desktop" /usr/local/share/applications/y700-shellbar.desktop
install -D -m 644 "$SRC/y700-dnd-toggle.desktop" /usr/local/share/applications/y700-dnd-toggle.desktop
install -D -o $U -g $U -m 644 "$SRC/y700-shellbar.service" $H/.config/systemd/user/y700-shellbar.service
RUN="sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
# KWin looks the desktop file up through the user's sycoca when the client connects
$RUN kbuildsycoca6 >/dev/null 2>&1 || true
# the Sleep key (Qt::Key_Sleep 0x01020004 = 16908292; the Magic Keyboard's fn+F6) to do not disturb, off PowerDevil's
# suspend and off plasmashell's "toggle do not disturb" (nothing answers it: its notifications applet is gone).
# kglobalaccel keeps it in kglobalshortcutsrc; needs the session (no-op from a bare tty). The new one with
# setShortcutKeys flags 6 = SetPresent | NoAutoloading: setForeignShortcutKeys only stores the keys of a shortcut
# nobody made present, kglobalaccel grabs nothing until its next start (11-03: fn+F6 did nothing until then)
G="$RUN busctl --user call org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel"
$G setForeignShortcutKeys 'asa(ai)' 4 org_kde_powerdevil Sleep 电源管理 挂起 0 >/dev/null 2>&1 || true
$G setForeignShortcutKeys 'asa(ai)' 4 plasmashell "toggle do not disturb" plasmashell 切换勿扰模式 0 >/dev/null 2>&1 || true
$G setShortcutKeys 'asa(ai)u' 4 y700-dnd-toggle.desktop _launch 勿扰模式 勿扰模式 1 4 16908292 0 0 0 6 >/dev/null 2>&1 || true
$RUN systemctl --user daemon-reload
[ "$1" = "--no-start" ] && { echo INSTALL_OK_NOT_STARTED; exit 0; }
$RUN systemctl --user disable --now y700-cc-pull.service >/dev/null 2>&1 || true
$RUN systemctl --user enable y700-shellbar.service >/dev/null 2>&1
$RUN systemctl --user restart y700-shellbar.service 2>/dev/null || $RUN systemctl --user start y700-shellbar.service
echo INSTALL_OK
