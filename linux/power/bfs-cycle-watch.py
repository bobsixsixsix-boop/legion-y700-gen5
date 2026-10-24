#!/usr/bin/env python3
"""Watch Chrome and the Claude desktop app through screen on -> off -> on with Chromium's frame-callback-driven
begin-frame source (linux/power/chromium-bfs.py, README "Chromium 新帧源开关").

Every INT s (and right after the screen changes state) one line: per app the number of processes, whether its GPU
process carries --enable-features=...WaylandExternalBeginFrameSource, the GPU-process compositor thread's
(VizCompositorTh) wakeups/s and the whole app's CPU (all its processes, % of one core); then the flight recorder's
latest row: system-domain entries/s and battery power. At the end, medians per screen state.

What to look for: screen off -> viz ~0 with the switch (60-120/s without); screen on -> both windows draw and
respond at once - the owner looks, this log can only show the compositor waking up again when something animates.
Run as root, detached, so the ssh session is not part of what is measured:
    systemd-run --unit=y700-bfscycle --collect /root/y700-bfs/bfs-cycle-watch.py
    (MIN=20 INT=10 by default: systemd-run -E MIN=30 ...; stop early: systemctl stop y700-bfscycle)
Output: /root/bfscycle-MMDD-HHMM.txt (line-buffered, readable while it runs). Pure Python, no subprocesses: a fork
per process every few seconds would itself wake the CPU it is measuring."""
import glob, os, signal, sys, time

MIN = float(os.environ.get("MIN", 20))
INT = float(os.environ.get("INT", 10))
FEATURE = "WaylandExternalBeginFrameSource"
APPS = {"chrome": "/opt/google/chrome/chrome", "claude": "/usr/lib/claude-desktop/claude-desktop"}
REC = "/var/log/y700-flightrec/current.log"
out = open(time.strftime("/root/bfscycle-%m%d-%H%M.txt"), "w", buffering=1)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))   # systemctl stop still prints the summary


def dpms():
    for c in sorted(glob.glob("/sys/class/drm/card*-*")):
        try:
            if open(c + "/status").read().strip() == "connected":
                return open(c + "/dpms").read().strip()
        except OSError:
            pass
    return "?"


def switches(task):
    return sum(int(l.split()[1]) for l in open(task + "/status") if "_ctxt_switches" in l)


def sample():
    s = {a: {"n": 0, "cpu": 0, "flag": None, "viz": None} for a in APPS}
    for p in glob.glob("/proc/[0-9]*"):
        try:
            exe = os.readlink(p + "/exe")
        except OSError:
            continue
        for a, path in APPS.items():
            if exe != path:
                continue
            d = s[a]
            try:
                st = open(p + "/stat").read().rsplit(")", 1)[1].split()
                cmd = open(p + "/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace")
                d["n"] += 1
                d["cpu"] += int(st[11]) + int(st[12])             # utime + stime (stat fields 14, 15), clock ticks
                if "--type=gpu-process" in cmd:                    # Chromium rewrites its title: one space-joined string
                    d["flag"] = FEATURE in cmd
                    for t in glob.glob(p + "/task/*"):
                        if open(t + "/comm").read().strip() == "VizCompositorTh":
                            d["viz"] = (t, switches(t))
            except OSError:                                        # exited between readlink and here
                pass
            break
    return s


def recorder():
    """(at, system-domain entries/s, battery field) from the flight recorder's last two rows."""
    try:
        with open(REC, "rb") as f:
            f.seek(max(0, os.path.getsize(REC) - 4096))
            rows = [l for l in f.read().decode(errors="replace").splitlines() if l.startswith("t=")][-2:]
        kv = [dict(x.split("=", 1) for x in r.split(" ") if "=" in x) for r in rows]
        last = kv[-1]
        sys_n = int(next(x for x in last["pd"].split(",") if x.startswith("sys:"))[4:].split("/")[0])
        dt = float(last["t"]) - float(kv[0]["t"]) if len(kv) == 2 else 10.0
        return last.get("at", "?"), sys_n / (dt or 10.0), last.get("bat", "?")
    except (OSError, ValueError, KeyError, StopIteration):
        return "?", None, "?"


def pkg_version(name):
    try:
        for block in open("/var/lib/dpkg/status", encoding="utf-8", errors="replace").read().split("\n\n"):
            if block.startswith(f"Package: {name}\n"):
                return next(l[9:] for l in block.splitlines() if l.startswith("Version: "))
    except (OSError, StopIteration):
        pass
    return "?"


tick = os.sysconf("SC_CLK_TCK")
electron = open("/usr/lib/claude-desktop/version").read().strip() if os.path.exists("/usr/lib/claude-desktop/version") else "?"
out.write(f"bfscycle {time.strftime('%F %T')}  MIN={MIN:g} INT={INT:g}  chrome {pkg_version('google-chrome-stable')}  "
          f"claude {pkg_version('claude-desktop')} (electron {electron})\n"
          "viz = GPU-process VizCompositorTh wakeups/s, cpu = all of the app's processes (% of one core), "
          "bfs = GPU process has the switch, sys = system-domain entries/s (flight recorder)\n")
prev, t_prev, screen = sample(), time.monotonic(), dpms()
out.write(f"\n== {time.strftime('%T')} screen {screen}\n")
segs = []                       # (screen, app, viz/s or None, cpu%)
end, next_full = time.monotonic() + MIN * 60, time.monotonic() + INT
try:
    while time.monotonic() < end:
        time.sleep(2)
        now_screen = dpms()
        changed = now_screen != screen
        if not changed and time.monotonic() < next_full:
            continue
        cur, t = sample(), time.monotonic()
        dt = t - t_prev
        cols = []
        for a in APPS:
            c, p = cur[a], prev[a]
            if not c["n"]:
                cols.append(f"{a} -")
                continue
            viz = (c["viz"][1] - p["viz"][1]) / dt if c["viz"] and p["viz"] and c["viz"][0] == p["viz"][0] else None
            cpu = (c["cpu"] - p["cpu"]) * 100 / tick / dt if p["n"] else None
            if cpu is not None and cpu < 0:                       # a process exited: its ticks left the sum
                cpu = None
            segs.append((screen, a, viz, cpu))
            cols.append(f"{a} {c['n']:2d}p bfs={'?YN'[0 if c['flag'] is None else 1 if c['flag'] else 2]} "
                        f"viz {'-' if viz is None else f'{viz:5.1f}'} cpu {'-' if cpu is None else f'{cpu:4.1f}%'}")
        at, sys_rate, bat = recorder()
        out.write(f"{time.strftime('%T')} {screen:3s} | " + " | ".join(cols)
                  + f" | rec {at} sys {'-' if sys_rate is None else f'{sys_rate:4.1f}'} bat {bat}\n")
        prev, t_prev, next_full = cur, t, t + INT
        if changed:             # the line above covers the interval up to the change; later ones the new state
            screen = now_screen
            out.write(f"\n== {time.strftime('%T')} screen {screen}\n")
finally:
    # medians, not means: one sample over an app start or a page load would swamp a mean of near-zero idle samples
    med = lambda xs: sorted(xs)[len(xs) // 2] if xs else float("nan")
    out.write(f"\ndone {time.strftime('%T')}  medians per screen state:\n")
    for scr in dict.fromkeys(s for s, *_ in segs):
        for a in APPS:
            rows = [(v, c) for s, aa, v, c in segs if s == scr and aa == a]
            if rows:
                out.write(f"  {scr:3s} {a:6s} viz {med([v for v, _ in rows if v is not None]):5.1f}/s  "
                          f"cpu {med([c for _, c in rows if c is not None]):4.1f}%  ({len(rows)} samples)\n")
