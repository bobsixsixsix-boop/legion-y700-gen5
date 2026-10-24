#!/bin/bash
# y700-power-ab.sh: idle power, one suspect removed at a time (2026-10-15, owner: 7-9 W doing nothing).
#   A as is   B Claude desktop minimized   C + HUD overlay stopped   D + backlight at half
# Everything is put back at the end (trap). Run as root on the tablet; needs y700-powerwhy + kwin-eval.sh.
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
BL=$(ls -d /sys/class/backlight/* | head -1); bl0=$(cat $BL/brightness)
hud0=$("${U[@]}" systemctl --user is-active y700-hud-overlay.service)
SECS=${SECS:-25}
claude() { echo "for (const w of workspace.windowList()) if (w.resourceClass == 'com.anthropic.Claude' && w.normalWindow) w.minimized = $1;" | /usr/local/libexec/kwin-eval.sh >/dev/null; }
restore() {
	echo "$bl0" > $BL/brightness
	[ "$hud0" = active ] && "${U[@]}" systemctl --user start y700-hud-overlay.service
	claude false
}
trap restore EXIT
m() { sleep 5; y700-powerwhy "$SECS" | grep -E "device power|panel refresh|cpu policy6|== CPU" | sed "s/^/   /"; }
echo "== A as is (backlight $bl0, HUD $hud0)"; m
claude true;                                                    echo "== B Claude minimized"; m
"${U[@]}" systemctl --user stop y700-hud-overlay.service;       echo "== C + HUD stopped"; m
echo $((bl0 / 2)) > $BL/brightness;                             echo "== D + backlight $((bl0 / 2))"; m
