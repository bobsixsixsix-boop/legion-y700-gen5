#!/usr/bin/env python3
# voice-asr-fake.py PORT DELAY_S LOG: a stand-in for the speech-recognition gateway (Y700_OSK_ASR_URL, see src/voice.h), for tests/voice-drop.sh.
# Answers every POST after DELAY_S with {"text": "语音测试<n>"}. While it waits it watches the connection,
# and appends one line per request to LOG: "<n> delivered", or "<n> dropped" when the keyboard closed the
# connection first (the result was thrown away unread). Listens on 127.0.0.1 only; the audio is ignored.
import itertools
import json
import select
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, DELAY, LOG = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
SEQ = itertools.count(1)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        n = next(SEQ)
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        end = time.monotonic() + DELAY
        try:
            # the client sends nothing more before the answer: readable means it closed the connection
            ready = select.select([self.connection], [], [], DELAY)[0]
            gone = bool(ready) and self.connection.recv(1, socket.MSG_PEEK) == b""
        except OSError:
            gone = True
        if not gone:
            time.sleep(max(0.0, end - time.monotonic()))
        with open(LOG, "a", encoding="utf-8", newline="\n") as f:
            f.write(f"{n} {'dropped' if gone else 'delivered'}\n")
        if gone:
            self.close_connection = True
            return
        body = json.dumps({"text": f"语音测试{n}"}, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
