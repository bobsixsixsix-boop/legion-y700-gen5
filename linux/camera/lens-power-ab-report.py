#!/usr/bin/env python3
"""lens-power-ab-report.py RAW [LOG]: the numbers of a linux/camera/lens-power-ab.sh run (2026-10-29). Standard library
only, runs anywhere (Win11: tools/venv/Scripts/python -X utf8 -I -B linux/camera/lens-power-ab-report.py ...).
RAW = /var/log/y700-lensab-raw.tsv: complete pairs only, in order, one line per window (label, mean mW, samples,
      distinct currents, battery status, per-second mW). Several runs appended to one file are fine.
LOG = /var/log/y700-lensab.txt (optional): the powersample line of every window, for the check that both arms saw
      the same system (CPU busy, interrupts, AOSS/CX sleep), and the PAIR lines the bench wrote.
B - A > 0 means the lens powered (the state before the 10-29 fix) costs that much more. One night gives roughly
+/-10 mW: an interval across 0 is an upper bound on |B - A|, not "no difference".
Also printed (10-29 review): the one-sided 95 % upper bound (the most the powered lens can cost; B < A is physically
possible only through the unproven CCI pull-up term, README "验证状态"); B - A with the zero gauge reads left out (the
bench's rule), counted at the lowest non-zero reading of the file (the gauge's floor), and counted as 0; the zero reads
per arm; and from LOG the windows dropped for zero reads per arm and the idle waits. Dropped windows have no per-second
data (the bench returns before writing it), so their effect can only be bounded by assumption."""
import math
import random
import re
import statistics
import sys
from statistics import NormalDist

LABEL = re.compile(r"^p(\d+) ([AB]) lens (on|off)$")


def t_quantile(p, df):
    """Student t quantile from the normal one (Cornish-Fisher, two terms): within 0.5 % for df >= 5"""
    z = NormalDist().inv_cdf(p)
    return z + (z ** 3 + z) / (4 * df) + (5 * z ** 5 + 16 * z ** 3 + 3 * z) / (96 * df ** 2)


def read_raw(path):
    wins = []
    for ln in open(path, encoding="utf-8"):
        f = ln.rstrip("\n").split("\t")
        if len(f) < 6:
            continue
        m = LABEL.match(f[0])
        if not m:
            continue
        samples = [float(x) for x in f[5].split(",") if x]
        good = [x for x in samples if x != 0]    # exactly 0 = a dropped gauge read; the bench leaves them out too
        wins.append({"k": int(m.group(1)), "arm": m.group(2), "label": f[0], "n": int(f[2]), "status": f[4],
                     "mw": statistics.fmean(good) if good else float(f[1]), "zeros": len(samples) - len(good),
                     "samples": samples})
    pairs = []
    i = 0
    while i + 1 < len(wins):
        a, b = wins[i], wins[i + 1]
        if a["k"] == b["k"] and {a["arm"], b["arm"]} == {"A", "B"}:
            first = a["arm"]
            A, B = (a, b) if a["arm"] == "A" else (b, a)
            pairs.append({"k": a["k"], "A": A, "B": B, "first": first})
            i += 2
        else:
            print(f"skipping an unpaired window: {a['label']}")
            i += 1
    return pairs


def read_log(path):
    """per PAIR line of the log: the powersample fields of its A and B windows (the last line with that label)"""
    last, out = {}, []
    for ln in open(path, encoding="utf-8", errors="replace"):
        if ln.startswith("=== "):
            last = {}
            continue
        m = re.match(r"^(p\d+ [AB] lens o(?:n|ff))\s+([\d.]+) W .*", ln)
        if m:
            busy = re.search(r"cpu busy ([\d.]+)%", ln)
            irq = re.search(r"\| irq (\d+)/s", ln)
            sl = dict(re.findall(r"(\w+)=(\d+)%/\d+x", ln))
            last[m.group(1)] = {"busy": float(busy.group(1)) if busy else None, "irq": int(irq.group(1)) if irq else None,
                                "aosd": int(sl["aosd"]) if "aosd" in sl else None, "cxsd": int(sl["cxsd"]) if "cxsd" in sl else None}
            continue
        m = re.search(r"PAIR (\d+): A ([\d.]+) mW, B ([\d.]+) mW", ln)
        if m:
            k = m.group(1)
            out.append({"k": int(k), "A": last.get(f"p{k} A lens off"), "B": last.get(f"p{k} B lens on")})
    return out


def describe(d, what):
    n = len(d)
    m = statistics.fmean(d)
    sd = statistics.stdev(d) if n > 1 else 0.0
    se = sd / math.sqrt(n) if n else 0.0
    t = t_quantile(0.975, n - 1) if n > 1 else float("nan")
    med = statistics.median(d)
    rnd = random.Random(20261029)
    boots = sorted(statistics.fmean(rnd.choices(d, k=n)) for _ in range(10000))
    up = m + t_quantile(0.95, n - 1) * se if n > 1 else float("nan")
    print(f"{what}: n {n}, mean {m:+.2f} mW (sd {sd:.2f}, se {se:.2f}, 95 % t {m - t * se:+.2f}..{m + t * se:+.2f}; "
          f"bootstrap {boots[250]:+.2f}..{boots[9749]:+.2f}), one-sided 95 % upper {up:+.2f}, median {med:+.2f}, "
          f"B > A in {sum(x > 0 for x in d)}/{n}")
    return m, se, med


def zero_rules(pairs):
    """B - A per pair under three rules for the exact-zero gauge reads: left out (the bench), at the gauge floor (the
    lowest non-zero reading in the file), as 0. Their cause is open (10-29: whole ~5 s gauge updates, next to the floor
    state more often than chance), so no rule is known to be right; a conclusion should hold under all three."""
    floor = min(x for p in pairs for a in "AB" for x in p[a]["samples"] if x != 0)
    rules = (("left out", lambda s: [x for x in s if x != 0]),
             (f"at the floor {floor:.1f}", lambda s: [x if x != 0 else floor for x in s]),
             ("as 0", lambda s: s))
    for name, f in rules:
        d = [statistics.fmean(f(p["B"]["samples"])) - statistics.fmean(f(p["A"]["samples"])) for p in pairs]
        n, m = len(d), statistics.fmean(d)
        se = statistics.stdev(d) / math.sqrt(n) if n > 1 else 0.0
        print(f"zero reads {name}: B - A {m:+.2f} mW (se {se:.2f}), one-sided 95 % upper "
              f"{m + t_quantile(0.95, n - 1) * se:+.2f}" if n > 1 else f"zero reads {name}: B - A {m:+.2f} mW")


def read_drops(path):
    """windows the bench dropped for zero gauge reads, per arm, and its idle waits (each restarts the 10-min wait)"""
    drops, waits = {"A": 0, "B": 0}, 0
    for ln in open(path, encoding="utf-8", errors="replace"):
        m = re.search(r" p\d+ ([AB]): \d+ zero gauge reads - window dropped", ln)
        if m:
            drops[m.group(1)] += 1
        elif re.search(r"\d idle \d+ min on battery", ln):
            waits += 1
    return drops, waits


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    pairs = read_raw(sys.argv[1])
    if not pairs:
        sys.exit("no complete pair in " + sys.argv[1])
    d = [p["B"]["mw"] - p["A"]["mw"] for p in pairs]
    A = [p["A"]["mw"] for p in pairs]
    B = [p["B"]["mw"] for p in pairs]
    print(f"{len(pairs)} pairs; A (lens off) mean {statistics.fmean(A):.1f} mW (median {statistics.median(A):.1f}, "
          f"range {min(A):.0f}-{max(A):.0f}); B (lens on) mean {statistics.fmean(B):.1f} mW (median {statistics.median(B):.1f}, "
          f"range {min(B):.0f}-{max(B):.0f})")
    print(f"windows not 'Discharging': {sum(p[x]['status'] != 'Discharging' for p in pairs for x in 'AB')}; "
          f"zero gauge reads left out: {sum(p[x]['zeros'] for p in pairs for x in 'AB')} "
          f"(A {sum(p['A']['zeros'] for p in pairs)} in {sum(p['A']['zeros'] > 0 for p in pairs)} windows, "
          f"B {sum(p['B']['zeros'] for p in pairs)} in {sum(p['B']['zeros'] > 0 for p in pairs)})")
    describe(d, "B - A, all pairs")
    zero_rules(pairs)
    med = statistics.median(d)
    mad = statistics.median(abs(x - med) for x in d) * 1.4826
    if mad > 0:
        kept = [x for x in d if abs(x - med) <= 5 * mad]
        if len(kept) < len(d):
            describe(kept, f"B - A without {len(d) - len(kept)} pairs beyond 5 MAD ({5 * mad:.1f} mW)")
    # order effect: ABBA should cancel a linear drift; a big second-minus-first means the settle is too short or the
    # drift is not linear
    so = [(p["B"]["mw"] - p["A"]["mw"]) if p["first"] == "A" else (p["A"]["mw"] - p["B"]["mw"]) for p in pairs]
    print(f"second window minus first (both orders): mean {statistics.fmean(so):+.2f} mW")
    if len(pairs) >= 4:
        h = len(pairs) // 2
        print(f"B - A first half {statistics.fmean(d[:h]):+.2f} mW, second half {statistics.fmean(d[h:]):+.2f} mW")
    if len(sys.argv) > 2:
        drops, waits = read_drops(sys.argv[2])
        print(f"log: windows dropped for zero gauge reads A {drops['A']}, B {drops['B']}; idle waits {waits} "
              f"(the first one included)")
        lg = [x for x in read_log(sys.argv[2]) if x["A"] and x["B"]]
        if lg:
            for key in ("busy", "irq", "aosd", "cxsd"):
                a = [x["A"][key] for x in lg if x["A"][key] is not None]
                b = [x["B"][key] for x in lg if x["B"][key] is not None]
                if a and b:
                    print(f"log {key}: A mean {statistics.fmean(a):.2f}, B mean {statistics.fmean(b):.2f} ({len(a)} pairs)")


if __name__ == "__main__":
    main()
