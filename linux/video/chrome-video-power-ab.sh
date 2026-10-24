#!/bin/bash
# [RES=1080|2160] [URL=page] chrome-video-power-ab.sh [WINDOW_S]: controlled Chrome video power test (VISIBLE: lights the screen and plays a
# muted test clip in a kiosk Chrome with a throw-away profile; the owner's Chrome and profile are not touched).
# ROOT, run with systemd-run, from a directory that also holds y700-no-waitboost.c. 2026-10-18.
# Why: the owner saw 5.8-6 W watching a 60 fps YouTube video in Chrome. Read-only look at that moment: hardware
# decode in use, but the GPU floor was held at 1200 MHz by msm's fence-deadline "wait boost" (965 boosts in 5 s,
# called from Chrome's GPU process through Mesa's syncobj waits), and Chrome's GPU process took 38 % GPU time.
# Windows (WINDOW_S each, default 60), counterbalanced:
#   A  Chrome as the owner starts it from the desktop icon (zink via /etc/drirc, same flags)
#   B  the same with LD_PRELOAD=y700-no-waitboost.so (the wait-boost hints dropped, waits unchanged)
#   order A B B A, then M = mpv, same clip (hwdec=vaapi, vo=gpu/OpenGL), as the reference for what the video costs
# Since 2026-10-18 22:36 the shim is in /etc/ld.so.preload, so EVERY Chrome window would carry it: the script sets the
# shim's switch file /run/user/1000/y700-no-waitboost.ctl to Y0 (off) for every window except B (Y1) and puts the
# previous value back on exit. The file is shared with the owner's Chrome, hence the "no video playing" precondition.
# Clip: RES p60 VP9 (default 1080; the owner's screen is 3040x1904, so YouTube "auto" sends 2160p60 there; VA-API
# decodes VP9 profile 0/2), looped, served over local http. Encoded once into /root/vt/ (2160p takes minutes).
# Per second: battery power, backlight, GPU cur/min freq, DDR and LLCC freq (devfreq), CPU busy % (all cores). Per window: msm_devfreq_boost and msm_fence_set_deadline
# hits (kprobe_profile, tracing_on 0 so nothing is buffered), GPU time per client (DRM fdinfo), CPU of the player and
# KWin, dropped/total frames (Chrome: DevTools getVideoPlaybackQuality; mpv: frame-drop-count), panel refresh.
# y700-refresh-auto takes both players down to 60 Hz like the owner's video (the test profile gets the extension).
# URL mode variants (CFGS="A L H W X V N ..." overrides the order; each window restarts Chrome):
#   A  the page as is, its player fullscreen      L  the local clip page instead (plain <video>, same flags)
#   H  A with every player overlay hidden (siblings of the video container)   W  A with the rest of the page hidden
#   X  H + W (only the video container is drawn)  V  the bare <video> element fullscreen (no player at all)
#   N  A with --disable-extensions (the Y700 video-state extension out)
#   D  A with the y700-gpu-floor daemon running (it stops for every other window and is started again at the end)
# A number after the letter sets the GPU floor (devfreq min_freq, MHz) for that window only: CFGS="A A282 A342" (the original floor is back after the window).
# Each window also logs: running animations, canvases, rAF per second, and the DevTools layer tree (count, area).
# Aborts (exit 4, screen left on) if the owner touches the screen; restores brightness, auto-brightness, DPMS,
# tracing_on and the kprobes on any exit. Results: /root/chrome-video-power-ab/{samples.tsv,windows.txt}, emptied at
# every start: copy the directory to /root/chrome-video-power-ab-runs/<name>/ to keep a run.
# URL=page instead of the local clip: Chrome opens the page, then DevTools mutes, plays and puts YouTube's own player
# (#movie_player) full screen; the format YouTube actually sent (codec, resolution) goes into windows.txt; no M window.
set -u
WIN=${1:-60}
BL_TEST=${BL_TEST:-800}
H=$(cd "$(dirname "$0")" && pwd)
O=/root/chrome-video-power-ab; mkdir -p $O; rm -f $O/*
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0)
GPU=/sys/class/devfreq/3d00000.gpu
BAT=/sys/class/power_supply/qcom-battmgr-bat
BL=$(ls -d /sys/class/backlight/*/ | head -1)
DPMS=$(ls /sys/class/drm/card*-DSI-1/dpms 2>/dev/null | head -1)
TR=/sys/kernel/tracing; [ -d $TR/events ] || TR=/sys/kernel/debug/tracing
T=/tmp/y700-cvp; P=9336; HP=8766
WL=$(ls /sys/class/net | grep -m1 '^wl')
ID=cgphccdichbpkkdlbnekjojganogdimg
URL=${URL:-}   # instead of the local clip: a web page with a video (e.g. a YouTube watch page), windows A B B A
RES=${RES:-1080}
case $RES in 1080) SIZE=1920x1080; RATE=6M; LEN=20 ;; 2160) SIZE=3840x2160; RATE=20M; LEN=12 ;; *) echo "RES 1080 or 2160" >&2; exit 2 ;; esac
CLIP=/root/vt/vp9-${RES}p60.webm
SOCK=/tmp/y700-cvp-mpv.sock
log() { echo "$(date +%T) $*" | tee -a $O/windows.txt; }
sb() { "${U[@]}" qdbus6 org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0 org.kde.ScreenBrightness.Display.SetBrightness "$1" 1 >/dev/null 2>&1; }
gb() { "${U[@]}" qdbus6 org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0 org.freedesktop.DBus.Properties.Get org.kde.ScreenBrightness.Display Brightness 2>/dev/null; }
touches() { awk '/NVT-ts/ {s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break; print s; exit}' /proc/interrupts; }
ticks() { local s=0 p; for p in "$@"; do s=$((s + $(awk '{print $14 + $15}' /proc/$p/stat 2>/dev/null || echo 0))); done; echo $s; }
hits() { awk -v e="$1" '$1 == e {print $2}' $TR/kprobe_profile; }
tree() { local c; echo $1; for c in $(pgrep -P $1); do tree $c; done; }
gputime() { # summed drm-engine-gpu (ns) over the distinct DRM clients of the given pids
	local p f; for p in "$@"; do for f in /proc/$p/fdinfo/*; do
		awk '/^drm-client-id/{c=$2} /^drm-engine-gpu/{e=$2} END{if (c != "") print c, e}' $f 2>/dev/null
	done; done | sort -u -k1,1 | awk '{s += $2} END{printf "%d", s}'; }
cdpx() { python3 - $P "$1" "${2:-0}" <<'PY'
import json, sys, urllib.request, websocket
try:
    page = next(t for t in json.load(urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/json/list", timeout=3)) if t.get("type") == "page")
    ws = websocket.create_connection(page["webSocketDebuggerUrl"], timeout=10, suppress_origin=True)
    ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": sys.argv[2],
        "returnByValue": True, "awaitPromise": True, "userGesture": sys.argv[3] == "1"}}))
    while True:
        m = json.loads(ws.recv())
        if m.get("id") == 1:
            print(m["result"]["result"].get("value", "?")); break
except Exception as e:
    print("0 0 cdp-error:" + type(e).__name__)
PY
}
cdp() { cdpx "(()=>{const v=document.querySelector('video'),q=v.getVideoPlaybackQuality();return q.totalVideoFrames+' '+q.droppedVideoFrames+' '+(v.paused?'paused':'playing')})()"; }
# URL mode: the page's own player goes fullscreen like the owner's (a DevTools "user gesture"), muted; what YouTube serves
YT_FS="(async()=>{const v=document.querySelector('video'); if(!v) return 'no video'; v.muted=true; try{await v.play()}catch(e){}
 const p=document.querySelector('#movie_player')||v.parentElement; try{await p.requestFullscreen()}catch(e){return 'fullscreen failed: '+e}
 return 'fullscreen '+(document.fullscreenElement.id||document.fullscreenElement.tagName)})()"
YT_FMT="(()=>{const v=document.querySelector('video'),p=document.querySelector('#movie_player');let c='';
 try{const s=p.getStatsForNerds();c=' '+(s.codecs||'')+' '+(s.resolution||'')}catch(e){} return v.videoWidth+'x'+v.videoHeight+c})()"
YT_NOUI="(()=>{const s=document.createElement('style'); s.textContent='#movie_player > :not(.html5-video-container){display:none!important}'; document.head.appendChild(s); return 'player overlays hidden'})()"
YT_ONLY="(()=>{const s=document.createElement('style'); s.textContent='body{visibility:hidden!important} #movie_player,#movie_player *{visibility:visible!important}'; document.head.appendChild(s); return 'rest of page hidden'})()"
YT_BARE="(async()=>{const v=document.querySelector('video'); try{await document.exitFullscreen()}catch(e){} try{await v.requestFullscreen()}catch(e){return 'video fullscreen failed: '+e} return 'fullscreen '+document.fullscreenElement.tagName})()"
DIAG="(async()=>{const a=document.getAnimations(); let n=0; await new Promise(r=>{const t0=performance.now(); const f=()=>{n++; if(performance.now()-t0<1000) requestAnimationFrame(f); else r()}; requestAnimationFrame(f)});
 return 'anims '+a.length+' running '+a.filter(x=>x.playState==='running').length+', canvases '+document.querySelectorAll('canvas').length+', rAF '+n+'/s, nodes '+document.getElementsByTagName('*').length})()"
snap() { # mid-window state dump, for diffing a "+1 W" window against a normal one (same GPU/CPU/DDR, 1 W more battery power)
	local d=$O/snap-$i-$cfg p; mkdir -p $d
	cat /sys/kernel/debug/clk/clk_summary > $d/clk 2>/dev/null; cat /sys/kernel/debug/regulator/regulator_summary > $d/regulator 2>/dev/null
	cat /sys/kernel/debug/pm_genpd/pm_genpd_summary > $d/genpd 2>/dev/null; cat /proc/interrupts > $d/irq; cat /proc/pressure/cpu > $d/psi 2>/dev/null
	for p in /sys/devices/system/cpu/cpufreq/policy*; do echo "$(basename $p) $(cat $p/scaling_cur_freq) $(cat $p/scaling_governor)"; done > $d/cpufreq
	for p in /sys/class/thermal/thermal_zone*; do echo "$(cat $p/type) $(cat $p/temp 2>/dev/null)"; done > $d/thermal
	for p in voltage_now current_now power_now temp capacity; do echo "$p $(cat $BAT/$p 2>/dev/null)"; done > $d/battery
	cat /sys/kernel/debug/dri/*/state > $d/drm-state 2>/dev/null; cat /sys/kernel/debug/gpio > $d/gpio 2>/dev/null
	"${U[@]}" pactl list sinks short > $d/sinks 2>&1; "${U[@]}" pactl list sink-inputs short > $d/sink-inputs 2>&1
	ps -eo pid,pcpu,comm --sort=-pcpu | head -15 > $d/ps
}
gpuall() { # every DRM client on the GPU: "client-id engine-ns comm/pid" (one line per client, whoever owns it)
	local f p
	grep -sl '^drm-client-id' /proc/[0-9]*/fdinfo/* 2>/dev/null | while read -r f; do p=${f#/proc/}; p=${p%%/*}
		awk -v c="$(tr ' ' _ < /proc/$p/comm 2>/dev/null)/$p" '/^drm-client-id/{id=$2} /^drm-engine-gpu/{e=$2} END{if (id != "") print id, e, c}' $f
	done | sort -u -k1,1; }
layers() { python3 - $P <<'PY'
import json, sys, time, urllib.request, websocket
try:
    page = next(t for t in json.load(urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/json/list", timeout=3)) if t.get("type") == "page")
    ws = websocket.create_connection(page["webSocketDebuggerUrl"], timeout=5, suppress_origin=True)
    for i, (m, p) in enumerate([("DOM.enable", {}), ("LayerTree.enable", {}), ("Runtime.evaluate", {"expression": "innerWidth+' '+innerHeight", "returnByValue": True})]):
        ws.send(json.dumps({"id": 10 + i, "method": m, "params": p}))
    vp = ls = None; t0 = time.time()
    while time.time() - t0 < 4 and (vp is None or ls is None):
        m = json.loads(ws.recv())
        if m.get("id") == 12: vp = [float(x) for x in m["result"]["result"]["value"].split()]
        if m.get("method") == "LayerTree.layerTreeDidChange" and m["params"].get("layers"): ls = m["params"]["layers"]
    va = vp[0] * vp[1]; dc = [l for l in ls if l.get("drawsContent")]
    area = lambda l: l["width"] * l["height"]
    top = sorted(dc, key=area, reverse=True)[:4]; out = []
    for k, l in enumerate(top):
        name = "?"
        if l.get("backendNodeId"):
            ws.send(json.dumps({"id": 100 + k, "method": "DOM.describeNode", "params": {"backendNodeId": l["backendNodeId"]}}))
            t1 = time.time()
            while time.time() - t1 < 2:
                m = json.loads(ws.recv())
                if m.get("id") == 100 + k:
                    n = m.get("result", {}).get("node", {}); name = n.get("localName", "?") + ("#" + dict(zip(n.get("attributes", [])[::2], n.get("attributes", [])[1::2])).get("id", "") if n.get("attributes") else ""); break
        out.append("%s %.0fx%.0f paints %s" % (name, l["width"], l["height"], l.get("paintCount")))
    print("layers %d, drawing %d, drawn area %.2fx viewport; biggest: %s" % (len(ls), len(dc), sum(map(area, dc)) / va, "; ".join(out)))
except Exception as e:
    print("layers: " + type(e).__name__ + " " + str(e)[:60])
PY
}
mpvprop() { python3 - "$SOCK" "$1" <<'PY'
import json, socket, sys
try:
    s = socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect(sys.argv[1])
    s.send((json.dumps({"command": ["get_property", sys.argv[2]]}) + "\n").encode()); buf = b""
    while b"\n" not in buf: buf += s.recv(4096)
    print(next(json.loads(l) for l in buf.decode().splitlines() if "error" in json.loads(l)).get("data"))
except Exception as e:
    print("?")
PY
}

bl0=$(gb); dpms0=$(cat $DPMS 2>/dev/null); ab0=$("${U[@]}" systemctl --user is-active y700-autobright.service)
ton0=$(cat $TR/tracing_on); owner=0; PL=; HTTPD=
stop_player() {
	pkill -u user -f -- "--user-data-dir=$T/prof" 2>/dev/null; pkill -u user -f "input-ipc-server=$SOCK" 2>/dev/null
	local k   # not i: that is the window counter
	for k in $(seq 1 20); do pgrep -u user -f -- "--user-data-dir=$T/prof|input-ipc-server=$SOCK" >/dev/null || break; sleep 0.5; done
	pkill -9 -u user -f -- "--user-data-dir=$T/prof" 2>/dev/null; PL=
}
reapply_floor() { # the helper re-applies its profile's floor; min_freq reads back msm's wait-boost requests too, so a saved value is wrong
	local p lo hi
	p=$(tb323fu-ctl gpu 2>/dev/null | sed -n 's/^ *Profile: *//p')
	read -r lo hi < <(tb323fu-ctl gpu 2>/dev/null | awk -v p="$p:" '/Floors:/{f=1; next} f && $1 == p {print $2, $3; exit}')
	[ -n "$p" ] && [ -n "${lo:-}" ] && tb323fu-ctl gpu limits "$p" "$lo" "$hi" >/dev/null 2>&1
}
SW=/run/user/1000/y700-no-waitboost.ctl
sw0=$(head -c 2 $SW 2>/dev/null); case $sw0 in Y0|Y1) ;; *) sw0= ;; esac
setsw() { # Y0 | Y1 into the shim's switch file (owned by the user: the shim in a user process must be able to open it)
	[ -e $SW ] || install -o user -g user -m 664 /dev/null $SW
	printf %s "$1" | dd of=$SW conv=notrunc status=none
}
restore() {
	trap - EXIT
	stop_player; [ -n "$HTTPD" ] && kill $HTTPD 2>/dev/null; pkill -f "http.server $HP" 2>/dev/null
	echo 0 > $TR/events/y700cvp/enable 2>/dev/null
	echo "-:y700cvp/boost" >> $TR/kprobe_events 2>/dev/null; echo "-:y700cvp/deadline" >> $TR/kprobe_events 2>/dev/null
	echo $ton0 > $TR/tracing_on
	[ -n "${flprev:-}" ] && reapply_floor
	setsw "${sw0:-Y1}"
	[ "${gf0:-}" = active ] && systemctl start y700-gpu-floor
	[ -n "$bl0" ] && sb "$bl0"
	[ "$ab0" = active ] && "${U[@]}" systemctl --user start y700-autobright.service
	if [ "$owner" -eq 0 ] && [ "$dpms0" = Off ]; then sleep 1; "${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1; sleep 3; fi
	rm -rf $T
	log "restored: brightness $(gb) (was $bl0), autobright $("${U[@]}" systemctl --user is-active y700-autobright.service) (was $ab0), dpms $(cat $DPMS) (was $dpms0), tracing_on $(cat $TR/tracing_on), kprobes left $(grep -c y700cvp $TR/kprobe_events), owner input $owner"
}

[ -n "$(ls /run/user/1000/y700-video/ 2>/dev/null)" ] && { echo "a video is playing (owner?): $(ls /run/user/1000/y700-video/)" >&2; exit 2; }
[ "$dpms0" = Off ] || [ "${FORCE:-0}" = 1 ] || { echo "screen is on (owner using the tablet?); FORCE=1 to run anyway" >&2; exit 2; }
[ -r $H/y700-no-waitboost.c ] || { echo "y700-no-waitboost.c not next to the script" >&2; exit 2; }
trap restore EXIT; trap 'exit 1' INT TERM
log "start: RES $RES, brightness $bl0, dpms $dpms0, autobright $ab0, battery $(cat $BAT/status) $(cat $BAT/capacity)%, GPU $(($(cat $GPU/min_freq)/1000000))-$(($(cat $GPU/max_freq)/1000000)) MHz, upthreshold $(cat /sys/kernel/debug/dri/1/devfreq/upthreshold 2>/dev/null)"
grep -q Discharging $BAT/status || log "WARNING: not on battery - W figures are not the consumption"

rm -rf $T; mkdir -p $T/www $T/prof/NativeMessagingHosts
gcc -O2 -shared -fPIC -o $T/y700-no-waitboost.so $H/y700-no-waitboost.c -ldl || { log "shim build failed"; exit 2; }
mkdir -p /root/vt
if [ ! -s $CLIP ]; then
	nice ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=$SIZE:rate=60 -t $LEN -c:v libvpx-vp9 -deadline realtime \
		-cpu-used 8 -row-mt 1 -b:v $RATE -g 120 $CLIP.tmp.webm && mv $CLIP.tmp.webm $CLIP || { log "clip encode failed"; exit 2; }
fi
cp $CLIP $T/www/v.webm
cat > $T/www/p.html <<'EOF'
<!doctype html><title>y700 video power</title><style>html,body{margin:0;background:#000;overflow:hidden}
video{position:fixed;inset:0;width:100vw;height:100vh;object-fit:contain;background:#000}</style>
<video src="v.webm" autoplay muted loop playsinline></video>
EOF
cp /home/user/.config/google-chrome/NativeMessagingHosts/fyi.y700.video_state.json $T/prof/NativeMessagingHosts/ 2>/dev/null
chown -R user: $T; chmod 755 $T $T/y700-no-waitboost.so
(cd $T/www && exec sudo -u user python3 -m http.server $HP --bind 127.0.0.1 >/dev/null 2>&1) & HTTPD=$!

echo "p:y700cvp/boost msm_devfreq_boost" >> $TR/kprobe_events
echo "p:y700cvp/deadline msm_fence_set_deadline" >> $TR/kprobe_events
echo 0 > $TR/tracing_on; echo 1 > $TR/events/y700cvp/enable

[ "$ab0" = active ] && "${U[@]}" systemctl --user stop y700-autobright.service
"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 4
sb "$BL_TEST"
KW=$(pgrep -x kwin_wayland | head -1)
hz=$(getconf CLK_TCK)
echo -e "time\twindow\tcfg\tW\tbacklight\tgpu_mhz\tgpu_floor_mhz\tddr_mhz\tllcc_mhz\tcpu_busy\tcomposites" > $O/samples.tsv
cpubusy() { awk '/^cpu /{print $2 + $3 + $4 + $7 + $8, $2 + $3 + $4 + $5 + $6 + $7 + $8; exit}' /proc/stat; }
declare -a ring=()
CHROME_FLAGS=(--ozone-platform=wayland --enable-wayland-ime --wayland-text-input-version=3
	--enable-features=WebRtcPipeWireCamera,WaylandExternalBeginFrameSource
	--user-data-dir=$T/prof --no-first-run --no-default-browser-check --kiosk
	--autoplay-policy=no-user-gesture-required --remote-debugging-port=$P)
ORDER="A B B A M"; [ -n "$URL" ] && ORDER="A B B A"   # mpv cannot play the web page
ORDER=${CFGS:-$ORDER}
i=0; flprev=; gf0=$(systemctl is-active y700-gpu-floor 2>/dev/null)
for cfg in $ORDER; do
	i=$((i + 1))
	stop_player
	fl=${cfg##*[A-Z]}; cfg=${cfg%"$fl"}; lab=$cfg$fl   # a number after the letter = GPU floor in MHz for that window (A282)
	[ -n "$flprev" ] && reapply_floor
	[ -n "$fl" ] && echo $((fl * 1000000)) > $GPU/min_freq
	flprev=$fl
	case $cfg in D) systemctl start y700-gpu-floor ;; *) [ "$gf0" = active ] && systemctl stop y700-gpu-floor ;; esac   # D = the floor daemon runs, any other window: stopped
	case $cfg in B) setsw Y1 ;; *) setsw Y0 ;; esac   # the globally preloaded shim: on only in B windows
	vflags=(); posts=(); purl="${URL:-http://127.0.0.1:$HP/p.html}"
	case $cfg in L) purl=http://127.0.0.1:$HP/p.html ;; N) vflags=(--disable-extensions) ;; H) posts=("$YT_NOUI") ;; W) posts=("$YT_ONLY") ;;
		X) posts=("$YT_NOUI" "$YT_ONLY") ;; V) posts=("$YT_BARE") ;; esac
	case $cfg in
	A|D|L|H|W|X|V|N) "${U[@]}" /opt/google/chrome/chrome "${CHROME_FLAGS[@]}" "${vflags[@]}" "$purl" >$O/chrome-$i.log 2>&1 & ;;
	B) "${U[@]}" LD_PRELOAD=$T/y700-no-waitboost.so /opt/google/chrome/chrome "${CHROME_FLAGS[@]}" "$purl" >$O/chrome-$i.log 2>&1 & ;;
	M) "${U[@]}" mpv --fs --ao=null --hwdec=vaapi --vo=gpu --gpu-api=opengl --loop-file=inf --no-osc --osd-level=0 \
		--input-ipc-server=$SOCK $CLIP >$O/mpv.log 2>&1 & ;;
	esac
	sleep 14   # start, extension/state file, y700-refresh-auto: 2-4 s of frame counting + 1.5 s stable -> 60 Hz
	if [ -n "$URL" ] && [ $cfg != L ]; then
		sleep 6; log "window $i $lab: $(cdpx "$YT_FS" 1)"; sleep 12   # the page loads; then fullscreen, rate, 60 Hz
		for js in "${posts[@]}"; do log "window $i $lab variant: $(cdpx "$js" 1)"; sleep 4; done
	elif [ -n "$URL" ]; then sleep 18; fi
	[ -n "$URL" ] && log "window $i $lab diag: $(cdpx "$DIAG"); $(layers)"
	if [ $cfg = M ]; then BR=$(pgrep -u user -f "input-ipc-server=$SOCK" | head -1)
	else BR=$(for p in $(pgrep -u user -f -- "^/opt/google/chrome/chrome .*--user-data-dir=$T/prof"); do
		tr '\0' ' ' < /proc/$p/cmdline | grep -q -- ' --type=' || echo $p; done | head -1); fi
	[ -z "$BR" ] && { log "window $i $lab: player did not start"; exit 3; }
	PL=$(tree $BR | tr '\n' ' ')   # the browser and all its children (GPU process, zygotes, renderers)
	GP=$(for p in $PL; do tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q -- '--type=gpu-process' && echo $p; done | head -1)
	dec="-"; for p in ${GP:-} $PL; do ls -l /proc/$p/fd 2>/dev/null | grep -q /dev/video0 && { dec="hw (/dev/video0 in $p)"; break; }; done
	[ $cfg = M ] && dec="$dec, mpv hwdec $(mpvprop hwdec-current)"
	pre=" shim switch $(head -c 2 $SW), shim mappings in GPU process: $(grep -c y700-no-waitboost /proc/${GP:-0}/maps 2>/dev/null);"
	if [ $cfg = M ]; then f0="$(mpvprop estimated-frame-number) $(mpvprop frame-drop-count)"; else f0=$(cdp); fi
	b0=$(hits boost); d0=$(hits deadline); c0=$(ticks $PL); k0=$(ticks $KW); g0=$(gputime $PL); gk0=$(gputime $KW); gpuall > $T/ga0; t0=$(date +%s.%N); rx0=$(cat /sys/class/net/$WL/statistics/rx_bytes)
	read -r cb0 ct0 < <(cpubusy); dprev=$(hits deadline)
	for s in $(seq $WIN); do
		read -r cb1 ct1 < <(cpubusy); busy=$(( (cb1 - cb0) * 100 / (ct1 - ct0 > 0 ? ct1 - ct0 : 1) )); cb0=$cb1; ct0=$ct1
		dn=$(hits deadline); kw=$((dn - dprev)); dprev=$dn   # KWin composites this second (60 = every vblank)
		echo -e "$(date +%T)\t$i\t$cfg\t$(awk '{printf "%.3f", ($1 < 0 ? -$1 : $1) / 1e6}' $BAT/power_now)\t$(cat $BL/brightness)\t$(( $(cat $GPU/cur_freq) / 1000000 ))\t$(( $(cat $GPU/min_freq) / 1000000 ))\t$(( $(cat /sys/class/devfreq/ddr/cur_freq) / 1000000 ))\t$(( $(cat /sys/class/devfreq/llcc/cur_freq) / 1000000 ))\t$busy\t$kw" >> $O/samples.tsv
		ring+=("$(touches)"); [ ${#ring[@]} -gt 10 ] && ring=("${ring[@]:1}")
		if [ $(( ${ring[-1]} - ${ring[0]} )) -ge 3 ]; then owner=1; log "owner touched the screen - stopping, screen stays on"; exit 4; fi
		[ $s -eq 20 ] && snap
		sleep 1
	done
	gpuall > $T/ga1; t1=$(date +%s.%N); rx1=$(cat /sys/class/net/$WL/statistics/rx_bytes); b1=$(hits boost); d1=$(hits deadline); c1=$(ticks $PL); k1=$(ticks $KW); g1=$(gputime $PL); gk1=$(gputime $KW)
	if [ $cfg = M ]; then f1="$(mpvprop estimated-frame-number) $(mpvprop frame-drop-count)"; else f1=$(cdp); fi
	stats=$(awk -F'\t' -v w=$i 'NR>1 && $2==w {n++; s+=$4; b+=$5; g+=$6; f+=$7; d+=$8; l+=$9; c+=$10; if ($6 >= 1200) top++; if ($11 < 55) sl++} END{printf "%.2f W, backlight %.0f, GPU %.0f MHz (floor %.0f, %.0f %% of s at 1200), DDR %.0f MHz, LLCC %.0f MHz, CPU busy %.1f %%, composites < 55/s in %d s", s/n, b/n, g/n, f/n, top/n*100, d/n, l/n, c/n, sl}' $O/samples.tsv)
	rates=$(awk -v t0=$t0 -v t1=$t1 -v hz=$hz -v b0=$b0 -v b1=$b1 -v d0=$d0 -v d1=$d1 -v c0=$c0 -v c1=$c1 -v k0=$k0 -v k1=$k1 \
		-v g0=$g0 -v g1=$g1 -v gk0=$gk0 -v gk1=$gk1 'BEGIN{t=t1-t0; printf "boosts %.0f/s, deadlines %.0f/s; GPU time player %.1f %%, kwin %.1f %%; CPU player %.1f %%, kwin %.1f %%",
		(b1-b0)/t, (d1-d0)/t, (g1-g0)/t/1e7, (gk1-gk0)/t/1e7, (c1-c0)/hz/t*100, (k1-k0)/hz/t*100}')
	gtop=$(awk -v T0=$t0 -v T1=$t1 'BEGIN {t = T1 - T0} NR == FNR {a[$1] = $2; next} ($1 in a) && $2 > a[$1] {printf "%s %.1f\n", $3, ($2 - a[$1]) / t / 1e7}' $T/ga0 $T/ga1 | sort -k2 -nr | head -5 | tr '\n' ',')
	fmt=""; [ -n "$URL" ] && fmt=" served $(cdpx "$YT_FMT");"
	log "window $i $lab: $stats; $rates; Wi-Fi rx $(( (rx1 - rx0) * 8 / 1000 / WIN )) kbit/s; GPU clients (% of GPU time) $gtop; frames/drops ${f0} -> ${f1} (dropped $(echo "$f0 $f1" | awk 'NF==6{print $5-$2; next} {print "?"}'));$fmt decode $dec;$pre panel $(grep -oE 'hz [0-9]+' /sys/module/msm/parameters/idle_refresh_state | head -1), mode $("${U[@]}" kscreen-doctor -o 2>/dev/null | grep -oE '[0-9]+x[0-9]+@[0-9.]+\*' | head -1)"
done
