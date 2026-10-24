#!/usr/bin/env python3
"""pop-analyze-h3.py DIR: zipper of volume steps, live chain (A) vs smoothed chain (B), from pop-test-h3.sh.
The 440 Hz tone is fitted per 5 ms block with a FIXED amplitude per 20 ms block would hide the steps, so instead:
the tone envelope is tracked with a sliding 440 Hz fit over 10 ms blocks, and the HIGH-PASSED residual (what is
not the tone) is measured in 2 ms peaks. A step applied instantly leaves a broadband click per step in the
residual; a smoothed step leaves only a slow envelope change that the per-block fit absorbs. Reported per side:
the residual during the steps vs during the steady tone before them. 2026-10-16."""
import sys, wave, numpy as np
D = sys.argv[1] if len(sys.argv) > 1 else "/root/pop-test-h3"
w = wave.open(f"{D}/mic.wav"); sr = w.getframerate()
x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64)
md = {l.split()[1]: float(l.split()[0]) for l in open(f"{D}/markers.txt")}
t0 = md["REC_STARTED"] - 1.0
B = int(0.01 * sr); nb = len(x) // B; res = np.zeros(nb * B); tt = np.arange(B) / sr
for b in range(nb):
    seg = x[b * B:(b + 1) * B]; ph = tt + b * B / sr
    A = np.stack([np.sin(2 * np.pi * 440 * ph), np.cos(2 * np.pi * 440 * ph), np.ones(B), np.arange(B) / B], 1)
    c, *_ = np.linalg.lstsq(A, seg, rcond=None); res[b * B:(b + 1) * B] = seg - A @ c
hp = np.diff(res, prepend=res[0]); win = int(0.002 * sr); n = len(hp) // win
pk = np.abs(hp[: n * win]).reshape(n, win).max(axis=1)
def idx(t): return int((t - t0) / 0.002)
for side in ("A", "B"):
    if f"{side}_STEPS" not in md: print(f"{side}: no data ({[k for k in md if k.startswith(side)]})"); continue
    s0, s1 = idx(md[f"{side}_STEPS"]), idx(md[f"{side}_STEPS_END"]) + 100
    q0, q1 = idx(md[f"{side}_TONE"]) + 500, idx(md[f"{side}_STEPS"]) - 50
    steady = float(np.percentile(pk[q0:q1], 99)) + 1
    dur = pk[s0:s1]
    print(f"{side} ({'live chain' if side == 'A' else 'smoothed chain'}): steady 99th pct {steady:.0f}; during the steps: max {dur.max():.0f} "
          f"({dur.max() / steady:.1f}x), 2 ms windows above 3x steady: {(dur > 3 * steady).sum()} of {len(dur)}")
import os
for f in ("log.txt", "instance.log"):
    p = f"{D}/{f}"
    if os.path.exists(p): print(f"--- {f}:", open(p).read().strip()[-600:])
