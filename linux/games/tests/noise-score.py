"""noise-score.py PNG... - count 32x32 tiles that look like random noise in a 3040x1904 Steam screenshot.
A pixel counts when its RGB difference (sum over channels) to both its right and its lower neighbour is over 40;
a tile is noisy when over 40 % of its pixels count. Calibrated 10-30 on the 10-29 screenshots: the GPU-drawn page
with noise blocks scores 1022 tiles, CPU-drawn store/review pages 0-21 (pixel-art game shots), so >150 = noise."""
import sys

import numpy as np
from PIL import Image

T = 32
for f in sys.argv[1:]:
    try:
        a = np.asarray(Image.open(f).convert("RGB"), dtype=np.int16)
    except OSError as e:
        print(f"{f}: unreadable ({e})")
        continue
    a = a[380:1800, 0:2560]  # below Steam's header, left of its scrollbar
    dx = np.abs(np.diff(a, axis=1)).sum(axis=2)[:-1, :] > 40
    dy = np.abs(np.diff(a, axis=0)).sum(axis=2)[:, :-1] > 40
    m = (dx & dy).astype(np.float32)
    h, w = m.shape[0] // T * T, m.shape[1] // T * T
    tiles = m[:h, :w].reshape(h // T, T, w // T, T).mean(axis=(1, 3))
    noisy = int((tiles > 0.40).sum())
    verdict = "NOISE" if noisy > 150 else "clean"
    print(f"{f.rsplit('/', 1)[-1]}: {verdict} - noisy tiles {noisy}/{tiles.size}, max tile {tiles.max():.2f}")
