#!/usr/bin/env python3
"""touch-jumps.py SECONDS: record the panel's raw multitouch stream (read-only, no grab) while the owner
types fast, then report what the keyboard would misread:
  - JUMPS: one tracking id moving further than JUMP px between two consecutive reports (a "teleport":
    the firmware carried a contact over from one finger to the next instead of lift + new down);
  - lift drift: how far each contact travelled between its first and last report (a slow upward
    roll at the lift would also look like a flick on the keyboard).
Only geometry is kept, in memory; nothing is written. Physical px of the 1904x3040 portrait panel
(digitizer units / 10). Run as root on the tablet.
2026-10-15: the owner sees a stray ';' when typing fast - n's flick hint is ';'."""
import sys, time, select, math
import evdev
from evdev import ecodes as e

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 30
JUMP = float(sys.argv[2]) if len(sys.argv) > 2 else 60      # physical px in ONE report (~0.4 key height)
WAIT = float(sys.argv[3]) if len(sys.argv) > 3 else 0       # wait up to WAIT s for the first touch, then record secs
dev = next(evdev.InputDevice(p) for p in evdev.list_devices() if evdev.InputDevice(p).name == "NVTCapacitiveTouchScreen")
slot, pending = 0, {}
slots = {}            # slot -> dict(tid, x, y, t0, x0, y0, steps)
contacts, jumps, maxstep = [], [], []
swaps = []            # same slot: a contact ended and a new one began within ONE report (frame)
ended = {}            # slot -> (x, y) of the contact that ended in the current frame
end = time.time() + (WAIT if WAIT > 0 else secs)
started = WAIT <= 0
print(f"recording {dev.path} for {secs:.0f} s" + (f" from the first touch (waiting up to {WAIT:.0f} s)" if WAIT > 0 else ""), flush=True)
while time.time() < end:
    r, _, _ = select.select([dev.fd], [], [], 0.2)
    if not r:
        continue
    for ev in dev.read():
        t = ev.timestamp()
        if ev.type == e.EV_ABS:
            if ev.code == e.ABS_MT_SLOT:
                slot = ev.value
            elif ev.code == e.ABS_MT_TRACKING_ID:
                if not started and ev.value >= 0:
                    started, end = True, time.time() + secs
                    print(f"first touch at {time.strftime('%H:%M:%S')}: recording {secs:.0f} s", flush=True)
                if ev.value < 0:
                    s = slots.pop(slot, None)
                    if s:
                        contacts.append(s)
                        ended[slot] = (s["x"], s["y"])
                else:
                    if slot in ended:
                        swaps.append([slot, ended[slot]])     # the new contact's position fills in below
                    slots[slot] = {"tid": ev.value, "x": None, "y": None, "t0": t, "x0": None, "y0": None, "n": 0, "max": 0.0, "last": t}
            elif ev.code in (e.ABS_MT_POSITION_X, e.ABS_MT_POSITION_Y):
                s = slots.get(slot)
                if s is not None:
                    pending.setdefault(slot, {})["x" if ev.code == e.ABS_MT_POSITION_X else "y"] = ev.value / 10
        elif ev.type == e.EV_SYN and ev.code == e.SYN_REPORT:
            for sl, p in pending.items():
                s = slots.get(sl)
                if not s:
                    continue
                nx, ny = p.get("x", s["x"]), p.get("y", s["y"])
                if s["x"] is None or s["y"] is None:
                    s["x0"], s["y0"] = nx, ny
                elif nx is not None and ny is not None:
                    step = math.hypot(nx - s["x"], ny - s["y"])
                    s["max"] = max(s["max"], step)
                    if step >= JUMP:
                        jumps.append((round((t - s["t0"]) * 1000), round(step), round(nx - s["x"]), round(ny - s["y"]), round((t - s["last"]) * 1000)))
                s["x"], s["y"], s["last"] = nx, ny, t
                s["n"] += 1
            for sw in swaps:
                if len(sw) == 2 and sw[0] in slots and slots[sw[0]]["x"] is not None and sw[1][0] is not None:
                    n = slots[sw[0]]
                    sw.append(round(math.hypot(n["x"] - sw[1][0], n["y"] - sw[1][1])))
            pending = {}
            ended = {}
contacts += list(slots.values())
print(f"contacts: {len(contacts)}")
if not contacts:
    sys.exit(0)
durs = sorted((c["last"] - c["t0"]) * 1000 for c in contacts)
trav = sorted(math.hypot((c["x"] or 0) - (c["x0"] or 0), (c["y"] or 0) - (c["y0"] or 0)) for c in contacts if c["x0"] is not None)
pct = lambda a, q: a[min(len(a) - 1, int(q * len(a)))]
print(f"contact duration ms  p50 {pct(durs,.5):.0f}  p90 {pct(durs,.9):.0f}  max {durs[-1]:.0f}")
print(f"down->lift travel px p50 {pct(trav,.5):.0f}  p90 {pct(trav,.9):.0f}  p99 {pct(trav,.99):.0f}  max {trav[-1]:.0f}")
print(f"largest single step px: {max(c['max'] for c in contacts):.0f}")
print(f"SAME-FRAME SWAPS (one finger lifts and another lands on the same slot in one report): {len(swaps)}")
for sw in swaps[:20]:
    if len(sw) > 2:
        print(f"   slot {sw[0]}: new contact {sw[2]} px from the one that lifted")
print(f"JUMPS (one report >= {JUMP:.0f} px): {len(jumps)}")
for j in jumps[:20]:
    print(f"   at +{j[0]} ms into the contact: {j[1]} px (dx {j[2]}, dy {j[3]}), {j[4]} ms after the previous report")
