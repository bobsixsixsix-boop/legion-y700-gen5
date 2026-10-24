#!/bin/bash
# test-chrome-video-state.sh (2026-10-18): ROOT on the tablet, after install-chrome.sh. The owner's Chrome and profile
# are not touched: part 2 runs an invisible headless Chrome with a throw-away profile.
#   1. host alone: two messages -> state file written per change; EOF -> file gone; SIGTERM -> file gone
#   2. headless Chrome installs the extension from /usr/share/google-chrome/extensions (a fresh profile enables it
#      without asking), then plays a 30 fps and a 60 fps clip filling the viewport, served over http (content scripts
#      get no file:// access): the state file must say playing=1 fullscreen=1 and fps within 0.7 of the clip's; the
#      page pauses at 12 s -> the extension closes the port -> the host removes the file.
#   3. same Chrome: an 8 s clip looping must keep the state file and its rate the whole time (a loop is a seek);
#      5 small captions flying over the video -> danmaku=1 with a why= line, and danmaku=0 again 8 s after they are
#      gone; one big animated overlay plus 2 small spinners (player UI) -> danmaku=0.
#   4. a page asks MediaSource / canPlayType / mediaCapabilities about AV1 and VP9: AV1 refused, VP9 offered.
#   5. a fullscreen element holding a video: body and the rest of the page turn visibility:hidden (what hides itself
#      inside stays hidden), back to normal on exit; a fullscreen element inside a shadow tree is left alone; the
#      prefixed webkitRequestFullscreen(), paused, then webkitExitFullscreen(): the page comes back (v1.5).
#   6. (v1.5) a page without a video (plus an iframe) never opens a port to the service worker; a viewport-filling video
#      in a minimized window (document hidden) is not reported as fullscreen (skipped when headless keeps it visible).
# The state file is the real one in $XDG_RUNTIME_DIR/y700-video, but y700-refresh-auto ignores it: its pid (the
# headless browser) never owns the active window.
set -u
U=user; H=/home/$U; RT=/run/user/1000; D=$RT/y700-video
ID=cgphccdichbpkkdlbnekjojganogdimg
BIN=$H/.local/bin/y700-chrome-video-state
SU=(sudo -u $U env XDG_RUNTIME_DIR=$RT HOME=$H)
fail=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
P=9335
[ -x $BIN ] && [ -r /usr/share/google-chrome/extensions/$ID.json ] || { echo "run install-chrome.sh first" >&2; exit 2; }
[ -z "$(ls $D/chrome-* 2>/dev/null)" ] || { echo "a Chrome video state file exists already (a video plays?): $(ls $D/chrome-*)" >&2; exit 2; }
T=$(mktemp -d /tmp/y700-cvs.XXXX)
trap 'pkill -f "remote-debugging-port=$P" 2>/dev/null; pkill -f "http.server 8765" 2>/dev/null; rm -rf $T' EXIT

echo "== 1. host alone"
cat > $T/feed.py <<'EOF'
import struct, sys, time
def m(s):
    b = s.encode(); sys.stdout.buffer.write(struct.pack("=I", len(b)) + b); sys.stdout.buffer.flush()
m('{"playing":1,"fullscreen":1,"osd":0,"danmaku":0,"fps":29.97}'); time.sleep(0.3)
m('{"playing":1,"fullscreen":1,"osd":0,"danmaku":0,"fps":29.97}'); time.sleep(0.3)
m('{"playing":1,"fullscreen":0,"osd":0,"danmaku":1,"fps":60}'); time.sleep(float(sys.argv[1]))
EOF
chown -R $U: $T
"${SU[@]}" sh -c "python3 $T/feed.py 1.5 | $BIN" & sleep 1
f=$(ls $D/chrome-* 2>/dev/null | head -1)
if [ -n "$f" ] && grep -q '^fullscreen=0' $f && grep -q '^danmaku=1' $f && grep -q '^fps=60.000' $f; then ok "state file $f"; else bad "state file: $(cat ${f:-/dev/null} 2>&1)"; fi
wait; sleep 0.2
[ -z "$(ls $D/chrome-* 2>/dev/null)" ] && ok "EOF removes it" || bad "file left after EOF"
"${SU[@]}" sh -c "python3 $T/feed.py 30 | $BIN" & sleep 1
kill -TERM $(pgrep -n -f "^$BIN"); sleep 0.3
[ -z "$(ls $D/chrome-* 2>/dev/null)" ] && ok "SIGTERM removes it" || bad "file left after SIGTERM"
pkill -f "$T/feed.py"; wait 2>/dev/null

echo "== 2. headless Chrome"
mkdir -p $T/prof/NativeMessagingHosts $T/www
cp $H/.config/google-chrome/NativeMessagingHosts/fyi.y700.video_state.json $T/prof/NativeMessagingHosts/
for r in 30 60; do
  ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=$r -t 20 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 300k $T/www/v$r.webm
  cat > $T/www/p$r.html <<EOF
<!doctype html><style>html,body{margin:0;background:#000;overflow:hidden}video{width:100vw;height:100vh;display:block}</style>
<video id=v src="v$r.webm" autoplay muted loop playsinline></video>
<script>setTimeout(() => document.getElementById('v').pause(), 12000)</script>
EOF
done
ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=60 -t 8 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 300k $T/www/loop.webm
CSS='html,body{margin:0;background:#000;overflow:hidden}#p{position:relative;width:100vw;height:100vh}video{width:100%;height:100%;display:block}'
cat > $T/www/loop.html <<EOF
<!doctype html><style>$CSS</style><div id=p><video id=v src="loop.webm" autoplay muted loop playsinline></video></div>
<script>setTimeout(() => document.getElementById('v').pause(), 30000)</script>
EOF
{ echo "<!doctype html><style>$CSS"
  echo '.d{position:absolute;left:100%;color:#fff;font:28px sans-serif;white-space:nowrap;animation:fly 6s linear infinite}'
  echo '@keyframes fly{from{transform:translateX(0)}to{transform:translateX(-120vw)}}</style>'
  echo '<div id=p><video id=v src="v60.webm" autoplay muted loop playsinline></video>'
  for k in 1 2 3 4 5; do echo "<span class=d style=\"top:$((k * 12))%;animation-delay:-$k.2s\">danmaku $k 233333</span>"; done
  echo '</div><script>'
  echo "setTimeout(() => document.querySelectorAll('.d').forEach((e) => e.remove()), 8000)"
  echo "setTimeout(() => document.getElementById('v').pause(), 22000)</script>"; } > $T/www/dm.html
{ echo "<!doctype html><style>$CSS"
  echo '#g{position:absolute;inset:0;background:linear-gradient(transparent,rgba(0,0,0,.6));animation:fade 2s ease-in-out infinite alternate}'
  echo '@keyframes fade{from{opacity:.2}to{opacity:.8}}'
  echo '.s{position:absolute;top:45%;width:40px;height:40px;border:4px solid #fff;border-top-color:transparent;border-radius:50%;animation:spin 1s linear infinite}'
  echo '@keyframes spin{to{transform:rotate(360deg)}}</style>'
  echo '<div id=p><video id=v src="v60.webm" autoplay muted loop playsinline></video><div id=g></div>'
  echo '<div class=s style="left:30%"></div><div class=s style="left:60%"></div></div>'
  echo "<script>setTimeout(() => document.getElementById('v').pause(), 12000)</script>"; } > $T/www/ui.html
chown -R $U: $T
(cd $T/www && exec sudo -u $U python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1) &
"${SU[@]}" timeout 200 /opt/google/chrome/chrome --headless=new --user-data-dir=$T/prof --no-first-run \
  --remote-debugging-port=$P --autoplay-policy=no-user-gesture-required --window-size=1600,1000 \
  --screen-info={1600x1000} about:blank >$T/log 2>&1 &
sw=""; for i in $(seq 1 30); do sleep 0.5
  curl -s http://127.0.0.1:$P/json/list | grep -q "chrome-extension://$ID/sw.js" && { sw=1; break; }; done
[ -n "$sw" ] && ok "extension installed and running (service worker)" || bad "extension not running"
for r in 30 60; do
  tab=$(curl -s -X PUT "http://127.0.0.1:$P/json/new?http://127.0.0.1:8765/p$r.html" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -1)
  got=""; for i in $(seq 1 22); do sleep 0.5; f=$(ls $D/chrome-* 2>/dev/null | head -1); [ -n "$f" ] && got=$(tr '\n' ' ' < $f); done
  fps=$(echo "$got" | sed -n 's/.*fps=\([0-9.]*\).*/\1/p')
  if echo "$got" | grep -q 'playing=1 fullscreen=1' && awk -v f="${fps:-0}" -v r=$r 'BEGIN{exit !(f > r - 0.7 && f < r + 0.7)}'; then
    ok "$r fps clip: $got"; else bad "$r fps clip: '$got'"; fi
  sleep 3
  [ -z "$(ls $D/chrome-* 2>/dev/null)" ] && ok "paused: file removed" || bad "file left after pause: $(cat $D/chrome-* 2>&1)"
  curl -s "http://127.0.0.1:$P/json/close/$tab" >/dev/null
done

echo "== 3. loops, danmaku"
snap() { local f; f=$(ls $D/chrome-* 2>/dev/null | head -1); [ -n "$f" ] && tr '\n' ' ' < $f; }
open_tab() { curl -s -X PUT "http://127.0.0.1:$P/json/new?http://127.0.0.1:8765/$1" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -1; }
tab=$(open_tab loop.html)
for i in $(seq 1 40); do sleep 0.2; snap | grep -q 'fps=[1-9]' && break; done
rates=""
for i in $(seq 1 65); do sleep 0.2  # 13 s: at least one loop point (every 8 s)
  r=$(snap | sed -n 's/.*fps=\([0-9.]*\).*/\1/p'); rates="$rates ${r:-gone}"
done
summary=$(echo $rates | tr ' ' '\n' | sort | uniq -c | awk '{printf "%s x%s, ", $2, $1}')
if echo $rates | tr ' ' '\n' | awk '$1 == "gone" || $1 < 59.3 || $1 > 60.7 {e = 1} END {exit !e}'; then
  bad "loop: file gone or rate off ($summary)"; else ok "loop: file and rate kept ($summary)"; fi
curl -s "http://127.0.0.1:$P/json/close/$tab" >/dev/null; sleep 3
tab=$(open_tab dm.html); sleep 5; s=$(snap)
echo "$s" | grep -q 'danmaku=1' && echo "$s" | grep -q 'why=anim ' && ok "captions: $s" || bad "captions: '$s'"
sleep 14; s=$(snap)  # removed at 8 s, held until 16 s
echo "$s" | grep -q 'playing=1 .*danmaku=0' && ! echo "$s" | grep -q 'why=' && ok "captions gone: $s" || bad "captions gone: '$s'"
curl -s "http://127.0.0.1:$P/json/close/$tab" >/dev/null; sleep 3
tab=$(open_tab ui.html); sleep 6; s=$(snap)
echo "$s" | grep -q 'playing=1 fullscreen=1 .*danmaku=0' && ok "player UI animations: $s" || bad "player UI animations: '$s'"
curl -s "http://127.0.0.1:$P/json/close/$tab" >/dev/null

echo "== 4. AV1 hidden from pages (no-av1.js, page world)"
tab=$(open_tab p30.html); sleep 2
av1=$(python3 - $P $tab <<'PY'
import json, sys, websocket
ws = websocket.create_connection(f"ws://127.0.0.1:{sys.argv[1]}/devtools/page/{sys.argv[2]}", timeout=10, suppress_origin=True)
ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"returnByValue": True, "awaitPromise": True, "expression": """(async () => {
  const av1 = 'video/webm; codecs="av01.0.08M.08"', vp9 = 'video/webm; codecs="vp09.00.40.08"';
  const di = (t) => navigator.mediaCapabilities.decodingInfo({type: 'media-source', video: {contentType: t, width: 1920, height: 1080, bitrate: 4e6, framerate: 60}}).then((r) => r.supported);
  return [MediaSource.isTypeSupported(av1), document.createElement('video').canPlayType(av1) || 'no', await di(av1),
          MediaSource.isTypeSupported(vp9), await di(vp9)].join(' ');
})()"""}}))
while True:
    m = json.loads(ws.recv())
    if m.get("id") == 1: print(m["result"]["result"].get("value", m)); break
PY
)
[ "$av1" = "false no false true true" ] && ok "AV1 refused, VP9 offered ($av1)" || bad "AV1/VP9 answers: '$av1' (want: false no false true true)"
curl -s "http://127.0.0.1:$P/json/close/$tab" >/dev/null

echo "== 5. page behind a fullscreen video is hidden"
cat > $T/www/fs.html <<EOF
<!doctype html><style>html,body{margin:0;background:#000}#side{height:3000px;background:#222;color:#fff}
#p{position:relative;width:100vw;height:100vh}video{width:100%;height:100%;display:block}</style>
<div id=side>the rest of the page</div>
<div id=p><video id=v src="v60.webm" autoplay muted loop playsinline></video><span id=hid style="visibility:hidden">menu</span><span id=vis>ok</span></div>
<div id=host><div id=sp>shadow</div></div>
<script>document.getElementById('host').attachShadow({mode:'open'}).innerHTML='<video id=sv src="v60.webm" autoplay muted loop></video>'</script>
EOF
chown $U: $T/www/fs.html
cdp_eval() { # TAB EXPRESSION: Runtime.evaluate with a user gesture (requestFullscreen needs one, and uses it up)
python3 - $P $1 "$2" <<'PY'
import json, sys, websocket
ws = websocket.create_connection(f"ws://127.0.0.1:{sys.argv[1]}/devtools/page/{sys.argv[2]}", timeout=15, suppress_origin=True)
ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"returnByValue": True, "awaitPromise": True, "userGesture": True, "expression": sys.argv[3]}}))
while True:
    m = json.loads(ws.recv())
    if m.get("id") == 1: print(m["result"]["result"].get("value", m)); break
PY
}
tab=$(open_tab fs.html); sleep 3
QS="const wait = (ms) => new Promise((r) => setTimeout(r, ms)), el = (id) => document.getElementById(id),
  q = () => ['side', 'hid', 'vis', 'v'].map((id) => getComputedStyle(el(id)).visibility).join(' '),
  st = () => (el('y700-fullscreen-quiet') ? 'style' : 'nostyle');"
fsq=$(cdp_eval $tab "(async () => { $QS const out = [q()];
  try { await el('p').requestFullscreen(); } catch (e) { return 'fullscreen failed: ' + e; }
  await wait(1200); out.push(q() + ' ' + st());
  await document.exitFullscreen(); await wait(1200); out.push(q() + ' ' + st());
  return out.join(' | '); })()")
want="visible hidden visible visible | hidden hidden visible visible style | visible hidden visible visible nostyle"
[ "$fsq" = "$want" ] && ok "fullscreen hides the rest, keeps what hides itself, restores on exit ($fsq)" || bad "fullscreen quiet: '$fsq' (want '$want')"
# a fullscreen element inside a shadow tree (a document-level :fullscreen cannot reach it) must not blank the page
fss=$(cdp_eval $tab "(async () => { $QS
  try { await el('host').shadowRoot.getElementById('sv').requestFullscreen(); } catch (e) { return 'shadow fullscreen failed: ' + e; }
  await wait(1200); const r = st() + ' host ' + getComputedStyle(el('host')).visibility + ' fullscreenElement ' + (document.fullscreenElement && document.fullscreenElement.id);
  await document.exitFullscreen(); return r; })()")
[ "$fss" = "nostyle host visible fullscreenElement host" ] && ok "shadow-tree fullscreen left alone ($fss)" || bad "shadow-tree fullscreen: '$fss'"
# prefixed API: Chrome fires only webkitfullscreenchange for it; paused first, so no 1 s tick comes along to clean up
fsw=$(cdp_eval $tab "(async () => { $QS
  el('p').webkitRequestFullscreen(); await wait(1200); const a = st();
  el('v').pause(); await wait(600); document.webkitExitFullscreen(); await wait(1500);
  const r = a + ' ' + st() + ' ' + getComputedStyle(el('side')).visibility; el('v').play(); return r; })()")
[ "$fsw" = "style nostyle visible" ] && ok "prefixed fullscreen, paused, exit: page back ($fsw)" || bad "prefixed fullscreen exit: '$fsw' (want 'style nostyle visible')"
curl -s "http://127.0.0.1:$P/json/close/$tab" >/dev/null

echo "== 6. idle pages stay silent, hidden documents report no fullscreen"
cdp_raw() { # WEBSOCKET_URL METHOD PARAMS_JSON: one DevTools call, prints its result as JSON
python3 - "$1" "$2" "$3" <<'PY'
import json, sys, websocket
ws = websocket.create_connection(sys.argv[1], timeout=15, suppress_origin=True)
ws.send(json.dumps({"id": 1, "method": sys.argv[2], "params": json.loads(sys.argv[3])}))
while True:
    m = json.loads(ws.recv())
    if m.get("id") == 1: print(json.dumps(m.get("result", m))); break
PY
}
cat > $T/www/novideo.html <<EOF
<!doctype html><p>no video here</p><iframe srcdoc="<p>nor here</p>"></iframe>
EOF
chown $U: $T/www/novideo.html
tab=$(open_tab novideo.html); sleep 3
swws=$(curl -s http://127.0.0.1:$P/json/list | python3 -c "import json,sys; print(next((t['webSocketDebuggerUrl'] for t in json.load(sys.stdin) if t['url'].endswith('$ID/sw.js')), ''))")
if [ -z "$swws" ]; then ok "page without a video: service worker not even running"
else n=$(cdp_raw "$swws" Runtime.evaluate '{"expression": "frames.size", "returnByValue": true}' | python3 -c "import json,sys; print(json.load(sys.stdin)['result'].get('value'))")
  [ "$n" = 0 ] && ok "page without a video (and its iframe): no port to the service worker" || bad "page without a video: $n frame ports open in the service worker"
fi
curl -s "http://127.0.0.1:$P/json/close/$tab" >/dev/null
# with sound and not muted: Chrome itself pauses a muted autoplay video in a hidden page (then nothing is reported anyway)
ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=60 -f lavfi -i sine=frequency=440 -t 20 -c:v libvpx-vp9   -deadline realtime -cpu-used 8 -b:v 300k -c:a libopus $T/www/bga.webm
cat > $T/www/bg.html <<EOF
<!doctype html><style>html,body{margin:0;background:#000;overflow:hidden}video{width:100vw;height:100vh;display:block}</style>
<video id=v src="bga.webm" loop playsinline></video><script>const v = document.getElementById('v'); v.volume = 0.05; v.play()</script>
EOF
chown $U: $T/www/bg.html $T/www/bga.webm
tab=$(open_tab bg.html); sleep 4; s1=$(snap)
bws=$(curl -s http://127.0.0.1:$P/json/version | python3 -c "import json,sys; print(json.load(sys.stdin)['webSocketDebuggerUrl'])")
win=$(cdp_raw "$bws" Browser.getWindowForTarget "{\"targetId\": \"$tab\"}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('windowId', ''))")
cdp_raw "$bws" Browser.setWindowBounds "{\"windowId\": ${win:-0}, \"bounds\": {\"windowState\": \"minimized\"}}" >/dev/null; sleep 2.5
vis=$(cdp_eval $tab "document.visibilityState"); s2=$(snap)
if [ "$vis" != hidden ]; then echo "SKIP minimized window: headless reports visibilityState '$vis' (state $s2)"
elif echo "$s1" | grep -q 'playing=1 fullscreen=1' && echo "$s2" | grep -q 'playing=1 fullscreen=0'; then ok "minimized (hidden) window: playing, not fullscreen ($s2)"
else bad "hidden document: before '$s1', after '$s2'"; fi
cdp_raw "$bws" Browser.setWindowBounds "{\"windowId\": ${win:-0}, \"bounds\": {\"windowState\": \"normal\"}}" >/dev/null
curl -s "http://127.0.0.1:$P/json/close/$tab" >/dev/null
sleep 1
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
