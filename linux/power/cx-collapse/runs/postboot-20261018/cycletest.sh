#!/bin/bash
# 2026-10-18: Chrome / Claude desktop renderers are idle, only their GPU processes' VizCompositorThread ticks at 60/120 Hz.
# Guess: a frame was still pending when the panel went off (06:01:43, kscreen-doctor right after boot), the presentation
# feedback never came, and viz keeps its BeginFrame timer running while it waits. Test: screen on for 10 s (KWin presents,
# everything pending gets acked), off again, wait for cx-auto to re-arm, then 60 s of counters and viz rates.
export LC_ALL=C
G=/sys/kernel/debug/pm_genpd
U="sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
snap() {
	printf "%s %s %s %s" "$(sed -n 2p $G/power-domain-cluster/idle_states | awk '{print $3}')" "$(sed -n 2p $G/power-domain-cluster1/idle_states | awk '{print $3}')" \
		"$(sed -n 2p $G/power-domain-system/idle_states | awk '{print $3}')" "$(awk '/arch_timer/ {s = 0; for (i = 2; i <= 9; i++) s += $i; print s}' /proc/interrupts)"
	for t in /proc/[0-9]*/task/[0-9]*; do [ "$(cat $t/comm 2>/dev/null)" = VizCompositorTh ] && awk -v t=${t##*/} '/ctxt_switches/ {s += $2} END {printf " %s:%d", t, s}' $t/status; done
	echo
}
win() {
	local a b; a=$(snap); sleep "${2:-60}"; b=$(snap)
	echo "$a" "$b" | awk -v t="$(date +%T)" -v w="$1" -v s="${2:-60}" -v d="$(cat /sys/class/drm/card*-DSI-1/dpms | head -1)" -v ar="$([ -e /run/y700-cx-auto.armed ] && echo Y || echo N)" '{
		n = NF / 2; printf "%s %-10s dpms=%s armed=%s  cl0 %.1f/s  cl1 %.1f/s  sys %.1f/s  arch_timer %.0f/s  | viz", t, w, d, ar, ($(n+1)-$1)/s, ($(n+2)-$2)/s, ($(n+3)-$3)/s, ($(n+4)-$4)/s
		for (i = 5; i <= n; i++) { split($i, x, ":"); split($(n+i), y, ":"); printf "  %s %.1f/s", x[1], (y[2]-x[2])/s }
		print "" }'
}
win before 30
$U kscreen-doctor --dpms on >/dev/null 2>&1
win screen-on 10
$U kscreen-doctor --dpms off >/dev/null 2>&1
echo "$(date +%T) screen off again"
for i in $(seq 1 24); do [ -e /run/y700-cx-auto.armed ] && break; sleep 5; done
echo "$(date +%T) armed=$([ -e /run/y700-cx-auto.armed ] && echo Y || echo N)"
sleep 15
win after
win after2
