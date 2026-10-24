#!/bin/bash
# gate-log.sh SECONDS [OUT]: record, for SECONDS, everything that decides whether the on-screen keyboard
# comes up: the y700-oskgate signals (touches, text-input show requests, IM active), fcitx5's
# ShowVirtualKeyboard/HideVirtualKeyboard to the keyboard, the KWin launcher's Controller1 Show/Hide,
# and the keyboard's own requestShow. One line per event, in dbus-monitor's order.
# Run as root on the tablet, in the background while a test drives vtouch.py.
secs=${1:-10}; out=${2:-/tmp/gate-log.txt}
py=$(mktemp /tmp/gate-log-XXXXXX.py)
trap 'rm -f "$py"' EXIT INT TERM      # gate-run.sh kills us before the end
cat > "$py" <<'EOF'
import re, sys
cur = None
for line in sys.stdin:
    m = re.match(r"^(signal|method call) time=([0-9.]+) .*?(?:interface=([^;]+); )?member=(\S+)", line)
    if m:
        cur = (float(m.group(2)), (m.group(3) or "").split(".")[-1], m.group(4))
        if cur[2] != "Event":
            print(f"{cur[0]:.3f} {cur[1]}.{cur[2]}", flush=True)
        continue
    s = re.match(r'^\s+string "(.*)"$', line)
    if s and cur and cur[2] == "Event":
        print(f"{cur[0]:.3f} gate {s.group(1)}", flush=True)
        cur = None
EOF
sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
	timeout "$secs" dbus-monitor --session \
	"type='signal',interface='org.y700.OskGate'" \
	"type='method_call',member='ShowVirtualKeyboard'" "type='method_call',member='HideVirtualKeyboard'" \
	"type='method_call',interface='fyi.fortime.Fcitx5Osk.Controller1'" 2>/dev/null |
	python3 -u "$py" > "$out"
rm -f "$py"
