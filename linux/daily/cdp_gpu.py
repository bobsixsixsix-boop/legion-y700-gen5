import json, sys, urllib.request, websocket
port = sys.argv[1] if len(sys.argv) > 1 else "9222"
v = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version"))
ws = websocket.create_connection(v["webSocketDebuggerUrl"], timeout=30, suppress_origin=True)
ws.send(json.dumps({"id": 1, "method": "SystemInfo.getInfo"}))
while True:
    r = json.loads(ws.recv())
    if r.get("id") == 1: break
g = r["result"]["gpu"]
for d in g["devices"]: print("device:", d.get("vendorString"), d.get("deviceString"), d.get("driverVendor"), d.get("driverVersion"))
a = g.get("auxAttributes", {})
for k in ("glImplementationParts", "glRenderer", "glVersion", "displayType", "skiaBackendType", "isAsan", "videoDecodeAcceleratorSupportedProfile"):
    if k in a: print(k, "=", a[k])
for k, s in sorted(g.get("featureStatus", {}).items()): print(f"  {k}: {s}")
print("videoDecoding:", [ (p["profile"], p["maxResolution"]) for p in g.get("videoDecoding", [])][:8])
print("videoEncoding:", len(g.get("videoEncoding", [])))
