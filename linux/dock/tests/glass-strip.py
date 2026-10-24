#!/usr/bin/env python3
# glass-strip.py OUT STRIP.png: the dock band of the dock-glass bed frames (dock-glass.sh in OUT) around the leave,
# one row per frame, the 01-desktop reference on top, each row labelled with the numbers the verdict uses: rim (the
# dock's glass rim), beside (the band left of the body), above (the wallpaper over the band), wall (mean of a
# wallpaper patch under the cards' tint). Prints the same table. dock-glass-run.sh makes it after every run.
import glob
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

out, dst = sys.argv[1], sys.argv[2]


def gray(p):
    return np.asarray(Image.open(p).convert("L"), dtype=np.float64)


def sharp(g, x0, y0, x1, y1):
    r = g[y0:y1, x0:x1]
    lap = -4 * r[1:-1, 1:-1] + r[:-2, 1:-1] + r[2:, 1:-1] + r[1:-1, :-2] + r[1:-1, 2:]
    return float(lap.var())


def edge(g):       # the blur's size, as dock-glass.sh edge(): the wallpaper's step at x 800 smeared under the dock
    p = g[895:906, :].mean(axis=0)
    s = np.convolve(p, np.ones(31) / 31, mode="same")
    step = 0.7 * abs(s[1200:1500].mean() - s[100:400].mean())
    r = s[600:1000]
    slope = np.abs(r[24:] - r[:-24]).max() / 24
    return float(step / slope) if slope > 0 else 0.0


def nums(g):
    return (max(sharp(g, 600, 895, 740, 906), sharp(g, 860, 895, 1000, 906)), sharp(g, 100, 895, 400, 906),
            sharp(g, 100, 862, 400, 880), float(g[300:500, 100:400].mean()), edge(g))


times = {}
for line in open(out + "/glass/frames.txt"):
    if line[0] != "#":
        p = line.split()
        times[int(p[0])] = p[1]          # frames.txt counts 0, 1, 2; the files are f000, f001, f002
frames = sorted(glob.glob(out + "/glass/f*.png"))
rows = [("01-desktop", out + "/01-desktop.png")]
vals = [nums(gray(f)) for f in frames]
ch = [i for i in range(1, len(vals)) if any(abs(a - b) > 0.5 for a, b in zip(vals[i], vals[i - 1]))]
if ch:
    lo, hi = max(0, ch[0] - 1), min(len(vals) - 1, ch[-1] + 2)
    idx = list(range(lo, hi + 1))
    step = max(1, (len(idx) + 23) // 24)
    rows += [(os.path.basename(frames[i])[:-4], frames[i]) for i in idx[::step]]
crops = []
for name, path in rows:
    im = Image.open(path).convert("RGB").crop((200, 850, 1400, 1002))
    r, b, a, m, e = nums(gray(path))
    t = times.get(int(name[1:]), "") if name[1:].isdigit() else ""      # the 01-desktop row has no time
    ImageDraw.Draw(im).text((4, 4), f"{name} {t}ms rim {r:.1f} beside {b:.1f} above {a:.1f} wall {m:.0f} edge {e:.0f}", fill=(255, 40, 40))
    crops.append(im)
    print(f"{name:>10} t={t or '-':>7} rim {r:7.1f} beside {b:7.1f} above {a:7.1f} wall {m:5.1f} edge {e:5.0f}")
w, h = crops[0].size
sheet = Image.new("RGB", (w, h * len(crops)))
for k, c in enumerate(crops):
    sheet.paste(c, (0, k * h))
sheet.save(dst)
