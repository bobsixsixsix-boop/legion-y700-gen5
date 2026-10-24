#!/usr/bin/env python3
"""Prepare a TB323FU 9008 package for flash_coloros.py (idempotent; originals kept as *.orig).

  python prep_pkg.py v17

- LUN0 GPT (main + backup): userdata fixed at 128 GiB, new last entry `baldur-root` (Linux fs type)
  from the next 1 MiB boundary; patch0.xml's "grow last partition" patches retargeted to it.
- flash_lun{0..5}.xml: the package's rawprogram files minus partitions that hold another
  device's state or that we deliberately keep (see DROP), minus entries whose file is missing.
  ddr is written with zeros (forces DDR retraining, as the stock-style v16 package does).
  Slot B is never written: in the v17 dump xbl_b/abl_b/tz_b/hyp_b/aop_b/modem_b/dsp_b are all
  zeros, and a later fallback to slot B would then loop into 9008. v16 writes slot A only too.
  All-zero images are skipped too (empty partitions on the source device: vm-bootsys_a,
  qtvm_dtbo_a, pvmfw_signed_a in v17), except ddr which is zeroed on purpose.
"""
import os, shutil, struct, sys, uuid, zlib, re

HERE = os.path.dirname(os.path.abspath(__file__))
SS = 4096
USERDATA_SECTORS = 128 * 2**30 // SS
LINUX_TYPE = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")
# baldur-root keeps the exact start and GUID it already has on the tablet (probe 2026-10-11),
# so the Ubuntu root filesystem Codex wrote there survives the flash untouched.
ROOT_GUID = uuid.UUID("a2ce1c90-1d13-4f07-b492-fc7ebc1fa6dd")
ROOT_START = 39476224

# Partitions never written from a package dump: device-unique calibration/identity/security state,
# another device's logs, all-zero placeholders, and the board config table.
DROP = {
    "modemst1", "modemst2", "fsg", "fsc", "fs_bkup",          # modem EFS / RF calibration
    "secdata", "uefivarstore", "spunvm", "keystore",          # attestation, UEFI vars, SPU NV
    "frp", "misc", "ssd", "devinfo", "persist", "oemowninfo",  # FRP, boot control, identity
    "logdump", "logfs", "xbl_sc_logs", "xbl_sc_test_mode",    # logs
    "vm-persist", "qmcs", "mdcompress", "connsec", "tzsc", "dpm",
    "cdt",                                                     # board config data table: never touch
    "qweslicstore_a", "qweslicstore_b",                        # runtime license store (v16 does not write it)
    "ALIGN_TO_128K_1", "ALIGN_TO_128K_2", "rawdump", "last_parti",
    "userdata", "metadata",                                    # formatted in recovery after flashing
}
PKGS = {"v16": "coloros-v9/image", "v17": "coloros-v17/image"}

# Labels a package MUST provide a (non-empty) file for. A dump missing one of these is incomplete,
# and writing the rest would leave mixed firmware on the tablet: stop instead of dropping it.
REQUIRED = {
    "xbl_a", "xbl_config_a", "abl_a", "tz_a", "hyp_a", "aop_a", "aop_config_a", "uefi_a", "uefisecapp_a",
    "keymaster_a", "cpucp_a", "shrm_a", "modem_a", "dsp_a", "devcfg_a", "qupfw_a", "imagefv_a", "multiimgoem_a",
    "boot_a", "init_boot_a", "vendor_boot_a", "dtbo_a", "vbmeta_a", "vbmeta_system_a", "recovery_a", "super",
}


def fix_gpt(img):
    for fn, hdr, arr in (("gpt_main0.bin", 1, 2), ("gpt_backup0.bin", 4, 0)):
        p = os.path.join(img, fn)
        if not os.path.exists(p + ".orig"):
            shutil.copy2(p, p + ".orig")
        d = bytearray(open(p + ".orig", "rb").read())
        ho, ao = hdr * SS, arr * SS
        npe, pesz = struct.unpack_from("<II", d, ho + 80)
        ud = ao + 13 * pesz
        assert d[ud + 56:ud + 128].decode("utf-16le").rstrip("\0") == "userdata"
        start = struct.unpack_from("<Q", d, ud + 32)[0]
        end = start + USERDATA_SECTORS - 1
        struct.pack_into("<Q", d, ud + 40, end)
        rs = ROOT_START
        assert rs > end
        e = ao + 14 * pesz
        assert d[e:e + 128] == b"\0" * 128
        d[e:e + 16] = LINUX_TYPE.bytes_le
        d[e + 16:e + 32] = ROOT_GUID.bytes_le
        struct.pack_into("<QQQ", d, e + 32, rs, rs, 0)
        d[e + 56:e + 128] = "baldur-root".encode("utf-16le").ljust(72, b"\0")
        struct.pack_into("<I", d, ho + 88, zlib.crc32(bytes(d[ao:ao + npe * pesz])))
        struct.pack_into("<I", d, ho + 16, 0)
        struct.pack_into("<I", d, ho + 16, zlib.crc32(bytes(d[ho:ho + 92])))
        open(p, "wb").write(d)
        print(f"{fn}: userdata {start}..{end}, baldur-root from {rs}")
    p = os.path.join(img, "patch0.xml")
    if not os.path.exists(p + ".orig"):
        shutil.copy2(p, p + ".orig")
    x = open(p + ".orig", encoding="utf-8").read()
    n = x.count('byte_offset="1704"')
    assert n == 4, n
    x = x.replace('byte_offset="1704"', 'byte_offset="1832"').replace(
        "last partition 14 'userdata'", "last partition 15 'baldur-root'")
    open(p, "w", encoding="utf-8").write(x)
    print("patch0.xml: 4 patches retargeted to baldur-root")


def all_zero(path):
    """A dump's all-zero image is an empty partition on the source device, not content to copy."""
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 24)
            if not b:
                return True
            if b.count(0) != len(b):
                return False


def flash_xmls(img, raw_names):
    zeros = os.path.join(img, "zeros_ddr.bin")
    problems = []      # (label, reason) for REQUIRED entries that cannot be written
    seen_required = set()
    staged = []        # (path, text): written only once every REQUIRED label is accounted for
    for lun, src in enumerate(raw_names):
        if src is None:
            continue
        out, dropped, kept = [], [], 0
        for line in open(os.path.join(img, src), encoding="utf-8"):
            if "<program" in line:
                lab = re.search(r'label="([^"]*)"', line).group(1)
                fn = re.search(r'filename="([^"]*)"', line).group(1)
                if lab == "ddr":
                    n = int(re.search(r'num_partition_sectors="(\d+)"', line).group(1))
                    if not os.path.exists(zeros) or os.path.getsize(zeros) != n * SS:
                        open(zeros, "wb").write(b"\0" * n * SS)
                    line = line.replace(f'filename="{fn}"', 'filename="zeros_ddr.bin"')
                elif lab in DROP or lab.endswith("_b") or lab == "apdpb"                         or (fn and not os.path.exists(os.path.join(img, fn)))                         or (fn and all_zero(os.path.join(img, fn))):
                    if lab in REQUIRED:
                        problems.append((lab, "file missing" if not fn or not os.path.exists(os.path.join(img, fn)) else "all zero"))
                    dropped.append(lab)
                    continue
                if lab in REQUIRED and fn:
                    seen_required.add(lab)
                kept += bool(fn)
            out.append(line)
        # staged, not published: an incomplete package must not leave a flashable-looking clean set behind
        # (and must not overwrite a good one from an earlier run)
        staged.append((os.path.join(img, f"flash_lun{lun}.xml"), "".join(out)))
        print(f"flash_lun{lun}.xml from {src}: {kept} writes; dropped {sorted(set(dropped))}")
    for lab in sorted(REQUIRED - seen_required):
        if lab not in dict(problems): problems.append((lab, "not in any rawprogram xml"))
    if problems:
        for lab, why in problems: print(f"REQUIRED {lab}: {why}")
        sys.exit("package incomplete: %d required image(s) cannot be written -- no flash XML was written" % len(problems))
    for path, text in staged:          # all checks passed: publish every list (temp file + rename, each one atomic)
        tmp = path + ".tmp"
        open(tmp, "w", encoding="utf-8").write(text)
        os.replace(tmp, path)
    print("published", ", ".join(os.path.basename(p) for p, _ in staged))


if __name__ == "__main__":
    key = sys.argv[1]
    img = os.path.join(HERE, PKGS[key])
    fix_gpt(img)
    if key == "v17":
        flash_xmls(img, [f"rawprogram{i}.xml" for i in range(6)])
    else:
        print("v16: flash_lun*.xml were generated earlier from the stock-style rawprogram files")
