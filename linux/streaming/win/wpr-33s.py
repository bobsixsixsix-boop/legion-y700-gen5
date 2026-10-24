#!/usr/bin/env python3
"""Which kernel driver makes the PC stall?  Analyse a WPR "CPU" trace (wpr-33s.cmd).

usage: py -3 wpr-33s.py cpu.etl [workdir]
  1. tracerpt converts the ETL to CSV in workdir (default %TEMP%\\wpr-33s; ~4x the ETL,
     a 2 GB trace gives a 9 GB CSV, takes ~3 min)
  2. pass 1: kernel image ranges (Image DCStart/Load) and, per thread, how many
     1 kHz profile samples landed in kernel space each second -> threads that peg a
     core (~1000 samples/s) in bursts
  3. pass 2: for the worst thread, IP -> driver histogram and its most common stacks
No symbols needed: module+offset is enough to name the driver.
2026-10-19 result: one System thread, 95 % of its samples in vgk.sys (Riot Vanguard),
~2.5 s at 100 % of a core every ~33 s, also with no game running.
"""
import bisect, collections, os, subprocess, sys
from pathlib import Path

KERNEL = 0xFFFF800000000000


def fields(line):
    return [x.strip() for x in line.split(",")]


def convert(etl, work):
    work.mkdir(parents=True, exist_ok=True)
    csv = work / "events.csv"
    if not csv.exists():
        subprocess.run(["tracerpt", str(etl), "-o", str(csv), "-of", "CSV", "-y"], check=True,
                       stdout=subprocess.DEVNULL)
    return csv


def pass1(csv):
    # columns: 16 clock-time (100 ns), 19.. user data
    imgs, persec, t0 = [], collections.defaultdict(collections.Counter), None
    with open(csv, encoding="ascii", errors="replace") as f:
        for line in f:
            s = line.lstrip()
            if s.startswith("PerfInfo, SampleProf"):          # IP, ThreadId, Count
                p = fields(line)
                ip, tid, ts = int(p[19], 16), int(p[20]), int(p[16])
                if ip >= KERNEL:
                    t0 = ts if t0 is None else t0
                    persec[tid][(ts - t0) // 10_000_000] += 1
            elif s.startswith("Image,"):                        # ImageBase, ImageSize, ..., FileName
                p = fields(line)
                try:
                    base, size = int(p[19], 16), int(p[20], 16)
                except (ValueError, IndexError):
                    continue
                if base >= KERNEL:
                    imgs.append((base, base + size, p[-1].strip('"').split("\\")[-1]))
    hot = []
    for tid, c in persec.items():
        if max(c.values()) >= 500:
            hot.append((max(c.values()), tid, sorted(k for k, v in c.items() if v >= 400)))
    return sorted(set(imgs)), sorted(hot, reverse=True)


def pass2(csv, imgs, tid):
    bases = [i[0] for i in imgs]

    def mod(a):
        k = bisect.bisect_right(bases, a) - 1
        if k >= 0 and imgs[k][0] <= a < imgs[k][1]:
            return imgs[k][2], f"{imgs[k][2]}+0x{a - imgs[k][0]:x}"
        return "?", f"0x{a:x}"
    ipm, stacks, inst = collections.Counter(), collections.Counter(), collections.Counter()
    with open(csv, encoding="ascii", errors="replace") as f:
        for line in f:
            s = line.lstrip()
            if s.startswith("PerfInfo, SampleProf"):
                p = fields(line)
                if int(p[20]) == tid:
                    ipm[mod(int(p[19], 16))[0]] += 1
            elif s.startswith("StackWalk"):                     # EventTimeStamp, Process, Thread, frames...
                p = fields(line)
                if int(p[21]) == tid:
                    fr = [mod(int(x, 16)) for x in p[22:] if x.startswith("0x")]
                    stacks[" <- ".join(x[1] for x in fr[:8])] += 1
                    for m in {x[0] for x in fr}:
                        inst[m] += 1
    return ipm, inst, stacks


def main():
    etl = Path(sys.argv[1])
    work = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(os.environ["TEMP"]) / "wpr-33s"
    csv = convert(etl, work)
    imgs, hot = pass1(csv)
    print(f"{len(imgs)} kernel images; threads pegging a core in bursts:")
    for mx, tid, secs in hot[:8]:
        print(f"  tid {tid}: max {mx} samples/s, busy seconds {secs}")
    if not hot:
        return
    ipm, inst, stacks = pass2(csv, imgs, hot[0][1])
    tot = sum(ipm.values())
    print(f"tid {hot[0][1]}: where the CPU was ({tot} samples):")
    for m, n in ipm.most_common(6):
        print(f"  {m:20s} {100 * n / tot:5.1f} %")
    print("  modules on its stacks:", ", ".join(f"{m} {n}" for m, n in inst.most_common(8)))
    for st, n in stacks.most_common(3):
        print(f"  {n:5d} x {st}")


if __name__ == "__main__":
    main()
