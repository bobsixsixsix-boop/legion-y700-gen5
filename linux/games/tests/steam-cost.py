#!/usr/bin/env python3
"""steam-cost.py TAG - what Steam's UI costs while idle and while being scrolled, for the GPU vs CPU drawing A/B.
Run as root with Steam on a store page (steam-tri.sh leaves it at the reviews) and y700-vtouch running.
Phase idle: 15 s without input. Phase scroll: 10 rounds of drag down + drag up on the page (20 s), between y 260 and 520:
any touch on Steam's page brings up the on-screen keyboard over the lower 40 % of the screen and Steam's window
shrinks to the space above it; a drag that starts on the keyboard or on Steam's bottom bar does not scroll the page.
Per phase: CPU cores used per process group (utime+stime from /proc/PID/stat), GPU busy per group (the msm
DRM fdinfo drm-engine-gpu counter, one value per DRM client; no debugfs), whole-system busy cores (/proc/stat)
and the battery's average discharge power."""
import glob, os, sys, time

TAG = sys.argv[1] if len(sys.argv) > 1 else "run"
HZ = os.sysconf("SC_CLK_TCK")
FIFO = "/run/y700-vtouch.fifo"
GROUPS = ("steamwebhelper", "steam", "Xwayland", "kwin_wayland")


def group(comm):
    return comm if comm in GROUPS else "other"


def snap():
    cpu, gpu, seen = {}, {}, set()
    for d in glob.glob("/proc/[0-9]*"):
        pid = int(d[6:])
        try:
            st = open(d + "/stat").read()
        except OSError:
            continue
        comm = st[st.index("(") + 1:st.rindex(")")]
        f = st[st.rindex(")") + 2:].split()
        cpu[pid] = (group(comm), int(f[11]) + int(f[12]))
        for fi in glob.glob(d + "/fdinfo/*"):
            try:
                t = open(fi).read()
            except OSError:
                continue
            if "drm-engine-gpu:" not in t:
                continue
            kv = dict(l.split(":", 1) for l in t.splitlines() if ":" in l)
            cid = kv.get("drm-client-id", "").strip()
            if cid in seen:
                continue
            seen.add(cid)
            gpu[cid] = (group(comm), int(kv["drm-engine-gpu"].split()[0]))
    s = open("/proc/stat").readline().split()[1:]
    busy = sum(int(x) for i, x in enumerate(s) if i not in (3, 4))  # all but idle, iowait
    return cpu, gpu, busy, time.monotonic()


def battery():
    for b in glob.glob("/sys/class/power_supply/*"):
        try:
            if open(b + "/type").read().strip() != "Battery":
                continue
            if os.path.exists(b + "/power_now"):
                return abs(int(open(b + "/power_now").read())) / 1e6
            return abs(int(open(b + "/current_now").read()) * int(open(b + "/voltage_now").read())) / 1e12
        except (OSError, ValueError):
            continue
    return float("nan")


def phase(name, secs, cmds=None):
    a = snap()
    if cmds:
        with open(FIFO, "w") as f:
            f.write("".join(c + "\n" for c in cmds))
    watts, end = [], time.monotonic() + secs
    while time.monotonic() < end:
        watts.append(battery())
        time.sleep(0.5)
    b = snap()
    dt = b[3] - a[3]
    cores = {g: 0.0 for g in GROUPS + ("other",)}
    for pid, (g, t) in b[0].items():
        cores[g] += (t - a[0].get(pid, (g, 0))[1]) / HZ / dt
    gbusy = {g: 0.0 for g in GROUPS + ("other",)}
    for cid, (g, ns) in b[1].items():
        gbusy[g] += (ns - a[1].get(cid, (g, 0))[1]) / 1e9 / dt * 100
    total = (b[2] - a[2]) / HZ / dt
    w = sum(watts) / len(watts)
    print(f"{TAG} {name} {dt:.1f}s: system {total:.2f} cores | CPU cores "
          + " ".join(f"{g}={v:.2f}" for g, v in cores.items())
          + f" | GPU busy% total={sum(gbusy.values()):.1f} "
          + " ".join(f"{g}={v:.1f}" for g, v in gbusy.items() if v >= 0.05)
          + f" | battery {w:.2f} W")


phase("idle", 15)
phase("scroll", 20, ["drag 1000 520 1000 260 600 20", "sleep 400", "drag 1000 260 1000 520 600 20", "sleep 400"] * 10)
