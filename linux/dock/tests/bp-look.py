#!/usr/bin/env python3
# bp-look.py: what batpage.sh checks on its bed screenshots of the battery page (linux/power/battery/DESIGN.md §6
# 「视觉」 and §8), and where the control centre's battery pill is. batpage-run.sh stages it next to the canned
# reports and the scenario runs it inside the bed (python3 with numpy and PIL, as bc-look.py in battcap.sh).
#   bp-look.py page PNG --checks max,margin,seg-right,list-right,pitch,nolist,sel,differs,like
#                       --frame X,Y,W,H [--client X,Y,W,H] [--area X,Y,W,H] [--sel N] [--differs PNG] [--like PNG]
#   bp-look.py pill PNG        -> "PILL x0 x1 y0 y1 n" or "PILL none n"
# page: one line per check, starting with PASS or FAIL (batpage.sh turns each FAIL into SBBED_EXPECT_FAIL), INFO
# lines are notes. --frame / --client / --area are KWin's frame and client rectangles of the page's window and its
# maximize area (batpage.sh's pageinfo; "none" where this KWin's script API had none). The screenshot is the whole
# screen, the layout numbers of DESIGN.md are the window's own (client) coordinates: every check but max measures in
# a crop of the client rectangle. With a KWin title bar (DESIGN.md 11b item 10: no BorderlessMaximizedWindows in the
# real kwinrc) the client is shorter than the frame; x is the same, and the page's top rows keep their y (the chart
# absorbs the height), so the checks hold either way and max only reports the title bar.
import argparse
import sys

import numpy as np
from PIL import Image

BG = 18                     # #121212, the page's Window colour
INK = 8                     # a channel further than this from BG is ink: the separators (#262626) are 20 off
ACCENT = np.array([0x2E, 0x6B, 0xF6], dtype=np.int16)   # the selected segment's fill
ACCENT_TOL = 16
PITCH = 76                  # a list row
SEG_TOL = 4                 # the accent block against its cell: the radius (<= 4 px) eats the corners' columns
DIFF_LEVEL = 24             # a pixel "differs" when a channel moved more than this (antialiasing jitter stays under)
DIFFERS_MIN = 0.002         # --differs: at least this share of the client's pixels changed
LIKE_MAX = 0.003            # --like: at most this share changed
CHECKS = ("max", "margin", "seg-right", "list-right", "pitch", "nolist", "sel", "differs", "like")


def load(path):
    return np.asarray(Image.open(path).convert("RGB")).astype(np.int16)


def rect(s):
    if s is None or s.strip() in ("", "none", "?"):
        return None
    v = [int(round(float(p))) for p in s.split(",")]
    if len(v) != 4:
        raise ValueError("not X,Y,W,H: %s" % s)
    return tuple(v)


def fmt(r):
    return "%d,%d %dx%d" % r if r else "none"


def ink(a):
    return np.abs(a - BG).max(axis=-1) > INK


def say(ok, name, text):
    print("%s %s: %s" % ("PASS" if ok else "FAIL", name, text))


class Layout:
    """DESIGN.md §6 in the client's coordinates, by orientation (Main.qml switches on width > height)."""

    def __init__(self, cw, ch):
        self.cw, self.ch = cw, ch
        self.land = cw > ch
        self.m = 56 if self.land else 32
        self.r = cw - self.m                       # the right edge everything ends on: 1544 / 970
        if self.land:
            self.seg = (24, 80)                    # the top bar; the segmented control is the right column's
            self.seg_x0 = 968                      # the column gap: 「电池」 at the left is not the control
            self.cells = [self.r - 528, self.r - 352, self.r - 176, self.r]     # 3 x 176 over x 1016-1544
            self.list_box = (1016, 184)            # the list: right column, y 184 down
            self.probe = (1080, self.r - 4)        # separators start at 1076; the share bars too, but only the
            #                                        biggest one runs the whole width
            self.ac_box = (1076, 184)
        else:
            self.seg = (96, 152)
            self.seg_x0 = 0
            w = self.r - self.m                    # 938 = 312 + 313 + 313
            a = w // 3
            self.cells = [self.m, self.m + a, self.m + a + (w - a) // 2, self.r]   # 32 / 344 / 657 / 970
            self.list_box = (0, 160)               # one Flickable: whatever is on screen below the control
            self.probe = (self.r - 400, self.r - 4)   # right of the share bars (468 long from x 92: to 560)
            self.ac_box = (self.m + 60, 0)


def line_rows(a, y0, y1, x0, x1):
    """Bottoms of thin (<= 6 px) full-width uniform lines: the separators (and a share bar right above one)."""
    reg = a[y0:y1, x0:x1]
    if reg.shape[0] == 0 or reg.shape[1] == 0:
        return []
    cover = ink(reg).mean(axis=1)
    flat = reg.std(axis=1).max(axis=-1)
    rows = (np.nonzero((cover >= 0.97) & (flat <= 8))[0] + y0).tolist()
    blocks = []
    for r in rows:
        if blocks and r == blocks[-1][1] + 1:
            blocks[-1][1] = r
        else:
            blocks.append([r, r])
    return [b[1] for b in blocks if b[1] - b[0] < 6]


def longest_run(ys):
    """The longest run of equal (+-1) steps between lines: (steps, median step)."""
    d = np.diff(np.array(ys, dtype=np.int64))
    best = (0, None)
    for i in range(len(d)):
        j = i + 1
        while j < len(d) and abs(int(d[j]) - int(d[i])) <= 1:
            j += 1
        if j - i > best[0]:
            best = (j - i, float(np.median(d[i:j])))
    return best


def autocorr(a, y0, y1, x0, x1):
    """The strongest period (50-110 px) of the ink per row: rows of text repeat at the row pitch even where no
    separator line is found (say a page that draws them in a colour too close to the background)."""
    reg = a[y0:y1, x0:x1]
    if reg.shape[0] < 230 or reg.shape[1] == 0:
        return None, 0.0
    p = ink(reg).sum(axis=1).astype(np.float64)
    p -= p.mean()
    e = float((p * p).sum())
    if e == 0:
        return None, 0.0
    best = (None, -1.0)
    for lag in range(50, 111):
        c = float((p[:-lag] * p[lag:]).sum()) / e
        if c > best[1]:
            best = (lag, c)
    return best


def pitch_of(a, L):
    y0 = L.list_box[1]
    ys = line_rows(a, y0, L.ch - 4, L.probe[0], L.probe[1])
    n, step = longest_run(ys)
    lag, c = autocorr(a, L.ac_box[1], L.ch - 4, L.ac_box[0], L.r)
    by_lines = n >= 2 and step is not None and abs(step - PITCH) <= 1
    by_ac = lag is not None and abs(lag - PITCH) <= 1 and c > 0.3
    text = "%d line(s) at y %s; longest even run %d step(s) of %s px; ink period %s px (%.2f)" % (
        len(ys), ",".join(str(y) for y in ys[:16]) + (",..." if len(ys) > 16 else ""), n,
        "%g" % step if step is not None else "-", lag if lag is not None else "-", c)
    return by_lines, by_ac, text


def accent_box(a, L):
    y0, y1 = L.seg
    band = a[y0:y1, L.seg_x0:]
    hit = np.all(np.abs(band - ACCENT) <= ACCENT_TOL, axis=-1)
    # columns that are mostly fill: the white label leaves holes, the rounded corners a fringe
    cols = np.nonzero(hit.sum(axis=0) >= max(4, (y1 - y0) // 4))[0]
    if len(cols) == 0:
        return None
    return L.seg_x0 + int(cols.min()), L.seg_x0 + int(cols.max()) + 1


def which_cell(box, L, tol):
    for i in range(3):
        if abs(box[0] - L.cells[i]) <= tol and abs(box[1] - L.cells[i + 1]) <= tol:
            return i
    return None


def page(args):
    img = load(args.png)
    H, W = img.shape[:2]
    frame, client, area = rect(args.frame), rect(args.client), rect(args.area)
    checks = [c for c in args.checks.split(",") if c]
    for c in checks:
        if c not in CHECKS:
            raise SystemExit("bp-look.py: unknown check %s" % c)
    if client is None:
        if frame is None:
            for c in checks:
                say(False, c, "no window geometry from KWin")
            return
        print("INFO KWin gave no client rectangle: measuring in the frame")
        client = frame
    cx, cy, cw, ch = client
    x0, y0, x1, y1 = max(0, cx), max(0, cy), min(W, cx + cw), min(H, cy + ch)
    if (x0, y0, x1, y1) != (cx, cy, cx + cw, cy + ch):
        print("INFO the client %s runs off the %dx%d screenshot: clipped" % (fmt(client), W, H))
    if x1 - x0 < 200 or y1 - y0 < 200:
        for c in checks:
            say(False, c, "the client %s is not on the screenshot" % fmt(client))
        return
    a = img[y0:y1, x0:x1]
    L = Layout(a.shape[1], a.shape[0])
    print("INFO %s, client %s, right edge x %d" % ("landscape" if L.land else "portrait", fmt(client), L.r))

    for c in checks:
        if c == "max":
            bar = args.bar
            want = (0, bar, W, H - bar)
            if frame is None:
                say(False, c, "no frame rectangle from KWin")
                continue
            ok = all(abs(f - w) <= 1 for f, w in zip(frame, want))
            note = ""
            if area is not None and area != want:
                note = "; KWin's maximize area is %s (another window reserving room?)" % fmt(area)
            elif area is not None:
                note = "; = KWin's maximize area"
            say(ok, c, "frame %s, want %s (the %dx%d screen less the %d px status bar)%s"
                % (fmt(frame), fmt(want), W, H, bar, note))
            tb = cy - frame[1]
            if tb > 0 or cw != frame[2]:
                print("INFO title bar %d px: the client is %dx%d (DESIGN.md 11b item 10; the chart absorbs it)"
                      % (tb, cw, ch))
            else:
                print("INFO no title bar: the client is the whole frame, %dx%d" % (cw, ch))
        elif c == "margin":
            m = ink(a[:, L.r + 1:])
            n = int(m.sum())
            if n == 0:
                say(True, c, "nothing right of x %d" % L.r)
            else:
                ys, xs = np.nonzero(m)
                say(False, c, "%d ink pixel(s) right of x %d, in x %d-%d y %d-%d" % (
                    n, L.r, L.r + 1 + xs.min(), L.r + 1 + xs.max(), ys.min(), ys.max()))
        elif c == "seg-right":
            sy0, sy1 = L.seg
            cols = np.nonzero(ink(a[sy0:sy1, L.seg_x0:]).sum(axis=0) >= 2)[0]
            right = L.seg_x0 + int(cols.max()) + 1 if len(cols) else None
            box = accent_box(a, L)
            if right is not None and abs(right - L.r) <= 1:
                say(True, c, "the control ends at x %d" % right)
            elif right is not None and right > L.r + 1:
                say(False, c, "ink in the control's band (y %d-%d) up to x %d, past %d" % (sy0, sy1, right, L.r))
            elif box is not None and which_cell(box, L, SEG_TOL) is not None:
                # unselected segments drawn as bare labels: the last label ends short of the edge, but the
                # selected block sits in its cell of a control that ends on L.r
                i = which_cell(box, L, SEG_TOL)
                say(True, c, "implied: the selected block x %d-%d is cell %d of %s (last ink x %s)"
                    % (box[0], box[1], i, "/".join(map(str, L.cells)), right))
            else:
                say(False, c, "the control's band (y %d-%d) ends at x %s, want %d; selected block %s"
                    % (sy0, sy1, right, L.r, "x %d-%d" % box if box else "none"))
        elif c == "list-right":
            lx, ly = L.list_box
            cols = np.nonzero(ink(a[ly:L.ch - 4, lx:]).sum(axis=0) >= 2)[0]
            right = lx + int(cols.max()) + 1 if len(cols) else None
            ok = right is not None and L.r - 3 <= right <= L.r
            say(ok, c, "the %s (x %d-, y %d-%d) ends at x %s, want %d-%d" % (
                "list" if L.land else "page below the control", lx, ly, L.ch - 4, right, L.r - 3, L.r))
        elif c in ("pitch", "nolist"):
            by_lines, by_ac, text = pitch_of(a, L)
            if c == "pitch":
                say(by_lines or by_ac, c, "rows %d px %s: %s" % (
                    PITCH, "by the separators" if by_lines else "by the ink period" if by_ac else "not found", text))
            else:
                say(not (by_lines or by_ac), c, "no %d px rows (the list is replaced): %s" % (PITCH, text))
        elif c == "sel":
            if args.sel is None:
                raise SystemExit("bp-look.py: sel needs --sel N")
            box = accent_box(a, L)
            want = (L.cells[args.sel], L.cells[args.sel + 1])
            ok = box is not None and abs(box[0] - want[0]) <= SEG_TOL and abs(box[1] - want[1]) <= SEG_TOL
            say(ok, c, "selected block %s, want segment %d at x %d-%d" % (
                "x %d-%d" % box if box else "none", args.sel, want[0], want[1]))
        elif c in ("differs", "like"):
            path = args.differs if c == "differs" else args.like
            if not path:
                raise SystemExit("bp-look.py: %s needs --%s PNG" % (c, c))
            try:
                b = load(path)[y0:y1, x0:x1]
            except OSError as e:
                say(False, c, "cannot read %s: %s" % (path, e))
                continue
            if b.shape != a.shape:
                say(False, c, "%s is %s, this client %s" % (path, b.shape[:2], a.shape[:2]))
                continue
            frac = float((np.abs(a - b).max(axis=-1) > DIFF_LEVEL).mean())
            if c == "differs":
                say(frac >= DIFFERS_MIN, c, "%.2f %% of the page changed against %s (want >= %.1f %%)"
                    % (100 * frac, path.rsplit("/", 1)[-1], 100 * DIFFERS_MIN))
            else:
                say(frac <= LIKE_MAX, c, "%.2f %% of the page changed against %s (want <= %.1f %%)"
                    % (100 * frac, path.rsplit("/", 1)[-1], 100 * LIKE_MAX))


def pill(args):
    # bc-look.py (battcap.sh) for any screen width: the bright pixels (luma > 170: the digits, the chevron, the
    # battery outline, a ⚡) in the header's right end, the last 400 px, y 20-119 (the clock and the date are at the
    # left; the controls start at y 162). Over the battery page the curtain's tint keeps the page's text below 170.
    img = load(args.png).astype(np.float32)
    W = img.shape[1]
    X0, Y0 = max(0, W - 400), 20
    luma = img[Y0:120, X0:W] @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    ys, xs = np.nonzero(luma > 170)
    if len(xs) < 20:
        print("PILL none %d" % len(xs))
    else:
        print("PILL %d %d %d %d %d" % (X0 + xs.min(), X0 + xs.max(), Y0 + ys.min(), Y0 + ys.max(), len(xs)))


def main():
    ap = argparse.ArgumentParser(prog="bp-look.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("page")
    p.add_argument("png")
    p.add_argument("--checks", required=True)
    p.add_argument("--frame")
    p.add_argument("--client")
    p.add_argument("--area")
    p.add_argument("--sel", type=int, choices=(0, 1, 2))
    p.add_argument("--differs")
    p.add_argument("--like")
    p.add_argument("--bar", type=int, default=28, help="the status bar's height (shellbar main.cpp)")
    q = sub.add_parser("pill")
    q.add_argument("png")
    args = ap.parse_args()
    if args.cmd == "page":
        page(args)
    else:
        pill(args)


if __name__ == "__main__":
    sys.exit(main())
