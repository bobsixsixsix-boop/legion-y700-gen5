"""Evaluate a JS expression in the first page of a Chrome started with --remote-debugging-port.
usage: python3 cdp_eval.py PORT 'expression'   (prints the JSON value)"""
import json, sys, urllib.request, websocket

port, expr = sys.argv[1], sys.argv[2]
page = next(t for t in json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list")) if t.get("type") == "page")
ws = websocket.create_connection(page["webSocketDebuggerUrl"], timeout=20, suppress_origin=True)
ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": expr, "returnByValue": True}}))
while True:
    r = json.loads(ws.recv())
    if r.get("id") == 1:
        break
print(json.dumps(r.get("result", {}).get("result", {}).get("value"), ensure_ascii=False))
