#!/usr/bin/env python3
"""test-flash-verify.py: offline test of flash_coloros.py's verify stage against a fake edl (no tablet, no edl,
no package: a tiny fake package, backup and log root are built in a temp dir).

The fake edl answers `r <label> <out> [--lun=N]` from a label -> LUN table the way the real one does
(edl-win/edlclient/Library/firehose.py getluns / detect_partition): given --lun=N it searches only LUN N and a label
on another LUN is "Couldn't detect partition", exit 1; without --lun it searches every LUN. `rs` returns a primary or
backup LUN0 GPT with the planned layout (userdata to USERDATA_END, then baldur-root to the end) and valid CRCs.

  pass      everything as planned -> VERIFY PASSED, exit 0; abl_b/boot_b (LUN4, like both packages) were read
            without a LUN0 restriction (before the 10-31 fix --lun=0 made the stage exit "edl failed" right there)
  changed   abl_b differs from the pre-flash backup -> "CHANGED", VERIFY FAILED, exit 1. abl_b, not boot_b: boot_b has
            a second check (must equal boot_a.img) that would fail the run on its own, so the backup comparison would
            not be what the test sees (10-31 review)
  listed    a flash XML also writes boot_b -> "KEEP labels found", VERIFY FAILED, exit 1 (before the 10-31 review that
            check only looked at VERIFY labels and could never fire)
The flash stage's checks before anything is written (10-31 audit A5; before it the first two passed and qfil ran):
  unique    a flash list that writes modemst1 or xbl_b -> check_flash_set reports it (another device's RF
            calibration / slot B, which is kept); one that writes metadata and logfs (in DROP, but the v16 list does
            it on purpose) -> no problem
  backup    no backup run, or the newest one older than the newest flash run -> the flash stage refuses and qfil never
            runs; a backup newer than the last flash -> qfil runs
Prints ALL PASS.
"""
import argparse
import gc
import importlib.machinery
import importlib.util
import io
import os
import shutil
import struct
import sys
import tempfile
import uuid
import zlib
from contextlib import redirect_stdout

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)                    # flash_coloros imports prep_pkg (REQUIRED) from the repo root
loader = importlib.machinery.SourceFileLoader("fc", os.path.join(REPO, "flash_coloros.py"))
fc = importlib.util.module_from_spec(importlib.util.spec_from_loader("fc", loader))
loader.exec_module(fc)
FAILS = []
SS = fc.SS
LAST = fc.ROOT_START + 1000                 # last usable LBA of the fake LUN0


def check(what, cond, info=""):
    print(("PASS " if cond else "FAIL ") + what + ("" if cond else f"  {info!r}"))
    if not cond:
        FAILS.append(what)


def gpt(primary):
    """6 sectors (primary: header at LBA1, entries at LBA2) or 5 (backup: entries, then the header last)."""
    ents = [("userdata", 5661480, fc.USERDATA_END), ("baldur-root", fc.ROOT_START, LAST)]
    arr = bytearray(128 * 128)
    for i, (name, s, e) in enumerate(ents):
        struct.pack_into("<16s16sQQQ72s", arr, i * 128, uuid.uuid4().bytes, uuid.uuid4().bytes, s, e, 0,
                         name.encode("utf-16le"))
    h = bytearray(92)
    struct.pack_into("<8sII", h, 0, b"EFI PART", 0x10000, 92)
    struct.pack_into("<QQQQ", h, 24, 1 if primary else LAST + 6, LAST + 6 if primary else 1, 6, LAST)
    struct.pack_into("<QIII", h, 72, 2 if primary else LAST + 2, 128, 128, zlib.crc32(arr))
    struct.pack_into("<I", h, 16, zlib.crc32(bytes(h)))
    hdr = bytes(h) + bytes(SS - 92)
    return (bytes(SS) + hdr + bytes(arr) + bytes(SS * 2)) if primary else (bytes(arr) + hdr)


def setup(tmp, abl_b_changed=False, keep_listed=False):
    img, logs = os.path.join(tmp, "image"), os.path.join(tmp, "flash-logs")
    os.makedirs(img)
    where = {"abl_b": 4, "boot_b": 4}       # both packages: rawprogram4.xml, physical_partition_number="4"
    progs = {n: [] for n in range(6)}
    for i, lab in enumerate(fc.VERIFY + ["efisp"]):
        lun = 1 if lab == "xbl_a" else 4
        where[lab] = lun
        fn = f"{lab}.img"
        with open(os.path.join(img, fn), "wb") as f:
            f.write(bytes([i + 1]) * SS)
        progs[lun].append(f'<program label="{lab}" filename="{fn}" physical_partition_number="{lun}" '
                          f'num_partition_sectors="1" sparse="false"/>')
    if keep_listed:
        progs[4].append('<program label="boot_b" filename="boot_b.img" physical_partition_number="4" '
                        'num_partition_sectors="1" sparse="false"/>')
    for x in ("flash_lun0.xml", "flash_lun1.xml", "flash_lun2.xml", "flash_lun3.xml", "flash_lun4.xml",
              "flash_lun4_keep-efisp.xml", "flash_lun5.xml"):
        lun = int(x[9])
        with open(os.path.join(img, x), "w", encoding="utf-8") as f:
            f.write("<data>" + "".join(progs[lun]) + "</data>")
    content = {lab: open(os.path.join(img, f"{lab}.img"), "rb").read() for lab in fc.VERIFY + ["efisp"]}
    content["abl_b"] = b"\x7a" * SS
    content["boot_b"] = content["boot_a"] + bytes(SS)     # Android boot: the package's boot_a.img, then padding
    bk = os.path.join(logs, "20261101-000000-backup", "backup")
    os.makedirs(bk)
    for lab in fc.KEEP:
        with open(os.path.join(bk, f"{lab}.img"), "wb") as f:
            f.write(content[lab])
    if abl_b_changed:
        content["abl_b"] = bytes(SS)          # the v17 dump's abl_b is all zeros
    return img, logs, where, content


def fake_edl(where, content, calls):
    def edl(self, *args, memory=True, check=True):
        calls.append(args)
        lun = next((int(a.split("=", 1)[1]) for a in args if a.startswith("--lun=")), None)
        rc = 0
        if args[0] == "r":
            lab, out = args[1], args[2]
            if lab not in where or (lun is not None and lun != where[lab]):
                rc = 1                      # real edl: "Couldn't detect partition: <lab>", exit 1
            else:
                with open(out, "wb") as f:
                    f.write(content[lab])
        elif args[0] == "rs":
            with open(args[3], "wb") as f:
                f.write(gpt(args[1] == "0"))
        if check and rc:
            sys.exit(f"edl failed (exit {rc}); log: {self.dir}")
        return rc, ""
    return edl


def verify(**kw):
    tmp = tempfile.mkdtemp(prefix="flash-verify-")
    saved = fc.IMG, fc.LOGROOT, fc.PATCHED, fc.Run.edl
    calls, buf = [], io.StringIO()
    try:
        img, logs, where, content = setup(tmp, **kw)
        fc.IMG, fc.LOGROOT, fc.PATCHED = img, logs, {}
        fc.Run.edl = fake_edl(where, content, calls)
        code = None
        with redirect_stdout(buf):
            try:
                fc.stage_verify(argparse.Namespace(efisp="package", super=False))
            except SystemExit as e:
                code = e.code
        return code, buf.getvalue(), calls
    finally:
        fc.IMG, fc.LOGROOT, fc.PATCHED, fc.Run.edl = saved
        gc.collect()                            # Run holds edl.log open; let it close before removing (Windows)
        shutil.rmtree(tmp, ignore_errors=True)


code, out, calls = verify()
check("pass: everything as planned -> VERIFY PASSED, exit 0", code == 0 and "VERIFY PASSED" in out, (code, out[-400:]))
kept = [c for c in calls if c[0] == "r" and c[1] in fc.KEEP]
check("pass: abl_b and boot_b were read without a --lun restriction",
      len(kept) == 2 and not any(a.startswith("--lun=") for c in kept for a in c), kept)
check("pass: both kept partitions compared OK and boot_b is the Android boot image",
      out.count("kept  OK") == 3, out)

code, out, _ = verify(abl_b_changed=True)
check("changed: abl_b differs from the backup -> CHANGED, VERIFY FAILED, exit 1 (only that check fails)",
      code == 1 and "abl_b            kept  CHANGED" in out and "VERIFY FAILED" in out
      and "MISMATCH" not in out and out.count("kept  OK") == 2, (code, out[-400:]))

code, out, _ = verify(keep_listed=True)
check("listed: a flash XML writes boot_b -> KEEP labels found, VERIFY FAILED, exit 1",
      code == 1 and "KEEP labels found in the flash XMLs" in out and "boot_b" in out and "VERIFY FAILED" in out,
      (code, out[-400:]))


def flash_set(img, extra=()):
    """A complete flash list: every REQUIRED label (plus extra) in flash_lun0.xml with a one-sector file."""
    os.makedirs(img)
    progs = []
    for lab in sorted(fc.REQUIRED) + list(extra):
        with open(os.path.join(img, f"{lab}.img"), "wb") as f:
            f.write(bytes(SS))
        progs.append(f'<program label="{lab}" filename="{lab}.img" physical_partition_number="0" '
                     f'num_partition_sectors="1" sparse="false"/>')
    for x in fc.xmls("package")[0]:
        with open(os.path.join(img, x), "w", encoding="utf-8") as f:
            f.write("<data>" + ("".join(progs) if x == "flash_lun0.xml" else "") + "</data>")


def problems(extra):
    tmp = tempfile.mkdtemp(prefix="flash-set-")
    saved = fc.IMG
    try:
        fc.IMG = os.path.join(tmp, "image")
        flash_set(fc.IMG, extra)
        return fc.check_flash_set(fc.xmls("package")[0])
    finally:
        fc.IMG = saved
        shutil.rmtree(tmp, ignore_errors=True)


p = problems([])
check("unique: a complete flash list has no problem", p == [], p)
p = problems(["metadata", "logfs"])
check("unique: metadata and logfs (written by the v16 list on purpose) are no problem", p == [], p)
for lab in ("modemst1", "xbl_b"):
    p = problems([lab])
    check(f"unique: a flash list that writes {lab} is refused", len(p) == 1 and lab in p[0], p)


def flash(backups, flashes):
    tmp = tempfile.mkdtemp(prefix="flash-stage-")
    saved = fc.IMG, fc.LOGROOT, fc.PATCHED, fc.Run.edl
    calls, buf = [], io.StringIO()
    try:
        img, logs = os.path.join(tmp, "image"), os.path.join(tmp, "flash-logs")
        flash_set(img)
        for t in backups:
            os.makedirs(os.path.join(logs, f"{t}-backup", "backup"))
        for t in flashes:
            os.makedirs(os.path.join(logs, f"{t}-flash"))
        os.makedirs(logs, exist_ok=True)
        fc.IMG, fc.LOGROOT, fc.PATCHED = img, logs, {}
        fc.Run.edl = fake_edl({}, {}, calls)
        code = None
        with redirect_stdout(buf):
            try:
                fc.stage_flash(argparse.Namespace(efisp="package", yes=True, allow_stock=False))
            except SystemExit as e:
                code = e.code
        return code, calls
    finally:
        fc.IMG, fc.LOGROOT, fc.PATCHED, fc.Run.edl = saved
        gc.collect()
        shutil.rmtree(tmp, ignore_errors=True)


code, calls = flash([], [])
check("backup: no backup run -> refused, qfil not run",
      isinstance(code, str) and "no backup since the last flash" in code and not calls, (code, calls))
code, calls = flash(["20261011-015806"], ["20261011-020021"])
check("backup: the newest backup is older than the newest flash -> refused, qfil not run",
      isinstance(code, str) and "no backup since the last flash" in code and not calls, (code, calls))
code, calls = flash(["20261011-015806", "20261101-000000"], ["20261011-020021"])
check("backup: a backup newer than the last flash -> qfil runs", code is None and [c[0] for c in calls] == ["qfil"],
      (code, calls))

print("ALL PASS" if not FAILS else f"{len(FAILS)} FAILED: {FAILS}")
sys.exit(1 if FAILS else 0)
