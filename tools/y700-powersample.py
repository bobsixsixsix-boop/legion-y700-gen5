#!/usr/bin/env python3
"""y700-powersample SECONDS LABEL: one line of numbers for one state of a power bench (y700-powerbench.sh).
Light on purpose (it runs inside the measurement): once a second it reads battery V/I, the panel's live
refresh rate, the GPU/DDR/LLCC devfreq frequency; at start and end it reads cpuidle residency, /proc/stat,
interrupts and the qcom_stats subsystem sleep counters. Battery only: with the charger in, the battery
current is not the device's power (use y700-powerwhy then). Read-only; run as root. 2026-10-15.
2026-10-29: with Y700_POWERSAMPLE_RAW=FILE it also appends one tab-separated line to FILE: label, mean power in mW
(two decimals; the printed line rounds to 10 mW), samples, distinct currents, battery status, then every per-second
power in mW comma-separated (linux/camera/lens-power-ab.sh averages it over many pairs). Written once at the end,
nothing extra inside the sampling loop. Without the variable the output is unchanged."""
import glob, os, re, sys, time
from collections import Counter

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 60
label = sys.argv[2] if len(sys.argv) > 2 else "-"
BAT = "/sys/class/power_supply/qcom-battmgr-bat"
DEVF = {n: f"/sys/class/devfreq/{p}/cur_freq" for n, p in (("gpu", "3d00000.gpu"), ("ddr", "ddr"), ("llcc", "llcc"))}
QS = ("adsp", "adsp_island", "cdsp", "soccp", "cxsd", "aosd")


def rd(p, d=None):
    try:
        return open(p).read().strip()
    except OSError:
        return d


def idle():
    """per cpuidle state name: total time (us) over all CPUs"""
    t = Counter()
    for s in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*"):
        t[rd(s + "/name", "?")] += int(rd(s + "/time", "0"))
    return t


def stat():
    f = open("/proc/stat").readline().split()[1:]
    v = [int(x) for x in f]
    return sum(v), v[3] + v[4]          # total jiffies, idle + iowait


def irq_total():
    n = 0
    for ln in open("/proc/interrupts").read().splitlines()[1:]:
        n += sum(int(x) for x in ln.split()[1:] if x.isdigit())
    return n


def qstats():
    out = {}
    for k in QS:
        m = re.search(r"Accumulated Duration:\s*(\d+)", rd(f"/sys/kernel/debug/qcom_stats/{k}", "") or "")
        c = re.search(r"Count:\s*(\d+)", rd(f"/sys/kernel/debug/qcom_stats/{k}", "") or "")
        if m and c:
            out[k] = (int(c.group(1)), int(m.group(1)))
    return out


ncpu = len(glob.glob("/sys/devices/system/cpu/cpu[0-9]*"))
i0, s0, q0, n0, t0 = idle(), stat(), qstats(), irq_total(), time.monotonic()
pw, hz, df, bl, ivals = [], Counter(), {k: [] for k in DEVF}, [], set()
while time.monotonic() - t0 < secs:
    v, i = int(rd(BAT + "/voltage_now", "0")), int(rd(BAT + "/current_now", "0"))
    ivals.add(i)
    pw.append(-(v / 1e6) * (i / 1e6))            # + = drawn from the battery
    m = re.search(r" hz (\d+)", rd("/sys/module/msm/parameters/idle_refresh_state", "") or "")
    if m:
        hz[int(m.group(1))] += 1
    for k, p in DEVF.items():
        f = rd(p)
        if f and f.isdigit():
            df[k].append(int(f) / 1e6)
    b = glob.glob("/sys/class/backlight/*/brightness")
    if b:
        bl.append(int(rd(b[0], "0")))
    time.sleep(1)
dt = time.monotonic() - t0
i1, s1, q1, n1 = idle(), stat(), qstats(), irq_total()

st = rd(BAT + "/status", "?")
avg = sum(pw) / len(pw)
busy = 100 * (1 - (s1[1] - s0[1]) / max(1, s1[0] - s0[0]))
res = " ".join(f"{k}={100 * (i1[k] - i0.get(k, 0)) / (dt * 1e6 * ncpu):.0f}%" for k in sorted(i1))
hzs = " ".join(f"{h}:{100 * c / sum(hz.values()):.0f}%" for h, c in sorted(hz.items(), reverse=True)) if hz else "-"
dfs = " ".join(f"{k}={sum(v) / len(v):.0f}MHz" for k, v in df.items() if v)
# qcom_stats durations are raw 19.2 MHz sleep-counter ticks here (Last Entered At / 19.2e6 = uptime)
qs = " ".join(f"{k}={100 * (q1[k][1] - q0[k][1]) / (dt * 19.2e6):.0f}%/{q1[k][0] - q0[k][0]}x" for k in q1 if k in q0)
print(f"{label:<28} {avg:5.2f} W (min {min(pw):.2f} max {max(pw):.2f}, {len(ivals)} distinct I in {len(pw)} s, {st}) "
      f"| backlight {sum(bl) // max(1, len(bl))} | panel {hzs} | cpu busy {busy:.1f}% idle[{res}] "
      f"| irq {(n1 - n0) / dt:.0f}/s | {dfs} | sleep {qs}", flush=True)
raw = os.environ.get("Y700_POWERSAMPLE_RAW")
if raw:
    with open(raw, "a") as f:
        f.write("\t".join([label, f"{avg * 1000:.2f}", str(len(pw)), str(len(ivals)), st,
                           ",".join(f"{p * 1000:.1f}" for p in pw)]) + "\n")
