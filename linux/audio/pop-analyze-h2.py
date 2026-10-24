#!/usr/bin/env python3
"""pop-analyze-h2.py DIR: glitches in the recorded 440 Hz tone of pop-test-h2.sh around each marker.
The tone is removed by a narrow notch (subtract the best-fitting 440 Hz sinusoid per 20 ms block), then 2 ms peaks of the
high-passed residual are compared with the residual's median over the steady part of the tone. A glitch (dropout,
discontinuity, zipper step) leaves a residual spike; room noise shows up as well, so each event is compared with the
same-sized windows that contain no event. Sample 0 = REC_STARTED - 1 s. 2026-10-16."""
import sys, wave, numpy as np
D = sys.argv[1] if len(sys.argv) > 1 else "/root/pop-test-h2"
w = wave.open(f"{D}/mic.wav"); sr = w.getframerate()
x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64)
md = {l.split()[1]: float(l.split()[0]) for l in open(f"{D}/markers.txt")}
t0 = md["REC_STARTED"] - 1.0
B = int(0.02 * sr); nb = len(x) // B; res = np.zeros(nb * B)
tt = np.arange(B) / sr
for b in range(nb):
    seg = x[b * B:(b + 1) * B]
    A = np.stack([np.sin(2 * np.pi * 440 * (tt + b * B / sr)), np.cos(2 * np.pi * 440 * (tt + b * B / sr)), np.ones(B)], 1)
    coef, *_ = np.linalg.lstsq(A, seg, rcond=None); res[b * B:(b + 1) * B] = seg - A @ coef
hp = np.diff(res, prepend=res[0]); win = int(0.002 * sr); n = len(hp) // win
pk = np.abs(hp[: n * win]).reshape(n, win).max(axis=1)
def idx(t): return int((t - t0) / 0.002)
s, e = idx(md["TONE_START"]) + 500, idx(md["TONE_STOP"]) - 100
base = float(np.median(pk[s:e])) + 1
print(f"tone residual: median 2 ms peak {base:.0f} over the tone; overall max {pk[s:e].max():.0f}")
events = [k for k in md if k[:2] in ("LL", "VO")]
for k in sorted(events, key=lambda k: md[k]):
    c = idx(md[k]); a, b = max(s, c - 50), min(e, c + 250)       # -0.1 .. +0.5 s around the event
    j = int(np.argmax(pk[a:b])); print(f"  {k:10s}: loudest residual {pk[a + j]:6.0f} ({pk[a + j] / base:5.1f}x) at {(a + j - c) * 2:+5d} ms")
# control windows: same size, between events
ctrl = []
for k in ("LL1_JOIN", "LL2_JOIN", "LL3_JOIN"):
    c = idx(md[k]) - 600; ctrl.append(float(pk[max(s, c - 50):c + 250].max()) / base)
print(f"  control windows 1.2 s before each join: {[round(v, 1) for v in ctrl]}x")
print(open(f"{D}/log.txt").read().strip() if __import__('os').path.exists(f"{D}/log.txt") else "")
