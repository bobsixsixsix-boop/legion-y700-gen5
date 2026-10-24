#!/usr/bin/env python3
"""y700-powerwhy SECONDS: where does the idle power go? Samples, without touching anything:
  - whole-device power (battery current x voltage, plus USB input when charging - same formula as the HUD)
  - CPU time per process (top 15), per-cluster frequency, temperatures
  - GPU: devfreq frequency + busy time per DRM client (fdinfo drm-engine-gpu), per process
  - panel refresh (msm idle_refresh_state), backlight
  - interrupts that fired most (top 10)
Read-only; run as root on the tablet. 2026-10-15: owner sees 7-9 W doing nothing."""
import glob, os, re, sys, time
from collections import defaultdict

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 30
CLK = os.sysconf("SC_CLK_TCK")

def rd(p, d=None):
    try:
        return open(p).read().strip()
    except OSError:
        return d

def power():
    b = "/sys/class/power_supply/qcom-battmgr-bat"; u = "/sys/class/power_supply/qcom-battmgr-usb"
    bi, bv = int(rd(b + "/current_now", "0")), int(rd(b + "/voltage_now", "0"))
    bp = bi / 1e6 * bv / 1e6                    # W, signed like the current (+ = charging)
    on = rd(u + "/online", "0") == "1"
    if on:
        up = int(rd(u + "/current_now", "0")) / 1e6 * int(rd(u + "/voltage_now", "0")) / 1e6
        return up - bp, bp, on
    return -bp, bp, on

def procs():
    out = {}
    for p in glob.glob("/proc/[0-9]*"):
        try:
            st = open(p + "/stat").read()
            r = st.rfind(")")
            f = st[r + 2:].split()
            comm = st[st.find("(") + 1:r]
            out[int(p[6:])] = (comm, int(f[11]) + int(f[12]))
        except Exception:
            pass
    return out

def gpu_clients():
    """pid -> gpu busy ns, summed over its DRM fds (fdinfo drm-engine-gpu), deduped by drm-client-id"""
    per_pid, seen = defaultdict(int), set()
    for fd in glob.glob("/proc/[0-9]*/fdinfo/*"):
        try:
            t = open(fd).read()
        except Exception:
            continue
        if "drm-driver:\tmsm" not in t:
            continue
        cid = re.search(r"drm-client-id:\s*(\d+)", t)
        eng = re.search(r"drm-engine-gpu:\s*(\d+)", t)
        if not cid or not eng or cid.group(1) in seen:
            continue
        seen.add(cid.group(1))
        per_pid[int(fd.split("/")[2])] += int(eng.group(1))
    return per_pid

def irqs():
    d = {}
    for ln in open("/proc/interrupts").read().splitlines()[1:]:
        parts = ln.split()
        if not parts or not parts[0].endswith(":"):
            continue
        n = sum(int(x) for x in parts[1:] if x.isdigit())
        d[parts[0][:-1] + " " + " ".join(p for p in parts[1:] if not p.isdigit())[-40:]] = n
    return d

def comm(pid):
    return (rd(f"/proc/{pid}/cmdline", "") or "").replace("\0", " ")[:70] or rd(f"/proc/{pid}/comm", "?")

p0, g0, i0, t0 = procs(), gpu_clients(), irqs(), time.time()
pw, freqs, gfreq, hz = [], defaultdict(list), [], []
while time.time() - t0 < secs:
    pw.append(power())
    for pol in glob.glob("/sys/devices/system/cpu/cpufreq/policy*"):
        freqs[os.path.basename(pol)].append(int(rd(pol + "/scaling_cur_freq", "0")) // 1000)
    gfreq.append(int(rd("/sys/class/devfreq/3d00000.gpu/cur_freq", "0")) // 1000000)
    m = re.search(r"hz (\d+)", rd("/sys/module/msm/parameters/idle_refresh_state", "") or "")
    if m:
        hz.append(int(m.group(1)))
    time.sleep(1)
dt = time.time() - t0
p1, g1, i1 = procs(), gpu_clients(), irqs()

sysw = [x[0] for x in pw]
print(f"== {dt:.0f} s sample, charger {'on' if pw[-1][2] else 'off'}")
print(f"device power W: avg {sum(sysw)/len(sysw):.2f}  min {min(sysw):.2f}  max {max(sysw):.2f}   (battery {pw[-1][1]:+.2f} W)")
for k, v in sorted(freqs.items()):
    print(f"cpu {k}: avg {sum(v)/len(v):.0f} MHz  max {max(v)}")
print(f"gpu: avg {sum(gfreq)/len(gfreq):.0f} MHz  max {max(gfreq)}" + (f"   panel refresh: {sorted(set(hz))} Hz (avg {sum(hz)/len(hz):.0f})" if hz else ""))
print(f"backlight: {rd(glob.glob('/sys/class/backlight/*/brightness')[0]) if glob.glob('/sys/class/backlight/*/brightness') else '?'}")
temps = []
for z in glob.glob("/sys/class/thermal/thermal_zone*"):
    t = rd(z + "/type", ""); v = rd(z + "/temp")
    if v and (t.startswith("cpu") or t.startswith("gpu") or t == "skin-thermal"):
        temps.append((int(v) / 1000, t))
temps.sort(reverse=True)
print("hottest: " + ", ".join(f"{t} {v:.0f}C" for v, t in temps[:4]))
cpu = []
for pid, (c, ticks) in p1.items():
    if pid in p0 and p0[pid][0] == c:
        d = (ticks - p0[pid][1]) / CLK / dt * 100
        if d >= 0.5:
            cpu.append((d, pid))
cpu.sort(reverse=True)
print(f"== CPU % of one core (total {sum(x[0] for x in cpu):.0f}%), top 15")
for d, pid in cpu[:15]:
    print(f"{d:6.1f}%  {pid:>7}  {comm(pid)}")
gpu = []
for pid, ns in g1.items():
    d = (ns - g0.get(pid, ns)) / 1e9 / dt * 100
    if d >= 0.2:
        gpu.append((d, pid))
gpu.sort(reverse=True)
print(f"== GPU busy % per process (total {sum(x[0] for x in gpu):.1f}%)")
for d, pid in gpu[:10]:
    print(f"{d:6.1f}%  {pid:>7}  {comm(pid)}")
irq = sorted(((i1.get(k, 0) - v) / dt, k) for k, v in i0.items())[::-1][:10]
print("== interrupts/s, top 10")
for r, k in irq:
    print(f"{r:8.0f}  {k}")
