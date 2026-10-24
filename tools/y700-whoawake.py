#!/usr/bin/env python3
"""y700-whoawake [SECONDS] [--off]: who keeps the CPUs busy while the tablet should be idle?
Read-only deltas over the window: interrupts per line (IPIs included), softirqs, forks and context
switches, CPU time per cgroup (unit) - this also counts short-lived children a per-process view misses -,
per process, wakeups per thread (context switches), and cpuidle entries per CPU.
--off: turn the display off (DPMS) for the window and back on afterwards (the owner wants the
screen-off power down without suspending, 2026-10-15). Run as root on the tablet."""
import glob, os, re, subprocess, sys, time
from collections import Counter

secs = 30
off = "--off" in sys.argv
for a in sys.argv[1:]:
    if a.isdigit():
        secs = int(a)
U = ["sudo", "-u", "user", "env", "XDG_RUNTIME_DIR=/run/user/1000", "WAYLAND_DISPLAY=wayland-0",
     "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"]


def rd(p, d=""):
    try:
        return open(p).read()
    except OSError:
        return d


def irqs():
    d = {}
    for ln in rd("/proc/interrupts").splitlines()[1:]:
        f = ln.split()
        if not f or not f[0].endswith(":"):
            continue
        n = sum(int(x) for x in f[1:] if x.isdigit())
        d[f[0][:-1] + " " + " ".join(x for x in f[1:] if not x.isdigit())[-48:]] = n
    return d


def softirqs():
    d = {}
    for ln in rd("/proc/softirqs").splitlines()[1:]:
        f = ln.split()
        d[f[0]] = sum(int(x) for x in f[1:])
    return d


def stat():
    d = {}
    for ln in rd("/proc/stat").splitlines():
        f = ln.split()
        if f[0] in ("ctxt", "processes"):
            d[f[0]] = int(f[1])
    return d


def cgroups():
    d = {}
    for p in glob.glob("/sys/fs/cgroup/**/cpu.stat", recursive=True):
        m = re.search(r"usage_usec (\d+)", rd(p))
        if m:
            d[p[len("/sys/fs/cgroup/"):-len("/cpu.stat")] or "/"] = int(m.group(1))
    return d


def procs():
    d = {}
    for p in glob.glob("/proc/[0-9]*"):
        try:
            st = open(p + "/stat").read()
            r = st.rfind(")")
            f = st[r + 2:].split()
            d[int(p[6:])] = (st[st.find("(") + 1:r], int(f[11]) + int(f[12]))
        except Exception:
            pass
    return d


def threads():
    d = {}
    for t in glob.glob("/proc/[0-9]*/task/[0-9]*/status"):
        try:
            s = open(t).read()
        except OSError:
            continue
        v = re.search(r"voluntary_ctxt_switches:\s*(\d+)", s)
        nv = re.search(r"nonvoluntary_ctxt_switches:\s*(\d+)", s)
        nm = re.search(r"Name:\s*(.*)", s)
        if v and nv and nm:
            parts = t.split("/")
            d[(int(parts[2]), int(parts[4]))] = (nm.group(1), int(v.group(1)) + int(nv.group(1)))
    return d


def idle_entries():
    d = Counter()
    for s in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*/usage"):
        d[s.split("/")[5]] += int(rd(s, "0"))
    return d


def comm(pid):
    c = rd(f"/proc/{pid}/cmdline").replace("\0", " ").strip()
    return (c or rd(f"/proc/{pid}/comm").strip())[:72]


def dpms(on):
    subprocess.run(U + ["kscreen-doctor", "--dpms", "on" if on else "off"], capture_output=True)


if off:
    dpms(False)
    time.sleep(8)        # autobright releases the sensor, the HUD sampler exits, KWin stops compositing
def panel():           # DSI DPMS state as the kernel sees it ("On" / "Off")
    return next((rd(p).strip() for p in sorted(glob.glob("/sys/class/drm/card*-DSI-1/dpms"))), "?")


try:
    i0, s0, st0, c0, p0, t0, e0, w0 = irqs(), softirqs(), stat(), cgroups(), procs(), threads(), idle_entries(), time.monotonic()
    d0 = panel()
    time.sleep(secs)
    i1, s1, st1, c1, p1, t1, e1 = irqs(), softirqs(), stat(), cgroups(), procs(), threads(), idle_entries()
    dt, d1 = time.monotonic() - w0, panel()
finally:
    if off:
        dpms(True)

# 2026-10-18: this used to say "screen on" whenever --off was not given, even with the panel already off
screen = {("Off", "Off"): "screen OFF", ("On", "On"): "screen on"}.get((d0, d1), f"screen {d0} -> {d1}")
print(f"== {dt:.0f} s, {screen}: forks {(st1['processes'] - st0['processes']) / dt:.0f}/s, context switches {(st1['ctxt'] - st0['ctxt']) / dt:.0f}/s, "
      f"idle entries {sum(e1.values()) - sum(e0.values()):.0f} total ({' '.join(f'{c}:{(e1[c] - e0[c]) / dt:.0f}' for c in sorted(e1))} /s)")
print("== interrupts/s, top 12")
for r, k in sorted(((i1.get(k, 0) - v) / dt, k) for k, v in i0.items())[::-1][:12]:
    if r >= 1:
        print(f"{r:8.0f}  {k}")
print("== softirqs/s")
print("   " + "  ".join(f"{k}:{(s1[k] - s0.get(k, 0)) / dt:.0f}" for k in s1 if (s1[k] - s0.get(k, 0)) / dt >= 1))
print("== CPU ms per second by cgroup (units; includes exited children), top 14")
for d, k in sorted(((c1.get(k, 0) - v) / dt / 1000, k) for k, v in c0.items())[::-1][:14]:
    if d >= 0.2 and not k.endswith(".slice") and k not in ("/", "user.slice/user-1000.slice/user@1000.service", "user.slice/user-1000.slice/user@1000.service/app.slice", "user.slice/user-1000.slice/user@1000.service/session.slice", "user.slice/user-1000.slice/user@1000.service/background.slice"):
        print(f"{d:7.1f}  {k.replace('user.slice/user-1000.slice/user@1000.service/', '~/')}")
CLK = os.sysconf("SC_CLK_TCK")
print("== CPU ms per second by process (alive the whole window), top 12")
rows = []
for pid, (c, ticks) in p1.items():
    if pid in p0 and p0[pid][0] == c:
        d = (ticks - p0[pid][1]) / CLK / dt * 1000
        if d >= 0.5:
            rows.append((d, pid))
for d, pid in sorted(rows, reverse=True)[:12]:
    print(f"{d:7.1f}  {pid:>6}  {comm(pid)}")
print("== wakeups/s by thread (context switches), top 16")
rows = []
for key, (name, n) in t1.items():
    if key in t0 and t0[key][0] == name:
        r = (n - t0[key][1]) / dt
        if r >= 1:
            rows.append((r, key[0], key[1], name))
for r, pid, tid, name in sorted(rows, reverse=True)[:16]:
    print(f"{r:7.0f}  {pid:>6}/{tid:<6} {name:<16} {comm(pid)[:50]}")
