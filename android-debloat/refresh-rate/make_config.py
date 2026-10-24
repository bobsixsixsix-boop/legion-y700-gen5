#!/usr/bin/env python3
"""生成放到 /data/system/refresh_rate_config.xml 的覆盖配置。

用法: python make_config.py <原文件> <覆盖清单> <输出文件> [新version] [--auto-cap N]
覆盖清单每行: 包名<空白>rateId串(a-b-c-d-e)   # 注释   （清单可以为空文件）
  - 5 个数对应设置档位: 0 自动 / 1 90 / 2 60 / 3 高(120/144/165) / 4 极致
  - 每个数是 rate id: 1=90 2=60 3=120 4=144 5=72 6=30 7=165 8=185 0=不指定
  - 包名已有条目(不带 activity 的那条)就改它的 rateId；没有就在 </refresh_rate_config> 前追加一条。
  - 带 activity 的条目不动。
--auto-cap N: 把所有条目(含带 activity 的)"自动"档(第 1 个数)里比 N 高的值压到 N。
  比如 --auto-cap 3：7/4/8(165/144/185) 都变成 3(120)，1/2(90/60) 保持。清单里的覆盖在之后应用，不受此影响。
新 version 默认 = 今天的日期(YYYYMMDD)；必须 >= 系统分区那份(20260930)才会被采用。
只改文本，不重新序列化 XML，其余内容（含 CRLF）逐字节保留。
"""
import re, sys, datetime

args = [a for a in sys.argv[1:] if not a.startswith('--')]
src, lst, dst = args[0], args[1], args[2]
ver = args[3] if len(args) > 3 else datetime.date.today().strftime('%Y%m%d')
auto_cap = None
if '--auto-cap' in sys.argv:
    auto_cap = int(sys.argv[sys.argv.index('--auto-cap') + 1])

RATE_HZ = {0: 0, 1: 90, 2: 60, 3: 120, 4: 144, 5: 72, 6: 30, 7: 165, 8: 185}

text = open(src, encoding='utf-8', newline='').read()   # newline='' 保留原有的 CRLF/LF

m = re.search(r'<refresh_rate_config version="(\d+)"', text)
assert m, 'no root version'
old_ver = int(m.group(1))
assert int(ver) >= old_ver, f'version {ver} < {old_ver}'
text = text[:m.start(1)] + ver + text[m.end(1):]

capped = 0
if auto_cap is not None:
    cap_hz = RATE_HZ[auto_cap]
    def cap(mm):
        global capped
        first = int(mm.group(2))
        if RATE_HZ.get(first, 0) > cap_hz:
            capped += 1
            return mm.group(1) + str(auto_cap) + mm.group(3)
        return mm.group(0)
    text = re.sub(r'(<item [^>]*?rateId=")([0-8])((?:-[0-8]){4}")', cap, text)

overrides = []
for line in open(lst, encoding='utf-8'):
    line = line.split('#', 1)[0].strip()
    if not line: continue
    pkg, rate = line.split()
    assert re.fullmatch(r'[0-8](-[0-8]){4}', rate), f'bad rateId {rate}'
    overrides.append((pkg, rate))

added, changed = [], []
for pkg, rate in overrides:
    # 只匹配不带 activity= 的 item
    pat = re.compile(r'(<item package="' + re.escape(pkg) + r'"(?![^>]*activity=)[^>]*?rateId=")([0-9-]+)(")')
    text, k = pat.subn(lambda mm: mm.group(1) + rate + mm.group(3), text)
    if k:
        changed.append((pkg, rate, k))
    else:
        added.append((pkg, rate))

if added:
    nl = '\r\n' if '\r\n' in text else '\n'
    block = nl + '  <!-- y700 覆盖（make_config.py 追加） -->' + nl + ''.join(
        f'  <item package="{p}" rateId="{r}" />{nl}' for p, r in added)
    i = text.rfind('</refresh_rate_config>')
    text = text[:i] + block + text[i:]

open(dst, 'w', encoding='utf-8', newline='').write(text)
print(f'version {old_ver} -> {ver}')
if auto_cap is not None: print(f'auto-cap {auto_cap} ({RATE_HZ[auto_cap]} Hz): {capped} items capped')
for p, r, k in changed: print(f'changed {p} -> {r} ({k} item)')
for p, r in added: print(f'added   {p} -> {r}')
