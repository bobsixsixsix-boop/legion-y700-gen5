#!/bin/bash
# 2026-10-18 06:35: read-only - which CPUs do the Chromium/Electron compositor threads run on, versions, panel mode,
# what the windows look like (KWin script), what the GPU processes' other threads do
export LC_ALL=C
U="sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
echo "== versions"
kwin_wayland --version 2>&1 | head -1
/opt/google/chrome/chrome --version 2>&1 | head -1
strings /usr/lib/claude-desktop/claude-desktop 2>/dev/null | grep -m1 -oE 'Chrome/[0-9.]+ Electron/[0-9.]+'
dpkg -l claude-desktop google-chrome-stable 2>/dev/null | awk '/^ii/ {print $2, $3}'
echo "== panel"; $U kscreen-doctor -o 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Output|Modes|\*' | cut -c1-200 | head -6
echo "== compositor threads: cpu now / allowed, 5 samples"
for tid in $(for t in /proc/[0-9]*/task/[0-9]*; do [ "$(cat $t/comm 2>/dev/null)" = VizCompositorTh ] && echo ${t##*/}; done); do
	p=$(awk '/^Tgid/ {print $2}' /proc/$tid/status)
	cpus=""; for i in 1 2 3 4 5; do cpus="$cpus $(awk '{print $39}' /proc/$tid/stat)"; sleep 0.2; done
	echo "$p/$tid $(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-60) | cpu:$cpus | allowed $(awk '/Cpus_allowed_list/ {print $2}' /proc/$tid/status)"
done
echo "== GPU-process threads, wakeups/s over 10 s"
for p in $(pgrep -f 'type=gpu-process'); do
	a=$(for t in /proc/$p/task/*; do echo "${t##*/} $(cat $t/comm) $(awk '/ctxt_switches/ {s += $2} END {print s}' $t/status)"; done)
	sleep 10
	b=$(for t in /proc/$p/task/*; do echo "${t##*/} $(awk '/ctxt_switches/ {s += $2} END {print s}' $t/status)"; done)
	echo "-- $p $(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-50)"
	join <(echo "$a" | sort) <(echo "$b" | sort) | awk '{r = ($4 - $3) / 10; if (r >= 0.5) printf "   %6.1f/s %s %s\n", r, $1, $2}' | sort -rn | head -8
done
echo "== renderer/browser threads with >= 5 wakeups/s over 10 s (claude-desktop, chrome)"
a=$(for t in /proc/[0-9]*/task/[0-9]*; do p=${t#/proc/}; p=${p%%/*}; case "$(cat /proc/$p/comm 2>/dev/null)" in claude-desktop|chrome) echo "$p/${t##*/} $(cat $t/comm | tr ' ' _) $(awk '/ctxt_switches/ {s += $2} END {print s}' $t/status)";; esac; done)
sleep 10
b=$(for t in /proc/[0-9]*/task/[0-9]*; do p=${t#/proc/}; p=${p%%/*}; case "$(cat /proc/$p/comm 2>/dev/null)" in claude-desktop|chrome) echo "$p/${t##*/} $(awk '/ctxt_switches/ {s += $2} END {print s}' $t/status)";; esac; done)
join <(echo "$a" | sort) <(echo "$b" | sort) | awk '{r = ($4 - $3) / 10; if (r >= 5) printf "   %6.1f/s %s %s\n", r, $1, $2}' | sort -rn | head -14
echo "== windows"
cp /root/y700win.js /tmp/y700win.js 2>/dev/null && bash /root/kwinlist.sh 2>&1 | grep -viE 'plasmashell|^script id' | head -12
