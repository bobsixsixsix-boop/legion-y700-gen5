#!/usr/bin/env python3
"""Flash a prepared ColorOS port (--pkg v16 | v17, see prep_pkg.py) to a TB323FU over EDL (9008) with bkerler/edl.

Stages (run in this order; each one logs to flash-logs/):
  plan     no device: check files, print every edl command that would run
  probe    read-only: storage info + all six GPTs (primary and backup) saved to flash-logs/<ts>/gpt/
  backup   read-only: device-unique partitions + current efisp -> flash-logs/<ts>/backup/
  flash    WRITES: qfil with flash_lun{0..5}.xml + patch{0..5}.xml  (needs --efisp package|keep and --yes)
  verify   read-only: read back written partitions, compare sha256; kept slot-B partitions unchanged
           since the backup (boot_b = Android boot); parse the new LUN0 GPT
  setslot  WRITES GPT attributes: make slot _a active (only if the tablet does not boot on its own)
  reset    reboot the tablet

Layout change vs. the stock package: LUN0 userdata fixed at 128 GiB, new partition `baldur-root`
(Linux filesystem type) from the next 1 MiB boundary to the end of LUN0 (see README.md).
"""
import argparse, datetime, hashlib, os, struct, subprocess, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
EDL_DIR = os.path.join(HERE, "edl-win")
PY = os.path.join(EDL_DIR, "venv", "Scripts", "python.exe")
LOADER = os.path.join(HERE, "y700-recovery", "loader", "qsahara_device_programmer.xml")
PKGS = {"v16": os.path.join(HERE, "coloros-v9", "image"), "v17": os.path.join(HERE, "coloros-v17", "image")}
IMG = None  # set from --pkg
LOGROOT = os.path.join(HERE, "flash-logs")
SS = 4096
USERDATA_END = 39215911          # 5661480 + 128 GiB/4096 - 1
ROOT_START = 39476224         # same start as the existing baldur-root on the tablet

UNIQUE = ["persist", "oemowninfo", "devinfo", "modemst1", "modemst2", "fsg", "fsc", "fs_bkup",
          "keystore", "secdata", "uefivarstore", "frp", "misc", "ssd", "efisp", "spunvm", "cdt", "ddr",
          "qweslicstore_a", "qweslicstore_b", "lenovoraw", "lenovocust", "dataext_a", "dataext_b",
          "abl_b", "boot_b"]            # kept partitions: the verify stage compares them with this copy
# Written by the flash and read back against the package file.
VERIFY = ["xbl_a", "abl_a", "boot_a", "init_boot_a", "vendor_boot_a", "vbmeta_a", "dtbo_a",
          "recovery_a", "tz_a", "modem_a", "vbmeta_system_a"]
# Deliberately NOT written (prep_pkg.py keeps slot B) and read back to prove the flash left them alone:
# compared with the copy the backup stage took before the flash; boot_b must in addition still be the
# Android boot image the Linux side switches to (= the package's boot_a.img, README "boot_b").
KEEP = ["abl_b", "boot_b"]
KEEP_EXPECT = {"boot_b": "boot_a.img"}
from prep_pkg import REQUIRED            # same list the package was prepared against


def verify_items(efisp, with_super):
    """(partition, lun, file) for VERIFY labels, read from the flash XMLs actually used."""
    import xml.etree.ElementTree as ET
    want = set(VERIFY) | ({"efisp"} if efisp == "package" else set()) | ({"super"} if with_super else set())
    out = []
    for x in xmls(efisp)[0]:
        for p in ET.parse(os.path.join(IMG, x)).getroot().iter("program"):
            if p.get("label") in want and p.get("filename"):
                out.append((p.get("label"), int(p.get("physical_partition_number")), p.get("filename")))
    return out


def ts():
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S")


class Run:
    def __init__(self, stage, dry):
        self.dir = os.path.join(LOGROOT, f"{ts()}-{stage}")
        self.dry = dry
        if not dry:
            os.makedirs(self.dir, exist_ok=True)
        self.log = None if dry else open(os.path.join(self.dir, "edl.log"), "a", encoding="utf-8")

    def edl(self, *args, memory=True, check=True):
        cmd = [PY, "edl.py", *args, f"--loader={LOADER}"]
        if memory:
            cmd += ["--memory=ufs"]
        line = " ".join(f'"{c}"' if " " in c else c for c in cmd[1:])
        print(">> edl", line, flush=True)
        if self.dry:
            return 0, ""
        self.log.write(f"\n== {datetime.datetime.now().isoformat()} {line}\n"); self.log.flush()
        env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUTF8="1")
        p = subprocess.Popen(cmd, cwd=EDL_DIR, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             env=env, text=True, encoding="utf-8", errors="replace")
        out = []
        for l in p.stdout:
            sys.stdout.write(l); self.log.write(l); out.append(l)
        rc = p.wait()
        self.log.write(f"== exit {rc}\n"); self.log.flush()
        text = "".join(out)
        if check and rc != 0:
            sys.exit(f"edl failed (exit {rc}); log: {self.dir}")
        return rc, text


def sha(path, length=None):
    h = hashlib.sha256(); left = length
    with open(path, "rb") as f:
        while True:
            n = 1 << 22 if left is None else min(1 << 22, left)
            if n == 0: break
            b = f.read(n)
            if not b: break
            h.update(b)
            if left is not None: left -= len(b)
    return h.hexdigest()


def parse_gpt(blob, hdr_off, arr_off):
    h = blob[hdr_off:hdr_off + 92]
    if h[:8] != b"EFI PART":
        return None
    cur, bak, first, last = struct.unpack_from("<QQQQ", h, 24)
    pe_lba, npe, pesz, pecrc = struct.unpack_from("<QIII", h, 72)
    hh = bytearray(h); hcrc = struct.unpack_from("<I", hh, 16)[0]; struct.pack_into("<I", hh, 16, 0)
    arr = blob[arr_off:arr_off + npe * pesz]
    ents = []
    for i in range(npe):
        e = arr[i * pesz:(i + 1) * pesz]
        if e[:16] == b"\0" * 16: continue
        s, en, a = struct.unpack_from("<QQQ", e, 32)
        ents.append((e[56:128].decode("utf-16le").rstrip("\0"), s, en, a))
    return dict(cur=cur, bak=bak, last=last, hdr_ok=zlib.crc32(bytes(hh)) == hcrc,
                arr_ok=zlib.crc32(arr) == pecrc, ents=ents)


def xmls(efisp):
    lun4 = "flash_lun4.xml" if efisp == "package" else "flash_lun4_keep-efisp.xml"
    raw = ["flash_lun0.xml", "flash_lun1.xml", "flash_lun2.xml", "flash_lun3.xml", lun4, "flash_lun5.xml"]
    return raw, [f"patch{i}.xml" for i in range(6)]


# Images that must be OUR verified copies, not the package's originals (compared by sha256 with patched/).
# init_boot_a: the package's kernelsu.ko only accepts the author's self-signed manager; patched/
# init_boot_a-ksu-official.img (official ksud 3.3.0 boot-patch) is what the tablet runs now (README).
PATCHED = {"init_boot_a.img": os.path.join(HERE, "patched", "init_boot_a-ksu-official.img")}


def manifest_sha(name):
    """Expected sha256 of a patched image from the versioned patched/SHA256SUMS (works without the image)."""
    try:
        for line in open(os.path.join(HERE, "patched", "SHA256SUMS"), encoding="utf-8"):
            parts = line.split()
            if len(parts) == 2 and parts[1].lstrip("*") == "patched/" + name:
                return parts[0]
    except OSError:
        pass
    return None


def check_patched(stop):
    """Refuse (stop=True) or warn when a package image differs from the verified patched copy.
    The reference is the versioned manifest (patched/SHA256SUMS); the image file itself is a convenience
    copy. No reference at all is a failure in stop mode: a flash must not proceed unverified."""
    bad = []
    for fn, src in PATCHED.items():
        dst = os.path.join(IMG, fn)
        want = manifest_sha(os.path.basename(src))
        have = sha(src) if os.path.exists(src) else None
        if want and have and want != have:
            bad.append(fn); print(f"INCONSISTENT reference: {os.path.relpath(src, HERE)} does not match patched/SHA256SUMS"); continue
        ref = want or have
        if not ref:
            bad.append(fn); print(f"NO REFERENCE for {fn}: neither patched/SHA256SUMS nor {os.path.relpath(src, HERE)} is available"); continue
        if not os.path.exists(dst) or sha(dst) != ref:
            bad.append(fn)
            print(f"NOT PATCHED {fn}: package file differs from the verified copy ({ref[:16]}...)")
            print(f"   fix: copy {os.path.relpath(src, HERE)} over {os.path.relpath(dst, HERE)} (keep the original as {fn}.orig)")
        else:
            print(f"patched  {fn} == {ref[:16]}... ({'manifest' if want else 'image file only'})")
    if bad and stop:
        sys.exit("refusing to flash: " + ", ".join(bad) + " is not verified as the KernelSU-patched image; --allow-stock to override")
    return not bad


def check_flash_set(raw):
    """The flash XMLs must carry every REQUIRED label with an existing, non-empty file of the declared size
    (the package is a dump: non-sparse files are exactly num_partition_sectors x 4096). Independent of
    prep_pkg.py: a stale or hand-edited list fails here, not on the tablet."""
    import xml.etree.ElementTree as ET
    seen, problems = set(), []
    for x in raw:
        for p in ET.parse(os.path.join(IMG, x)).getroot().iter("program"):
            lab, fn = p.get("label"), p.get("filename")
            if not fn:
                continue
            f = os.path.join(IMG, fn)
            if not os.path.exists(f):
                problems.append(f"{x}:{lab}: {fn} missing"); continue
            size, sectors = os.path.getsize(f), int(p.get("num_partition_sectors", "0"))
            if size == 0:
                problems.append(f"{x}:{lab}: {fn} is empty")
            elif p.get("sparse", "false") != "true" and size != sectors * SS:
                problems.append(f"{x}:{lab}: {fn} is {size} bytes, XML declares {sectors} sectors ({sectors * SS} bytes)")
            seen.add(lab)
    for lab in sorted(REQUIRED - seen):
        problems.append(f"REQUIRED {lab} is not written by any flash XML")
    return problems


def stage_plan(a):
    import xml.etree.ElementTree as ET
    for p in (PY, LOADER, IMG):
        print(("ok      " if os.path.exists(p) else "MISSING ") + p)
    check_patched(stop=False)
    raw, patch = xmls(a.efisp or "package")
    for prob in check_flash_set(raw): print("PROBLEM", prob)
    total = 0
    for x in raw:
        for p in ET.parse(os.path.join(IMG, x)).getroot().iter("program"):
            fn = p.get("filename")
            if fn and os.path.exists(os.path.join(IMG, fn)): total += os.path.getsize(os.path.join(IMG, fn))
    print(f"bytes to write: {total / 2**30:.2f} GiB")
    g = open(os.path.join(IMG, "gpt_main0.bin"), "rb").read()
    t = parse_gpt(g, SS, 2 * SS)
    for n, s, e, _ in t["ents"][-3:]:
        print(f"  LUN0 {n:<12} {s}..{e}")
    Run("plan", True).edl("qfil", ",".join(raw), ",".join(patch), IMG)


def stage_probe(a):
    r = Run("probe", False)
    os.makedirs(os.path.join(r.dir, "gpt"), exist_ok=True)
    r.edl("getstorageinfo", check=False)
    r.edl("getactiveslot", check=False)
    sizes = {}
    for lun in range(6):
        f = os.path.join(r.dir, "gpt", f"lun{lun}-primary.bin")
        r.edl("rs", "0", "6", f, f"--lun={lun}")
        g = parse_gpt(open(f, "rb").read(), SS, 2 * SS)
        if not g:
            print(f"LUN{lun}: no valid primary GPT"); continue
        n = g["bak"] + 1; sizes[lun] = n
        fb = os.path.join(r.dir, "gpt", f"lun{lun}-backup.bin")
        r.edl("rs", str(n - 5), "5", fb, f"--lun={lun}")
        print(f"LUN{lun}: {n} sectors ({n * SS / 2**30:.2f} GiB) hdrCRC={g['hdr_ok']} arrCRC={g['arr_ok']} entries={len(g['ents'])}")
        if lun == 0:
            for name, s, e, at in g["ents"]:
                print(f"   {name:<16} {s:>11}..{e:<11} {(e - s + 1) * SS / 2**30:8.2f} GiB")
    if 0 in sizes:
        last_usable = sizes[0] - 6
        ok = last_usable > ROOT_START + (8 << 30) // SS
        print(f"LUN0 last usable {last_usable}; baldur-root would be {(last_usable - ROOT_START + 1) * SS / 2**30:.2f} GiB -> {'OK' if ok else 'TOO SMALL'}")
    print("saved to", r.dir)


def stage_backup(a):
    r = Run("backup", False)
    d = os.path.join(r.dir, "backup"); os.makedirs(d, exist_ok=True)
    for p in UNIQUE:
        f = os.path.join(d, f"{p}.img")
        rc, _ = r.edl("r", p, f, check=False)
        print(f"{p}: {'ok ' + sha(f) if rc == 0 and os.path.exists(f) else 'not read (exit %d)' % rc}")
    with open(os.path.join(d, "SHA256SUMS"), "w") as s:
        for f in sorted(os.listdir(d)):
            if f.endswith(".img"): s.write(f"{sha(os.path.join(d, f))}  {f}\n")
    print("saved to", d, "-- copy this folder somewhere else too")


def stage_flash(a):
    if a.efisp not in ("package", "keep"):
        sys.exit("--efisp package|keep is required for flash")
    if not a.yes:
        sys.exit("flash writes the whole tablet; rerun with --yes")
    raw, patch = xmls(a.efisp)
    check_patched(stop=not a.allow_stock)
    problems = check_flash_set(raw)
    if problems:
        sys.exit("flash set incomplete, nothing written:\n  " + "\n  ".join(problems))
    r = Run("flash", False)
    rc, text = r.edl("qfil", ",".join(raw), ",".join(patch), IMG, check=False)
    errs = [l for l in text.splitlines() if "error" in l.lower() or "failed" in l.lower()]
    print("\n".join(errs[-20:]) if errs else "no error lines in edl output")
    print(f"qfil exit {rc}; log {r.dir}")
    if rc != 0:
        sys.exit(1)


def stage_verify(a):
    r = Run("verify", False)
    d = os.path.join(r.dir, "readback"); os.makedirs(d, exist_ok=True)
    items = verify_items(a.efisp or "package", a.super)
    want = set(VERIFY) | ({"efisp"} if (a.efisp or "package") == "package" else set())
    absent = sorted(want - {p for p, _, _ in items})
    if absent:
        # the flash XMLs are built by prep_pkg.py; a label missing there means it was never written
        print("NOT IN FLASH XMLS (never written):", ", ".join(absent))
    written_keep = sorted(set(KEEP) & {p for p, _, _ in items})
    if written_keep:
        print("KEEP labels found in the flash XMLs (they must never be written):", ", ".join(written_keep))
    bad = len(absent) + len(written_keep)
    # kept partitions: unchanged since the backup, and boot_b still the Android boot image
    backups = sorted(b for b in os.listdir(LOGROOT) if b.endswith("-backup") and os.path.isdir(os.path.join(LOGROOT, b, "backup"))) if os.path.isdir(LOGROOT) else []
    bdir = os.path.join(LOGROOT, backups[-1], "backup") if backups else None
    for part in KEEP:
        out = os.path.join(d, part + ".img")
        r.edl("r", part, out, "--lun=0")
        got = sha(out)
        ref = os.path.join(bdir, part + ".img") if bdir else None
        if ref and os.path.exists(ref):
            same = sha(ref) == got
            bad += not same
            print(f"{part:<16} kept  {'OK ' if same else 'CHANGED'} (vs {os.path.relpath(ref, HERE)})")
        else:
            bad += 1
            print(f"{part:<16} kept  NO BACKUP to compare with (run the backup stage before flashing)")
        if part in KEEP_EXPECT:
            exp_f = os.path.join(IMG, KEEP_EXPECT[part]); n = os.path.getsize(exp_f)
            same = sha(out, n) == sha(exp_f)
            bad += not same
            print(f"{part:<16} kept  {'OK ' if same else 'MISMATCH'} (must equal {KEEP_EXPECT[part]}: the Android boot image)")
    for part, lun, fn in items:
        out = os.path.join(d, part + ".img")
        r.edl("r", part, out, f"--lun={lun}")
        src = os.path.join(IMG, fn); n = os.path.getsize(src)
        if fn in PATCHED and os.path.exists(PATCHED[fn]) and sha(src) != sha(PATCHED[fn]):
            print(f"{part:<16} LUN{lun} package file is NOT the patched copy ({os.path.relpath(PATCHED[fn], HERE)})"); bad += 1
        same = sha(out, n) == sha(src)
        bad += not same
        print(f"{part:<16} LUN{lun} {'OK ' if same else 'MISMATCH'} ({n} bytes of {fn} compared)")
        if part == "super": os.remove(out)
    f = os.path.join(d, "lun0-primary.bin")
    r.edl("rs", "0", "6", f, "--lun=0")
    g = parse_gpt(open(f, "rb").read(), SS, 2 * SS)
    if not g:
        print("LUN0: no valid primary GPT"); sys.exit(1)
    print(f"LUN0 GPT hdrCRC={g['hdr_ok']} arrCRC={g['arr_ok']} last_usable={g['last']}")
    for name, s, e, _ in g["ents"][-2:]:
        print(f"   {name:<12} {s}..{e}  {(e - s + 1) * SS / 2**30:.2f} GiB")
    exp = len(g["ents"]) >= 2 and g["ents"][-2][1:3] == (5661480, USERDATA_END) and g["ents"][-1][0] == "baldur-root" \
        and g["ents"][-1][1] == ROOT_START and g["ents"][-1][2] == g["last"]
    # backup GPT (last 5 sectors): header in the last sector, entries in the 4 before it
    fb = os.path.join(d, "lun0-backup.bin")
    n = g["bak"] + 1
    r.edl("rs", str(n - 5), "5", fb, "--lun=0")
    gb = parse_gpt(open(fb, "rb").read(), 4 * SS, 0)
    bak_ok = bool(gb) and gb["hdr_ok"] and gb["arr_ok"] and gb["ents"] == g["ents"]
    print(f"LUN0 backup GPT {'OK (same entries, CRCs good)' if bak_ok else 'BAD or different from primary'}")
    crc_ok = g["hdr_ok"] and g["arr_ok"]
    # every check gates the exit code: a partition mismatch, a wrong layout OR a bad CRC is a failure
    print("LUN0 layout", "as planned" if exp and crc_ok and bak_ok else "NOT as planned")
    print("VERIFY", "PASSED" if not bad and exp and crc_ok and bak_ok else "FAILED")
    sys.exit(0 if not bad and exp and crc_ok and bak_ok else 1)


def stage_setslot(a):
    if not a.yes: sys.exit("setslot writes GPT attributes; rerun with --yes")
    Run("setslot", False).edl("setactiveslot", "a", memory=False)


def stage_reset(a):
    Run("reset", False).edl("reset", "--resetmode=reset", memory=False, check=False)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("stage", choices=["plan", "probe", "backup", "flash", "verify", "setslot", "reset"])
    ap.add_argument("--pkg", choices=sorted(PKGS), help="required for plan/flash/verify")
    ap.add_argument("--efisp", choices=["package", "keep"])
    ap.add_argument("--super", action="store_true", help="verify: also read back the 20 GiB super")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--allow-stock", action="store_true", help="flash: proceed although a PATCHED image is the package original")
    a = ap.parse_args()
    if a.stage in ("plan", "flash", "verify") and not a.pkg:
        sys.exit("--pkg v16|v17 is required for " + a.stage)
    IMG = PKGS.get(a.pkg)
    globals()["stage_" + a.stage](a)
