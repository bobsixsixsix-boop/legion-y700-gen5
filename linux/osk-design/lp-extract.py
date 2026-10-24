#!/usr/bin/env python3
"""Minimal LP (Android dynamic partition) metadata reader/extractor for the y700 super partition.
usage: lp-extract.py DEV            -> list partitions (slot 0)
       lp-extract.py DEV NAME OUT   -> write partition NAME (concatenated extents) to OUT
"""
import struct, sys
dev = sys.argv[1]
f = open(dev, 'rb')
f.seek(4096); g = f.read(4096)
magic, ssz = struct.unpack('<II', g[:8]); assert magic == 0x616c4467, hex(magic)
max_size, slots, blk = struct.unpack('<III', g[40:52])
base = 4096 * 3
f.seek(base); h = f.read(256)
hmagic, major, minor, hsize = struct.unpack('<IHHI', h[:12]); assert hmagic == 0x414C5030, hex(hmagic)
tables_size = struct.unpack('<I', h[44:48])[0]
def desc(off): return struct.unpack('<III', h[off:off+12])
parts, exts, groups, bdevs = desc(80), desc(92), desc(104), desc(116)
f.seek(base + hsize); t = f.read(tables_size)
def table(d):
    off, n, esz = d; return [t[off+i*esz: off+(i+1)*esz] for i in range(n)]
P = table(parts); E = table(exts); G = table(groups)
def pname(e): return e[:36].split(b'\0')[0].decode()
def extent(e): ns, tt, td, tsrc = struct.unpack('<QIQI', e[:24]); return ns, tt, td
if len(sys.argv) == 2:
    print(f'LP {major}.{minor} slots={slots} max={max_size} partitions={len(P)} extents={len(E)}')
    for e in P:
        name = pname(e); attr, fx, nx, gi = struct.unpack('<IIII', e[36:52])
        size = sum(extent(E[i])[0] for i in range(fx, fx+nx)) * 512
        grp = G[gi][:36].split(b'\0')[0].decode()
        print(f'{name:28s} {size/2**20:9.1f} MiB extents={nx} group={grp} first={extent(E[fx])[2]*512 if nx else 0}')
    sys.exit()
name, out = sys.argv[2], sys.argv[3]
for e in P:
    if pname(e) == name:
        attr, fx, nx, gi = struct.unpack('<IIII', e[36:52]); break
else: sys.exit('no such partition')
with open(out, 'wb') as o:
    for i in range(fx, fx+nx):
        ns, tt, td = extent(E[i]); assert tt == 0
        f.seek(td*512); left = ns*512
        while left:
            c = f.read(min(left, 64*2**20)); o.write(c); left -= len(c)
print('wrote', out)
