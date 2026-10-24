#!/usr/bin/env python3
"""y700-vtouch: a virtual touchscreen for driving the tablet's UI from test scripts ("computer use").

A uinput clone of the panel's NVTCapacitiveTouchScreen (same MT axes and ranges, INPUT_PROP_DIRECT), so
KWin maps it exactly like the real panel, rotation included. A touchscreen has no pointer capability:
KWin stays in tablet mode (a device with a pointer, like ydotool's, would end it).

Run as root, it reads commands from a FIFO, one per line, in KWin LOGICAL coordinates (the landscape
desktop, e.g. 1600x1003 at scale 1.9):
    tap X Y [HOLD_MS]            finger down, hold (default 60 ms), up
    drag X1 Y1 X2 Y2 [MS] [STEPS] down at 1, move to 2 in STEPS over MS, up
    down X Y | move X Y | up     single-finger primitives
    swap X Y                     the finger lifts and a new one lands at X Y in the SAME report, same slot
    sleep MS                     pause (to pace a scenario sent in one write)
    quit                         destroy the device and exit
usage: vtouch.py [--fifo /run/y700-vtouch.fifo] [--scale 1.9] [--rot r270|r90|none]
  (typically: systemd-run --unit y700-vtouch python3 vtouch.py; then echo "tap 800 500" > the fifo)
The panel is 1904x3040 portrait (digitizer units x10); the desktop is shown rotated (kscreen Rotation 8).
"""
import argparse, os, sys, time
import evdev
from evdev import ecodes as e, AbsInfo, UInput

ap = argparse.ArgumentParser()
ap.add_argument("--fifo", default="/run/y700-vtouch.fifo")
ap.add_argument("--scale", type=float, default=1.9)
ap.add_argument("--rot", default="r270", choices=["r270", "r90", "none"])
ap.add_argument("--panel", default="1904x3040", help="native panel size in physical pixels (portrait)")
a = ap.parse_args()
PW, PH = (int(v) for v in a.panel.split("x"))
UNIT = 10                                   # digitizer units per physical pixel (19039/1904)

def to_native(lx, ly):
    """logical landscape point -> digitizer units of the portrait panel"""
    px, py = lx * a.scale, ly * a.scale     # physical landscape pixels (PH wide, PW tall)
    if a.rot == "r270":
        nx, ny = PW - 1 - py, px
    elif a.rot == "r90":
        nx, ny = py, PH - 1 - px
    else:
        nx, ny = px, py
    clamp = lambda v, hi: max(0, min(hi, v))
    return int(clamp(nx, PW - 1) * UNIT), int(clamp(ny, PH - 1) * UNIT)

caps = {
    e.EV_KEY: [e.BTN_TOUCH],
    e.EV_ABS: [
        (e.ABS_MT_SLOT, AbsInfo(0, 0, 9, 0, 0, 0)),
        (e.ABS_MT_TOUCH_MAJOR, AbsInfo(0, 0, 255, 0, 0, 0)),
        (e.ABS_MT_POSITION_X, AbsInfo(0, 0, PW * UNIT - 1, 0, 0, 0)),
        (e.ABS_MT_POSITION_Y, AbsInfo(0, 0, PH * UNIT - 1, 0, 0, 0)),
        (e.ABS_MT_TRACKING_ID, AbsInfo(0, 0, 65535, 0, 0, 0)),
        (e.ABS_MT_PRESSURE, AbsInfo(0, 0, 1500, 0, 0, 0)),
    ],
}
ui = UInput(caps, name="y700-vtouch", input_props=[e.INPUT_PROP_DIRECT])
tid = 100
down_now = False

def frame(ev):
    for t, c, v in ev:
        ui.write(t, c, v)
    ui.syn()

def down(x, y):
    global tid, down_now
    tid = (tid + 1) % 65000
    nx, ny = to_native(x, y)
    frame([(e.EV_ABS, e.ABS_MT_SLOT, 0), (e.EV_ABS, e.ABS_MT_TRACKING_ID, tid),
           (e.EV_ABS, e.ABS_MT_POSITION_X, nx), (e.EV_ABS, e.ABS_MT_POSITION_Y, ny),
           (e.EV_ABS, e.ABS_MT_TOUCH_MAJOR, 12), (e.EV_ABS, e.ABS_MT_PRESSURE, 300),
           (e.EV_KEY, e.BTN_TOUCH, 1)])
    down_now = True

def move(x, y):
    nx, ny = to_native(x, y)
    frame([(e.EV_ABS, e.ABS_MT_SLOT, 0), (e.EV_ABS, e.ABS_MT_POSITION_X, nx), (e.EV_ABS, e.ABS_MT_POSITION_Y, ny)])

def up():
    global down_now
    frame([(e.EV_ABS, e.ABS_MT_SLOT, 0), (e.EV_ABS, e.ABS_MT_TRACKING_ID, -1), (e.EV_KEY, e.BTN_TOUCH, 0)])
    down_now = False

def swap(x, y):
    """one finger lifts and another lands on the SAME slot within ONE report (fast typing on some
    panels): does the stack deliver it as a lift + a new press, or as one contact jumping?"""
    global tid, down_now
    tid = (tid + 1) % 65000
    nx, ny = to_native(x, y)
    frame([(e.EV_ABS, e.ABS_MT_SLOT, 0), (e.EV_ABS, e.ABS_MT_TRACKING_ID, -1),
           (e.EV_ABS, e.ABS_MT_TRACKING_ID, tid),
           (e.EV_ABS, e.ABS_MT_POSITION_X, nx), (e.EV_ABS, e.ABS_MT_POSITION_Y, ny),
           (e.EV_ABS, e.ABS_MT_TOUCH_MAJOR, 12), (e.EV_ABS, e.ABS_MT_PRESSURE, 300)])
    down_now = True

def run(line):
    p = line.split()
    if not p:
        return True
    cmd, n = p[0], [float(v) for v in p[1:]]
    if cmd == "tap":
        down(n[0], n[1]); time.sleep((n[2] if len(n) > 2 else 60) / 1000); up()
    elif cmd == "drag":
        ms = n[4] if len(n) > 4 else 400
        steps = int(n[5]) if len(n) > 5 else 20
        down(n[0], n[1]); time.sleep(0.03)
        for i in range(1, steps + 1):
            f = i / steps
            move(n[0] + (n[2] - n[0]) * f, n[1] + (n[3] - n[1]) * f)
            time.sleep(ms / 1000 / steps)
        time.sleep(0.03); up()
    elif cmd == "down":
        down(n[0], n[1])
    elif cmd == "move":
        move(n[0], n[1])
    elif cmd == "up":
        up()
    elif cmd == "swap":
        swap(n[0], n[1])
    elif cmd == "sleep":
        time.sleep(n[0] / 1000)
    elif cmd == "quit":
        return False
    else:
        print("unknown command:", line, flush=True)
    return True

if os.path.exists(a.fifo):
    os.unlink(a.fifo)
os.mkfifo(a.fifo, 0o600)
print(f"y700-vtouch ready: {a.fifo}, rot={a.rot}, scale={a.scale}", flush=True)
try:
    alive = True
    while alive:
        with open(a.fifo) as f:              # blocks until a writer opens it; EOF when it closes
            for line in f:
                try:
                    alive = run(line)
                except Exception as ex:      # a bad line must never leave a finger down
                    print("error:", line.strip(), ex, flush=True)
                    if down_now:
                        up()
                if not alive:
                    break
finally:
    if down_now:
        up()
    ui.close()
    os.unlink(a.fifo)
