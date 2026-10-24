#!/usr/bin/env python3
"""pop-analyze-h1.py DIR: transients of pop-test-h1.sh relative to each cycle's OPEN / CLOSE marker and to the
kernel's amplifier start / stop times (journal short-unix = the kernel timestamps converted to wall clock).
The recording's sample 0 is taken as REC_STARTED - 1 s (pw-record started one second before the marker); the
amp times in amp.txt give the expected positions. A transient that repeats near the same amp event in every cycle
is the power transient; anything else is room noise. 2026-10-16."""
import sys, wave, numpy as np
D = sys.argv[1] if len(sys.argv) > 1 else "/root/pop-test-h1"
w = wave.open(f"{D}/mic.wav"); sr = w.getframerate()
x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)
md = {l.split()[1]: float(l.split()[0]) for l in open(f"{D}/markers.txt")}
t0 = md["REC_STARTED"] - 1.0
hp = np.diff(x, prepend=x[0]); win = int(0.002 * sr); n = len(hp) // win
pk = np.abs(hp[: n * win]).reshape(n, win).max(axis=1)
amp = []
for l in open(f"{D}/amp.txt"):
    t = float(l.split()[0]); kind = "start" if "start success" in l else "stop"
    if not amp or t - amp[-1][0] > 0.2 or amp[-1][1] != kind: amp.append((t, kind))
print(f"recording {len(x)/sr:.1f} s, noise floor (median 2 ms peak) {np.median(pk):.0f}, amp events: {[(round(a - t0, 2), k) for a, k in amp]}")
half = int(1.0 / 0.002)
for a, k in amp:
    c = int((a - t0) / 0.002)
    lo, hi = max(0, c - 250), min(n, c + 250)          # +-0.5 s around the amp event
    seg = pk[lo:hi]; base = np.median(pk[max(0, c - half):min(n, c + half)]) + 1
    j = int(np.argmax(seg)); t = (lo + j) * 0.002
    print(f"  amp {k:5s} at {a - t0:7.2f} s: loudest 2 ms within +-0.5 s = {seg[j]:6.0f} ({seg[j]/base:5.1f}x local median) at {(t - (a - t0))*1000:+5.0f} ms")
quiet = []
for nm in ("C1_OPEN", "C2_OPEN", "C3_OPEN"):
    c = int((md[nm] - t0 - 2.0) / 0.002); quiet.append(float(pk[max(0, c - 250):c + 250].max()))
print(f"  reference: loudest 2 ms in the 1 s of silence 2 s before each OPEN: {[round(q) for q in quiet]}")
