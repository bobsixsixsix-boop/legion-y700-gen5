#!/usr/bin/env python3
"""How smooth does the stream actually look?  Count what reaches the panel (root, tablet).

usage: ml-flips.py SECS [out.txt]
Moonlight's own stats only see frames it drops itself.  With frame pacing off it hands
every decoded frame to KWin at once; KWin latches the newest one per refresh, so two
frames in one refresh -> one silently lost, none -> the old one shown twice.  This
traces, in a private tracefs instance (no debugfs):
  irq/irq_handler_entry for the iris decoder IRQ   -> frames decoded
  drm/drm_vblank_event_delivered (KWin is the DRM master) -> page flips = new frames shown
and prints flips/s, decodes/s and the flip intervals in refresh periods:
1 = smooth, 2 = a frame shown twice (stutter), 3+ = longer hold; and the 1 % / 0.1 % low fps
(mean time on screen of the slowest 1 % / 0.1 % of frames, as fps), and per second the phase of the decoder
(ms from the previous flip to the end of a frame's decode) next to that second's repeats.
The refresh period is read from the vblank sequence numbers, so 60/120/164 Hz all work.
"""
import bisect, collections, os, re, sys, time

T = "/sys/kernel/tracing"
INST = f"{T}/instances/y700-mlflips"


def w(path, val):
    with open(path, "w") as f:
        f.write(val)


def iris_irq():
    for line in open("/proc/interrupts"):
        if "iris" in line or "vidc" in line:
            return int(line.split(":")[0])
    # iris shows up without a name on this kernel: the IRQ the v4l2 decoder's
    # device owns (msm iris = aa00000.video-codec)
    for d in os.listdir("/proc/irq"):
        if d.isdigit() and any("video" in x or "iris" in x for x in os.listdir(f"/proc/irq/{d}")):
            return int(d)
    return None


def main():
    secs = float(sys.argv[1])
    irq = int(os.environ.get("IRIS_IRQ", 0)) or iris_irq()
    if os.path.exists(INST):
        os.rmdir(INST)
    os.mkdir(INST)
    try:
        w(f"{INST}/buffer_size_kb", "8192")
        w(f"{INST}/trace_clock", "mono")
        w(f"{INST}/events/drm/drm_vblank_event_delivered/enable", "1")
        if irq:
            w(f"{INST}/events/irq/irq_handler_entry/filter", f"irq=={irq}")
            w(f"{INST}/events/irq/irq_handler_entry/enable", "1")
        w(f"{INST}/tracing_on", "1")
        time.sleep(secs)
        w(f"{INST}/tracing_on", "0")
        data = open(f"{INST}/trace").read()
    finally:
        try:
            w(f"{INST}/events/enable", "0")
            os.rmdir(INST)
        except OSError:
            pass
    flips, decs = [], []
    for line in data.splitlines():
        m = re.search(r"^\s*(\S+)-\d+\s.*?\s(\d+\.\d+):\s+(\w+):\s*(.*)$", line)
        if not m:
            continue
        comm, ts, ev, rest = m.group(1), float(m.group(2)), m.group(3), m.group(4)
        if ev == "drm_vblank_event_delivered":
            # KWin is the only DRM master, so every delivered flip event is KWin's;
            # the event carries no pid (runs in irq context), only crtc and seq
            s = re.search(r"seq=(\d+)", rest)
            c = re.search(r"crtc=(\d+)", rest)
            flips.append((ts, int(s.group(1)) if s else None, int(c.group(1)) if c else None))
        elif ev == "irq_handler_entry":
            decs.append(ts)
    crtcs = collections.Counter(f[2] for f in flips)
    if crtcs:  # keep the busiest crtc (the panel)
        main_crtc = crtcs.most_common(1)[0][0]
        flips = [f for f in flips if f[2] == main_crtc]
    out = [f"secs={secs:.0f} iris_irq={irq} crtcs={dict(crtcs)}"]
    if len(flips) < 2:
        out.append("no page flips traced")
    else:
        dur = flips[-1][0] - flips[0][0]
        seqs = [f[1] for f in flips if f[1] is not None]
        period = dur / max(1, seqs[-1] - seqs[0]) if len(seqs) > 1 else None
        hist = collections.Counter()
        for a, b in zip(flips, flips[1:]):
            n = (b[1] - a[1]) if a[1] is not None and b[1] is not None else round((b[0] - a[0]) / period)
            hist[min(n, 4)] += 1
        tot = sum(hist.values())
        hz = 1 / period if period else 0
        out.append(f"refresh {hz:.2f} Hz, flips {len(flips) / dur:.1f}/s, iris IRQs {len(decs) / dur:.1f}/s")
        out.append("flip interval (refreshes): " + "  ".join(
            f"{k if k < 4 else '4+'}: {v} ({100 * v / tot:.2f} %)" for k, v in sorted(hist.items())))
        # 1 % / 0.1 % low as benchmarks use it: the slowest 1 % of frames (time each new frame stayed on screen),
        # their mean frame time as fps; with a 120 Hz panel a frame stays 8.3 ms or a multiple of it
        ft = sorted(((b[1] - a[1]) * period if a[1] is not None and b[1] is not None else b[0] - a[0])
                    for a, b in zip(flips, flips[1:]) if b[0] > a[0])
        lows = []
        for share in (0.01, 0.001):
            worst = ft[-max(1, int(len(ft) * share)):]
            lows.append(f"{share * 100:g} % low {1 / (sum(worst) / len(worst)):.1f} fps")
        out.append(f"avg {len(ft) / sum(ft):.1f} fps, " + ", ".join(lows)
                   + f", worst frame {ft[-1] * 1000:.1f} ms")
        # one-second view: how many seconds had any repeat
        per = collections.Counter()
        for a, b in zip(flips, flips[1:]):
            if a[1] is not None and b[1] is not None and b[1] - a[1] >= 2:
                per[int(b[0] - flips[0][0])] += 1
        out.append(f"seconds with a repeated frame: {len(per)}/{int(dur)}; worst: "
                   + ", ".join(f"t+{k}s x{v}" for k, v in per.most_common(5)))
        # phase: where in the refresh period the decoder finishes a frame (last iris IRQ of a frame's burst,
        # ms after the previous flip). Host and panel run on different clocks, so this drifts; when it sits near
        # Moonlight's per-vblank decision point, small jitter flips frames between "in time" and "late" ->
        # bursts of repeat+drop. One line per second: median phase / repeats that second.
        if period and decs:
            ends = [a for a, b in zip(decs, decs[1:] + [1e18]) if b - a > 0.002]
            fts = [f[0] for f in flips]
            ph = collections.defaultdict(list)
            for e in ends:
                i = bisect.bisect_right(fts, e) - 1
                if 0 <= i:
                    ph[int(e - flips[0][0])].append(((e - fts[i]) % period) * 1000)
            cells = []
            for s in range(int(dur)):
                v = sorted(ph.get(s, []))
                cells.append(f"{s}:{v[len(v) // 2]:.1f}/{per.get(s, 0)}" if v else f"{s}:-/{per.get(s, 0)}")
            out.append("phase ms/repeats per second: " + " ".join(cells))
    text = "\n".join(out)
    print(text)
    if len(sys.argv) > 2:
        open(sys.argv[2], "w").write(text + "\n")


if __name__ == "__main__":
    main()
