#!/usr/bin/env python3
"""Write one logical partition of a super image to stdout (read-only). usage: lpcat.py SUPER NAME"""
import struct, sys
dev, want = sys.argv[1], sys.argv[2]
f = open(dev, "rb")
f.seek(4096); g = f.read(4096)
mmax = struct.unpack_from("<I", g, 40)[0]
f.seek(4096 * 3); h = f.read(mmax)
hsize = struct.unpack_from("<I", h, 8)[0]
off = 4 + 2 + 2 + 4 + 32 + 4 + 32
tabs = [struct.unpack_from("<III", h, off + 12 * i) for i in range(4)]
exts = [struct.unpack_from("<QIQI", h, hsize + tabs[1][0] + i * tabs[1][2]) for i in range(tabs[1][1])]
out = sys.stdout.buffer
for i in range(tabs[0][1]):
    p = h[hsize + tabs[0][0] + i * tabs[0][2]:][:tabs[0][2]]
    if p[:36].split(b"\0")[0].decode() != want:
        continue
    fe, ne = struct.unpack_from("<II", p, 40)
    for k in range(ne):
        n, typ, data, src = exts[fe + k]
        assert typ == 0
        f.seek(data * 512); left = n * 512
        while left:
            b = f.read(min(left, 8 << 20)); out.write(b); left -= len(b)
    sys.exit(0)
sys.exit("no such partition")
