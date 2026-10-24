#!/usr/bin/env python3
"""y700-dpms-probe [SECONDS]: turn the display off and watch whether it stays off, counting input
events (touch, pen, keys) meanwhile - the usual reason a dark screen comes back is an input event
(KWin wakes on any). 2026-10-15: the bench's screen-off states came back on after 21 s. Run as root."""
import os, select, struct, subprocess, sys, time, glob

secs = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 60
U = ["sudo", "-u", "user", "env", "XDG_RUNTIME_DIR=/run/user/1000", "WAYLAND_DISPLAY=wayland-0",
     "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"]
EV = struct.Struct("qqHHi")        # struct input_event on arm64
DPMS = [p for p in glob.glob("/sys/class/drm/card*-DSI-*/dpms")]
devs = {}
for p in glob.glob("/dev/input/event*"):
    name = open(f"/sys/class/input/{os.path.basename(p)}/device/name").read().strip()
    if "haptics" in name:
        continue
    fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)   # a plain reader: nothing is grabbed from KWin
    devs[fd] = [name, 0, 0, None]                  # name, events, syn reports, last (type, code, value)
pl = select.poll()
for fd in devs:
    pl.register(fd, select.POLLIN)


def dpms():
    return " ".join(open(p).read().strip() for p in DPMS)


print("display:", dpms(), "- turning it off")
subprocess.run(U + ["kscreen-doctor", "--dpms", "off"], capture_output=True)
t0 = time.monotonic(); last = ""; woke = None
try:
    while time.monotonic() - t0 < secs:
        for fd, _ in pl.poll(500):
            try:
                buf = os.read(fd, EV.size * 64)
            except BlockingIOError:
                continue
            for i in range(0, len(buf) - EV.size + 1, EV.size):
                sec, usec, typ, code, val = EV.unpack_from(buf, i)
                d = devs[fd]
                if typ == 0:
                    d[2] += 1
                else:
                    d[1] += 1; d[3] = (typ, code, val, round(time.monotonic() - t0, 1))
        st = dpms()
        if st != last:
            print(f"{time.monotonic() - t0:6.1f} s  display {st}")
            last = st
            if "On" in st and woke is None and time.monotonic() - t0 > 2:
                woke = time.monotonic() - t0
finally:
    subprocess.run(U + ["kscreen-doctor", "--dpms", "on"], capture_output=True)
print("woke by itself after" if woke else "stayed off for", f"{woke or secs:.0f} s")
for fd, (name, n, syn, lastev) in devs.items():
    if n or syn:
        print(f"  {name}: {n} events, {syn} reports, last {lastev}")
if not any(d[1] for d in devs.values()):
    print("  no input events at all")
