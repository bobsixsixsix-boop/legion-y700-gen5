#!/bin/bash
# y12-orchestrate.sh: run on the Win11 side (Git Bash), in the background. 2026-10-16.
# Rules it follows: reboot the tablet only when it is not in use; visible tests <= 15 min and only while the
# tablet is idle; no ssh during a measurement window (one held session per run, no polling logins);
# quiet hours: no visible test / reboot after LAST (default 23:00), because the screen lights up.
#   1. wait for idle (status page dpms=Off for >= 4 polls 1 min apart, then one ssh: no running sink, no touch in 30 s)
#   2. y10 baseline: video-gpu-tune2.sh on y10 (same conditions as on y12 later); an owner touch aborts it -> back to 1
#   3. reboot into the y12 trial; wait for the new boot id on the status page (gives up after 6 min: then stop and
#      report - do NOT force more reboots, an early-boot hang is not caught by the trial counter)
#   4. y12-postboot.sh; any FAIL line -> stop here (a human looks before anything else runs on y12)
#   5. wait for idle again, then video-gpu-tune2.sh on y12
# Everything is printed with timestamps; the summaries of both tune2 runs are printed at the end.
set -u
LAST=${LAST:-23:00}
K=(ssh -i "$HOME/.ssh/y700_ed25519" -o ConnectTimeout=10 -o ServerAliveInterval=30 root@100.64.0.10)
st() { curl -s -m 5 http://100.64.0.10:8766/; }
say() { echo "$(date +%T) $*"; }
late() { [ "$(date +%H:%M)" \> "$LAST" ]; }
wait_idle() {   # returns 0 when idle, 1 when it got too late
	local off=0 c
	# IDLE_MODE=go (explicit go-ahead with the screen left on): idle = no running sink and no touch in
	# 60 s, whatever the screen state
	while [ "${IDLE_MODE:-off}" = go ]; do
		late && return 1
		c=$("${K[@]}" 'export LC_ALL=C; s=$(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 LC_ALL=C pactl list short sinks | grep -c RUNNING); a=$(awk "/NVT-ts/ {print \$2}" /proc/interrupts); sleep 60; b=$(awk "/NVT-ts/ {print \$2}" /proc/interrupts); echo "$s $((b - a))"')
		say "idle check, go mode (running sinks, touches in 60 s): $c"
		set -- $c
		[ "${1:-1}" = 0 ] && [ "${2:-1}" = 0 ] && return 0
		sleep 60
	done
	while :; do
		late && return 1
		if st | grep -q "^device *dpms=Off"; then off=$((off + 1)); else off=0; fi
		if [ $off -ge 4 ]; then
			c=$("${K[@]}" 'export LC_ALL=C; s=$(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 LC_ALL=C pactl list short sinks | grep -c RUNNING); a=$(awk "/NVT-ts/ {print \$2}" /proc/interrupts); sleep 30; b=$(awk "/NVT-ts/ {print \$2}" /proc/interrupts); echo "$s $((b - a)) $(cat /sys/class/drm/card*-DSI-1/dpms)"')
			say "idle check (running sinks, touches in 30 s, dpms): $c"
			set -- $c
			[ "${1:-1}" = 0 ] && [ "${2:-1}" = 0 ] && [ "${3:-On}" = Off ] && return 0
			off=0
		fi
		sleep 60
	done
}
run_tune2() {   # $1 = label; returns 0 = completed, 4 = owner touched, other = failed
	local tag=$1 out
	say "tune2 ($tag) starting on $("${K[@]}" uname -r)"
	out=$("${K[@]}" 'systemctl reset-failed y700-video-gpu-tune2 2>/dev/null; systemd-run --unit=y700-video-gpu-tune2 --collect -p KillMode=mixed bash /root/video-gpu-tune2.sh 75 >/dev/null 2>&1; sleep 5
		for i in $(seq 120); do grep -q restored /root/video-gpu-tune2/windows.txt 2>/dev/null && break; sleep 10; done
		cat /root/video-gpu-tune2/windows.txt; echo; bash /root/video-gpu-ab-analyze.sh /root/video-gpu-tune2 | grep -E "^(reference|profile)"
		d=/root/video-gpu-tune2-'"$tag"'-$(date +%H%M); cp -a /root/video-gpu-tune2 $d && echo "saved to $d"')
	echo "$out" | sed "s/^/    /"
	echo "$out" | grep -q "owner input 1" && return 4
	echo "$out" | grep -q "window 8 " && return 0
	return 1
}
boot0=$(st | awk '/^time/ {print $NF}')
say "start: boot $boot0, nothing new after $LAST"
# --- 1+2: y10 baseline
while :; do
	wait_idle || { say "too late for a visible test today - stopping before the reboot (y12 stays installed as trial for the next start)"; exit 0; }
	run_tune2 y10; rc=$?
	[ $rc = 0 ] && break
	[ $rc = 4 ] && { say "owner came back during the y10 run - waiting for the next idle"; continue; }
	say "y10 tune2 failed (rc $rc) - stopping"; exit 1
done
# --- 3: reboot
wait_idle || { say "too late to reboot today - y12 stays installed as trial for the next start"; exit 0; }
say "rebooting into the y12 trial"
"${K[@]}" 'sync; systemctl reboot' || true
b=""
for j in $(seq 36); do sleep 10; b=$(st | awk '/^time/ {print $NF}'); [ -n "$b" ] && [ "$b" != "$boot0" ] && break; done
[ -z "$b" ] || [ "$b" = "$boot0" ] && { say "the tablet is not back after 6 min (status page) - STOP, do not force reboots; check the panel / USB"; exit 2; }
say "back up: boot $b"; sleep 90
# --- 4: post-boot checks
pb=$("${K[@]}" 'uname -r; bash /root/y12-postboot.sh' 2>&1); echo "$pb" | sed "s/^/    /"
echo "$pb" | head -1 | grep -q -- "-y12$" || { say "not running y12 after the reboot - STOP"; exit 2; }
echo "$pb" | grep -qE "^FAIL|SOME FAILED" && { say "y12-postboot has FAIL lines - STOP for a human look (nothing else runs on y12)"; exit 3; }
# --- 5: y12 run
while :; do
	wait_idle || { say "too late for the y12 visible test today - stopping (y12 verified, not yet compared, still trial)"; exit 0; }
	run_tune2 y12; rc=$?
	[ $rc = 0 ] && break
	[ $rc = 4 ] && { say "owner came back during the y12 run - waiting for the next idle"; continue; }
	say "y12 tune2 failed (rc $rc) - stopping"; exit 1
done
say "done: compare the two tune2 summaries above (same conditions, y10 vs y12)"
