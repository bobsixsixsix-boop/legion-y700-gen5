#!/usr/bin/env python3
"""rawdump-ls.py [DEV] [NAME...]: list the sections of a Qualcomm "Raw_Dmp!" crash dump (the rawdump
partition XBL fills in download mode) and print the named small sections (lastkmsg.log, RST_STAT.BIN,
PMIC_PON.BIN ...). Read-only. Header: 8-byte magic, then 64-byte section records from 0x40: u32 flags,
u32 version, u32 type, u64 offset, u64 size, u64 base, char name[20]. 2026-10-15, Y700 cx-collapse research."""
import struct, sys

dev = sys.argv[1] if len(sys.argv) > 1 else "/dev/disk/by-partlabel/rawdump"
want = sys.argv[2:]
f = open(dev, "rb")
hdr = f.read(0x100000)
assert hdr[:8] == b"Raw_Dmp!", hdr[:8]
secs = []
off = 0x38          # first record (verified against the Y700's dump: OCIMEM.BIN at offset 0x20f8, size 0x27000, base 0x14680000)
while off + 0x40 <= len(hdr):
    flags, ver, typ, soff, size, base, _rsvd = struct.unpack_from("<IIIQQQQ", hdr, off)
    name = hdr[off + 0x2c:off + 0x40].split(b"\0")[0]
    if not name or not all(32 <= c < 127 for c in name):
        break
    secs.append((name.decode(), soff, size, base, typ, flags))
    off += 0x40
print(f"{len(secs)} sections; header words: {struct.unpack_from('<IIIIIIII', hdr, 8)}")
tot = 0
for name, soff, size, base, typ, flags in secs:
    tot = max(tot, soff + size)
    print(f"  {name:<16} off 0x{soff:09x} size {size:>11} base 0x{base:010x} type {typ} flags {flags:#x}")
print(f"dump extent 0x{tot:x} ({tot / 2**20:.1f} MiB)")
for name, soff, size, base, typ, flags in secs:
    if name in want:
        f.seek(soff)
        data = f.read(min(size, 2 * 2**20))
        print(f"\n===== {name} ({size} bytes; showing {len(data)})")
        if name.endswith((".log", ".txt")) or b"Linux version" in data[:200000]:
            txt = data.decode("utf-8", "replace")
            lines = [l for l in txt.splitlines() if l.strip()]
            print("\n".join(lines[:12])); print("..."); print("\n".join(lines[-40:]))
        else:
            print(data[:256].hex(" ", 4))
