#!/usr/bin/env python3
"""Inspect a TB323FU 9008 package: XML write list, GPTs, slot attrs, efisp, AVB, device-unique images.

usage: python analyze_pkg.py <image_dir> [--ref16 <coloros-v9/image>]
"""
import hashlib, os, struct, sys, uuid, zlib, xml.etree.ElementTree as ET

SS = 4096
UNIQUE = ["persist", "devinfo", "oemowninfo", "modemst1", "modemst2", "fsg", "fsc", "fs_bkup",
          "keystore", "secdata", "uefivarstore", "frp", "misc", "ssd", "spunvm", "qweslicstore",
          "connsec", "tzsc", "cdt", "dpm", "qmcs", "mdcompress", "logdump", "logfs", "storsec"]
HERE = os.path.dirname(os.path.abspath(__file__))


def sha(p, n=None):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        h.update(f.read() if n is None else f.read(n))
    return h.hexdigest()


def gpt(path, hdr_sec=1, arr_sec=2):
    d = open(path, "rb").read()
    h = d[hdr_sec * SS:hdr_sec * SS + 92]
    if h[:8] != b"EFI PART":
        return None
    cur, bak, first, last = struct.unpack_from("<QQQQ", h, 24)
    pe, npe, pesz, pecrc = struct.unpack_from("<QIII", h, 72)
    hh = bytearray(h); hc = struct.unpack_from("<I", hh, 16)[0]; struct.pack_into("<I", hh, 16, 0)
    arr = d[arr_sec * SS:arr_sec * SS + npe * pesz]
    ents = []
    for i in range(npe):
        e = arr[i * pesz:(i + 1) * pesz]
        if e[:16] == b"\0" * 16:
            continue
        s, en, a = struct.unpack_from("<QQQ", e, 32)
        ents.append(dict(i=i, name=e[56:128].decode("utf-16le").rstrip("\0"), start=s, end=en, attr=a,
                         type=str(uuid.UUID(bytes_le=e[:16]))))
    return dict(cur=cur, bak=bak, first=first, last=last, npe=npe,
                hdr_ok=zlib.crc32(bytes(hh)) == hc, arr_ok=zlib.crc32(arr) == pecrc, ents=ents)


def slot(a):
    return f"prio={(a >> 48) & 3} active={(a >> 50) & 1} retry={(a >> 51) & 7} ok={(a >> 54) & 1} unboot={(a >> 55) & 1}"


def avb(p):
    d = open(p, "rb").read(256)
    if d[:4] != b"AVB0":
        return "no AVB0 header"
    rb = struct.unpack_from(">Q", d, 96)[0]; fl = struct.unpack_from(">I", d, 104)[0]
    alg = struct.unpack_from(">I", d, 28)[0]
    return f"algo={alg} rollback_index={rb} flags={fl:#x}"


def content(p):
    d = open(p, "rb").read()
    nz = len(d) - d.count(0)
    ff = d.count(0xFF)
    return f"{len(d)} B, nonzero={nz}, 0xFF={ff}" + (" (ALL ZERO)" if nz == 0 else "") + \
        (" (ALL 0xFF)" if ff == len(d) else "")


def main():
    img = sys.argv[1]
    ref16 = sys.argv[sys.argv.index("--ref16") + 1] if "--ref16" in sys.argv else None
    print("=" * 70, "\nWRITE LIST (rawprogram*.xml)")
    total = 0; missing = []
    for x in sorted(f for f in os.listdir(img) if f.startswith("rawprogram") and f.endswith(".xml")):
        rows = []
        for p in ET.parse(os.path.join(img, x)).getroot().iter("program"):
            fn = p.get("filename") or ""
            lab = p.get("label")
            if fn:
                fp = os.path.join(img, fn)
                if os.path.exists(fp):
                    total += os.path.getsize(fp)
                else:
                    missing.append((x, lab, fn))
            rows.append(f"{lab}{'' if fn else '(skip)'}")
        print(f"{x} [LUN {p.get('physical_partition_number')}] {len(rows)} entries:\n   " + ", ".join(rows))
    print(f"total bytes referenced: {total / 2**30:.2f} GiB; missing files: {missing or 'none'}")

    print("=" * 70, "\nPATCH XMLs (distinct 'what')")
    for x in sorted(f for f in os.listdir(img) if f.startswith("patch") and f.endswith(".xml")):
        whats = sorted({p.get("what") for p in ET.parse(os.path.join(img, x)).getroot().iter("patch")
                        if "last partition" in (p.get("what") or "")})
        print(x, whats)

    print("=" * 70, "\nGPT")
    g = {}
    for lun in range(6):
        g[lun] = gpt(os.path.join(img, f"gpt_main{lun}.bin"))
        b = gpt(os.path.join(img, f"gpt_backup{lun}.bin"), 4, 0)
        t = g[lun]
        print(f"LUN{lun}: entries={len(t['ents'])} last_usable={t['last']} bak={t['bak']} "
              f"hdrCRC={t['hdr_ok']} arrCRC={t['arr_ok']} | backup ok={b and b['hdr_ok'] and b['arr_ok']}")
    print("LUN0 layout:")
    for e in g[0]["ents"]:
        print(f"   [{e['i']:2}] {e['name']:<16} {e['start']:>10}..{e['end']:<10} {(e['end'] - e['start'] + 1) * SS / 2**30:9.3f} GiB")
    print("LUN4 slot attributes:")
    for e in g[4]["ents"]:
        if e["name"] in ("boot_a", "boot_b", "vbmeta_a", "vbmeta_b", "init_boot_a", "init_boot_b"):
            print(f"   {e['name']:<12} {slot(e['attr'])}")
    if ref16:
        for lun in range(6):
            r = gpt(os.path.join(ref16, f"gpt_main{lun}.bin.orig" if lun == 0 else f"gpt_main{lun}.bin"))
            a = {e["name"]: (e["start"], e["end"]) for e in g[lun]["ents"]}
            bb = {e["name"]: (e["start"], e["end"]) for e in r["ents"]}
            diff = sorted(n for n in set(a) | set(bb) if a.get(n) != bb.get(n))
            print(f"LUN{lun} vs ColorOS16 package: {'identical layout' if not diff else 'DIFF ' + str(diff)}")
        dev = gpt(os.path.join(HERE, "y700-recovery", "materials", "gpt-lun4-primary-0225.bin"))
        a = {e["name"]: (e["start"], e["end"]) for e in g[4]["ents"]}
        bb = {e["name"]: (e["start"], e["end"]) for e in dev["ents"]}
        diff = sorted(n for n in set(a) | set(bb) if a.get(n) != bb.get(n))
        print(f"LUN4 vs tablet snapshot 10-10: {'identical layout' if not diff else 'DIFF ' + str(diff)}")

    print("=" * 70, "\nEFISP / AVB / BOOT")
    ef = os.path.join(img, "efisp.img")
    d = open(ef, "rb").read()
    print("efisp:", content(ef), "sha256", sha(ef), "MZ" if d[:2] == b"MZ" else "not PE")
    for tag in (b"gbl_root_canoe", b"superfastboot", b"jenkins_build/", b"runner/work/"):
        i = d.find(tag)
        if i >= 0:
            print("   string:", d[max(0, i - 40):i + 80].split(b"\0")[0][-120:])
    known = {}
    for f in os.listdir(os.path.join(HERE, "gbl-compare")):
        fp = os.path.join(HERE, "gbl-compare", f)
        if os.path.isfile(fp) and f.endswith(".efi"):
            known[sha(fp)] = f
    if ref16:
        known[sha(os.path.join(ref16, "efisp.img"))] = "ColorOS16 package efisp"
    tr = d.rstrip(b"\0")
    print("   matches known:", known.get(sha(ef)) or known.get(hashlib.sha256(tr).hexdigest()) or "none")
    for v in ("vbmeta_a.img", "vbmeta_b.img", "vbmeta_system_a.img", "vbmeta_system_b.img"):
        p = os.path.join(img, v)
        if os.path.exists(p):
            print(f"{v}: {avb(p)}")
    for b in ("boot_a.img", "boot_b.img", "init_boot_a.img", "init_boot_b.img"):
        p = os.path.join(img, b)
        if os.path.exists(p):
            dd = open(p, "rb").read(4096)
            ks, rs = struct.unpack_from("<II", dd, 8)
            print(f"{b}: magic={dd[:8]} hdr_v={struct.unpack_from('<I', dd, 40)[0]} kernel={ks} ramdisk={rs} sha={sha(p)[:16]}")
    for a_, b_ in (("boot_a.img", "boot_b.img"), ("init_boot_a.img", "init_boot_b.img"), ("abl_a.img", "abl_b.img"),
                   ("xbl_a.img", "xbl_b.img"), ("vbmeta_a.img", "vbmeta_b.img"), ("modem_a.img", "modem_b.img")):
        pa, pb = os.path.join(img, a_), os.path.join(img, b_)
        if os.path.exists(pa) and os.path.exists(pb):
            print(f"{a_} == {b_}: {sha(pa) == sha(pb)}")

    print("=" * 70, "\nDEVICE-UNIQUE / STATE IMAGES IN PACKAGE")
    for u in UNIQUE:
        p = os.path.join(img, u + ".img")
        if os.path.exists(p):
            print(f"   {u:<14} {content(p)}")


if __name__ == "__main__":
    main()
