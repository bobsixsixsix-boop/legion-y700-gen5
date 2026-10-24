#!/usr/bin/env python3
"""Frames, CPU and GPU clocks while something animates (root, tablet). For the touch-boost question:
do the card gestures drop frames, and are the clocks the reason?

usage: ts-frames.py start          # begin tracing (private tracefs instance, no debugfs)
       ts-frames.py mark NAME      # a named point in the trace (e.g. "hold", "scroll"), from the driver
       ts-frames.py stop [LABEL]   # stop, analyse, print one block
Traces drm_vblank_event_delivered (KWin is the only DRM master: one event per new frame on the panel;
the panel is in command mode, so a frame is only sent when KWin has a new one),
power/cpu_frequency, drm_msm_gpu/msm_gpu_freq_change and sched_switch of KWin's main thread (KWin
renders there). Frames only flip while something changes, so the flips are grouped into bursts
(a gap over 100 ms ends one) and only intervals inside a burst count: 1 refresh = smooth, 2+ = the old
frame shown again. Per gesture (between two marks): frames lost in steady motion, how long the big
cores (cpu6) and the GPU took to clock up from the gesture's start, and how busy KWin's main thread was.
"""
import collections, os, re, sys, time

T = "/sys/kernel/tracing"
INST = f"{T}/instances/y700-tsframes"
# GPU clock: devfreq/devfreq_frequency (simple_ondemand, samples every 50 ms); msm_gpu_freq_change never fired here.
# NOTE 10-21: devfreq_frequency did not fire either, although trans_stat counts transitions: the "gpu" column
# only shows the clock read at the end. KWin's GPU job times (msm_gpu_submit_retired) are what to read instead.
# KWin's GPU work: drm_msm_gpu/msm_gpu_submit + _retired (GPU busy time and submit-to-done wall time per job)
EVENTS = ["drm/drm_vblank_event_delivered", "power/cpu_frequency", "devfreq/devfreq_frequency",
          "sched/sched_switch", "drm_msm_gpu/msm_gpu_submit", "drm_msm_gpu/msm_gpu_submit_retired"]


def w(path, val):
    with open(path, "w") as f:
        f.write(val)


def kwin_pid():
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            if open(f"/proc/{p}/comm").read().strip() != "kwin_wayland":
                continue
            if b"--virtual" in open(f"/proc/{p}/cmdline", "rb").read().split(b"\0"):
                continue
            return int(p)
        except OSError:
            pass
    return None


def start():
    if os.path.exists(INST):
        os.rmdir(INST)
    os.mkdir(INST)
    w(f"{INST}/buffer_size_kb", "16384")
    w(f"{INST}/trace_clock", "mono")
    k = kwin_pid()
    w(f"{INST}/events/sched/sched_switch/filter", f"prev_pid=={k} || next_pid=={k}")
    w(f"{INST}/events/power/cpu_frequency/filter", "cpu_id==0 || cpu_id==6")
    w(f"{INST}/events/drm_msm_gpu/msm_gpu_submit/filter", f"pid=={k}")
    w(f"{INST}/events/drm_msm_gpu/msm_gpu_submit_retired/filter", f"pid=={k}")
    w(f"{INST}/events/devfreq/devfreq_frequency/filter", 'dev_name ~ "3d00000*"')
    for e in EVENTS:
        w(f"{INST}/events/{e}/enable", "1")
    w(f"{INST}/tracing_on", "1")
    print(f"tracing, kwin {k}")


def mark(name):
    w(f"{INST}/trace_marker", f"tsmark {name}")


def stop(label):
    w(f"{INST}/tracing_on", "0")
    data = open(f"{INST}/trace").read()
    w(f"{INST}/events/enable", "0")
    os.rmdir(INST)
    k = kwin_pid()
    flips, freq, gpu, marks, sw = [], {0: [], 6: []}, [], [], []
    subm, jobs = {}, []   # jobs: (submit ts, GPU busy ms, submit-to-retired ms)
    for line in data.splitlines():
        m = re.search(r"\s(\d+\.\d+):\s+(\w+):\s*(.*)$", line)
        if not m:
            continue
        ts, ev, rest = float(m.group(1)), m.group(2), m.group(3)
        if ev == "drm_vblank_event_delivered":
            s, c = re.search(r"seq=(\d+)", rest), re.search(r"crtc=(\d+)", rest)
            flips.append((ts, int(s.group(1)), int(c.group(1)) if c else 0))
        elif ev == "cpu_frequency":
            s, c = re.search(r"state=(\d+)", rest), re.search(r"cpu_id=(\d+)", rest)
            freq[int(c.group(1))].append((ts, int(s.group(1)) // 1000))
        elif ev == "devfreq_frequency":
            s = re.search(r" freq=(\d+)", rest)
            if s:
                gpu.append((ts, int(s.group(1)) // 1000000))
        elif ev == "sched_switch":
            pp, np_ = re.search(r"prev_pid=(\d+)", rest), re.search(r"next_pid=(\d+)", rest)
            if np_ and int(np_.group(1)) == k:
                sw.append((ts, 1))
            elif pp and int(pp.group(1)) == k:
                sw.append((ts, 0))
        elif ev == "msm_gpu_submit":
            subm[re.search(r"id=(\d+)", rest).group(1)] = ts
        elif ev == "msm_gpu_submit_retired":
            i, el = re.search(r"id=(\d+)", rest).group(1), re.search(r"elapsed=(\d+)", rest)
            if i in subm and el:
                t = subm.pop(i)
                jobs.append((t, int(el.group(1)) / 1e6, (ts - t) * 1000))
        elif "tsmark" in rest:
            marks.append((ts, rest.split("tsmark", 1)[1].strip()))
    crtcs = collections.Counter(f[2] for f in flips)
    if crtcs:
        main = crtcs.most_common(1)[0][0]
        flips = [f for f in flips if f[2] == main]
    print(f"== {label}: {len(flips)} flips, crtcs {dict(crtcs)}, marks {[m[1] for m in marks]}")
    if len(flips) < 3:
        return
    # the DSI panel runs in command mode: the vblank counter only counts frames actually sent, so the
    # sequence numbers say nothing about repeats. Use the time between flips in refresh periods instead.
    period = 1 / float(os.environ.get("REFRESH", "120"))

    def at(series, t, before=None):   # value of a step series at time t
        v = before
        for ts, x in series:
            if ts > t:
                break
            v = x
        return v

    def reach(series, t0, t1, thr, first):   # ms from t0 until the series is >= thr (None: not in [t0, t1])
        if (at(series, t0, first) or 0) >= thr:
            return 0
        for ts, x in series:
            if t0 < ts <= t1 and x >= thr:
                return round((ts - t0) * 1000)
        return None

    def busy(t0, t1):   # KWin main thread on-CPU share in [t0, t1]
        b, on = 0.0, (t0 if at(sw, t0, 0) == 1 else None)
        for ts, s in sw:
            if ts <= t0 or ts > t1:
                continue
            if s == 1 and on is None:
                on = ts
            elif s == 0 and on is not None:
                b, on = b + ts - on, None
        if on is not None:
            b += t1 - on
        return 100 * b / max(t1 - t0, 1e-3)

    f6 = freq[6][0][1] if freq[6] else None
    f0 = freq[0][0][1] if freq[0] else None
    g0 = gpu[0][1] if gpu else int(open("/sys/class/devfreq/3d00000.gpu/cur_freq").read()) // 1000000
    # one segment per mark (the driver marks each gesture); only gaps under 100 ms count, longer ones are
    # the picture standing still. A "miss": a 2-refresh gap with a 1-refresh gap on both sides, i.e. one
    # frame lost in steady motion; longer gaps inside motion are mostly the picture not changing (finger
    # resting, cards settled), a command-mode panel gets no frame then.
    segs = marks + [(flips[-1][0] + 1, "end")]
    if not marks or marks[0][0] > flips[0][0]:
        segs = [(flips[0][0], "-")] + segs
    print(f"panel {1 / period:.0f} Hz (REFRESH); per gesture: frames / misses / repeats (2+ refreshes) / worst gap ms / "
          f"cpu6 MHz at start, ms to 3 GHz / cpu0 MHz / gpu MHz at start, ms to 600 / kwin main thread busy %")
    tot, by, allj = collections.Counter(), collections.defaultdict(collections.Counter), []

    def pct(v, q):
        v = sorted(v)
        return v[min(len(v) - 1, int(len(v) * q))] if v else 0
    for (t0, name), (t1, _) in zip(segs, segs[1:]):
        fs = [f for f in flips if t0 <= f[0] < t1]
        gs = [round((b[0] - a[0]) / period) for a, b in zip(fs, fs[1:]) if b[0] - a[0] < 0.1]
        if len(fs) < 4:
            continue
        miss = sum(1 for i in range(1, len(gs) - 1) if gs[i] == 2 and gs[i - 1] == 1 and gs[i + 1] == 1)
        rep = sum(1 for g in gs if g >= 2)
        worst = max(gs) * period * 1000 if gs else 0
        kind = name.rstrip("0123456789")
        js = [j for j in jobs if t0 <= j[0] < t1]
        by[kind].update(frames=len(fs), miss=miss, rep=rep, n=len(gs))
        if kind != "x":
            allj.extend(js)
        tot.update(frames=len(fs), miss=miss, rep=rep, n=len(gs))
        print(f"  t+{t0 - flips[0][0]:6.2f}s {name:8} {len(fs):4} fr  miss {miss:3}  rep {rep:3}  worst {worst:5.1f}  "
              f"cpu6 {at(freq[6], t0, f6)}/{reach(freq[6], t0, t1, 3000, f6)}  cpu0 {at(freq[0], t0, f0)}  "
              f"gpu {at(gpu, t0, g0)}/{reach(gpu, t0, t1, 600, g0)}  kwin {busy(t0, t1):3.0f}%  "
              f"gpu job {pct([j[1] for j in js], .5):.2f}/{pct([j[1] for j in js], .95):.2f} ms "
              f"done {pct([j[2] for j in js], .5):.2f}/{pct([j[2] for j in js], .95):.2f} ms")
    for kind, c in sorted(by.items()):
        print(f"  {kind:8} {c['frames']:5} fr  misses {c['miss']:3} ({100 * c['miss'] / max(c['n'], 1):.2f} %)  "
              f"repeats {c['rep']:3} ({100 * c['rep'] / max(c['n'], 1):.2f} %)")
    if allj:
        print(f"  KWin GPU jobs in gestures: {len(allj)}, GPU busy median {pct([j[1] for j in allj], .5):.2f} / p95 "
              f"{pct([j[1] for j in allj], .95):.2f} ms, submit to done median {pct([j[2] for j in allj], .5):.2f} / "
              f"p95 {pct([j[2] for j in allj], .95):.2f} ms")
    if tot["n"]:
        print(f"TOTAL {label}: {tot['n']} intervals, misses in motion {tot['miss']} ({100 * tot['miss'] / tot['n']:.2f} %), "
              f"repeats {tot['rep']} ({100 * tot['rep'] / tot['n']:.2f} %)")

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "start":
        start()
    elif cmd == "mark":
        mark(sys.argv[2])
    elif cmd == "stop":
        stop(sys.argv[2] if len(sys.argv) > 2 else "run")
