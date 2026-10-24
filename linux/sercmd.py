#!/usr/bin/env python3
"""Run a shell command on the tablet's Linux through the USB ACM serial root shell (COM8 by default).

The tablet side was started with:
  sudo sh -c 'stty -F /dev/ttyGS0 raw -echo; setsid bash -i </dev/ttyGS0 >/dev/ttyGS0 2>&1 &'

usage: python sercmd.py [--port COM8] [--timeout 60] 'command ...'
       python sercmd.py --file script.sh        # sends the file's text as the command
Prints the command's output (between unique markers) and its exit status.
"""
import argparse, sys, time, uuid
import serial

ap = argparse.ArgumentParser()
ap.add_argument("cmd", nargs="?")
ap.add_argument("--file")
ap.add_argument("--port", default="COM8")
ap.add_argument("--timeout", type=float, default=60)
a = ap.parse_args()
cmd = open(a.file, encoding="utf-8").read() if a.file else a.cmd
if not cmd:
    sys.exit("no command")

tag = uuid.uuid4().hex[:12]
beg, end = f"__B_{tag}__", f"__E_{tag}__"
# run in a subshell so `exit` in the command cannot kill the serial shell
# markers are assembled at run time, so an echo of this line never contains them
payload = f"echo __B_{tag[:6]}''{tag[6:]}__; ( {cmd}\n) 2>&1; echo __E_{tag[:6]}''{tag[6:]}__ $?\n"

s = serial.Serial(a.port, 115200, timeout=0.5, write_timeout=10)
s.reset_input_buffer()
s.write(payload.encode())
buf = b""
deadline = time.time() + a.timeout
while time.time() < deadline:
    chunk = s.read(65536)
    if chunk:
        buf += chunk
        if end.encode() in buf.split(beg.encode(), 1)[-1] and buf.rstrip().endswith(b"") and b"\n" in buf.split(end.encode(), 1)[-1]:
            break
s.close()
text = buf.decode("utf-8", "replace").replace("\r", "")
if beg in text:
    text = text.split(beg, 1)[1].lstrip("\n")
status = None
if end in text:
    body, tail = text.split(end, 1)
    status = tail.strip().split()[0] if tail.strip() else "?"
    text = body
sys.stdout.write(text)
print(f"[exit {status if status is not None else 'TIMEOUT'}]")
sys.exit(0 if status == "0" else 1)
