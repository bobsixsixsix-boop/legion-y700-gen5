#!/usr/bin/env python3
# Timeline of one txdbg apjoin run, station spells included: the run's session marks plus every instrumented
# kernel line that names the PC's MAC (as text, or as bytes in a raw HTT/WMI dump), every vdev create and every
# HTT peer map/unmap. Usage: mactrace.py /root/aptest2/join-HHMMSS [MAC]
import re, subprocess, sys
O = sys.argv[1]
mac = (sys.argv[2] if len(sys.argv) > 2 else '02:00:00:00:00:20').lower()
hexb = ' '.join(mac.split(':')[:4])
run = open(f'{O}/run.log', errors='replace').read().splitlines()
start = re.search(r'start (\d\d:\d\d:\d\d)', run[0]).group(1)
end = next((re.search(r'end (\d\d:\d\d:\d\d)', l).group(1) for l in run if l.startswith('== end')), None)
cmd = ['journalctl', '-k', '-o', 'short-precise', '--since', start] + (['--until', end] if end else [])
rows = []
for l in run:
    m = re.match(r'^(\d\d:\d\d:\d\d\.\d+) (s\d+ .*)', l)
    if m:
        rows.append((m.group(1)[:12], 'RUN  ' + m.group(2)[:110]))
    m = re.match(r'^(\d\d:\d\d:\d\d\.\d+) NM: (.*)', l)
    if m:
        rows.append((m.group(1)[:12], 'RUN  NM ' + m.group(2)[:80]))
for l in subprocess.run(cmd, capture_output=True, text=True).stdout.splitlines():
    m = re.match(r'^\w+ \d+ (\d\d:\d\d:\d\d\.\d+) \S+ kernel: (.*)', l)
    if not m:
        continue
    t, msg = m.group(1)[:12], m.group(2)
    if not re.search(r'y700(dbg|htc|wmi|htt|tx|cmp)', msg):
        continue
    if mac in msg.lower() or hexb in msg or re.search(r'vdev create|htt peer (un)?map|peer create', msg):
        msg = re.sub(r'^.*?(y700\w+:)', r'\1', msg)
        if 'y700tx:' in msg or 'y700cmp:' in msg or 'y700htt:' in msg:
            continue  # data path lines: per-session summaries have them
        rows.append((t, 'KERN ' + msg[:150]))
rows.sort()
for t, m in rows:
    print(t, m)
