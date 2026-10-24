#!/usr/bin/env python3
# capseq.py: a burst of screen frames from the LIVE KWin, as fast as it renders them, to catch a one-frame glitch
# (the blur "flicker" when the curtain starts pulling). Runs the y700-capseq binary (a copy of python3 whose desktop
# file carries X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2, see install.sh) as the session user:
#   y700-capseq capseq.py OUT N [SCREEN] [X0 Y0 X1 Y1]
# Keeps N frames in memory (ScreenShot2.CaptureScreen, logical resolution; ~6.4 MB each at 1600x1003, so N=100 is
# 640 MB), then writes OUT/fNNN.png, a contact sheet OUT/sheet.png and OUT/frames.txt: per frame its time (ms from
# the first), the mean brightness and a sharpness number (variance of the Laplacian) inside the region X0 Y0 X1 Y1
# (default 300,40-1400,150: the strip under the curtain's header, where the curtain itself draws nothing), and
# the curtain analysis (blur-flicker.sh reads it):
#   tint_rows  how many rows of the region, from the top, are under the curtain: a row counts when its mean is
#              below 0.85 x the same row's mean in the FIRST frame (which must have no curtain). Partial frames
#              (the lower edge crossing the region) are thereby judged on their covered rows only.
#   sharp_t    the sharpness of those rows (the bottom 4 dropped: the edge hairline), 0 when fewer than 24
#   ratio      sharp_t over the first frame's sharpness of the same rows. The 46% tint alone leaves
#              (1 - 0.46)^2 = 0.29 of the desktop's sharpness; KWin's blur (strength 12) leaves under 0.1.
#              A ratio above 0.22 is a frame painted tinted but sharp: the curtain without its blur.
import os
import sys
import time

import gi

gi.require_version("Gio", "2.0")
import numpy as np
from gi.repository import Gio, GLib
from PIL import Image

out = sys.argv[1]
n = int(sys.argv[2])
screen = sys.argv[3] if len(sys.argv) > 3 else "DSI-1"
reg = tuple(int(v) for v in sys.argv[4:8]) if len(sys.argv) >= 8 else (300, 40, 1400, 150)
os.makedirs(out, exist_ok=True)

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
frames = []
t0 = time.monotonic()
for i in range(n):
    r, w = os.pipe()
    fdl = Gio.UnixFDList.new()
    idx = fdl.append(w)
    os.close(w)
    params = GLib.Variant("(sa{sv}h)", (screen, {"native-resolution": GLib.Variant("b", False)}, idx))
    res, _ = bus.call_with_unix_fd_list_sync(
        "org.kde.KWin", "/org/kde/KWin/ScreenShot2", "org.kde.KWin.ScreenShot2", "CaptureScreen",
        params, GLib.VariantType("(a{sv})"), Gio.DBusCallFlags.NONE, 5000, fdl, None)
    t = time.monotonic() - t0
    wd = (int(time.time() * 1000000) % (1 << 32)) // 1000   # the ms stamp WAYLAND_DEBUG prints, for lining up
    attrs = res.unpack()[0]
    del fdl, _    # the fd list keeps its own dup of the write end: drop it or the read below never sees EOF
    data = bytearray()
    with os.fdopen(r, "rb") as f:
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            data += chunk
    frames.append((t, wd, attrs, bytes(data)))
print(f"captured {n} frames in {time.monotonic() - t0:.2f} s", flush=True)


def to_rgb(attrs, data):
    w, h, stride, fmt = attrs["width"], attrs["height"], attrs["stride"], attrs["format"]
    a = np.frombuffer(data, dtype=np.uint8)[: h * stride].reshape(h, stride)[:, : w * 4].reshape(h, w, 4)
    # QImage::Format_ARGB32 (5) / _Premultiplied (6) / RGB32 (4) are BGRA in memory on little-endian; RGBA8888 (17-19) as is
    return a[:, :, :3] if fmt in (17, 18, 19) else a[:, :, 2::-1]


def laplacian(g):
    return 4 * g[1:-1, 1:-1] - g[:-2, 1:-1] - g[2:, 1:-1] - g[1:-1, :-2] - g[1:-1, 2:]


x0, y0, x1, y1 = reg
lines = ["# i  t_ms  wdebug_ms  mean  sharp  tint_rows  sharp_t  ratio   (region %d,%d-%d,%d)" % reg]
thumbs = []
g0 = rows0 = None
for i, (t, wd, attrs, data) in enumerate(frames):
    rgb = to_rgb(attrs, data)
    img = Image.fromarray(np.ascontiguousarray(rgb))
    img.save(os.path.join(out, f"f{i:03d}.png"))
    g = rgb[y0:y1, x0:x1].astype(np.float32).mean(axis=2)
    lap = laplacian(g)
    if g0 is None:
        g0, rows0 = g, g.mean(axis=1)
        lines.append(f"# first: mean {g.mean():.1f} sharp {lap.var():.1f}")
    tinted = g.mean(axis=1) < 0.85 * rows0
    k = int(np.argmin(tinted)) if not tinted.all() else len(tinted)
    sharp_t = ratio = 0.0
    if k >= 24:
        kk = k - 4
        sharp_t = float(laplacian(g[:kk]).var())
        # against the first frame's same rows; a flat first frame (sharpness under 50: the blur's own noise
        # scores more) says nothing, ratio stays 0 and blur-flicker.sh's gate on the first frame reports it
        s0 = float(laplacian(g0[:kk]).var())
        ratio = sharp_t / s0 if s0 >= 50 else 0.0
    lines.append(f"{i:3d} {t * 1000:7.1f} {wd:10d} {g.mean():6.1f} {lap.var():8.1f} {k:5d} {sharp_t:8.1f} {ratio:6.3f}")
    thumbs.append(img.resize((400, max(1, round(400 * img.height / img.width)))))
with open(os.path.join(out, "frames.txt"), "w") as f:
    f.write("\n".join(lines) + "\n")
print("\n".join(lines))
cols = 5
rows = (len(thumbs) + cols - 1) // cols
tw, th = thumbs[0].size
sheet = Image.new("RGB", (cols * tw, rows * th), (30, 30, 30))
for i, im in enumerate(thumbs):
    sheet.paste(im, ((i % cols) * tw, (i // cols) * th))
sheet.save(os.path.join(out, "sheet.png"))
