#!/usr/bin/env python3
"""pop-analyze.py DIR: find click/pop transients in DIR/mic.wav (pop-test.sh) and map them to the step markers.
Alignment: the recording's first sample ~ REC_STARTED - 1 s is too coarse, so the S1 tone (2 kHz, 150 ms) is located
in the recording and its offset to the S1_TONE marker gives the clock offset (the pw-play start latency of a cold
speaker path is part of what is measured, so S5_TONE - a warm path - is used for the offset when found, S1 otherwise).
Transient = a 2 ms window whose high-passed peak exceeds THRESH x the median 2 ms peak of the surrounding 2 s and an
absolute floor; tone windows are excluded. Also prints the aw882xx start/stop lines of DIR/timeline.txt per step.
2026-10-16."""
import sys, wave, numpy as np
D = sys.argv[1] if len(sys.argv) > 1 else "/root/pop-test"
THRESH, FLOOR = 8.0, 400          # x local median, absolute (s16)
w = wave.open(f"{D}/mic.wav"); sr = w.getframerate(); x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)
marks = [(float(l.split()[0]), l.split()[1]) for l in open(f"{D}/markers.txt")]
t_rec = dict((n, t) for t, n in marks)["REC_STARTED"] - 1.0     # pw-record was started 1 s before the marker
hp = np.diff(x, prepend=x[0])                                       # crude high-pass: clicks are broadband
win = int(0.002 * sr); n = len(hp) // win
pk = np.abs(hp[: n * win]).reshape(n, win).max(axis=1)
# 2 kHz tone detector: energy at 2 kHz in 10 ms frames
f10 = int(0.01 * sr); m = len(x) // f10
fr = x[: m * f10].reshape(m, f10); k = np.exp(-2j * np.pi * 2000 * np.arange(f10) / sr)
tone = np.abs(fr @ k) / f10
on = tone > max(50, 10 * np.median(tone))
segs, i = [], 0
while i < m:
    if on[i]:
        j = i
        while j < m and on[j]: j += 1
        if j - i >= 5: segs.append((i * 0.01, j * 0.01))
        i = j
    else: i += 1
md = dict((nm, t) for t, nm in marks)
def rel(nm): return md[nm] - t_rec
offset = 0.0
if len(segs) >= 2: offset = segs[1][0] - rel("S5_TONE"); src = "S5 tone"
elif segs: offset = segs[0][0] - rel("S1_TONE"); src = "S1 tone"
else: src = "none (no tone found)"
print(f"recording {len(x)/sr:.1f} s, tone segments at {[(round(a,2), round(b,2)) for a,b in segs]}, clock offset {offset*1000:+.0f} ms from {src}")
for nm in ("S1_TONE", "S5_TONE"):
    if nm in md: print(f"  {nm}: marker at {rel(nm)+offset:.2f} s in the recording (after offset)")
if segs and "S1_TONE" in md:
    print(f"  cold-path start latency (S1 tone heard - S1 marker): {(segs[0][0] - (rel('S1_TONE') + offset))*1000:.0f} ms")
excl = [(a - 0.03, b + 0.03) for a, b in segs]
ev = []
half = int(1.0 / 0.002)
for i in range(n):
    t = i * 0.002
    if any(a <= t <= b for a, b in excl): continue
    lo, hi = max(0, i - half), min(n, i + half)
    base = np.median(pk[lo:hi]) + 1
    if pk[i] > FLOOR and pk[i] > THRESH * base:
        if ev and t - ev[-1][0] < 0.05:
            if pk[i] > ev[-1][1]: ev[-1] = (ev[-1][0], pk[i], pk[i] / base)
            continue
        ev.append((t, pk[i], pk[i] / base))
order = sorted(((rel(nm) + offset, nm) for nm in md), key=lambda z: z[0])
def step_of(t):
    s = "before S1"
    for tt, nm in order:
        if tt <= t: s = nm
    return s
print(f"\n{len(ev)} transient(s) (peak > {THRESH:.0f}x local median and > {FLOOR}):")
for t, p, r in ev:
    near = min(order, key=lambda z: abs(z[0] - t))
    print(f"  t={t:7.3f} s  peak {p:6.0f}  {r:5.1f}x  in {step_of(t):15s} ({(t - near[0])*1000:+6.0f} ms from {near[1]})")
print("\nmic noise floor (median 2 ms peak):", round(float(np.median(pk)), 1))
try:
    tl = open(f"{D}/timeline.txt").read().splitlines()
    print("\naw882xx / stream events by step:")
    import datetime
    for l in tl:
        if any(k in l for k in ("start success", "device_stop: done", "new' on sink-input", "SUSPENDED", "RUNNING")):
            hh, mm, ss = l.split()[0].split(":")
            day = datetime.datetime.fromtimestamp(t_rec).replace(hour=int(hh), minute=int(mm), second=0, microsecond=0)
            tt = day.timestamp() + float(ss) - t_rec + offset
            print(f"  t={tt:7.3f} s  in {step_of(tt):15s}  {l[13:120]}")
except FileNotFoundError:
    pass
