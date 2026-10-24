import json, sys, time, urllib.request, websocket
port, expr = sys.argv[1], sys.argv[2]
ts = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list"))
t = [x for x in ts if x["type"] == "page"][0]
print("page:", t["url"])
ws = websocket.create_connection(t["webSocketDebuggerUrl"], timeout=90, suppress_origin=True)
for i in range(30):
    ws.send(json.dumps({"id": 100+i, "method": "Runtime.evaluate", "params": {"expression": "location.href", "returnByValue": True}}))
    while True:
        r = json.loads(ws.recv())
        if r.get("id") == 100+i: break
    if r["result"]["result"].get("value", "").startswith("http"): break
    time.sleep(1)
ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": expr, "awaitPromise": True, "returnByValue": True}}))
while True:
    r = json.loads(ws.recv())
    if r.get("id") == 1: break
print(json.dumps(r.get("result", r), ensure_ascii=False)[:1500])
