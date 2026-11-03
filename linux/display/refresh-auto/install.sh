#!/bin/bash
# install.sh: install y700-refresh-auto on the tablet (ROOT; files copied to /tmp/ra/ first). 2026-10-16.
#   /usr/local/libexec/y700-refresh-auto                        daemon: Rust since 2026-11-03, built and installed by
#                                                               daemon/install.sh, which must run first (the Python one
#                                                               this script used to put in ~/.local/bin: git 669f79f)
#   ~user/.config/systemd/user/y700-refresh-auto.service    user unit (enabled, graphical-session)
#   ~user/.local/share/kwin/scripts/y700-refresh-auto/      KWin script, enabled by default (metadata EnabledByDefault):
#                                                               KWin loads it at login; the daemon unload/load/starts it on
#                                                               its own start so that it re-reports the active window. It
#                                                               must stay enabled: Scripting.start() unloads disabled scripts
#   /usr/local/libexec/y700-display-watchdog                    restores to the daemon's base, not to a video rate (2026-10-16)
#   ~user/.config/mpv/scripts/y700-video-state.lua          standalone mpv state
#   /usr/local/bin/wiliwili                                     rebuilt with wiliwili-video-state.patch (ninja install),
#                                                               old binary kept as /root/wiliwili.bin.bak-20261016-vs
# Rollback: systemctl --user disable --now y700-refresh-auto (puts the base mode back), rm the files above,
#   cp /root/wiliwili.bin.bak-20261016-vs /usr/local/bin/wiliwili.
set -eu
U=user; H=/home/$U; S=/tmp/ra
RUN=(sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0)
install -d -o $U -g $U $H/.local/bin $H/.config/systemd/user $H/.config/mpv/scripts $H/.local/share/kwin/scripts
[ -x /usr/local/libexec/y700-refresh-auto ] || { echo "no daemon: run daemon/install.sh first"; exit 1; }
install -m 644 -o $U -g $U $S/y700-refresh-auto.service $H/.config/systemd/user/y700-refresh-auto.service
install -m 644 -o $U -g $U $S/y700-video-state.lua $H/.config/mpv/scripts/y700-video-state.lua
rm -rf $H/.local/share/kwin/scripts/y700-refresh-auto
cp -r $S/kwin-script $H/.local/share/kwin/scripts/y700-refresh-auto
chown -R $U:$U $H/.local/share/kwin/scripts/y700-refresh-auto
[ -e /root/y700-display-watchdog.bak-20261016 ] || cp -a /usr/local/libexec/y700-display-watchdog /root/y700-display-watchdog.bak-20261016
install -m 755 $S/y700-display-watchdog /usr/local/libexec/y700-display-watchdog
if [ "${WILIWILI:-1}" = 1 ]; then
	if pgrep -x wiliwili >/dev/null; then echo "wiliwili is running: binary NOT replaced (re-run with it closed)"; else
		[ -e /root/wiliwili.bin.bak-20261016-vs ] || cp -a /usr/local/bin/wiliwili /root/wiliwili.bin.bak-20261016-vs
		(cd /usr/local/src/wiliwili/build && ninja >/dev/null && ninja install >/dev/null) && echo "wiliwili installed: $(stat -c %y /usr/local/bin/wiliwili | cut -c1-19)"
	fi
fi
"${RUN[@]}" systemctl --user daemon-reload
"${RUN[@]}" systemctl --user enable y700-refresh-auto.service
"${RUN[@]}" systemctl --user restart y700-refresh-auto.service
sleep 3
"${RUN[@]}" systemctl --user is-active y700-refresh-auto.service
"${RUN[@]}" journalctl --user -u y700-refresh-auto -n 8 --no-pager -o cat
