#!/usr/bin/env python3
# The station spells between the access points of one txdbg apjoin run: for each spell (sN stopped -> sN+1 release)
# the states on both sides (ok/BAD), the BSS NetworkManager joined, and the WMI commands (>) / events (<) seen in it.
# Then which WMI ids show up only in spells where the state flipped, or only where it did not.
# Usage: spells.py /root/aptest2/join-HHMMSS
import re, subprocess, sys, collections
O = sys.argv[1]
run = open(f'{O}/run.log', errors='replace').read().splitlines()
state, marks, nm = {}, [], {}
for l in run:
    m = re.match(r"^s(\d+) Y700-T\d+ .* M2 (\d+) ", l)
    if m:
        state[int(m.group(1))] = 'ok' if int(m.group(2)) else 'BAD'
    m = re.match(r'^(\d\d:\d\d:\d\d\.\d+) s(\d+) (release|stopped)', l)
    if m:
        marks.append((m.group(1), int(m.group(2)), m.group(3)))
    m = re.match(r'^(\d\d:\d\d:\d\d\.\d+) NM: \S+:connected:(\S+)', l)
    if m:
        nm[m.group(1)] = m.group(2)
start = re.search(r'start (\d\d:\d\d:\d\d)', run[0]).group(1)
log = []
for l in subprocess.run(['journalctl', '-k', '-o', 'short-precise', '--since', start], capture_output=True,
                        text=True).stdout.splitlines():
    m = re.match(r'^\w+ \d+ (\d\d:\d\d:\d\d\.\d+) \S+ kernel: .*?y700wmi: ([<>]) (\w+) ', l)
    if m:
        log.append((m.group(1), m.group(2) + m.group(3)))
stopped = {k: t for t, k, w in marks if w == 'stopped'}
release = {k: t for t, k, w in marks if w == 'release'}
spells = []
for k in sorted(stopped):
    if k + 1 not in release:
        continue
    a, b = stopped[k], release[k + 1]
    ids = collections.Counter(i for t, i in log if a <= t <= b)
    bss = [v for t, v in nm.items() if a <= t <= b]
    flip = state.get(k) != state.get(k + 1)
    spells.append((k, flip, ids))
    print(f's{k} {state.get(k)} -> s{k+1} {state.get(k+1)} {"FLIP" if flip else "    "} {a}-{b} {",".join(bss)}: '
          + ' '.join(f'{i}x{n}' for i, n in sorted(ids.items())))
allids = set().union(*(s[2] for s in spells)) if spells else set()
for i in sorted(allids):
    f = [s[0] for s in spells if s[1] and i in s[2]]
    n = [s[0] for s in spells if not s[1] and i in s[2]]
    nf = sum(1 for s in spells if s[1]); nn = sum(1 for s in spells if not s[1])
    if len(f) != nf or len(n) != nn:
        print(f'{i}: in {len(f)}/{nf} flip spells {f}, {len(n)}/{nn} other spells {n}')
