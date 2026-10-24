#!/bin/bash
# 2026-10-18: does Chrome's --enable-features=WaylandExternalBeginFrameSource (Chromium's new compositor-driven
# frame source, disabled by default; it stops issuing begin frames while the toplevel is xdg "suspended", and KWin
# 6.6 marks every window suspended while DPMS is off) stop the GPU-process compositor (VizCompositorTh) from
# ticking at refresh rate with the screen off? Run with the screen OFF, as root, via systemd-run (no ssh while it
# measures). Per run: a throwaway Chrome (own profile under /tmp, the owner's profile untouched) on a local page,
# SETTLE s, then WIN s of per-thread context switches (≈ wakeups) and per-process CPU, then kill.
# Pages: tick = static text updated once a second (damage every second, like an idle chat app); anim = a CSS
# animation (worst case). Output: /root/bfstest-HHMM.txt
export LC_ALL=C
SETTLE=${SETTLE:-45}; WIN=${WIN:-60}
OUT=/root/bfstest-$(date +%H%M).txt
CH=/opt/google/chrome/chrome
U=user
E="XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
mkdir -p /tmp/bfs; chmod 755 /tmp/bfs
cat > /tmp/bfs/tick.html <<'EOF'
<!doctype html><title>tick</title><p id=t></p><script>setInterval(() => t.textContent = new Date().toISOString(), 1000)</script>
EOF
cat > /tmp/bfs/anim.html <<'EOF'
<!doctype html><title>anim</title><style>div{width:60px;height:60px;background:#c33;animation:s 1s linear infinite}
@keyframes s{to{transform:rotate(360deg)}}</style><div></div>
EOF
chmod 644 /tmp/bfs/*.html

dpms() { for c in /sys/class/drm/card*-*; do [ "$(cat $c/status 2>/dev/null)" = connected ] && cat $c/dpms; done | head -1; }
# all chrome processes (only ours: the owner has no Chrome open, checked at start)
procs() { pgrep -f "^$CH( |$)"; }
# Chrome rewrites its process title, so cmdline is one space-joined string, not NUL-separated args
ptype() { tr '\0' ' ' < /proc/$1/cmdline 2>/dev/null | grep -o -m1 -e '--type=[a-z-]*' | head -1 | cut -d= -f2; }
cpu() { awk '{print $14 + $15}' /proc/$1/stat 2>/dev/null; }
# this kernel has no per-task schedstat: count wakeups as voluntary + involuntary context switches
snap() {  # P pid type cputicks / T pid tid comm switches
	for p in $(procs); do
		t=$(ptype $p); echo "P $p ${t:-browser} $(cpu $p)"
		for th in /proc/$p/task/*; do echo "T $p ${th##*/} $(cat $th/comm | tr ' ' _) $(awk '/_ctxt_switches/ {s += $2} END {print s + 0}' $th/status 2>/dev/null)"; done
	done
}

{
echo "bfstest $(date '+%F %T')  chrome $($CH --version 2>/dev/null)  kwin $(kwin_wayland --version 2>/dev/null)  dpms=$(dpms)  SETTLE=$SETTLE WIN=$WIN"
if [ -n "$(procs)" ]; then echo "Chrome already running - abort"; exit 1; fi
for run in tick:default tick:bfs anim:default anim:bfs; do
	page=${run%%:*}; v=${run#*:}
	feat=""; [ $v = bfs ] && feat="--enable-features=WaylandExternalBeginFrameSource"
	rm -rf /tmp/bfs/prof-$v; install -d -o $U /tmp/bfs/prof-$v
	sudo -u $U env $E $CH --ozone-platform=wayland --user-data-dir=/tmp/bfs/prof-$v --no-first-run \
		--no-default-browser-check --password-store=basic --disable-sync --disable-component-update $feat \
		file:///tmp/bfs/$page.html >/dev/null 2>&1 &
	sleep $SETTLE
	g=""; for p in $(procs); do [ "$(ptype $p)" = gpu-process ] && g=$p; done
	echo; echo "== $page / $v  dpms=$(dpms)  gpu=$g  gpu-args: $(tr '\0' ' ' < /proc/$g/cmdline 2>/dev/null | grep -o -e '--ozone-platform=[a-z]*' -e 'WaylandExternalBeginFrameSource' | sort -u | tr '\n' ' ')"
	snap > /tmp/bfs/a; t0=$(date +%s.%N)
	sleep $WIN
	snap > /tmp/bfs/b; t1=$(date +%s.%N)
	awk -v S=$(awk -v a=$t0 -v b=$t1 'BEGIN {print b - a}') 'FNR == NR {a[$1" "$2" "$3] = $NF; next}
		$1 == "P" {k = $1" "$2" "$3; if (k in a) printf "  proc %-8s %-14s cpu %5.1f %%\n", $2, $3, ($4 - a[k]) / S}
		$1 == "T" {k = $1" "$2" "$3; if (k in a) {d = $5 - a[k]; if (d / S >= 2) printf "    thread %-8s %-18s %6.1f wakeups/s\n", $2, $4, d / S}}' \
		/tmp/bfs/a /tmp/bfs/b
	pkill -TERM -f "^$CH .*--user-data-dir=/tmp/bfs/prof-$v"; sleep 5; pkill -KILL -f "^$CH( |$)"; sleep 2
done
echo; echo "done $(date '+%T')  dpms=$(dpms)"
rm -rf /tmp/bfs
} > $OUT 2>&1
