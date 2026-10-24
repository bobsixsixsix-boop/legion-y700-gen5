#!/usr/bin/env python3
"""y700-frames SECONDS: who keeps the panel at 120 Hz? Polls the msm idle-refresh state every 10 ms
(read-only; run as root on the tablet) and reports the rhythm of new frames: the kernel's idle_ms
drops back to ~0 whenever a frame is flushed, so the intervals between those drops tell what is
drawing (500 ms = a blinking text caret, 1000 ms = a once-a-second clock/HUD, a few ms = an animation),
plus how long the panel actually spent at each refresh rate. Prints the visible windows too.
2026-10-15: the HUD shows 120 Hz all the time even with nothing happening."""
import re, sys, time, subprocess
from collections import Counter

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 15
P = "/sys/module/msm/parameters/idle_refresh_state"

def state():
    s = open(P).read()
    hz = re.search(r"\bhz (\d+)", s); idle = re.search(r"idle_ms (\d+)", s)
    return int(hz.group(1)) if hz else 0, int(idle.group(1)) if idle else 0

frames, hzt = [], Counter()
last_idle, t0 = None, time.time()
prev = t0
while time.time() - t0 < secs:
    hz, idle = state()
    now = time.time()
    hzt[hz] += now - prev
    prev = now
    if last_idle is not None and idle + 15 < last_idle:      # idle_ms reset: a frame went out
        frames.append(now - idle / 1000)
    last_idle = idle
    time.sleep(0.01)
gaps = [round((b - a) * 1000) for a, b in zip(frames, frames[1:])]
tot = sum(hzt.values())
print(f"== {secs:.0f} s: panel time per rate: " + ", ".join(f"{h} Hz {v / tot * 100:.0f}%" for h, v in sorted(hzt.items())))
print(f"frames seen (idle_ms resets): {len(frames)}  (~{len(frames) / secs:.1f}/s)")
if gaps:
    b = Counter(min(g // 50 * 50, 2000) for g in gaps)
    print("gap histogram (ms bucket: count): " + ", ".join(f"{k}: {v}" for k, v in sorted(b.items())))
    print("first gaps ms: " + " ".join(str(g) for g in gaps[:30]))
