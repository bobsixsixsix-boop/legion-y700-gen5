#!/usr/bin/env python3
# Every apjoin session of the day in time order: good/bad, first and last association, quiet time since the client's
# previous attempt, restarts. bad = associated but no M2 (or a FW drop in a txdbg kernel log).
import re, pathlib, datetime
rows = []
for d in sorted(pathlib.Path('/root/aptest2').glob('join-*')):
    run = (d / 'run.log').read_text(errors='replace') if (d / 'run.log').exists() else ''
    head = run.splitlines()[0][:110] if run else ''
    for m in re.finditer(r"^s(\d+) Y700-T\d+ channel '([^']*)' assoc (\d+) M1 (\d+) M2 (\d+)", run, re.M):
        k, ch, assoc, m1, m2 = m.group(1), m.group(2), int(m.group(3)), int(m.group(4)), int(m.group(5))
        h = d / f'h{k}.log'
        ts = []
        if h.exists():
            for ln in h.read_text(errors='replace').splitlines():
                if 'IEEE 802.11: associated' in ln or 'WPA_PTK entering state PTKSTART' in ln:
                    t = re.match(r'^(\d+\.\d+):', ln)
                    if t:
                        ts.append(float(t.group(1)))
        kl = d / f'k{k}.log'
        drop = ok = 0
        if kl.exists():
            s = kl.read_text(errors='replace')
            drop = len(re.findall(r'y700htt: wbm 1 p 888e', s))
            ok = len(re.findall(r'y700htt: wbm 0 p 888e', s))
        state = '-' if assoc == 0 else ('BAD' if m2 == 0 else 'ok')
        rows.append((ts[0] if ts else None, ts[-1] if ts else None, d.name, k, ch.split()[-1] if ch else '?', assoc, m1, m2,
                     drop, ok, state))
rows = [r for r in rows if r[0]]
rows.sort()
prev_last = None
for r in rows:
    first, last = r[0], r[1]
    quiet = f'{first - prev_last:7.0f}' if prev_last else '      -'
    f = datetime.datetime.fromtimestamp(first).strftime('%H:%M:%S')
    print(f'{f} quiet {quiet}s  {r[2]} s{r[3]:<2} w{r[4]:<3} assoc {r[5]:<2} M1 {r[6]:<3} M2 {r[7]:<2} drop {r[8]:<3} ok {r[9]:<3} {r[10]}'
          f'  span {last - first:5.1f}s')
    prev_last = last
