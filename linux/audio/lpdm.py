#!/usr/bin/env python3
"""Create READ-ONLY dm-linear devices /dev/mapper/ro_<name> for logical partitions in super."""
import struct, subprocess, sys
dev, names = sys.argv[1], sys.argv[2:]
f = open(dev, "rb")
f.seek(4096); g = f.read(4096)
mmax = struct.unpack_from("<I", g, 40)[0]
f.seek(4096 * 3); h = f.read(mmax)
hsize = struct.unpack_from("<I", h, 8)[0]
off = 4 + 2 + 2 + 4 + 32 + 4 + 32
tabs = [struct.unpack_from("<III", h, off + 12 * i) for i in range(4)]
exts = [struct.unpack_from("<QIQI", h, hsize + tabs[1][0] + i * tabs[1][2]) for i in range(tabs[1][1])]
for i in range(tabs[0][1]):
    p = h[hsize + tabs[0][0] + i * tabs[0][2]:][:tabs[0][2]]
    name = p[:36].split(b"\0")[0].decode()
    if name not in names:
        continue
    fe, ne = struct.unpack_from("<II", p, 40)
    lines, pos = [], 0
    for k in range(ne):
        n, typ, data, src = exts[fe + k]
        assert typ == 0 and src == 0
        lines.append(f"{pos} {n} linear {dev} {data}")
        pos += n
    subprocess.run(["dmsetup", "create", "--readonly", "ro_" + name], input="\n".join(lines) + "\n", text=True, check=True)
    print("/dev/mapper/ro_" + name, pos * 512)
