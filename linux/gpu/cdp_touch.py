"""Drive a Chrome started with --remote-debugging-port like a finger would: print the GPU backend, then
for each site: open it, wait for it to settle, touch-scroll down and up (Input.synthesizeScrollGesture,
gestureSourceType=touch). Used by chrome-gpu-repro.sh (DURING=...): the reported trigger was "open a few
sites and move a little and it crashes" (2026-10-14).
usage: python3 cdp_touch.py [port] [rounds per site] [url ...]"""
import json, sys, time, urllib.request, websocket

port = sys.argv[1] if len(sys.argv) > 1 else "9333"
rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 2
sites = sys.argv[3:] or ["https://en.wikipedia.org/wiki/Linux", "https://github.com/trending",
                         "https://www.bbc.com/news", "https://www.youtube.com", "https://www.bilibili.com",
                         "https://news.ycombinator.com"]
base = f"http://127.0.0.1:{port}"
_id = 0

def call(ws, method, params=None, timeout=30):
    global _id
    _id += 1
    ws.send(json.dumps({"id": _id, "method": method, "params": params or {}}))
    end = time.time() + timeout
    while time.time() < end:
        r = json.loads(ws.recv())
        if r.get("id") == _id:
            return r
    raise TimeoutError(method)

v = json.load(urllib.request.urlopen(base + "/json/version"))
bws = websocket.create_connection(v["webSocketDebuggerUrl"], timeout=30, suppress_origin=True)
g = call(bws, "SystemInfo.getInfo")["result"]["gpu"]
a = g.get("auxAttributes", {})
print("gpu:", a.get("glRenderer"), "|", a.get("glImplementationParts"), "| skia:", a.get("skiaBackendType"), flush=True)
fs = g.get("featureStatus", {})
print("compositing/raster/video:", fs.get("gpu_compositing"), fs.get("rasterization"), fs.get("video_decode"), flush=True)
page = next(t for t in json.load(urllib.request.urlopen(base + "/json/list")) if t.get("type") == "page")
pws = websocket.create_connection(page["webSocketDebuggerUrl"], timeout=60, suppress_origin=True)
t0 = time.time()
for url in sites:
    try:
        call(pws, "Page.navigate", {"url": url}, timeout=20)
        time.sleep(4)
        for i in range(rounds):
            for dy in (-1200, 1200):
                call(pws, "Input.synthesizeScrollGesture",
                     {"x": 500, "y": 600, "yDistance": dy, "gestureSourceType": "touch", "speed": 2000}, timeout=20)
        print(f"{time.time() - t0:5.1f}s ok {url}", flush=True)
    except Exception as e:
        print(f"{time.time() - t0:5.1f}s FAIL {url}: {e!r}", flush=True)
