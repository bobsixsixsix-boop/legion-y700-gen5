#!/bin/bash
# 2026-10-18: is it the Chromium/Electron windows? Screen off, cx-auto armed. 60 s baseline, then minimize the Chrome and
# Claude windows through a KWin script (xdg_toplevel "suspended" should tell Chromium it is hidden), settle 15 s, 60 s
# again, then un-minimize them bottom-to-top in the old stacking order and give focus back to the window that had it.
# Touches window state only, no process.
export LC_ALL=C
G=/sys/kernel/debug/pm_genpd
B="sudo -u user DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus busctl --user"
dpkg -l kwin-wayland kwin-common 2>/dev/null | awk '/^ii/ {print $2, $3}'
kwin() {   # run JS once in KWin, print its Y700M lines
	printf '%s\n' "$1" > /tmp/y700m.js; chmod 644 /tmp/y700m.js
	local since id; since=$(date '+%F %T')
	$B call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s y700m >/dev/null 2>&1
	id=$($B call org.kde.KWin /Scripting org.kde.kwin.Scripting loadScript ss /tmp/y700m.js y700m | awk '{print $2}')
	$B call org.kde.KWin /Scripting/Script$id org.kde.kwin.Script run >/dev/null
	sleep 1
	$B call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s y700m >/dev/null
	journalctl --since "$since" --no-pager -o cat | grep Y700M | sed 's/.*Y700M //'
}
snap() {   # cluster0 cluster1 system arch_timer, then tid:ctxt of every VizCompositorTh
	printf "%s %s %s %s" "$(sed -n 2p $G/power-domain-cluster/idle_states | awk '{print $3}')" "$(sed -n 2p $G/power-domain-cluster1/idle_states | awk '{print $3}')" \
		"$(sed -n 2p $G/power-domain-system/idle_states | awk '{print $3}')" "$(awk '/arch_timer/ {s = 0; for (i = 2; i <= 9; i++) s += $i; print s}' /proc/interrupts)"
	for t in /proc/[0-9]*/task/[0-9]*; do [ "$(cat $t/comm 2>/dev/null)" = VizCompositorTh ] && awk -v t=${t##*/} '/ctxt_switches/ {s += $2} END {printf " %s:%d", t, s}' $t/status; done
	echo
}
win() {
	local a b; a=$(snap); sleep 60; b=$(snap)
	echo "$a" "$b" | awk -v t="$(date +%T)" -v w="$1" -v d="$(cat /sys/class/drm/card*-DSI-1/dpms | head -1)" -v ar="$([ -e /run/y700-cx-auto.armed ] && echo Y || echo N)" '{
		n = NF / 2; printf "%s %-9s dpms=%s armed=%s  cl0 %.1f/s  cl1 %.1f/s  sys %.1f/s  arch_timer %.0f/s  | viz", t, w, d, ar, ($(n+1)-$1)/60, ($(n+2)-$2)/60, ($(n+3)-$3)/60, ($(n+4)-$4)/60
		for (i = 5; i <= n; i++) { split($i, x, ":"); split($(n+i), y, ":"); printf "  %s %.1f/s", x[1], (y[2]-x[2])/60 }
		print "" }'
}
LIST='const so = workspace.stackingOrder; for (let i = 0; i < so.length; i++) { const w = so[i]; if (w.normalWindow) print("Y700M " + i + " " + w.resourceClass + " min=" + w.minimized + " active=" + (w === workspace.activeWindow) + " [" + w.caption + "]"); }'
echo "== before"; BEFORE=$(kwin "$LIST"); echo "$BEFORE"
ACT=$(echo "$BEFORE" | awk '/active=true/ {print $2; exit}')
win baseline
kwin 'const so = workspace.stackingOrder; for (let i = 0; i < so.length; i++) { const w = so[i]; if (w.resourceClass == "google-chrome" || w.resourceClass == "com.anthropic.Claude") { w.minimized = true; print("Y700M minimized " + w.resourceClass); } }'
sleep 15
win minimized
kwin 'const so = workspace.stackingOrder; for (let i = 0; i < so.length; i++) { const w = so[i]; if ((w.resourceClass == "google-chrome" || w.resourceClass == "com.anthropic.Claude") && w.minimized) { w.minimized = false; print("Y700M restored " + w.resourceClass); } }'
[ -n "$ACT" ] && kwin 'const so = workspace.stackingOrder; for (let i = so.length - 1; i >= 0; i--) { if (so[i].normalWindow && so[i].resourceClass == "'"$ACT"'") { workspace.activeWindow = so[i]; print("Y700M focused " + so[i].resourceClass); break; } }'
echo "== after"; kwin "$LIST"
sleep 15
win restored
