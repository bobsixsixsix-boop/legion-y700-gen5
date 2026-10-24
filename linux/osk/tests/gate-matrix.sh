#!/bin/bash
# gate-matrix.sh: the keyboard-popup scenarios the owner cares about, driven with the virtual finger.
# Layout first (KWin script): Telegram on the left (10,10 780x900), Claude desktop on the right
# (810,10 780x900). Each "activate" scenario makes the OTHER window active first, so the tap also
# activates its window - the case that popped the keyboard up for nothing (2026-10-14).
# Expected: tap a text field -> keyboard; tap elsewhere / drag the title -> no keyboard; tap an already
# focused field again after the keyboard was hidden -> keyboard.
# Run as root on the tablet: y700-vtouch running, y700_oskgate loaded. Prints a compact log per case.
K=/usr/local/libexec
act() { echo "for (const w of workspace.windowList()) if (w.resourceClass == '$1') workspace.activeWindow = w;" | $K/kwin-eval.sh >/dev/null; sleep 0.8; }
place() {
	cat <<'EOF' | $K/kwin-eval.sh >/dev/null
const place = { "org.telegram.desktop": [10, 10, 780, 900], "com.anthropic.Claude": [810, 10, 780, 900] };
for (const w of workspace.windowList()) { const p = place[w.resourceClass]; if (p && w.normalWindow) { w.setMaximize(false, false); w.frameGeometry = { x: p[0], y: p[1], width: p[2], height: p[3] }; } }
EOF
	sleep 0.8
}
run() { $K/gate-run.sh "$@" | sed -E 's/"wid":"[^"]*",?//g; s/"t0?":[0-9]+,?//g; s/"(x0|y0)":([0-9]+)\.[0-9]+/"\1":\2/g' | grep -vE 'DBus\.Name'; }

TG_PANE="510 570"; TG_SEARCH="190 55"; TG_TITLE="475 19"
CL_PROMPT="1187 762"; CL_EMPTY="1206 570"
place
act com.anthropic.Claude;  run tg-pane "tap $TG_PANE 60" 2
act com.anthropic.Claude;  run tg-search "tap $TG_SEARCH 60" 2
run tg-search-again "tap $TG_SEARCH 60" 2
act com.anthropic.Claude;  run tg-title-drag "drag $TG_TITLE 575 60 400 20" 2
place
act org.telegram.desktop;  run cl-prompt "tap $CL_PROMPT 60" 2
act org.telegram.desktop;  run cl-empty "tap $CL_EMPTY 60" 2
act com.anthropic.Claude;  run cl-prompt-again "tap $CL_PROMPT 60" 2
act org.telegram.desktop;  run tg-pane-same "tap $TG_PANE 60" 2
sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus /usr/local/bin/y700-osk hide
