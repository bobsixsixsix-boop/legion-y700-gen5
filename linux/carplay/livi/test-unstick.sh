#!/bin/bash
# linux/carplay/livi/test-unstick.sh [LAUNCHER] -- stub test for y700-carplay's unstick (10-23): an iPhone that asked
# for CarPlay over Bluetooth while the hotspot's interface was gone gets its Bluetooth link dropped once the access
# point is up. Runs anywhere (Git Bash on the PC, or the tablet as any user): fake iw/ip/bluetoothctl on PATH, a
# "sleep" standing in for LIVI and a log file written by hand; nothing real is touched. ~20 s.
#   late      failure, access point up 1.5 s later -> one disconnect of that phone, and not before the access point
#   wired     the failure names a USB interface (wired iPhone) -> nothing
#   started   a start went out before the access point came up -> nothing
#   left      the phone left Bluetooth meanwhile -> nothing
#   nomac     no "phone connected" line before the failure -> nothing
#   four      four failures, access point up -> three disconnects, no more
#   quit      LIVI quits while unstick waits for the access point -> nothing, and unstick ends with it
H=$(cd "$(dirname "$0")" && pwd)
L=${1:-$H/y700-carplay}
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin"
printf '#!/bin/sh\n[ -e "$STUB/ap" ] && echo "	type AP" || echo "	type managed"\n' >"$T/bin/iw"
printf '#!/bin/sh\n[ -e "$STUB/ap" ] && echo "    inet6 fe80::1/64 scope link"\nexit 0\n' >"$T/bin/ip"
cat >"$T/bin/bluetoothctl" <<'EOF'
#!/bin/sh
case "$1" in
    info) [ -e "$STUB/connected" ] && echo "	Connected: yes" || echo "	Connected: no" ;;
    disconnect) echo "disconnect $2" >>"$STUB/calls" ;;
esac
EOF
chmod +x "$T"/bin/*
MAC=02:00:00:00:00:30
CONN="[00:21:30.507] [helper] [helperd] phone connected mac=$MAC"
FAIL='[00:21:31.034] [helper!] [cp-sock] bt bring-up failed: no link-local on "wlp1s0"'

fails=0
# run SCENARIO: a fake LIVI (sleep) and a fresh log; the scenario writes the log and flags, then checks
start() {
    rm -f "$T/ap" "$T/calls" "$T/connected" "$T/log"; : >"$T/log"; touch "$T/connected"
    sleep "${1:-6}" & livi=$!
    STUB=$T PATH="$T/bin:$PATH" sh "$L" --unstick "$livi" "$T/log" >>"$T/log" 2>&1 & watcher=$!
    sleep 0.5
}
calls() { [ -e "$T/calls" ] && grep -c "^disconnect $MAC$" "$T/calls" || echo 0; }
finish() {   # name, expected disconnects, what the log must say ("" for nothing)
    kill "$livi" 2>/dev/null; wait "$watcher" 2>/dev/null
    got=$(calls)
    if [ "$got" = "$2" ] && { [ -z "$3" ] || grep -q -- "$3" "$T/log"; }; then
        echo "PASS $1"
    else
        echo "FAIL $1: $got disconnects (want $2)${3:+, log wants \"$3\"}"; sed 's/^/     /' "$T/log"; fails=$((fails + 1))
    fi
}

start; echo "$CONN" >>"$T/log"; echo "$FAIL" >>"$T/log"; sleep 1.5
early=$(calls); touch "$T/ap"; sleep 1.5
if [ "$early" = 0 ]; then
    finish late 1 "dropping its Bluetooth link"
else
    echo "     (late: disconnected before the access point was up)"; finish late none
fi

start; touch "$T/ap"; echo "$CONN" >>"$T/log"
echo '[00:21:31.034] [helper!] [cp-sock] usb bring-up failed: no link-local on "enx3e1d"' >>"$T/log"; sleep 1.5
finish wired 0

start; echo "$CONN" >>"$T/log"; echo "$FAIL" >>"$T/log"; sleep 0.5
echo "[00:21:33.000] [helper] [cp] CarPlayStartSession ip=fe80::1 port=7000 device_id=x pk_len=64" >>"$T/log"
touch "$T/ap"; sleep 1.5
finish started 0 "a start went out meanwhile"

start; rm -f "$T/connected"; touch "$T/ap"; echo "$CONN" >>"$T/log"; echo "$FAIL" >>"$T/log"; sleep 1.5
finish left 0 "left Bluetooth meanwhile"

start; touch "$T/ap"; echo "$FAIL" >>"$T/log"; sleep 1.5
finish nomac 0

start; touch "$T/ap"; echo "$CONN" >>"$T/log"
for k in 1 2 3 4; do echo "$FAIL" >>"$T/log"; sleep 0.7; done; sleep 1
finish four 3 "(3/3"

start 2; echo "$CONN" >>"$T/log"; echo "$FAIL" >>"$T/log"; sleep 3.5
if kill -0 "$watcher" 2>/dev/null; then
    echo "FAIL quit: unstick still runs 2 s after LIVI quit"; fails=$((fails + 1)); kill "$watcher"
else
    finish quit 0
fi

[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
