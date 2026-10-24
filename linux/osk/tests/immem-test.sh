#!/bin/sh
# 中/英 memory check (run as root on the tablet, display off: it opens a test window).
# Pretends the owner last picked Chinese, restarts fcitx5 (its state falls back to English), opens
# the probe text field and expects the keyboard to come up in Chinese. Restores the owner's value.
U="sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0"
PROBE=/usr/local/src/y700-osk/tests/probe/build/y700-osk-probe
CONF=/home/user/.config/y700/y700-osk.conf
if [ "$1" != "--force" ] && ! grep -q Off /sys/class/drm/card*-DSI-1/dpms 2>/dev/null; then echo "display is on: run with --force to override"; exit 3; fi
dbg() { $U busctl --user call fyi.y700.Osk /Osk fyi.y700.Osk debug ss "$1" "$2" 2>&1; }
chain() {   # restart fcitx5 (state back to English), then the launcher chain (it exits with fcitx5)
    $U busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 Restart >/dev/null 2>&1
    sleep 3; $U /usr/local/bin/y700-osk-ctl restart; sleep 4
}
orig=$($U kreadconfig6 --file $CONF --group im --key last)
$U kwriteconfig6 --file $CONF --group im --key last rime
chain
$U QT_QPA_PLATFORM=wayland $PROBE 30 >/dev/null 2>&1 &
sleep 3
# the probe's programmatic focus no longer brings the keyboard up while the KWin gate is loaded;
# Osk::show(false) is what a confirmed tap calls (and it restores the remembered 中/英)
$U /usr/local/bin/y700-osk show >/dev/null 2>&1; sleep 1
st=$(dbg state x)
pkill -x y700-osk-probe 2>/dev/null
if echo "$st" | grep -q '\\"zh\\":true'; then echo "PASS remembered Chinese restored after an fcitx5 restart"; r=0
else echo "FAIL expected Chinese after restart: $st"; r=1; fi
# put the owner's own choice back, and let fcitx5 start over with it
if [ -n "$orig" ]; then $U kwriteconfig6 --file $CONF --group im --key last "$orig"; else $U kwriteconfig6 --file $CONF --group im --key last --delete; fi
chain
echo "owner's remembered IM restored: ${orig:-<none>}"
exit $r
