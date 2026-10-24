#!/usr/bin/env python3
"""Does a held finger drag move the picture evenly? (root, tablet; nothing on screen moves by itself)

usage: ts-touchpace.py SECS [eventN]       then drag on the panel yourself during SECS
Records the panel's touch reports (evdev, CLOCK_MONOTONIC) and KWin's page flips (tracefs vblank events,
mono clock) side by side. While a finger is down it prints: the touch report rate and its jitter, how many
touch reports fall between two flips (0 / 1 / 2+: a frame with 0 shows no movement, one with 2 jumps
twice as far = judder even at 120 fps), and how uneven the finger travel per frame is.
Written 10-21 for the owner's 「后台卡片滑动是很流畅的，但是手指按住拖动会卡」.
"""
import collections, fcntl, os, select, statistics, struct, sys, time

T = "/sys/kernel/tracing"
INST = f"{T}/instances/y700-touchpace"
EV = struct.Struct("llHHi")
EVIOCSCLOCKID = 0x400445A0   # _IOW('E', 0xa0, int)


def w(p, v):
    with open(p, "w") as f:
        f.write(v)


def main():
    secs = float(sys.argv[1])
    dev = sys.argv[2] if len(sys.argv) > 2 else next(
        n for n in sorted(os.listdir("/sys/class/input")) if n.startswith("event")
        and "Touch" in open(f"/sys/class/input/{n}/device/name").read())
    fd = os.open(f"/dev/input/{dev}", os.O_RDONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, EVIOCSCLOCKID, struct.pack("i", time.CLOCK_MONOTONIC))
    if os.path.exists(INST):
        os.rmdir(INST)
    os.mkdir(INST)
    w(f"{INST}/trace_clock", "mono")
    w(f"{INST}/buffer_size_kb", "4096")
    w(f"{INST}/events/drm/drm_vblank_event_delivered/enable", "1")
    w(f"{INST}/tracing_on", "1")
    reports, down, x, y, touch = [], False, 0, 0, None   # reports: (t, down, x, y)
    end = time.monotonic() + secs
    print(f"recording {dev} for {secs:.0f} s: drag now", flush=True)
    while time.monotonic() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        data = os.read(fd, EV.size * 64)
        for i in range(0, len(data), EV.size):
            s, us, kind, code, val = EV.unpack_from(data, i)
            if kind == 3 and code == 0x35:
                x = val
            elif kind == 3 and code == 0x36:
                y = val
            elif kind == 1 and code == 0x14a:
                touch = val
            elif kind == 0 and code == 0:
                if touch is not None:
                    down, touch = bool(touch), None
                reports.append((s + us / 1e6, down, x, y))
    w(f"{INST}/tracing_on", "0")
    trace = open(f"{INST}/trace").read()
    w(f"{INST}/events/enable", "0")
    os.rmdir(INST)
    flips = []
    for line in trace.splitlines():
        if "drm_vblank_event_delivered" in line:
            try:
                flips.append(float(line.split(": drm_vblank")[0].split()[-1]))
            except ValueError:
                pass
    moving = [r for r in reports if r[1]]
    print(f"{len(reports)} touch reports ({len(moving)} with a finger down), {len(flips)} flips")
    if len(moving) < 10:
        print("no drag recorded")
        return
    # strokes: consecutive down reports
    strokes, cur = [], []
    for r in reports:
        if r[1]:
            cur.append(r)
        elif cur:
            strokes.append(cur)
            cur = []
    if cur:
        strokes.append(cur)
    per_frame = collections.Counter()
    gaps, steps_rel = [], []
    for st in strokes:
        if len(st) < 10:
            continue
        t0, t1 = st[0][0], st[-1][0]
        dt = [b[0] - a[0] for a, b in zip(st, st[1:])]
        gaps += dt
        fl = [f for f in flips if t0 <= f <= t1]
        # touch reports between consecutive flips, and the finger travel each frame shows
        for a, b in zip(fl, fl[1:]):
            n = sum(1 for r in st if a < r[0] <= b)
            per_frame[min(n, 3)] += 1
        pos = []
        for f in fl:
            last = [r for r in st if r[0] <= f]
            if last:
                pos.append((f, last[-1][2], last[-1][3]))
        d = [((b[1] - a[1]) ** 2 + (b[2] - a[2]) ** 2) ** .5 for a, b in zip(pos, pos[1:])]
        moved = [v for v in d if v > 0]
        if len(moved) > 5:
            m = statistics.mean(d)
            if m > 0:
                steps_rel.append(statistics.pstdev(d) / m)
        print(f"  stroke {t1 - t0:5.2f} s: {len(st)} reports ({len(st) / (t1 - t0):.0f}/s), {len(fl)} flips "
              f"({len(fl) / max(t1 - t0, 1e-3):.0f}/s), frames with no new touch {sum(1 for v in d if v == 0)}/{len(d)}")
    gm = statistics.median(gaps) * 1000
    print(f"touch report interval median {gm:.2f} ms ({1000 / gm:.0f} Hz), p10 {sorted(gaps)[len(gaps) // 10] * 1000:.2f}"
          f" p90 {sorted(gaps)[len(gaps) * 9 // 10] * 1000:.2f} ms")
    tot = sum(per_frame.values())
    print("touch reports per frame: " + "  ".join(f"{k if k < 3 else '3+'}: {v} ({100 * v / tot:.1f} %)"
                                                  for k, v in sorted(per_frame.items())))
    if steps_rel:
        print(f"finger travel per frame, stdev / mean: {statistics.mean(steps_rel):.2f} (0 = perfectly even)")


if __name__ == "__main__":
    main()
