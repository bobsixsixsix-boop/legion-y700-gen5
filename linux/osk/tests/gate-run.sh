#!/bin/bash
# gate-run.sh NAME 'vtouch lines separated by ;' [SETTLE_S]
# One keyboard-popup scenario: hide the keyboard, record (gate-log.sh) while the virtual finger does the
# lines, wait SETTLE_S (default 1.5), then print whether the keyboard is shown, the keyboard's own
# decisions (Gate log, last GATELINES lines) and, unless QUIET is set, every recorded D-Bus event.
# Run as root on the tablet; needs y700-vtouch (vtouch.py) running.
name=${1:?name}; cmds=${2:?commands}; settle=${3:-1.5}
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
log=/tmp/gate-$name.log
# a touch on a dark screen only wakes it (KWin's DPMS filter swallows it): keep the panel on
if grep -q Off /sys/class/drm/card*-DSI-1/dpms 2>/dev/null; then "${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 1.2; fi
"${U[@]}" /usr/local/bin/y700-osk hide >/dev/null 2>&1; sleep 0.6
/usr/local/libexec/gate-log.sh 30 "$log" & lp=$!
sleep 0.6
printf '%s\n' "$cmds" | tr ';' '\n' | sed 's/^ *//' > /run/y700-vtouch.fifo
sleep "$settle"
shown=$("${U[@]}" busctl --user call fyi.y700.Osk /Osk fyi.y700.Osk debug ss state x 2>/dev/null | grep -o 'shown[^,]*' | head -1)
kill $lp 2>/dev/null; pkill -f "dbus-monitor --session type=.signal.,interface=.org.y700.OskGate" 2>/dev/null; sleep 0.2
echo "=== $name   keyboard: ${shown:-?}"
"${U[@]}" busctl --user call fyi.y700.Osk /Osk fyi.y700.Osk debug ss gate x 2>/dev/null |
	python3 /usr/local/libexec/gate-unescape.py "${GATELINES:-7}"
if [ -z "${QUIET:-}" ]; then
	t0=$(head -1 "$log" | cut -d' ' -f1)
	awk -v t0="$t0" '{ printf "%+7.3f %s\n", $1 - t0, substr($0, index($0, $2)) }' "$log"
fi
