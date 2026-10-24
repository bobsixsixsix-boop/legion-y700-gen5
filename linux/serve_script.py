#!/usr/bin/env python3
"""Serve one script over plain TCP on the USB link, for:  sudo bash -c 'bash </dev/tcp/192.168.7.1/9000'
Each connection gets the file's bytes, then the socket closes. Logs every connection.
usage: python serve_script.py FILE [--bind 192.168.7.1] [--port 9000] [--count 3]
"""
import argparse, socket, datetime

ap = argparse.ArgumentParser()
ap.add_argument("file")
ap.add_argument("--bind", default="192.168.7.1")
ap.add_argument("--port", type=int, default=9000)
ap.add_argument("--count", type=int, default=3, help="stop after this many connections")
a = ap.parse_args()
data = open(a.file, "rb").read().replace(b"\r\n", b"\n")
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((a.bind, a.port))
srv.listen(4)
print(f"serving {a.file} ({len(data)} bytes) on {a.bind}:{a.port}", flush=True)
for _ in range(a.count):
    c, addr = srv.accept()
    c.sendall(data)
    c.shutdown(socket.SHUT_WR)
    c.close()
    print(f"{datetime.datetime.now():%H:%M:%S} sent to {addr[0]}:{addr[1]}", flush=True)
srv.close()
