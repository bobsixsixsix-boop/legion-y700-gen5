"""stage-power-ab.py OUT: per phase of stage-power-ab.sh, the mean battery W, CPU busy, Anim's frames, panel Hz,
and the CPU of the busiest processes (by pid, between each chunk's two /proc/*/stat snapshots; kworker names
grouped; % of one core). OUT copied back with its mtimes (tar): a chunk's length is its two snapshots' mtimes."""
import os, re, sys
from collections import defaultdict

d = sys.argv[1]
HZ = 100


def snap(p):
    out = {}
    for line in open(p, encoding="utf-8", errors="replace"):
        i = line.rfind(")")
        if i < 0:
            continue
        pid = line[:line.index(" ")]
        comm = line[line.index("(") + 1:i]
        f = line[i + 2:].split()
        try:
            out[pid] = (comm, int(f[11]) + int(f[12]))   # utime + stime (fields 14, 15)
        except (IndexError, ValueError):
            pass
    return out


def name(c):
    return "kworker*" if c.startswith("kworker") else c


phases = defaultdict(list)
for line in open(os.path.join(d, "chunks"), encoding="utf-8"):
    ph, k, ps, t, anim = line.split()[:5]
    m = re.search(r"\|\s*\S+\s+(\S+) W \(min (\S+) max (\S+)", line)
    cpu = re.search(r"cpu busy (\S+)%", line)
    panel = re.search(r"panel ([^|]+)\|", line)
    a, b = snap(os.path.join(d, ps + ".a")), snap(os.path.join(d, ps + ".b"))
    secs = os.path.getmtime(os.path.join(d, ps + ".b")) - os.path.getmtime(os.path.join(d, ps + ".a"))
    per = defaultdict(int)
    for pid, (c, tk) in b.items():
        if pid in a and a[pid][0] == c:
            per[name(c)] += tk - a[pid][1]
    phases[ph].append(dict(k=k, t=t, anim=int(anim[5:]), w=float(m.group(1)) if m else None,
                           cpu=float(cpu.group(1)) if cpu else None, panel=panel.group(1).strip() if panel else "?",
                           per=per, secs=secs, line=line.rstrip()))

for ph, ch in phases.items():
    ws = [c["w"] for c in ch if c["w"] is not None]
    cs = [c["cpu"] for c in ch if c["cpu"] is not None]
    secs = sum(c["secs"] for c in ch)
    print(f"== {ph}: {len(ch)} chunks, {secs:.0f} s | battery {sum(ws) / len(ws):.2f} W (chunks {', '.join(f'{w:.2f}' for w in ws)})"
          f" | cpu busy {sum(cs) / len(cs):.1f}% of 8 | Anim {sum(c['anim'] for c in ch)} frames | panel {', '.join(c['panel'] for c in ch)}")
    tot = defaultdict(int)
    for c in ch:
        for n, tk in c["per"].items():
            tot[n] += tk
    allt = sum(tot.values())
    print(f"   all processes {allt / HZ / secs * 100:.1f}% of one core; top:",
          ", ".join(f"{n} {tk / HZ / secs * 100:.1f}%" for n, tk in sorted(tot.items(), key=lambda x: -x[1])[:12]))
