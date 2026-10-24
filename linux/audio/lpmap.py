#!/usr/bin/env python3
"""Print logical partitions of an Android super partition: name start_byte size_bytes (single-extent only)."""
import struct, sys
dev = sys.argv[1]
f = open(dev, "rb")
f.seek(4096); g = f.read(4096)
magic, ssize = struct.unpack_from("<II", g, 0)
assert magic == 0x616c4467, hex(magic)
mmax, slots, lbs = struct.unpack_from("<III", g, 40)
f.seek(4096 * 3); h = f.read(mmax)
magic, maj, mnr, hsize = struct.unpack_from("<IHHI", h, 0)
assert magic == 0x414C5030, hex(magic)
off = 4 + 2 + 2 + 4 + 32 + 4 + 32
tabs = [struct.unpack_from("<III", h, off + 12 * i) for i in range(4)]
base = hsize
parts = [h[base + tabs[0][0] + i * tabs[0][2]: base + tabs[0][0] + (i + 1) * tabs[0][2]] for i in range(tabs[0][1])]
exts = [struct.unpack_from("<QIQI", h, base + tabs[1][0] + i * tabs[1][2]) for i in range(tabs[1][1])]
for p in parts:
    name = p[:36].split(b"\0")[0].decode()
    attr, fe, ne, gi = struct.unpack_from("<IIII", p, 36)
    segs = [exts[fe + k] for k in range(ne)]
    total = sum(s[0] for s in segs) * 512
    if ne == 1 and segs[0][1] == 0:
        print(name, segs[0][2] * 512, total)
    else:
        print(name, "extents=%d" % ne, total, [(s[2] * 512, s[0] * 512) for s in segs if s[1] == 0])
