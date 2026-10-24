"""Which video decoder does Chrome really use? Plays a video in the first page of a Chrome started with
--remote-debugging-port and prints the media player's decoder properties (Media domain), e.g.
kVideoDecoderName=VaapiVideoDecoder + kIsPlatformVideoDecoder=true for hardware decoding.
usage: python3 cdp_media.py [port] [video url]"""
import json, sys, time, urllib.parse, urllib.request, websocket

port = sys.argv[1] if len(sys.argv) > 1 else "9333"
video = sys.argv[2] if len(sys.argv) > 2 else \
    "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"   # H.264 1080p
html = f'<video id=v autoplay muted playsinline src="{video}" style="width:100%"></video>'
base = f"http://127.0.0.1:{port}"
page = next(t for t in json.load(urllib.request.urlopen(base + "/json/list")) if t.get("type") == "page")
ws = websocket.create_connection(page["webSocketDebuggerUrl"], timeout=30, suppress_origin=True)
ws.send(json.dumps({"id": 1, "method": "Media.enable"}))
# a local file is opened directly (Chrome's media document plays it; a data: page may not load file://)
target = video if video.startswith("file://") else "data:text/html," + urllib.parse.quote(html)
ws.send(json.dumps({"id": 2, "method": "Page.navigate", "params": {"url": target}}))
props, errors, end = {}, [], time.time() + 15
ws.settimeout(1)
while time.time() < end:
    try:
        m = json.loads(ws.recv())
    except websocket.WebSocketTimeoutException:
        continue
    if m.get("method") == "Media.playerPropertiesChanged":
        for p in m["params"]["properties"]:
            props[p["name"]] = p["value"]
    elif m.get("method") == "Media.playerErrorsRaised":
        errors += [e.get("errorType") for e in m["params"]["errors"]]
for k in ("kVideoDecoderName", "kIsPlatformVideoDecoder", "kVideoCodecName", "kResolution", "kFrameUrl"):
    if k in props:
        print(f"{k} = {props[k][:120]}")
print("errors:", errors or "none")
