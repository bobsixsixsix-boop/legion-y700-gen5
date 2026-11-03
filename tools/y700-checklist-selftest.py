#!/usr/bin/env python3
"""y700-checklist-selftest: runs tools/y700-checklist.py's main() end to end on the PC (no tablet), against a fake
root directory, so every check - the closures for the CX knobs, the flight recorder and the rawdump partition
included - is exercised with controlled data and the exit code is asserted. The script's `os`, `glob`, `open`
and `run` are replaced by proxies that map "/..." paths into a temporary directory, fake file ctimes (pstore
freshness is judged by ctime, which Windows cannot set) and answer systemctl / journalctl / dpkg from a scenario
table. The real 03:41 crash log (linux/power/cx-collapse/crash-0341-lastkmsg.log) is the console / lastkmsg text.
    python -X utf8 -I tools/y700-checklist-selftest.py            (from the y700 repo; args: [checklist.py] [kmsg.log])
Scenarios: warm reset after a crash, cold cut, panic record then a clean reboot, a reset in an earlier boot since the
last --save (10-31), first run without checked_at,
knob left on with/without a y700-cx-exp unit, rawdump first/same/rewritten/erased/unreadable, recorder dead /
stale / not installed, everything fine (exit 0), a check that raises (one WARN, run continues), systemd-pstore
archived but no console/pmsg, systemctl unanswerable (fallback threshold, with and without a checked_at and after a
7 h dump-mode sit), wireless CarPlay (launcher absent / idle with the chip probe / busy without it / each WARN), the
LIVI version baseline, the refresh-rate daemon's D-Bus status, the volume keys' kded6 wait and whether armed E3a
actually reaches the system domain. The fake root's files are owned by root (st_uid 0) and keep Windows modes unless
a scenario sets MODE / UID. 2026-10-16, CarPlay
2026-10-17, refresh rate / volume keys / E3a effect 2026-10-18. The battery page (y700-batteryd's restarts against
the baseline, the ledger's age and size, flightrec's energy line with torn reads, the report's diag) 2026-10-30. Kernel
y16's SDI-disable line and the watchdog bark in a console tail 2026-11-01; kernel y17's boot-time e2fsck results per
boot and the root's ext4 state 2026-11-01."""
import builtins, contextlib, glob as realglob, hashlib, importlib.util, io, json, os as realos, re, shutil, struct, sys, tempfile, time, types

HERE = realos.path.dirname(realos.path.abspath(__file__))
SCRIPT = sys.argv[1] if len(sys.argv) > 1 else realos.path.join(HERE, "y700-checklist.py")
KMSG = sys.argv[2] if len(sys.argv) > 2 else realos.path.join(HERE, "..", "linux", "power", "cx-collapse", "crash-0341-lastkmsg.log")
ROOT = tempfile.mkdtemp(prefix="y700-checklist-selftest-")
NOW = time.time()
BOOT8, PREV8 = "e2b6380a", "baa113c4"
BOOT_ID = "e2b6380a-0542-403a-a632-1b6c2be6e3a5"
PREV_ID, CUR_ID = f"{PREV8}fe0f487ebfd5c6c625f3b791", f"{BOOT8}0542403aa6321f6b2ce6e3a5"
KERNEL = "7.3.0-rc4-tb323fu-t49-y9"
LC_VER = "0.7.0-1ubuntu2+y700.1"                      # libcamera with our AF + lens patches (S30)
CTIME, LINKS, S, MODE, UID = {}, {}, {}, {}, {}
LIVI_SRC = realos.path.join(HERE, "..", "linux", "carplay", "livi")
KDED6_WAIT = "/etc/systemd/user/plasma-kded6.service.d/y700-wait-tuned-sink.conf"
DRIRC_SRC = realos.path.join(HERE, "..", "linux", "gpu", "drirc")
# the tablet's powerdevilrc / kscreenlockerrc as of 10-24 16:45 (熄屏不锁屏), and the powerdevilrc of that morning
PDRC_GOOD = ("[AC][Display]\nDimDisplayWhenIdle=false\nLockBeforeTurnOffDisplay=false\nTurnOffDisplayWhenIdle=false\n\n"
             "[AC][SuspendAndShutdown]\nAutoSuspendAction=0\nPowerButtonAction=128\n\n"
             "[Battery][Display]\nDimDisplayIdleTimeoutSec=120\nLockBeforeTurnOffDisplay=false\nTurnOffDisplayIdleTimeoutSec=300\n\n"
             "[Battery][SuspendAndShutdown]\nAutoSuspendAction=0\nAutoSuspendIdleTimeoutSec=1800\nPowerButtonAction=128\n\n"
             "[BatteryManagement]\nBatteryCriticalAction=8\n\n"
             "[LowBattery][Display]\nDimDisplayIdleTimeoutSec=60\nLockBeforeTurnOffDisplay=false\nTurnOffDisplayIdleTimeoutSec=120\n\n"
             "[LowBattery][SuspendAndShutdown]\nAutoSuspendAction=0\nPowerButtonAction=128\n")
PDRC_1015 = ("[AC][Display]\nDimDisplayWhenIdle=false\nTurnOffDisplayWhenIdle=false\n\n"
             "[AC][SuspendAndShutdown]\nAutoSuspendAction=0\nPowerButtonAction=128\n\n"
             "[Battery][SuspendAndShutdown]\nAutoSuspendAction=0\nAutoSuspendIdleTimeoutSec=1800\nPowerButtonAction=128\n\n"
             "[BatteryManagement]\nBatteryCriticalAction=8\n\n"
             "[LowBattery][SuspendAndShutdown]\nAutoSuspendAction=0\nPowerButtonAction=128\n")
KLRC_GOOD = "[Daemon]\nAutolock=false\nLockOnResume=false\n"
# journalctl --list-boots -o json as systemd 259 prints it (gpu_hangs' boot labels and retention, 10-23)
BOOTS_JSON = [{"index": -1, "boot_id": PREV_ID, "first_entry": int((NOW - 3 * 86400) * 1e6), "last_entry": int((NOW - 5000) * 1e6)},
              {"index": 0, "boot_id": CUR_ID, "first_entry": int((NOW - 5000) * 1e6), "last_entry": int(NOW * 1e6)}]


def tr(p):
    """POSIX absolute path -> its place under the fake root."""
    if isinstance(p, str) and p.startswith("/"):
        return realos.path.join(ROOT, *p.strip("/").split("/"))
    return p


def untr(p):
    return "/" + realos.path.relpath(p, ROOT).replace("\\", "/").rstrip("/")


class PathProxy:
    def __getattr__(self, n):
        return getattr(realos.path, n)
    exists = staticmethod(lambda p: realos.path.exists(tr(p)))
    isfile = staticmethod(lambda p: realos.path.isfile(tr(p)))
    isdir = staticmethod(lambda p: realos.path.isdir(tr(p)))
    islink = staticmethod(lambda p: p in LINKS)
    getsize = staticmethod(lambda p: realos.path.getsize(tr(p)))
    getmtime = staticmethod(lambda p: realos.path.getmtime(tr(p)))
    realpath = staticmethod(lambda p: LINKS.get(p, p))


class OsProxy:
    path = PathProxy()

    def __getattr__(self, n):
        return getattr(realos, n)

    def stat(self, p):
        st = realos.stat(tr(p))
        return types.SimpleNamespace(st_ctime=CTIME.get(p, st.st_mtime), st_mtime=st.st_mtime, st_size=st.st_size,
                                     st_mode=MODE.get(p, st.st_mode), st_uid=UID.get(p, 0))  # Windows has no root / POSIX modes
    lstat = stat                        # links only exist as LINKS here

    def readlink(self, p):
        if p in LINKS:
            return LINKS[p]
        raise OSError(22, "not a link", p)

    def makedirs(self, p, exist_ok=False):
        realos.makedirs(tr(p), exist_ok=exist_ok)

    def replace(self, a, b):
        realos.replace(tr(a), tr(b))

    def uname(self):
        return types.SimpleNamespace(release=KERNEL)

    def listdir(self, p):
        return realos.listdir(tr(p))


class GlobProxy:
    @staticmethod
    def glob(pat):
        return [untr(r) for r in realglob.glob(tr(pat))]


FAILOPEN = {}                                         # path -> exception the next open() of it raises (S19)
FLAKY = {}                                            # path -> the bytes successive open()s of it return (S33: torn reads)


def fopen(p, mode="r", *a, **k):
    if p in FAILOPEN:
        raise FAILOPEN[p]
    if FLAKY.get(p):
        return io.BytesIO(FLAKY[p].pop(0))
    if "b" not in mode and "encoding" not in k:
        k["encoding"] = "utf-8"
    return builtins.open(tr(p), mode, *a, **k)


def put(path, data, ctime=None, mtime=None):
    real = tr(path)
    realos.makedirs(realos.path.dirname(real), exist_ok=True)
    with builtins.open(real, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())
    if mtime is not None:
        realos.utime(real, (mtime, mtime))
    if ctime is not None:
        CTIME[path] = ctime


spec = importlib.util.spec_from_file_location("checklist", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.os, mod.glob, mod.open = OsProxy(), GlobProxy(), fopen

KMSG_TEXT = builtins.open(KMSG, "rb").read()
REC_LINE = ("t=5120.0 at=03:41:02 up=5120.0 bat=+420mW dpms=Off wifi=up/+3 gov=teo aco=Y aso=- dl=off busy=1.2 ctxt=409 "
            "irqt=310 irq=arch_timer:160,IPI1:86,ce2:40 c0=wfi:100,ret:50,rej:10 c1=wfi:20,ret:5,rej:0 "
            "pd=cl0:0/58,cl1:0/42,sys:0/0 qs=apss:0/+0,cxsd:0/+0,aosd:0/+0,ddr:0/+0\n")
REC_LOG = (f"HEADER boot={PREV8} at=2026-10-16 03:00:00 kernel={KERNEL} interval=1.0 sync=5 pstore_archived=7 aco=N aso=- dl=off\n"
           + REC_LINE * 40 + "MARK t=5100.0 at=03:40:40 E1 start 30min\n" + REC_LINE * 20)


def refresh_status(**kw):
    """y700-refresh-auto's status() as `gdbus call` prints it: a (s) tuple holding json.dumps of the daemon's state
    (GVariant text quotes a string without ' in single quotes, which is all this JSON ever is)."""
    d = {"base_hz": 120, "cur_hz": 120, "expected_hz": None, "video_target": None, "active": ["org.kde.konsole", False, 2310],
         "players": {}, "manual": False, "locked": False, "touch_age_s": 41.2, "touch_attached": True,
         "shielded_touches": 0, "backoff": False}
    d.update(kw)
    return f"('{json.dumps(d)}',)"


def fake_gpu_journal(c):
    """gpu_hangs' `{ journalctl _TRANSPORT=kernel {--since @T | -b 0} -g RE -o json ...; echo rc=$?; } | tail -n N` over
    S["kernel_journal"] = [(epoch s, boot id, message)], with journalctl's own filtering (since / this boot, grep), its
    exit codes (1 and no output when nothing matched) and the tail. S["gpu_journal"] answers as is instead."""
    if "gpu_journal" in S:
        return S["gpu_journal"]
    m = re.search(r"--since @(\d+)", c)
    assert (m or "-b 0" in c) and " -n " not in c.split("|")[0], c     # -n with --since and -g prints nothing (systemd 259)
    rows = [r for r in S.get("kernel_journal", []) if (r[0] >= int(m.group(1)) if m else r[1] == CUR_ID)]
    rows = [r for r in rows if re.search(mod.GPU_HANG_GREP, r[2])]
    out = [json.dumps({"__REALTIME_TIMESTAMP": str(int(t * 1e6)), "_BOOT_ID": b, "MESSAGE": msg}) for t, b, msg in rows]
    out.append("rc=0" if rows else "rc=1")
    return "\n".join(out[-int(re.search(r"\| tail -n (\d+)", c).group(1)):])


# check_xft_dpi (10-29): the live Xwayland resource database as `xrdb -query; echo xrdb-rc=$?` prints it on 10-29 after
# the fix, and the session env `systemctl --user show-environment` gives
XRDB_GOOD = "*customization:\t-color\nXcursor.size:\t45\nXcursor.theme:\tbreeze_cursors\nXft.dpi:\t182\nxrdb-rc=0"
SD_ENV = "DISPLAY=:0\nLANG=zh_CN.UTF-8\nWAYLAND_DISPLAY=wayland-0\nXAUTHORITY=/run/user/1000/xauth_qGEGkm\nXDG_SESSION_TYPE=wayland"


# y700-battery-report --json as the checklist sees it (S33): the diag block of DESIGN.md 6b.a, everything below every
# threshold; the rest of the document is not read by the checklist. The screen-off pair is like with like (10-30
# review): the measured P25 of the >= 20 min screen-off segments and the model's power for the same segments, F_off
# (147) + wakeups (~103 mW at 150/s) + a little CPU, so both near 250 mW - never F_off alone
REPORT_DIAG = {"unexplained_median_7d": 0.08, "floor_off_learned_mw": 252.0, "floor_off_model_mw": 240.0, "coeff_age_days": 12,
               "ledger_bytes": 2400000, "ledger_newest_age_s": 120, "energy_age_s": 4, "segments_flagged_7d": 0}


def report_doc(coeffs=None, **diag):
    d = dict(REPORT_DIAG)
    d.update(diag)
    return json.dumps({"v": 1, "now": int(NOW), "tz_offset_min": 540, "coeffs": coeffs or {"version": 2, "calibrated": True,
                       "date": "2026-10-18", "source": "user"}, "diag": d}, ensure_ascii=False, separators=(",", ":"))


def fake_run_rc(cmd, user=False, timeout=20):
    """run_rc(): the report (check_battery_diag, 10-30) answers from S - stdout "report", exit status "report_rc"
    (None = run_rc's backstop timeout), stderr "report_err" - and records who ran it, how, for how long"""
    if "/usr/local/bin/y700-battery-report" in cmd:
        S.setdefault("report_calls", []).append((cmd, user, timeout))
        rc = S.get("report_rc", 0)
        return rc, "" if rc is None else S.get("report", report_doc()), S.get("report_err", "")
    return 0, fake_run(cmd, user, timeout), ""


def fake_run(cmd, user=False, timeout=20):
    c = " ".join(cmd)
    if cmd[0] == "cat":
        try:
            return builtins.open(tr(cmd[1]), encoding="utf-8").read().strip()
        except OSError:
            return ""
    if cmd[0] == "pidof":
        return S.get("pids", {}).get(cmd[1], "")
    if cmd[0] == "dpkg-query":
        return S.get("pkgs", {}).get(cmd[-1], "1.0")
    if c.startswith("journalctl --list-boots -o json"):
        return S.get("boots_json", json.dumps(BOOTS_JSON))
    if c.startswith("journalctl --list-boots"):
        return (f"-1 {PREV_ID} Tue 2026-07-28 05:44:02 JST Thu 2026-10-16 03:41:05 JST\n"
                f" 0 {CUR_ID} Tue 2026-07-28 05:44:02 JST Thu 2026-10-16 10:00:00 JST")
    m = re.match(r"journalctl -b (\S+) -n (300|1) ", c)
    if m:                 # how a boot ended: S["journal_tails"] per boot id (S2x), else S["journal_tail"] (the previous boot's)
        S.setdefault("ended_asked", []).append(m.group(1))
        if m.group(2) == "1":
            return "2026-10-16T03:41:05+0900 baldur kernel: arm-scmi timed out"
        return S.get("journal_tails", {}).get(m.group(1), S.get("journal_tail", "kernel: something\nkernel: last line"))
    if cmd[:3] == ["journalctl", "-k", "-b"] and "SDI disable: " in cmd:   # the download_mode check, y16's 1058 line (11-01)
        S.setdefault("sdi_asked", []).append(c)
        return S.get("sdi_log", "")
    if cmd[:3] == ["journalctl", "-k", "-b"] and mod.FSCK_GREP in cmd:   # check_bootfsck (11-01): per boot id, "0" = this one
        S.setdefault("fsck_asked", []).append(cmd[3])
        return S.get("fsck_logs", {}).get(cmd[3], "")
    if cmd[:3] == ["findmnt", "-no", "SOURCE"]:
        return S.get("rootdev", "/dev/sda15")
    if cmd[0] == "tune2fs":
        return S.get("tune2fs", "Filesystem state:         clean\n")
    if c.startswith("systemctl show -a --timestamp=unix"):
        return S.get("pstore_show", "LoadState=loaded\nConditionResult=yes\nExecMainStartTimestamp=")
    if cmd[0] == "/usr/local/libexec/y700-kmsg-watch":
        return S.get("kmsg_watch", "selftest 1-1 ok wifi=0 display=0; up 600 s, records 12, lost 0, overruns 0, "
                                   "matches wifi=0 display=2, starts wifi=2 display=3, failed starts wifi=0 display=0")
    if cmd[0] == "/usr/local/sbin/y700-kwin-uclamp":
        st = S.get("kwin_uclamp", "kwin_wayland 2901: 13 threads, 0 below 512: uclamp.min " + "512 " * 13)
        return st.pop(0) if isinstance(st, list) else st     # a list: one answer per call (the 6 s recheck)
    if cmd[:2] == ["systemctl", "is-active"] or cmd[:3] == ["systemctl", "--user", "is-active"]:
        return S.get("active", {}).get(cmd[-1], "active")
    if cmd[:2] == ["systemctl", "is-enabled"] or cmd[:3] == ["systemctl", "--user", "is-enabled"]:
        return S.get("enabled", {}).get(cmd[-1], "enabled")
    if cmd[:2] == ["systemctl", "--failed"]:            # check_failed_units (10-22)
        return S.get("failed_sys", "")
    if cmd[:3] == ["systemctl", "--user", "--failed"]:
        return S.get("failed_user", "")
    if cmd[:2] == ["systemctl", "list-units"]:
        return S.get("cx_units", "")
    if cmd[:3] == ["systemctl", "--user", "show"] and "NRestarts" in cmd:
        return S.get("nrestarts", {}).get(cmd[-1], "0")
    if cmd[:2] == ["systemctl", "show"] and "NRestarts" in cmd:   # system units (check_gamepad_screen, 11-03)
        return S.get("nrestarts", {}).get(cmd[-1], "0")
    if cmd[0] == "busctl" and "isScriptLoaded" in cmd and "y700-home" in cmd:
        return S.get("home_loaded", "b true")
    if cmd[0] == "busctl" and "isEffectLoaded" in cmd and "y700-taskswitcher" in cmd:
        return S.get("ts_loaded", "b true")
    if cmd[0] == "busctl" and "isEffectLoaded" in cmd and "blur" in cmd:
        return S.get("blur_loaded", "b true")
    if cmd[0] == "busctl" and "isScriptLoaded" in cmd and "y700-edge" in cmd:
        return S.get("edge_loaded", "b true")
    if cmd[0] == "busctl" and cmd[-1] == "list":           # who holds the notification service (check_shellbar, 10-22)
        return S.get("bus_list", "org.freedesktop.Notifications - - - (activatable) - -\n"
                                 "org.freedesktop.Notifications 4321 y700-shellbar user :1.9 y700-shellbar.service - -")
    if cmd[0] == "busctl":
        return "b true"
    if cmd[0] == "kreadconfig6":                         # per key (S["kread"]), else one answer for all
        return S.get("kread", {}).get(cmd[cmd.index("--key") + 1], S.get("kreadconfig", "true"))
    if cmd[0] == "sh" and "y700-home: bottom edge" in c:
        return S.get("home_edge", "y700-home: bottom edge on")
    if cmd[0] == "sh" and "y700-taskswitcher: bottom edge" in c:
        return S.get("ts_edge", "y700-taskswitcher: bottom edge on")
    if cmd[0] == "sh" and "y700-taskswitcher: loaded" in c:
        return S.get("ts_build", "y700-taskswitcher: loaded 6.6.5-0ubuntu0.1+abc123")
    if cmd[0] == "sh" and "app quit: StartUnit failed" in c:   # check_appquit (10-31): failures this boot
        return S.get("aq_fails", "0")
    if cmd[0] == "sh" and "-u y700-gamepad-screen" in c:   # check_gamepad_screen (11-01): failures this boot
        return S.get("gs_fails", "0")
    if cmd[0] == "sh" and "pulse event connection" in c:   # check_speaker_guard (11-03): its last word on the events
        return S.get("sg_conn", "watching the default output, the speaker sinks and their streams")
    if cmd[0] == "sh" and "-u y700-refresh-auto" in c:    # check_refresh_auto (11-03): its last word on KWin's events
        return S.get("ra_kwin", "watching KWin screen events")
    if cmd[0] == "sh" and "KWin screen events" in c:      # check_autobright (11-03): its last word on KWin's events
        return S.get("ab_kwin", "watching KWin screen events")
    if cmd[0] == "sh" and "-u plasma-kded6" in c:        # y700-wait-tuned-sink's last line, from kded6's ExecStartPre
        return S.get("kded6_wait", "tuned sink is the default after 2.25 s")
    if cmd[0] == "sh" and "restarting plasma-kded6" in c:
        return S.get("kded6_heals", "0")
    if cmd[0] == "sh" and "sample failed" in c:          # check_hud: sampling panics this boot
        return S.get("hud_fails", "0")
    if cmd[0] == "sh" and "offending task:" in c:        # gpu_hangs (10-23)
        return fake_gpu_journal(c)
    if cmd[0] == "sh" and "dpkg --compare-versions" in c:   # check_libcamera: Ubuntu's candidate newer than ours (10-29)
        return S.get("lc_newer", "")
    if cmd[0] == "sh":
        return "0"
    if cmd[:2] == ["apt-mark", "showhold"]:
        return S.get("holds", "gstreamer1.0-libcamera\nlibcamera-ipa\nlibcamera-tools\nlibcamera-v4l2\nlibcamera0.7")
    if cmd[:4] == ["env", "LC_ALL=C", "apt-cache", "policy"]:
        return S.get("lc_policy", f"libcamera0.7:\n  Installed: {LC_VER}\n  Candidate: {LC_VER}\n  Version table:\n")
    if cmd[0] == "env" and cmd[-1] == "xrdb -query; echo xrdb-rc=$?":   # check_xft_dpi: the live Xwayland database (10-29)
        S.setdefault("xrdb_calls", []).append(c)
        return S.get("xrdb", XRDB_GOOD)
    if cmd[:3] == ["systemctl", "--user", "show-environment"]:
        return S.get("sd_env", SD_ENV)
    if cmd[0] == "gdbus" and "fyi.y700.RefreshAuto.status" in cmd:
        return S.get("refresh_status", refresh_status())
    if cmd[0] == "gdbus" and "org.kde.Solid.PowerManagement.PolicyAgent.HasInhibition" in cmd:
        return S.get("has_inhibition", "(true,)")
    if cmd[0] == "pgrep" and "y700-carplay --while-frames" in cmd:   # keep_awake's holder under kde-inhibit
        return S.get("holder", "")
    if cmd[0] == "ps" and "etimes=" in cmd:
        return S.get("held_s", "")
    if cmd[0] == "ss":                                   # Android Auto's session on 5277 (keep_awake, 10-20)
        return S.get("aa_ss", "")
    if cmd[:4] == ["iw", "dev", "wlp1s0", "link"]:      # power save's pending mark (10-24)
        return S.get("iw_link", "Connected to 02:00:00:aa:bb:cc (on wlp1s0)\n\tSSID: HOME_6G")
    if cmd[0] == "iw":
        return S.get("power_save", "Power save: on")
    if cmd[0] == "gsettings":
        return "'icon:minimize,maximize,close'"
    if cmd[0] == "modinfo":
        return "y700-1041"
    return ""


mod.run, mod.run_rc = fake_run, fake_run_rc
mod.mono_s = lambda: S.get("mono", 5000.0)            # CLOCK_MONOTONIC: no clock_gettime on Windows (S33)


def rawdump_image(kmsg, rst=b"\x01\x00\x00\x00\x40\x00\x00\x00", pon=b"\x80\x00\x00\x01" * 4):
    """A Raw_Dmp! header laid out as rawdump-ls.py reads it: 64-byte records from 0x38, the name at +0x2c."""
    secs = [("OCIMEM.BIN", b"\xaa" * 64), ("RST_STAT.BIN", rst), ("PMIC_PON.BIN", pon), ("lastkmsg.log", kmsg)]
    hdr = bytearray(0x2000)
    hdr[:8] = b"Raw_Dmp!"
    struct.pack_into("<IIIIIIII", hdr, 8, 0x2000, 1, 0, len(secs), 0, 0, 0, 0)
    body, off, data_off = bytearray(), 0x38, 0x2000
    for name, data in secs:
        struct.pack_into("<IIIQQQQ", hdr, off, 0, 1, 2, data_off + len(body), len(data), 0x14680000, 0)
        hdr[off + 0x2c:off + 0x2c + len(name)] = name.encode()
        body += data + b"\0" * (-len(data) % 16)
        off += 0x40
    return bytes(hdr) + bytes(body)


def base_tree(download_mode="off", aco="N", aso="N", recorder=True):
    """A tablet where every legacy check passes; the crash-forensics inputs are added per scenario."""
    shutil.rmtree(ROOT, ignore_errors=True)
    CTIME.clear(); LINKS.clear(); S.clear(); MODE.clear(); UID.clear(); FLAKY.clear()
    put("/proc/sys/kernel/random/boot_id", BOOT_ID + "\n")
    put("/proc/uptime", "5000.00 30000.00\n")
    put("/sys/module/qcom_scm/parameters/download_mode", download_mode + "\n")
    put("/sys/module/printk/parameters/time", "Y\n")
    put("/sys/module/cpuidle_psci_domain/parameters/allow_cluster_off", aco + "\n")
    if aso is not None:
        put("/sys/module/cpuidle_psci_domain/parameters/allow_system_off", aso + "\n")
    put("/sys/module/msm/parameters/idle_refresh_ms60", "500\n")
    put("/sys/module/ath12k/version", "y700-1041\n")
    put("/sys/bus/platform/devices/a600000.usb/power/control", "auto\n")
    put("/sys/bus/platform/devices/a600000.usb/power/runtime_status", "suspended\n")
    put("/sys/devices/system/cpu/cpuidle/current_governor", "teo\n")
    put("/sys/devices/system/cpu/cpuidle/available_governors", "menu teo\n")
    for d in ("ddr", "llcc", "ddr-qos"):
        put(f"/sys/class/devfreq/{d}/polling_interval", "1000\n")
    put("/usr/local/share/y700-osk/oskgate.kwin-version", "1.0\n")
    put("/etc/drirc", builtins.open(DRIRC_SRC, "rb").read())   # the repo's own file (10-23: chrome, ChatGPT, steamwebhelper)
    put("/home/user/.config/powerdevilrc", PDRC_GOOD)
    put("/home/user/.config/kscreenlockerrc", KLRC_GOOD)
    put(KDED6_WAIT, builtins.open(realos.path.join(HERE, "..", "linux", "audio", "y700-kded6-wait-tuned-sink.conf"), "rb").read())
    S["enabled"] = {"sleep.target": "masked", "y700-autobright.service": "disabled", "y700-flightrec": "enabled" if recorder else ""}
    S["active"] = {"y700-flightrec": "active" if recorder else "inactive", "livi-wifi-ap.service": "inactive",
                   "y700-carplay-test-guard.timer": "inactive"}
    if recorder:
        put("/etc/systemd/system/y700-flightrec.service", "[Unit]\n")
        put(f"/var/log/y700-flightrec/flightrec-{BOOT8}.log", REC_LOG, mtime=NOW - 3)
        LINKS["/var/log/y700-flightrec/current.log"] = f"/var/log/y700-flightrec/flightrec-{BOOT8}.log"
        put("/var/log/y700-flightrec/current.log", "link")


def archived(this_boot=True, console=True, pmsg=True, stale_dmesg=True, recorder_copy=True, fresh_dmesg=False):
    """systemd-pstore's flat archive as cx-audit-2247.txt lists it. this_boot: console/pmsg archived THIS boot (warm
    reset); otherwise (cold cut) they are stale copies from an earlier boot and systemd-pstore did not run."""
    at = NOW - 4000                                   # systemd-pstore ran 4000 s ago this boot (uptime 5000 s)
    old = NOW - 3 * 86400
    t_cp = at + 2 if this_boot else old
    if console:
        put("/var/lib/systemd/pstore/console-ramoops-0", KMSG_TEXT, ctime=t_cp, mtime=0)
    if pmsg:
        put("/var/lib/systemd/pstore/pmsg-ramoops-0", REC_LOG, ctime=t_cp, mtime=10)
    if stale_dmesg:
        for n in ("dmesg-ramoops-0", "dmesg-ramoops-1"):
            put(f"/var/lib/systemd/pstore/{n}", "Panic#1 Part1\nold panic text\n", ctime=old, mtime=old)
        put("/var/lib/systemd/pstore/dmesg-ramoops-0.enc.z", b"\x78\x9c\x01\x02", ctime=old, mtime=old)
    if fresh_dmesg:
        put("/var/lib/systemd/pstore/dmesg-ramoops-3", "Oops#1 Part1\nfresh oops text\n", ctime=NOW - 50, mtime=old)
    if recorder_copy:
        for f in realglob.glob(tr("/var/lib/systemd/pstore") + "/*"):
            put(f"/var/log/y700-flightrec/pstore/{BOOT8}/{realos.path.basename(f)}", builtins.open(f, "rb").read(), ctime=NOW - 3990)
    S["pstore_show"] = (f"LoadState=loaded\nConditionResult=yes\nExecMainStartTimestamp=@{int(at)}" if this_boot
                        else "LoadState=loaded\nConditionResult=no\nExecMainStartTimestamp=")


def state(**kw):
    d = {"pkgs": {p: "1.0" for p in mod.PACKAGES}, "kernel": KERNEL, "checked_at": NOW - 86400, "boot8": "deadbeef",
         "tb323fu_mesa": None, "fex": None, "prev_boot": "deadbeefcafe"}
    d.update(kw)
    put(mod.STATE, json.dumps(d))


def run_main(save=False):
    sys.argv = ["y700-checklist"] + (["--save"] if save else [])
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = mod.main()
    return rc, buf.getvalue().splitlines()


FAILS = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"   <- {detail}"))
    if not cond:
        FAILS.append(name)


def has(lines, kind, sub):
    return any(l.startswith(kind) and sub in l for l in lines)


def show(title, lines, pref=("WARN", "INFO", "CHANGED")):
    print(f"\n== {title}")
    for l in lines:
        if l.startswith(pref):
            print("      | " + l[:230])


# ---- unit level: the console classifier on the real 03:41 log (no printk prefix, 163 identical SCMI lines, cut mid-line)
text = KMSG_TEXT.decode("utf-8", "replace")
tail, why = mod.console_tail(text), mod.classify_console(text)
print("console_tail(03:41):", tail); print("classify(03:41):", why)
check("03:41 tail collapses the SCMI repeats", any("×" in l for l in tail), tail)
check("03:41 tail is 3 lines", len(tail) == 3)
check("03:41 classified as SCMI/RPMh bus hang", any("SCMI" in w for w in why), why)
check("03:41 classified with DPU timeout", any("DPU" in w for w in why), why)

# ---- unit level: the 10-31 21:04 console (die() printed the SEA, CPU0 stopped mid-register-dump; chronic DPU/GMU noise before)
SEA_TEXT = "\n".join(["[drm:dpu_encoder_phys_vid_wait_for_commit_done:583] [dpu error]vblank timeout: 400000"] +
                     ["platform 3d6c000.gmu: delay in fenced register write (0x8c1)"] * 9 +
                     ["Internal error: synchronous external abort: 0000000096001610 [#1]  SMP",
                      "CPU: 0 UID: 0 PID: 0 Comm: swapper/0 Tainted: G   M       O        7.3.0-tb323fu-t52-y15 #4 PREEMPT",
                      "pc : msm_mdss_irq+0x68/0xf0", "lr : generic_handle_domain_irq+0x48/0x78",
                      "x11: 0000000000000000 x10: ffff0008005bfaa0 x9 : ffffad938f"])
why = mod.classify_console(SEA_TEXT); print("classify(10-31):", why)
check("10-31 SEA named first, before the DPU noise", why and "SEA" in why[0] and any("DPU" in w for w in why[1:]), why)
check("10-31 MDSS irq named", any("msm" in w.lower() or "MDSS" in w for w in why), why)
check("10-31 not called an Oops that panics", not any("oops=panic" in w for w in why), why)

# ---- unit level: the 11-02 15:15 console (boot 447a621b): DPU noise, the battery firmware times out twice, then the reset
BATT_TEXT = "\n".join(["[89301.663054] [drm:dpu_encoder_phys_vid_wait_for_commit_done:583] [dpu error]vblank timeout: 400000",
                       "[89317.877387] power_supply qcom-battmgr-bat: driver failed to report `status' property: -110",
                       "[89318.926843] power_supply qcom-battmgr-bat: driver failed to report `capacity' property: -110"])
why = mod.classify_console(BATT_TEXT); print("classify(11-02):", why)
check("11-02 battery firmware silence named first, before the DPU noise",
      why and "电池固件" in why[0] and any("DPU" in w for w in why[1:]) and not any("SCMI" in w for w in why), why)

# ---- S1 warm reset after a crash: console + pmsg archived this boot, recorder active, stale dmesg records ignored
base_tree(); archived(this_boot=True); state()
put(f"/var/log/y700-flightrec/flightrec-{PREV8}.log", REC_LOG, mtime=NOW - 5000)
rc, out = run_main(); show("S1 warm reset after crash", out)
check("S1 exit 10", rc == 10, rc)
check("S1 WARN unclean with SCMI verdict", has(out, "WARN", "上一次开机没有正常结束") and has(out, "WARN", "SCMI"))
check("S1 INFO console tail", has(out, "INFO", "控制台尾部") and has(out, "INFO", "×"))
check("S1 INFO pmsg archived", has(out, "INFO", "pmsg 环挺过了复位"))
check("S1 INFO ufs last line", has(out, "INFO", "UFS 份") and has(out, "INFO", "aco=Y"))
check("S1 stale dmesg records not blamed", not has(out, "WARN", "dmesg 转储") and not has(out, "WARN", "panic/oops 转储"))
check("S1 recorder INFO", has(out, "INFO", "飞行记录器在跑"))
check("S1 knobs OK", has(out, "OK", "CX 实验旋钮都在默认值"))
check("S1 no script-error WARN", not has(out, "WARN", "出错"))

# ---- S2 cold cut: systemd-pstore did not run, the recorder dir holds only stale re-copies
base_tree(); archived(this_boot=False); state()
rc, out = run_main(); show("S2 cold cut", out)
check("S2 verdict says pstore empty / cold cut", has(out, "WARN", "冷切断"))
check("S2 WARN pmsg ring lost", has(out, "WARN", "没有挺过这次复位"))
check("S2 stale console NOT shown as previous boot's", not has(out, "INFO", "控制台尾部"))

# ---- S3 clean reboot but a fresh panic record since the last --save; S3b first run without checked_at
base_tree(); archived(this_boot=True, fresh_dmesg=True); state()
S["journal_tail"] = "systemd-shutdown[1]: Syncing filesystems\nReached target reboot.target"
rc, out = run_main(); show("S3 clean reboot + fresh panic record", out)
check("S3 OK clean previous boot", has(out, "OK", "正常关机"))
check("S3 WARN new panic record (1, Oops head)", has(out, "WARN", "1 份新的内核 panic/oops 转储") and has(out, "WARN", "Oops#1 Part1"))
base_tree(); archived(this_boot=True, fresh_dmesg=True); state(checked_at=None)
S["journal_tail"] = "Reached target reboot.target"
rc, out = run_main(); show("S3b no checked_at", out)
check("S3b INFO listing, not WARN", has(out, "INFO", "历史内核 panic/oops 转储") and not has(out, "WARN", "panic/oops 转储"))

# ---- S3c-e every boot since the last --save ended (10-31 audit C2): the check runs once a day and looked only at the
# previous boot, so a reset in the boot the last --save ran in, then a clean reboot, then the daily run never told it
SAVED_ID, MID1_ID, MID2_ID = "5afe5afe" + "2" * 24, "0ddba11a" + "1" * 24, "c0ffee00" + "3" * 24
CLEAN_TAIL = "systemd-shutdown[1]: Syncing filesystems\nReached target reboot.target"


def boots_json(*ids):
    """journalctl --list-boots -o json for these boots, oldest first, the last one this boot (index 0)"""
    return json.dumps([{"index": i + 1 - len(ids), "boot_id": b, "first_entry": int((NOW - 80 * 86400) * 1e6),
                        "last_entry": int((NOW - (len(ids) - 1 - i) * 5000) * 1e6)} for i, b in enumerate(ids)])


base_tree(); archived(); state(boot8=SAVED_ID[:8])
S["boots_json"] = boots_json(SAVED_ID, MID1_ID, MID2_ID, PREV_ID, CUR_ID)
S["journal_tail"] = CLEAN_TAIL                         # the previous boot's (and MID1's): clean
S["journal_tails"] = {SAVED_ID: "kernel: arm-scmi timed out", MID2_ID: "kernel: something"}
put(f"/var/log/y700-flightrec/flightrec-{SAVED_ID[:8]}.log", REC_LOG)
rc, out = run_main(save=True); show("S3c reset in the last --save's boot and in a later one, then clean reboots", out)
check("S3c a reset in the last --save's boot -> WARN naming it, with its recorder's last UFS line",
      has(out, "WARN", f"开机 -4（{SAVED_ID[:8]}，上次体检以来、上一次之前的）没有正常结束") and has(out, "WARN", "UFS 份最后一行 at=03:41:02"),
      [l for l in out if "开机" in l])
check("S3c a reset in a later boot without a recorder log -> its own WARN, no UFS part",
      any(l.startswith("WARN") and f"开机 -2（{MID2_ID[:8]}" in l and "UFS" not in l for l in out))
check("S3c the clean ones -> one OK for the earlier clean boot, the previous boot's own OK; exit 10",
      has(out, "OK", "上一次之前的 1 次开机都是正常关机/重启的") and has(out, "OK", "上一次开机是正常关机/重启的") and rc == 10)
check("S3c each boot asked once by its id, oldest first", list(dict.fromkeys(S["ended_asked"])) == [SAVED_ID, MID1_ID, MID2_ID, PREV_ID],
      S["ended_asked"])
saved = json.loads(builtins.open(tr(mod.STATE), encoding="utf-8").read())
S["ended_asked"] = []
rc, out = run_main()
check("S3d the next run in the same boot (the --save above) -> no boot reported again",
      saved.get("boot8") == BOOT8 and saved.get("prev_boot") == PREV_ID and not S["ended_asked"]
      and not any("没有正常结束" in l or "正常关机/重启" in l for l in out), (saved.get("boot8"), S["ended_asked"]))
base_tree(); archived(); state(boot8="0badf00d")
S["boots_json"] = boots_json(MID2_ID, PREV_ID, CUR_ID)
S["journal_tail"] = CLEAN_TAIL
S["journal_tails"] = {MID2_ID: "kernel: something"}
rc, out = run_main()
check("S3e the last --save's boot no longer in journald's list -> the previous boot only, as before",
      list(dict.fromkeys(S.get("ended_asked", []))) == [PREV_ID] and has(out, "OK", "上一次开机是正常关机/重启的")
      and not has(out, "WARN", "没有正常结束"), S.get("ended_asked"))

# ---- S4 knob left on without a unit / with a unit / no y10 knob
base_tree(aco="Y"); archived(); state(prev_boot=PREV_ID)
S["journal_tail"] = "Reached target reboot.target"
rc, out = run_main(); show("S4 knob left on", out)
check("S4 WARN knob not restored", has(out, "WARN", "实验旋钮没复原") and has(out, "WARN", "allow_cluster_off=Y"))
S["cx_units"] = "y700-cx-exp.service loaded active running /usr/local/libexec/cx-exp.sh E1 30"
rc, out = run_main()
check("S4b INFO experiment running, no WARN", has(out, "INFO", "CX 实验 y700-cx-exp.service 正在跑") and not has(out, "WARN", "旋钮"))
base_tree(aco="N", aso=None); archived(); state(prev_boot=PREV_ID)
rc, out = run_main()
check("S4c no y10 knob -> OK with 无", has(out, "OK", "allow_system_off=无"))
check("S4d printk time on -> OK", has(out, "OK", "内核日志带时间戳"))
put("/sys/module/printk/parameters/time", "N\n")
rc, out = run_main()
check("S4e printk time off (initramfs default) -> WARN, exit 10", has(out, "WARN", "内核日志没有时间戳") and rc == 10, rc)

# ---- S5 rawdump: first seen -> INFO + baseline; same -> OK; rewritten -> WARN with tail + regs; erased; unreadable
base_tree(); archived(); state(prev_boot=PREV_ID)
put(mod.RAWDUMP, rawdump_image(KMSG_TEXT))
rc, out = run_main(save=True); show("S5 rawdump first", out)
check("S5 first run INFO baseline", has(out, "INFO", "rawdump 分区里有一份崩溃转储") and has(out, "INFO", "4 段"))
saved = json.loads(builtins.open(tr(mod.STATE), encoding="utf-8").read())
check("S5 baseline has hash", isinstance(saved.get("rawdump"), str) and len(saved["rawdump"]) == 16, saved.get("rawdump"))
rc, out = run_main()
check("S5 same dump OK", has(out, "OK", "rawdump 分区没有新的崩溃转储"))
put(mod.RAWDUMP, rawdump_image(KMSG_TEXT + b"\nKernel panic - not syncing: Fatal exception\n", rst=b""))
rc, out = run_main(); show("S5 rawdump rewritten", out)
check("S5 WARN new dump", has(out, "WARN", "新的崩溃转储"))
check("S5 WARN carries empty RST_STAT as 空段 and PMIC_PON hex", has(out, "WARN", "RST_STAT=空段") and has(out, "WARN", "PMIC_PON=80000001"))
check("S5 WARN carries kmsg tail", has(out, "WARN", "Kernel panic"))
put(mod.RAWDUMP, b"\0" * 0x10000)
rc, out = run_main()
check("S5 dump erased -> INFO", has(out, "INFO", "转储没了"))
realos.remove(tr(mod.RAWDUMP))
rc, out = run_main()
check("S5 unreadable -> silent, baseline kept", not any("rawdump" in l for l in out))

# ---- S6 recorder enabled but dead; not installed; active but log stale
base_tree(); archived(); state(prev_boot=PREV_ID)
S["active"]["y700-flightrec"] = "failed"
rc, out = run_main(); show("S6 recorder dead", out)
check("S6 WARN recorder enabled but failed", has(out, "WARN", "飞行记录器 enabled 但是 failed"))
base_tree(recorder=False); archived(recorder_copy=False); state(prev_boot=PREV_ID)
rc, out = run_main()
check("S6b INFO not installed", has(out, "INFO", "飞行记录器未安装"))
base_tree(); archived(); state(prev_boot=PREV_ID)
realos.utime(tr(f"/var/log/y700-flightrec/flightrec-{BOOT8}.log"), (NOW - 600, NOW - 600))
rc, out = run_main()
check("S6c WARN stale log while active", has(out, "WARN", "没更新"))

# ---- S7 everything fine: INFO lines present, exit 0
base_tree(); archived(); state(prev_boot=PREV_ID)
rc, out = run_main(); show("S7 all OK", out)
check("S7 has INFO lines", any(l.startswith("INFO") for l in out))
check("S7 exit 0 (INFO does not raise it)", rc == 0, [l for l in out if l.startswith(("WARN", "CHANGED"))])

# ---- S8 a check that raises is one WARN line and the run continues
base_tree(); archived(); state(prev_boot=PREV_ID)
orig = mod.rawdump_summary
mod.rawdump_summary = lambda: 1 / 0
rc, out = run_main()
mod.rawdump_summary = orig
check("S8 guard WARN", has(out, "WARN", "检查「rawdump」出错") and has(out, "OK", "CX 实验旋钮"))
check("S8 exit 10", rc == 10)

# ---- S9 unclean, systemd-pstore ran but archived no console/pmsg (only the stale dmesg records)
base_tree(); archived(this_boot=True, console=False, pmsg=False); state()
rc, out = run_main(); show("S9 archived but no console/pmsg", out)
check("S9 verdict: no console in pstore", has(out, "WARN", "没有它的控制台"))
check("S9 WARN recorder was not writing pmsg", has(out, "WARN", "没有新的 pmsg-ramoops"))

# ---- S10 systemctl cannot answer: fallback threshold = boot start - 10 min (or checked_at), stale records still old
base_tree(); archived(this_boot=True); state(checked_at=None)
S["pstore_show"] = "ERROR [Errno 2] No such file or directory: 'systemctl'"
rc, out = run_main(); show("S10 systemctl unanswerable", out)
check("S10 fresh console still shown", has(out, "INFO", "控制台尾部"))
check("S10 stale dmesg not blamed without checked_at", not has(out, "WARN", "dmesg 转储"))
check("S10 pmsg archived INFO", has(out, "INFO", "pmsg 环挺过了复位"))

# ---- S10b fallback with a checked_at and a 7 h dump-mode sit: the archive's ctime is on the early clock (timesyncd's last save,
# i.e. the crash time), hours before this boot's true start; yesterday's checked_at must still count it as the previous boot's
base_tree(); archived(this_boot=True); state()
S["pstore_show"] = "ERROR [Errno 2] No such file or directory: 'systemctl'"
for n in ("console-ramoops-0", "pmsg-ramoops-0"):
    CTIME[f"/var/lib/systemd/pstore/{n}"] = NOW - 5000 - 7 * 3600
rc, out = run_main(); show("S10b fallback after a 7 h dump-mode sit", out)
check("S10b console archived on the lagging early clock still shown", has(out, "INFO", "控制台尾部") and has(out, "WARN", "SCMI"))
check("S10b pmsg archived INFO, not 'recorder was not writing'", has(out, "INFO", "pmsg 环挺过了复位") and not has(out, "WARN", "没有新的 pmsg-ramoops"))
check("S10b stale dmesg still not blamed", not has(out, "WARN", "dmesg 转储"))

# ---- S11 y700-kmsg-watch installed (linux/net/KMSG-WATCH.md): it answers -> OK and the timers are not required;
# deaf / dead / a timer enabled again -> WARN; not installed -> the timers are checked as before
base_tree(); archived(); state(prev_boot=PREV_ID)
put("/etc/systemd/system/y700-kmsg-watch.service", "[Unit]\n")
S["enabled"].update({"y700-wifi-watchdog.timer": "disabled", "y700-display-watchdog.timer": "disabled"})
rc, out = run_main(); show("S11 kmsg-watch installed and answering", out, pref=("WARN", "CHANGED", "OK"))
check("S11 OK line with its counters", has(out, "OK", "y700-kmsg-watch 读得到内核日志") and has(out, "OK", "starts wifi=2"))
check("S11 timers no longer required", not any("watchdog.timer" in l for l in out))
check("S11 exit 0", rc == 0, [l for l in out if l.startswith(("WARN", "CHANGED"))])
S["kmsg_watch"] = "selftest 1-1 NOANSWER: y700-kmsg-watch did not answer within 10 s (systemctl status y700-kmsg-watch)"
rc, out = run_main()
check("S11b no answer -> WARN, exit 10", has(out, "WARN", "自检没通过") and rc == 10)
S.pop("kmsg_watch"); S["active"]["y700-kmsg-watch.service"] = "failed"
rc, out = run_main()
check("S11c watcher dead -> WARN", has(out, "WARN", "y700-kmsg-watch.service 是 failed") and rc == 10)
S["active"].pop("y700-kmsg-watch.service"); S["enabled"]["y700-wifi-watchdog.timer"] = "enabled"
rc, out = run_main()
check("S11d a timer enabled again -> WARN", has(out, "WARN", "y700-wifi-watchdog.timer 又启用了") and rc == 10)
put("/etc/systemd/system/y700-wifi-watchdog.timer.d/y700-safety.conf", "[Timer]\n")
rc, out = run_main()
check("S11f enabled with the 15-min safety drop-in -> OK", has(out, "OK", "安全网") and rc == 0,
      [l for l in out if l.startswith(("WARN", "CHANGED"))])
put("/usr/local/libexec/y700-kmsg-watch", "\x7fELF\x02\x01\x01")
rc, out = run_main()
check("S11g the Rust binary -> no rollback WARN", not has(out, "WARN", "Python 版") and rc == 0, out)
put("/usr/local/libexec/y700-kmsg-watch", "#!/usr/bin/python3\n")
rc, out = run_main()
check("S11h the Python version back -> WARN", has(out, "WARN", "y700-kmsg-watch 跑的是 Python 版") and rc == 10, out)
base_tree(); archived(); state(prev_boot=PREV_ID)
rc, out = run_main()
check("S11e not installed: the timers are still checked", has(out, "OK", "y700-wifi-watchdog.timer active"))
check("S12 home gesture not installed -> no line", not any("底边上滑" in l for l in out))

# ---- S12 the bottom-edge home gesture (linux/gesture): the edge state the script logged vs the blockers KWin sees
mod.kwin_js = lambda code: S.get("kwin_js", ["false"])
def home(**kw):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    put("/home/user/.local/share/kwin/scripts/y700-home/metadata.json", "{}")
    S.update(kw)
    return run_main()[1]
out = home()
check("S12a loaded, edge on, nothing up -> OK", has(out, "OK", "底边上滑手势就绪"), out)
out = home(home_edge="y700-home: bottom edge off", kwin_js=["true"])
check("S12b keyboard up, edge off -> OK paused", has(out, "OK", "手势按设计暂停"))
out = home(home_edge="y700-home: bottom edge off")
check("S12c edge stuck off, nothing up -> WARN", has(out, "WARN", "底边上滑手势状态不对"))
out = home(home_edge="")
check("S12d no state line -> WARN", has(out, "WARN", "没有记录"))
out = home(home_loaded="b false")
check("S12e script not loaded -> WARN", has(out, "WARN", "y700-home 没加载"))
out = home(kreadconfig="")
check("S12f RemainActiveOnFullscreen unset -> WARN", has(out, "WARN", "RemainActiveOnFullscreen"))
out = home(kwin_js=None)
check("S12g KWin will not run the probe -> WARN", has(out, "WARN", "KWin 不肯跑检查脚本"))

# ---- S12h-n the edge handed to the task switcher effect (linux/gesture/taskswitcher, 10-21): BottomEdge=false
TS_QML = '    readonly property string y700Build: "6.6.5-0ubuntu0.1+abc123"\n'
def ts(**kw):
    kread = {"BottomEdge": "false", "navigationPanelEnabled": "false", "RemainActiveOnFullscreen": "true"}
    kread.update(kw.pop("kread", {}))
    base_tree(); archived(); state(prev_boot=PREV_ID)
    put("/home/user/.local/share/kwin/scripts/y700-home/metadata.json", "{}")
    put("/home/user/.local/share/kwin/effects/y700-taskswitcher/contents/ui/main.qml", kw.pop("qml", TS_QML))
    for path, data in kw.pop("files", {}).items():
        put(path, data)
    S.update(kread=kread, **kw)
    return run_main()[1]
out = ts()
check("S12h effect loaded, build matches, edge on -> OK", has(out, "OK", "多任务卡片就绪") and not has(out, "OK", "底边上滑手势就绪"), out)
out = ts(ts_edge="y700-taskswitcher: bottom edge off", kwin_js=["true"])
check("S12i keyboard up, edge off -> OK paused", has(out, "OK", "底边手势按设计暂停"))
out = ts(ts_edge="y700-taskswitcher: bottom edge off")
check("S12j edge stuck off -> WARN", has(out, "WARN", "多任务卡片手势状态不对"))
out = ts(ts_loaded="b false")
check("S12k effect not loaded -> WARN", has(out, "WARN", "y700-taskswitcher 没加载"))
out = ts(ts_build="y700-taskswitcher: loaded 6.6.5-0ubuntu0.1+old999")
check("S12l running build != installed (reinstall without login) -> WARN", has(out, "WARN", "重新登录") and has(out, "WARN", "old999"))
out = ts(ts_build="")
check("S12m no loaded line -> WARN", has(out, "WARN", "没有记录"))
out = ts(kread={"navigationPanelEnabled": ""})
check("S12n plasmamobilerc nav panel not off -> WARN", has(out, "WARN", "navigationPanelEnabled"))
# ---- S12aq1-5 a swiped-away card quits its app (taskswitcher/appquit.py, 10-31): WARN only, silent when all is well
AQ = {"/home/user/.local/share/kwin/effects/y700-taskswitcher/contents/ui/AppQuit.qml": "QtObject {}\n",
      "/usr/local/libexec/y700-appquit": "#!/usr/bin/env python3\n",
      "/home/user/.config/systemd/user/y700-appquit@.service": "[Service]\n"}
out = ts()
check("S12aq1 effect without AppQuit.qml (older build) -> no line", not any("划走卡片" in l for l in out), out)
out = ts(files=AQ)
check("S12aq2 all installed, no failures -> no line", not any("划走卡片" in l for l in out), out)
out = ts(files={k: v for k, v in AQ.items() if "libexec" not in k})
check("S12aq3 script missing -> WARN", has(out, "WARN", "/usr/local/libexec/y700-appquit 不在"), out)
out = ts(files=AQ, aq_fails="2")
check("S12aq4 two failures this boot -> WARN", has(out, "WARN", "失败了 2 次"), out)
out = ts(files=AQ, aq_fails="ERROR timed out")
check("S12aq5 the journal read fails -> no line", not any("划走卡片" in l for l in out), out)
# ---- S12gs1-6 the G9 screen-off service (linux/gamepad/screen, 11-01; Rust 11-03): WARN when its error line loops,
# when it restarts itself (a panic) and when the Python version is back
GS = {"/usr/local/libexec/y700-gamepad-screen": b"\x7fELF\x02\x01\x01" + b"\0" * 57}
out = ts(gs_fails="4008")
check("S12gs1 not installed -> no line", not any("G9 息屏" in l for l in out), out)
out = ts(files=GS)
check("S12gs2 installed, no failures -> no line", not any("G9 息屏" in l for l in out), out)
out = ts(files=GS, gs_fails="4008")
check("S12gs3 4008 failures this boot (11-01 before the fix) -> WARN", has(out, "WARN", "报错 4008 次"), out)
out = ts(files=GS, gs_fails="ERROR timed out")
check("S12gs4 the journal read fails -> no line", not any("G9 息屏" in l for l in out), out)
out = ts(files=GS, nrestarts={"y700-gamepad-screen": "6"})
check("S12gs5 6 automatic restarts -> WARN", has(out, "WARN", "自动重启了 6 次"), out)
out = ts(files={"/usr/local/libexec/y700-gamepad-screen": "#!/usr/bin/python3\n"})
check("S12gs6 the Python version back -> WARN", has(out, "WARN", "不是编译好的 Rust 程序"), out)
# ---- S12sg1-8 the speaker guard (Rust 11-03): WARN when the bash version is back, when it restarts itself (a panic) and
# when its last word on pipewire-pulse's events is a lost or missing connection (it then checks every 2 s)
SG = {"/usr/local/libexec/y700-speaker-guard": b"\x7fELF\x02\x01\x01" + b"\0" * 57}
LOST = "pulse event connection lost (failed to fill whole buffer); checking every 2 s until it is back"
out = ts(sg_conn=LOST, nrestarts={"y700-speaker-guard.service": "9"})
check("S12sg1 not installed -> no line", not any("扬声器守护" in l for l in out), out)
out = ts(files=SG)
check("S12sg2 started, connected -> no line", not any("扬声器守护" in l for l in out), out)
out = ts(files=SG, sg_conn=LOST)
check("S12sg3 the event connection lost and not back -> WARN", has(out, "WARN", "扬声器守护收不到 pipewire-pulse 的事件"), out)
out = ts(files=SG, sg_conn="no pulse event connection (No such file or directory (os error 2)); checking every 2 s until there is one")
check("S12sg4 never connected -> WARN", has(out, "WARN", "正每 2 秒查一次"), out)
out = ts(files=SG, sg_conn="pulse event connection back")
check("S12sg5 lost and back again -> no line", not any("扬声器守护" in l for l in out), out)
out = ts(files=SG, nrestarts={"y700-speaker-guard.service": "6"})
check("S12sg6 6 automatic restarts -> WARN", has(out, "WARN", "扬声器守护自动重启了 6 次"), out)
out = ts(files={"/usr/local/libexec/y700-speaker-guard": "#!/bin/bash\n"})
check("S12sg7 the bash version back -> WARN", has(out, "WARN", "扬声器守护") and has(out, "WARN", "不是编译好的 Rust 程序"), out)
out = ts(files=SG, sg_conn="ERROR timed out")
check("S12sg8 the journal read fails -> no line", not any("扬声器守护" in l for l in out), out)
# ---- S12ab1-8 automatic brightness (Rust 11-03): WARN when it is on but not running, when the Python version is back,
# when it restarts itself (a panic) and when its last word on KWin's screen events is the sysfs fallback
AB_UNIT = "/home/user/.config/systemd/user/y700-autobright.service"
AB = {AB_UNIT: "[Service]\nExecStart=/usr/local/libexec/y700-autobright\n"}
AB_ON = {"sleep.target": "masked", "y700-autobright.service": "enabled", "y700-flightrec": ""}
out = ts(files=AB)
check("S12ab1 switched off -> no line", not any("自动亮度" in l for l in out), out)
out = ts(files=AB, enabled=AB_ON)
check("S12ab2 on, running, KWin events -> OK", has(out, "OK", "自动亮度在跑"), out)
out = ts(files=AB, enabled=AB_ON, active={"y700-autobright.service": "activating"})
check("S12ab3 on but not running -> WARN", has(out, "WARN", "自动亮度开着但服务是 activating"), out)
out = ts(files={AB_UNIT: "[Service]\nExecStart=/usr/bin/python3 %h/.local/bin/y700-autobright\n"}, enabled=AB_ON)
check("S12ab4 the Python version back -> WARN", has(out, "WARN", "自动亮度跑的是 Python 版"), out)
out = ts(files=AB, enabled=AB_ON, nrestarts={"y700-autobright.service": "6"})
check("S12ab5 6 automatic restarts -> WARN", has(out, "WARN", "自动亮度自动重启了 6 次"), out)
out = ts(files=AB, enabled=AB_ON, ab_kwin="no KWin screen events (the compositor closed the connection); checking the screen every second")
check("S12ab6 KWin's events lost and not back -> WARN", has(out, "WARN", "自动亮度收不到 KWin 的熄屏事件"), out)
out = ts(files=AB, enabled=AB_ON, ab_kwin="KWin screen events back")
check("S12ab7 lost and back again -> OK", has(out, "OK", "自动亮度在跑") and not has(out, "WARN", "自动亮度"), out)
out = ts(files=AB, enabled=AB_ON, ab_kwin="ERROR timed out")
check("S12ab8 the journal read fails -> OK", has(out, "OK", "自动亮度在跑"), out)

# ---- S21a-d the control centre's gestures (10-21): pull-down strip unit, y700-edge (back key), fake_input desktop file
CC_UNIT = "/home/user/.config/systemd/user/y700-cc-pull.service"
CC_DESK = "/usr/local/share/applications/y700-control-center.desktop"
GOOD_DESK = "[Desktop Entry]\nExec=/usr/local/bin/y700-control-center\nX-KDE-Wayland-Interfaces=org_kde_kwin_fake_input\n"
out = ts()
check("S21a strip not installed -> no line", not any("控制中心手势" in l for l in out))
out = ts(files={CC_UNIT: "[Unit]\n", CC_DESK: GOOD_DESK})
check("S21b all there -> OK", has(out, "OK", "控制中心手势就绪"), out)
out = ts(files={CC_UNIT: "[Unit]\n", CC_DESK: GOOD_DESK}, active={"y700-cc-pull.service": "failed", "y700-shellbar.service": "inactive"})
check("S21c strip down, no shellbar -> WARN", has(out, "WARN", "y700-cc-pull.service 是 failed"))
# the shellbar's status bar took the strip's job (10-22): the old unit being off is the installed state then
out = ts(files={CC_UNIT: "[Unit]\n", CC_DESK: GOOD_DESK}, active={"y700-cc-pull.service": "inactive"})
check("S21k strip down, shellbar running -> no WARN", has(out, "OK", "控制中心手势就绪") and not has(out, "WARN", "y700-cc-pull.service 是"))
out = ts(files={CC_UNIT: "[Unit]\n", CC_DESK: "[Desktop Entry]\n"}, edge_loaded="b false")
check("S21d edge script off + no fake_input grant -> one WARN naming both", has(out, "WARN", "y700-edge 没加载")
      and has(out, "WARN", "缺 fake_input"))
out = ts(files={CC_UNIT: "[Unit]\n", CC_DESK: GOOD_DESK}, blur_loaded="b false")
check("S21e blur effect not loaded -> WARN", has(out, "WARN", "模糊特效 blur 没加载"))

# ---- S21f-j the curtain's live-screen blur test (10-22): its tools (the grants live in desktop files) and the last result
BLUR_SH = "/usr/local/share/y700-control-center/tests/blur-flicker.sh"
BLUR_TOOLS = {BLUR_SH: "#!/bin/sh\n", "/usr/local/bin/y700-capseq": "", "/usr/local/bin/y700-ftouch": "",
              "/usr/local/share/applications/y700-capseq.desktop": "[Desktop Entry]\nX-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2\n",
              "/usr/local/share/applications/y700-ftouch.desktop": "[Desktop Entry]\nX-KDE-Wayland-Interfaces=org_kde_kwin_fake_input\n"}
BLUR_LAST = "/var/lib/y700/cc-blur-last.txt"
out = ts()
check("S21f blur test not installed -> no line", not any("模糊自检" in l for l in out))
out = ts(files={**BLUR_TOOLS, BLUR_LAST: "2026-10-22 03:30:00 OK 61 frames under the curtain, all blurred (first frame mean 87.1 sharp 899.6)\n"})
check("S21g tools there, last run passed -> OK with its time", has(out, "OK", "上次自检 2026-10-22 03:30:00 通过"), [l for l in out if "模糊" in l])
out = ts(files={**BLUR_TOOLS, BLUR_LAST: "2026-10-22 03:30:00 FAIL 3 of 61 frames under the curtain are tinted but sharp: 25(0.310)\n"})
check("S21h last run failed -> WARN", has(out, "WARN", "上次没过") and has(out, "WARN", "25(0.310)"))
out = ts(files={BLUR_SH: "#!/bin/sh\n", "/usr/local/bin/y700-capseq": "", "/usr/local/share/applications/y700-capseq.desktop": "[Desktop Entry]\n"})
check("S21i capseq without its grant, no ftouch -> one WARN naming both", has(out, "WARN", "ScreenShot2") and has(out, "WARN", "fake_input"))
out = ts(files=BLUR_TOOLS)
check("S21j never run -> INFO", has(out, "INFO", "还没跑过"))

# ---- S21p-v the dock's glass inside the task switcher (10-22): the last dock-glass-run.sh verdict, stamped with the
# build it tested, against the installed build (abc123 in ts()). (S21k is the shellbar/strip case above.)
GLASS_LAST = "/var/lib/y700/dock-glass-last.txt"
out = ts()
check("S21p glass test never run -> INFO", has(out, "INFO", "Dock 玻璃自检还没跑过"))
out = ts(files={GLASS_LAST: "2026-10-22 12:00:00 OK 90 frames, the dock's rim blurred throughout (max 16.1, reference 15.3, limit 61) build 6.6.5-0ubuntu0.1+abc123\n"})
check("S21q last run passed on the installed build -> OK with its time", has(out, "OK", "Dock 玻璃") and has(out, "OK", "2026-10-22 12:00:00 通过"), [l for l in out if "玻璃" in l])
out = ts(files={GLASS_LAST: "2026-10-22 12:00:00 FAIL 5 of 90 frames show the dock's rim sharp (limit 61, reference 15.3): f017@820.0ms(301) build 6.6.5-0ubuntu0.1+abc123\n"})
check("S21r last run failed -> WARN naming the frame", has(out, "WARN", "Dock 玻璃自检上次没过") and has(out, "WARN", "f017@820.0ms(301)"))
# the glass lighter than KWin's own blur (the owner, 10-22 13:10: 「从淡模糊变成浓模糊」) is a FAIL of its own kind
out = ts(files={GLASS_LAST: "2026-10-22 13:40:00 FAIL the glass is not as heavy as KWin's blur in 12 frames (blur edge, reference 213, wanted 0.7-1.5 x): f070(96) f071(95) build 6.6.5-0ubuntu0.1+abc123\n"})
check("S21w glass too light -> WARN naming the edge", has(out, "WARN", "Dock 玻璃自检上次没过") and has(out, "WARN", "f070(96)"))
out = ts(files={GLASS_LAST: "2026-10-22 12:00:00 OK 90 frames, the dock's rim blurred throughout build 6.6.5-0ubuntu0.1+old999\n"})
check("S21s verdict for another build -> INFO rerun", has(out, "INFO", "不是现在装的") and has(out, "INFO", "abc123") and has(out, "INFO", "old999"))
# the install checklist's red run is against the old build; once the new one is installed that FAIL is stale: a
# rerun, not a failure (it was a WARN with "修好再跑" until the review of 10-22)
out = ts(files={GLASS_LAST: "2026-10-22 12:00:00 FAIL 5 of 90 frames show the dock's rim sharp (limit 61, reference 15.3): f017@820.0ms(301) build 6.6.5-0ubuntu0.1+old999\n"})
check("S21t stale FAIL from the build before -> INFO rerun, no WARN", has(out, "INFO", "不是现在装的") and not has(out, "WARN", "Dock 玻璃"))
# dock-glass-run.sh stamps "build unknown" when it cannot read the build; an unreadable installed build is the same
out = ts(files={GLASS_LAST: "2026-10-22 12:00:00 OK 90 frames, the dock's rim blurred throughout build unknown\n"})
check("S21u verdict for build unknown -> INFO rerun, not OK", has(out, "INFO", "不是现在装的") and not has(out, "OK", "Dock 玻璃"))
out = home()
check("S21v no switcher installed -> no glass line", not any("Dock 玻璃" in l for l in out))

# ---- S22a-d the status bar + dock (linux/dock, 10-22): installed / enabled, and the curtain's control centre
SB_BIN = "/usr/local/bin/y700-shellbar"
SB_DESK = "/usr/local/share/applications/y700-shellbar.desktop"
SB_GOOD = {SB_BIN: "", SB_DESK: "[Desktop Entry]\nX-KDE-Wayland-Interfaces=org_kde_plasma_window_management\n"}
NOTES_QML = "/usr/local/share/y700-control-center/qml/NotesPane.qml"
SB_QUIET = {"y700-cc-pull.service": "inactive"}
out = ts()
check("S22a shellbar not installed -> no line", not any("状态栏与 dock" in l for l in out))
out = ts(files={**SB_GOOD, NOTES_QML: "Item {}\n"}, active=SB_QUIET)
check("S22b enabled, new control centre -> OK", has(out, "OK", "状态栏与 dock 就绪"), [l for l in out if "dock" in l])
out = ts(files=SB_GOOD, active=SB_QUIET)
check("S22c enabled, old control centre (no NotesPane) -> WARN", has(out, "WARN", "没有通知中心"))
out = ts(files=SB_GOOD, active=SB_QUIET, enabled={"y700-shellbar.service": "disabled"})
check("S22d installed but not enabled, old control centre -> no curtain WARN", not has(out, "WARN", "没有通知中心"))
# S22e-g the notification service (10-22): a running shellbar must hold org.freedesktop.Notifications
SB_FULL = {**SB_GOOD, NOTES_QML: "Item {}\n"}
out = ts(files=SB_FULL, active=SB_QUIET, bus_list="org.freedesktop.Notifications 196383 plasmashell user :1.3762 user@1000.service - -")
check("S22e service running, plasmashell holds the notifications -> WARN naming it", has(out, "WARN", "在 plasmashell 手里"))
out = ts(files=SB_FULL, active=SB_QUIET, bus_list="org.freedesktop.Notifications - - - (activatable) - -")
check("S22f service running, nobody holds it -> WARN", has(out, "WARN", "在 没人 手里"))
out = ts(files=SB_FULL, active={**SB_QUIET, "y700-shellbar.service": "inactive"}, enabled={"y700-shellbar.service": "disabled"},
         bus_list="org.freedesktop.Notifications 196383 plasmashell user :1.3762 user@1000.service - -")
check("S22g service not running (phase 3 not yet) -> plasmashell's name is no WARN", not has(out, "WARN", "手里"), [l for l in out if "dock" in l])
# S22h-l the tray (the dock's stage 4, 10-23): with TrayTile.qml installed the control centre must own
# org.kde.StatusNotifierHost-<pid>, and kded6's watcher must be on the bus
TRAY_QML = "/usr/local/share/y700-control-center/qml/TrayTile.qml"
SNI_WATCHER = "org.kde.StatusNotifierWatcher 3207 kded6 user :1.31 user@1000.service - -"
SNI_OURS = "org.kde.StatusNotifierHost-250247 250247 y700-control-ce user :1.422 user@1000.service - -"
TRAY_LINES = lambda out: [l for l in out if "控制中心托盘" in l or "托盘宿主" in l]
out = ts(files={TRAY_QML: "Item {}\n"}, bus_list=SNI_WATCHER + "\n" + SNI_OURS)
check("S22h tray installed, our host and the watcher on the bus -> OK", has(out, "OK", "控制中心是托盘宿主") and has(out, "OK", "kded6"), TRAY_LINES(out))
out = ts(files={TRAY_QML: "Item {}\n"},
         bus_list=SNI_WATCHER + "\norg.kde.StatusNotifierHost-196383 196383 plasmashell user :1.3 user@1000.service - -")
check("S22i only plasmashell is a host -> WARN naming it", has(out, "WARN", "控制中心没占") and has(out, "WARN", "plasmashell"), TRAY_LINES(out))
out = ts(files={TRAY_QML: "Item {}\n"}, bus_list=SNI_OURS)
check("S22j no watcher -> WARN about the watcher only", has(out, "WARN", "StatusNotifierWatcher 不在") and not has(out, "WARN", "控制中心没占"), TRAY_LINES(out))
out = ts(files={TRAY_QML: "Item {}\n"}, active={"y700-control-center.service": "failed"})
check("S22k control centre not running -> only the unit's own WARN", not TRAY_LINES(out) and has(out, "WARN", "y700-control-center.service 是 failed"))
out = ts(bus_list=SNI_WATCHER)
check("S22l no tray installed (before stage 4) -> no line", not TRAY_LINES(out))

def pstat(pid, comm, cpu, start):
    return f"{pid} ({comm}) R 1 {pid} {pid} 0 -1 4194560 100 0 0 0 {cpu} 0 0 0 20 0 9 0 {start} 1536260 154036\n"
def kwin_proc(pid, start=5000, virtual=False, uid=1000):
    """/proc files of a kwin_wayland: the session one as kwin_wayland_wrapper starts it, or a headless test one as
    linux/video/chrome-vp9-check.sh does (checklist session_kwin(), 10-23)"""
    args = (["kwin_wayland", "--virtual", "--no-lockscreen", "--no-global-shortcuts", "--width", "1920", "--height", "1080",
             "--socket", f"y700-cvp9-{pid}"] if virtual else
            ["/usr/bin/kwin_wayland", "--wayland-fd", "7", "--socket", "wayland-0", "--xwayland-fd", "8", "--xwayland"])
    return {f"/proc/{pid}/stat": pstat(pid, "kwin_wayland", 900, start), f"/proc/{pid}/cmdline": "\0".join(args) + "\0",
            f"/proc/{pid}/status": f"Name:\tkwin_wayland\nUmask:\t0022\nState:\tS (sleeping)\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n"}

# ---- S12o-r KWin still running a replaced plugin / library (the gate effect reinstalled, 10-21): /proc/<kwin>/maps
GATE_SO = "/usr/lib/aarch64-linux-gnu/qt6/plugins/kwin/effects/plugins/y700_oskgate.so"
def maps_of(*paths):
    return ("".join(f"ffff8{i}000000-ffff8{i}001000 r-xp 00000000 103:05 {100 + i} {p}\n" for i, p in enumerate(paths))
            + "ffff9a000000-ffff9a100000 rw-s 00000000 00:01 7 /memfd:wayland-shm (deleted)\n")
def kwin_maps(*paths):
    return ts(pids={"kwin_wayland": "2901"}, files={**kwin_proc(2901), "/proc/2901/maps": maps_of(*paths)})
out = kwin_maps(GATE_SO, "/usr/lib/aarch64-linux-gnu/libQt6Gui.so.6.10.2")
check("S12o kwin maps current files only (a deleted memfd is not a library) -> OK", has(out, "OK", "KWin 用的都是当前装着的")
      and not has(out, "WARN", "KWin 还"), out)
out = kwin_maps(GATE_SO + " (deleted)")
check("S12p gate plugin replaced under KWin -> WARN re-login, no generic line", has(out, "WARN", "键盘门卫特效换了新版")
      and not has(out, "WARN", "被升级替换掉的库") and not has(out, "OK", "KWin 用的都是"))
out = kwin_maps("/usr/lib/aarch64-linux-gnu/libQt6Gui.so.6.10.2 (deleted)", "/usr/lib/aarch64-linux-gnu/libQt6Core.so.6.10.2 (deleted)")
check("S12q Qt replaced by an upgrade -> one WARN naming both", has(out, "WARN", "2 个被升级替换掉的库") and has(out, "WARN", "libQt6Core")
      and not has(out, "WARN", "键盘门卫特效换了新版"))
out = ts()
check("S12r kwin_wayland not running -> no KWin-library line", not has(out, "OK", "KWin 用的都是") and not has(out, "WARN", "KWin 还"))
# a headless test KWin (chrome-vp9-check.sh, 10-23) is the newest kwin_wayland, first in pidof's list: the session
# KWin's maps are judged, never the test one's
QT_GONE = "/usr/lib/aarch64-linux-gnu/libQt6Gui.so.6.10.2 (deleted)"
def kwin_with_test(session_maps, test_maps):
    return ts(pids={"kwin_wayland": "6100 2901"}, files={**kwin_proc(2901), "/proc/2901/maps": session_maps,
                                                        **kwin_proc(6100, start=9000, virtual=True), "/proc/6100/maps": test_maps})
out = kwin_with_test(maps_of(QT_GONE), maps_of(GATE_SO))
check("S12r2 session KWin on a replaced Qt, a fresh test KWin listed first -> WARN (missed before)",
      has(out, "WARN", "1 个被升级替换掉的库") and not has(out, "OK", "KWin 用的都是"), out)
out = kwin_with_test(maps_of(GATE_SO), maps_of(QT_GONE))
check("S12r3 test KWin's replaced Qt not judged -> OK", has(out, "OK", "KWin 用的都是") and not has(out, "WARN", "KWin 还"), out)
out = ts(pids={"kwin_wayland": "6100"}, files={**kwin_proc(6100, start=9000, virtual=True), "/proc/6100/maps": maps_of(QT_GONE)})
check("S12r4 only a test KWin up (no session) -> no KWin-library line", not has(out, "OK", "KWin 用的都是")
      and not has(out, "WARN", "KWin 还"), out)
def stale_exe(target):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    put("/proc/4343/exe", ""); LINKS["/proc/4343/exe"] = target + " (deleted)"
    put("/proc/4343/cgroup", "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-y700-osk.scope\n")
    return run_main()[1]
out = stale_exe("/usr/local/bin/y700-osk")
check("S12s keyboard binary replaced, old one running -> WARN says y700-osk-ctl restart", has(out, "WARN", "旧二进制")
      and has(out, "WARN", "y700-osk-ctl restart"), out)
out = stale_exe("/usr/libexec/tb323fu-helperd")
check("S12t another replaced binary -> WARN without the keyboard hint", has(out, "WARN", "旧二进制")
      and not has(out, "WARN", "y700-osk-ctl") and not has(out, "WARN", "别单独重启"), out)
out = stale_exe("/usr/lib/systemd/systemd-logind")
check("S12t3 logind left on the old binary (postinst never restarts it) -> WARN says wait for a reboot",
      has(out, "WARN", "systemd-logind 别单独重启") and has(out, "WARN", "等下次整机重启"), out)
out = stale_exe("/usr/bin/wireplumber")
check("S12t4 wireplumber on the old binary -> WARN says don't restart it alone (pro-audio)",
      has(out, "WARN", "wireplumber 别单独重启") and has(out, "WARN", "pro-audio"), out)
out = stale_exe("/usr/local/bin/y700-shellbar")
check("S12t2 shellbar built (install.sh --no-start) but the old one still up -> WARN says systemctl --user restart",
      has(out, "WARN", "旧二进制") and has(out, "WARN", "systemctl --user restart y700-shellbar") and not has(out, "WARN", "y700-osk-ctl"), out)

# ---- S12u-w an app the previous login left behind (10-21: wiliwili spun at 100 % after a re-login): /proc/<pid>/stat
# start ticks against the session kwin_wayland's; only app-* units in user's app.slice count
APPS = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/"
def orphans(*procs, pids="2901", kwins=None):
    files = dict(kwins or kwin_proc(2901))
    for pid, comm, cg, cpu, start in procs:
        files[f"/proc/{pid}/stat"] = pstat(pid, comm, cpu, start)
        files[f"/proc/{pid}/cgroup"] = APPS + cg + "\n"
    return ts(pids={"kwin_wayland": pids}, files=files)
out = orphans((4401, "wiliwili", "app-cn.xfangfang.wiliwili@603b.service", 330000, 4000),
              (4402, "claude-desktop", "app-com.anthropic.Claude-4402.scope", 600, 5010))
check("S12u wiliwili older than KWin -> WARN with unit and CPU minutes, the newer app not named",
      has(out, "WARN", "1 个程序是上一次登录留下的") and has(out, "WARN", "app-cn.xfangfang.wiliwili@603b.service")
      and has(out, "WARN", "累计 CPU 55 分钟") and not has(out, "WARN", "claude-desktop"), out)
out = orphans((4402, "claude-desktop", "app-com.anthropic.Claude-4402.scope", 600, 5010),
              (4403, "y700-hud-overla", "y700-hud-overlay.service", 50, 3000))
check("S12v apps newer than KWin, an old y700 user service -> OK", has(out, "OK", "没有上一次登录留下的程序"), out)
out = ts()
check("S12w kwin_wayland not running -> no leftover-app line", not has(out, "OK", "没有上一次登录")
      and not has(out, "WARN", "上一次登录留下"))
# a headless test KWin started after the owner's apps (chrome-vp9-check.sh runs ~3 min, 10-23): this login still
# began with the session KWin; taking the test one's start named every open app as left over
WILI_OLD = (4401, "wiliwili", "app-cn.xfangfang.wiliwili@603b.service", 330000, 4000)
CLAUDE_NOW = (4402, "claude-desktop", "app-com.anthropic.Claude-4402.scope", 600, 5010)
WITH_TEST = {**kwin_proc(2901), **kwin_proc(6100, start=9000, virtual=True)}
out = orphans(CLAUDE_NOW, pids="6100 2901", kwins=WITH_TEST)
check("S12w2 test KWin newer than the owner's apps -> OK (every app WARNed before)", has(out, "OK", "没有上一次登录留下的程序")
      and not has(out, "WARN", "上一次登录留下"), out)
out = orphans(WILI_OLD, CLAUDE_NOW, pids="6100 2901", kwins=WITH_TEST)
check("S12w3 test KWin up, a real leftover -> WARN naming it alone", has(out, "WARN", "1 个程序是上一次登录留下的")
      and has(out, "WARN", "wiliwili") and not has(out, "WARN", "claude-desktop"), out)
out = orphans(CLAUDE_NOW, pids="6100", kwins=kwin_proc(6100, start=9000, virtual=True))
check("S12w4 only a test KWin up (no session) -> no leftover-app line", not has(out, "OK", "没有上一次登录")
      and not has(out, "WARN", "上一次登录留下"), out)
# a re-login: the old session KWin (the higher pid, pids wrapped) still exiting, and another user's kwin_wayland (an
# SDDM Wayland greeter) started last: judged from the session KWin started last (1200)
RELOGIN = {**kwin_proc(2901, start=5000), **kwin_proc(1200, start=7000), **kwin_proc(3001, start=9500, uid=120)}
out = orphans((4404, "wiliwili", "app-cn.xfangfang.wiliwili@60c1.service", 1200, 6000),
              (4405, "claude-desktop", "app-com.anthropic.Claude-4405.scope", 600, 7100), pids="3001 2901 1200", kwins=RELOGIN)
check("S12w5 two session KWins and another user's -> the session one started last counts", has(out, "WARN", "1 个程序是上一次登录留下的")
      and has(out, "WARN", "wiliwili") and not has(out, "WARN", "claude-desktop"), out)

# ---- S12x-z the self-built wiliwili carries our four patches (10-21): one marker string per patch in the binary
WW_MARKS = (b"Video mirror order: {}", b"WILIWILI_DRM_RENDER_NODE", b"/y700-video", b"Wayland: Lost the connection to the compositor")
def ww_binary(*marks):
    return ts(files={"/usr/local/bin/wiliwili": b"\x7fELF\x02\x01\x01" + b"\0".join(marks) + b"\0" * 64})
out = ww_binary(*WW_MARKS)
check("S12x all four markers -> OK", has(out, "OK", "wiliwili 带着我们的 4 个补丁") and not has(out, "WARN", "wiliwili 缺"), out)
out = ww_binary(*WW_MARKS[:3])
check("S12y rebuilt without the GLFW patch -> WARN naming only it", has(out, "WARN", "缺 1 个我们的补丁")
      and has(out, "WARN", "wiliwili-glfw-wayland-disconnect.patch") and not has(out, "WARN", "zero-copy"), out)
out = ts()
check("S12z no self-built wiliwili -> no wiliwili line", not has(out, "OK", "wiliwili 带着") and not has(out, "WARN", "wiliwili 缺"))

# ---- S13 wireless CarPlay (linux/carplay): the real launcher and hotspot drop-in from the repo, the MFi coprocessor
# node /dev/i2c-99; busy (livi-core up) -> gst-host's environ checked
GST_SO = "/usr/local/lib/y700-carplay/y700-gst-colorimetry.so"
LOCKOUT = "/etc/NetworkManager/conf.d/99-livi-ap-unmanaged.conf"
AWAKE_STAMP = "/run/user/1000/y700-carplay-frames"
GST_LOG = "/home/user/.config/LIVI/log/gst-host.log"
AP_UNIT = "/etc/systemd/system/livi-wifi-ap.service"   # as LIVI 9.4.0 writes it (its template, user filled in)
AP_UNIT_TEXT = ("[Unit]\nDescription=LIVI wireless projection AP (early boot)\n\n[Service]\nType=simple\n"
                "Environment=SUDO_USER=%s\nExecStart=/usr/local/sbin/livi-helperd --wifi-ap\n")
KWIN_RULES = "/home/user/.config/kwinrulesrc"   # as install-livi.sh step 6 leaves it, next to an older rule of ours
LIVI_RULE = ("[y700-livi-fullscreen]\nDescription=LIVI 主屏全屏（y700，10-23）\nfullscreen=true\nfullscreenrule=2\n"
             "title=LIVI\ntitlematch=1\nwmclass=dev.f-io.livi\nwmclasscomplete=false\nwmclassmatch=1\n")
def kwin_rules(rule=LIVI_RULE, listed="y700-chatgpt-max,y700-livi-fullscreen"):
    put(KWIN_RULES, f"[General]\ncount=2\nrules={listed}\n\n[y700-chatgpt-max]\nwmclass=chatgpt\n\n{rule}")
SYS_WL = "/usr/lib/aarch64-linux-gnu/libwayland-client.so.0.24.0"
PS_HOOK = "/etc/NetworkManager/dispatcher.d/90-y700-carplay-ps"   # ps-restore's second half (10-24)
PS_PENDING = "/run/y700-carplay/ps-pending-wlp1s0"
def carplay(busy=False):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    put("/usr/local/bin/y700-carplay", builtins.open(realos.path.join(LIVI_SRC, "y700-carplay"), "rb").read())
    put("/etc/systemd/system/livi-wifi-ap.service.d/y700.conf", builtins.open(realos.path.join(LIVI_SRC, "livi-wifi-ap-y700.conf"), "rb").read())
    put(AP_UNIT, AP_UNIT_TEXT % "user")
    put(PS_HOOK, builtins.open(realos.path.join(LIVI_SRC, "90-y700-carplay-ps"), "rb").read()); MODE[PS_HOOK] = 0o100755
    put(GST_SO, b"\x7fELF\x02\x01\x01" + b"\0" * 57)
    put("/dev/i2c-99", "")
    put("/usr/bin/kde-inhibit", "bin")
    kwin_rules()
    if busy:
        S["pids"] = {"livi-core": "4100", "livi-gst-host": "4242"}
        S["active"]["livi-wifi-ap.service"] = "active"; S["power_save"] = "Power save: off"   # AP mode has no power save
        put("/proc/4242/environ", f"HOME=/root\0LIVI_GST_PRELOAD={GST_SO}\0LD_PRELOAD={GST_SO}\0")
        put("/proc/4242/maps", f"ffff8a000000-ffff8a001000 r-xp 00000000 103:05 1234 {GST_SO}\n"
                               f"ffff8b000000-ffff8b010000 r-xp 00000000 103:05 77 {SYS_WL}\n")
        # keep_awake: its loop's stamp, the phone's frames 3 s ago, the holder up for 2 min (time.time(), not NOW:
        # S13 runs a while after the selftest starts and these are compared with the clock)
        put(AWAKE_STAMP, "", mtime=time.time() - 4); put(GST_LOG, "[cp_screen] recv 0x7a000001: in=150\n", mtime=time.time() - 3)
        S["holder"], S["held_s"] = "4300", "120"
def cp(lines):
    return [l for l in lines if "CarPlay：" in l or "CarPlay 就绪" in l or "「CarPlay」" in l]
carplay(); realos.remove(tr("/usr/local/bin/y700-carplay")); put(LOCKOUT, "[keyfile]\n")
rc, out = run_main()
check("S13a launcher absent -> no CarPlay line", not cp(out), cp(out))
check("S13a power save OK with the hotspot down", has(out, "OK", "Wi-Fi 省电模式开着"))
carplay()
rc, out = run_main(); show("S13b CarPlay idle, all good", cp(out) + [l for l in out if "省电模式" in l], pref=("OK", "WARN", "INFO"))
check("S13b idle -> OK", has(out, "OK", "CarPlay 就绪") and not has(out, "WARN", "CarPlay"), cp(out))
carplay(); realos.remove(tr("/dev/i2c-99"))
rc, out = run_main()
check("S13c no /dev/i2c-99 -> WARN, exit 10", has(out, "WARN", "没有 /dev/i2c-99") and rc == 10, cp(out))
carplay(busy=True)
rc, out = run_main(); show("S13e CarPlay busy", cp(out) + [l for l in out if "热点占着" in l], pref=("OK", "WARN", "INFO"))
check("S13e busy -> OK", has(out, "OK", "CarPlay 就绪") and not has(out, "WARN", "CarPlay"), cp(out))
check("S13e hotspot up -> power-save line INFO, not WARN", has(out, "INFO", "CarPlay 的热点占着") and not has(out, "WARN", "省电模式"))
carplay(busy=True); put("/proc/4242/environ", f"HOME=/root\0LIVI_GST_PRELOAD={GST_SO}\0")   # inherited, never preloaded
put("/proc/4242/maps", "ffff8a000000-ffff8a001000 r-xp 00000000 103:05 99 /usr/lib/aarch64-linux-gnu/libgstvideo-1.0.so.0\n")
rc, out = run_main()
check("S13f busy, gst-host has the variable but not the library -> WARN",
      has(out, "WARN", "4242 没加载色彩修正库"))
carplay(); put("/etc/systemd/system/livi-wifi-ap.service.d/y700.conf", "[Unit]\nWants=y700-carplay-ap-tune.service\n")
rc, out = run_main()
check("S13j drop-in without settle -> WARN", has(out, "WARN", "没挂 y700-carplay-ap-settle"))
# ps-restore's stop timeout (10-23): LIVI's unit gives 8 s, the drop-in 40; the repo's drop-in passes (S13b)
DROPIN = "/etc/systemd/system/livi-wifi-ap.service.d/y700.conf"
REPO_DROPIN = builtins.open(realos.path.join(LIVI_SRC, "livi-wifi-ap-y700.conf"), encoding="utf-8").read()
carplay(); put(DROPIN, re.sub(r"(?m)^TimeoutStopSec=.*\n", "", REPO_DROPIN))
rc, out = run_main()
check("S13j2 drop-in with ps-restore but no TimeoutStopSec (LIVI's 8 s) -> WARN", has(out, "WARN", "TimeoutStopSec")
      and not has(out, "OK", "CarPlay 就绪") and rc == 10, cp(out))
carplay(); put(DROPIN, REPO_DROPIN.replace("TimeoutStopSec=40", "TimeoutStopSec=8"))
rc, out = run_main()
check("S13j3 TimeoutStopSec=8 -> WARN", has(out, "WARN", "TimeoutStopSec"), cp(out))
carplay(); put(DROPIN, REPO_DROPIN.replace("ExecStopPost=-/usr/local/sbin/y700-carplay-ps-restore", ""))
rc, out = run_main()
check("S13j4 no ps-restore at all -> WARN", has(out, "WARN", "没挂 y700-carplay-ps-restore"), cp(out))
carplay(); put(DROPIN, REPO_DROPIN.replace("TimeoutStopSec=40", "TimeoutStopSec=30s"))
rc, out = run_main()
check("S13j5 TimeoutStopSec=30s -> no WARN", not has(out, "WARN", "CarPlay"), cp(out))
# ps-restore's dispatcher hook (10-24): NetworkManager skips one that is not root's, root-only-writable and executable
carplay(); realos.remove(tr(PS_HOOK))
rc, out = run_main()
check("S13j6 dispatcher hook missing -> WARN 不在", has(out, "WARN", "90-y700-carplay-ps 不在") and rc == 10, cp(out))
carplay(); MODE[PS_HOOK] = 0o100775
rc, out = run_main()
check("S13j7 hook group-writable (NM skips it) -> WARN", has(out, "WARN", "不是 root 所有、只有 root 能写的可执行文件"), cp(out))
carplay(); MODE[PS_HOOK] = 0o100644
rc, out = run_main()
check("S13j8 hook not executable -> WARN", has(out, "WARN", "90-y700-carplay-ps 不是 root"), cp(out))
carplay(); UID[PS_HOOK] = 1000
rc, out = run_main()
check("S13j9 hook not root's -> WARN", has(out, "WARN", "90-y700-carplay-ps 不是 root"), cp(out))
carplay(); put(PS_HOOK, "#!/bin/sh\nexit 0\n")
rc, out = run_main()
check("S13j10 hook that does not call ps-restore -> WARN", has(out, "WARN", "没调 y700-carplay-ps-restore"), cp(out))
# power save off with the pending mark (10-24): not connected -> INFO (the hook's job is still due); connected -> WARN
# naming the mark; no mark -> the old WARN
def ps_off(mark=True, link=None):
    carplay(); S["power_save"] = "Power save: off"
    if mark:
        put(PS_PENDING, "2026-10-23 23:49:09\n")
    if link is not None:
        S["iw_link"] = link
    rc, out = run_main()
    return rc, out, [l for l in out if "省电模式" in l]
rc, out, ps = ps_off(link="Not connected.")
check("S13j11 power save off, mark, not connected -> INFO, no WARN", has(out, "INFO", "等 NetworkManager 下次连上时")
      and not has(out, "WARN", "省电模式"), ps)
rc, out, ps = ps_off()
check("S13j12 power save off, mark, connected -> WARN naming the mark and the hook",
      has(out, "WARN", "这次它留了待办") and has(out, "WARN", "90-y700-carplay-ps 开回来") and rc == 10, ps)
rc, out, ps = ps_off(mark=False, link="Not connected.")
check("S13j13 power save off, no mark (not connected) -> the old WARN", has(out, "WARN", "Wi-Fi 省电模式是「Power save: off」")
      and not has(out, "WARN", "这次它留了待办"), ps)
rc, out, ps = ps_off(link="ERROR Command ['iw', 'dev', 'wlp1s0', 'link'] timed out after 20 seconds")
check("S13j14 mark, iw link failed -> WARN (not taken for not connected)", has(out, "WARN", "这次它留了待办"), ps)
carplay(); put(LOCKOUT, "[keyfile]\nunmanaged-devices=interface-name:wlp1s0\n")
rc, out = run_main()
check("S13k lockout conf left while idle -> WARN", has(out, "WARN", "99-livi-ap-unmanaged.conf 还在"))
carplay(busy=True); put(LOCKOUT, "[keyfile]\n")
rc, out = run_main()
check("S13k2 lockout conf while busy -> no WARN", not has(out, "WARN", "CarPlay"), cp(out))
carplay(); S["active"]["livi-wifi-ap.service"] = "active"; S["power_save"] = "Power save: off"
rc, out = run_main()
check("S13l hotspot up without LIVI -> WARN, power-save INFO", has(out, "WARN", "热点单元却开着") and has(out, "INFO", "CarPlay 的热点占着")
      and not has(out, "WARN", "省电模式"))
carplay(); S["active"]["livi-wifi-ap.service"] = "deactivating"; S["power_save"] = ""; put(LOCKOUT, "[keyfile]\n")
rc, out = run_main()
check("S13l2 hotspot stopping (LIVI gone, ath12k reloading) -> INFO only, no WARN",
      has(out, "INFO", "热点正在起/停") and not has(out, "WARN", "省电模式") and not has(out, "WARN", "CarPlay"), cp(out))
# the hotspot unit's user (10-20): root (LIVI once started through plain sudo) -> WARN; no unit -> not judged
carplay(); put(AP_UNIT, AP_UNIT_TEXT % "root")
rc, out = run_main()
check("S13l3 hotspot unit written for root -> WARN", has(out, "WARN", "热点单元里写的用户是 root") and rc == 10, cp(out))
carplay(); realos.remove(tr(AP_UNIT))
rc, out = run_main()
check("S13l4 no hotspot unit -> not judged", has(out, "OK", "CarPlay 就绪") and not has(out, "WARN", "CarPlay"), cp(out))
carplay(); S["enabled"]["y700-carplay-boot-guard.service"] = "disabled"
rc, out = run_main()
check("S13m boot guard disabled -> WARN", has(out, "WARN", "y700-carplay-boot-guard 没启用"))
carplay(); put(GST_SO, "not an ELF")
rc, out = run_main()
check("S13n colorimetry .so not ELF -> WARN", has(out, "WARN", "色彩修正库"))
carplay(); put("/usr/local/bin/y700-carplay", "#!/bin/sh\nexec /opt/livi/AppRun\n")
rc, out = run_main()
check("S13n2 launcher without LIVI_GST_PRELOAD -> WARN", has(out, "WARN", "LIVI_GST_PRELOAD"))
# LIVI 10.0.0's own libwayland-client (10-23): the launcher must preload the system's; a gst-host mapping the
# bundled one -> WARN naming it
carplay(); put("/usr/local/bin/y700-carplay", f"#!/bin/sh\nexport LIVI_GST_PRELOAD={GST_SO}\nexec /opt/livi/LIVI --while-frames\n")
rc, out = run_main()
check("S13n3 LIVI_GST_PRELOAD without libwayland-client -> WARN 1.23", has(out, "WARN", "没带系统的 libwayland-client")
      and not has(out, "OK", "CarPlay 就绪"), cp(out))
BUNDLED_WL = "/opt/livi-10.0.0/resources/gst-host/lib/libwayland-client.so.0.23.1"
carplay(busy=True); put("/proc/4242/maps", f"ffff8a000000-ffff8a001000 r-xp 00000000 103:05 1234 {GST_SO}\n"
                                           f"ffff8b000000-ffff8b010000 r-xp 00000000 103:05 88 {BUNDLED_WL}\n")
rc, out = run_main()
check("S13n4 busy, gst-host maps LIVI's own libwayland-client -> WARN naming it",
      has(out, "WARN", "LIVI 自带的 libwayland-client") and has(out, "WARN", BUNDLED_WL), cp(out))
carplay(busy=True)
rc, out = run_main()
check("S13n5 busy, the system's libwayland-client mapped -> no WARN", not has(out, "WARN", "CarPlay"), cp(out))
# KWin rule forcing LIVI 10 full screen (10-23): missing, not listed, only applied initially -> WARN; any group
# name counts (the settings page names its rules by UUID)
carplay(); put(KWIN_RULES, "[General]\ncount=1\nrules=y700-chatgpt-max\n\n[y700-chatgpt-max]\nwmclass=chatgpt\n")
rc, out = run_main()
check("S13n6 no KWin rule for LIVI -> WARN 32 px", has(out, "WARN", "KWin 没有强制 LIVI 全屏的规则")
      and not has(out, "OK", "CarPlay 就绪") and rc == 10, cp(out))
carplay(); kwin_rules(listed="y700-chatgpt-max")
rc, out = run_main()
check("S13n7 rule written but not in General/rules (KWin ignores it) -> WARN", has(out, "WARN", "KWin 没有强制 LIVI 全屏的规则"), cp(out))
carplay(); kwin_rules(rule=LIVI_RULE.replace("fullscreenrule=2", "fullscreenrule=3"))
rc, out = run_main()
check("S13n8 rule only 'apply initially' -> WARN", has(out, "WARN", "KWin 没有强制 LIVI 全屏的规则"), cp(out))
UUID_G = "8b0c1f9e-5c1d-4c3e-9f2a-1d2e3f4a5b6c"
carplay(); kwin_rules(rule=LIVI_RULE.replace("y700-livi-fullscreen", UUID_G), listed=f"y700-chatgpt-max,{UUID_G}")
rc, out = run_main()
check("S13n9 the same rule under a UUID group name -> OK", has(out, "OK", "全屏规则")
      and not has(out, "WARN", "CarPlay"), cp(out))
carplay(); realos.remove(tr(KWIN_RULES))
rc, out = run_main()
check("S13n10 no kwinrulesrc at all -> WARN", has(out, "WARN", "KWin 没有强制 LIVI 全屏的规则"), cp(out))
DASH = {f"dash{i}": {"aux": False, "dash": False, "main": i < 3, "pos": i} for i in range(1, 5)}
PROJ = {"projectionWidth": 1600, "projectionHeight": 1000, "projectionDpi": 0}   # dpi 0 since 10-23 (10.0.0)
def livi_cfg(**kw):
    put("/home/user/.config/LIVI/config.json", json.dumps({"wifiPassword": "SELFTEST-PASS-NOT-SECRET", **PROJ,
                                                                "carPlayVehicleClimate": False, **kw}))
carplay(); livi_cfg(dashboards=DASH, wirelessAaEnabled=True)
rc, out = run_main()
check("S13p cluster dashboards off, Android Auto on -> OK naming AA", has(out, "OK", "CarPlay 就绪") and has(out, "OK", "无线 Android Auto 开着")
      and not has(out, "WARN", "CarPlay"), cp(out))
DASH["dash3"]["main"] = True
carplay(); livi_cfg(dashboards=DASH, wirelessAaEnabled=True)
rc, out = run_main()
check("S13p2 dash3 on -> WARN 30 帧, passphrase never printed", has(out, "WARN", "仪表盘开着（dash3）") and not has(out, "WARN", "dash4")
      and not has(out, "WARN", "Android Auto") and not any("SELFTEST-PASS" in l for l in out), cp(out))
DASH["dash3"]["main"] = False
# 10.0.0's "dashboard" (10-23): migrated from 9.4.0's slots it came out main = true -> 30 fps; it wins over a stale
# "dashboards"
OFF = {"main": False, "cluster": False, "aux": False}
carplay(); livi_cfg(dashboard=OFF, wirelessAaEnabled=True)
rc, out = run_main()
check("S13p10 10.0.0 dashboard all off -> OK", has(out, "OK", "CarPlay 就绪") and not has(out, "WARN", "CarPlay"), cp(out))
carplay(); livi_cfg(dashboard={**OFF, "main": True}, wirelessAaEnabled=True)
rc, out = run_main()
check("S13p11 10.0.0 dashboard main on (9.4.0's migration) -> WARN 30 帧, passphrase never printed",
      has(out, "WARN", "仪表盘开着（main）") and has(out, "WARN", "30 帧") and not any("SELFTEST-PASS" in l for l in out)
      and rc == 10, cp(out))
carplay(); livi_cfg(dashboard=OFF, dashboards={**DASH, "dash3": {**DASH["dash3"], "main": True}}, wirelessAaEnabled=True)
rc, out = run_main()
check("S13p12 dashboard off, a stale dashboards with dash3 on -> no WARN (10.0.0 reads dashboard)",
      not has(out, "WARN", "CarPlay"), cp(out))
# wireless Android Auto (10-20): on in config.json; off or absent (LIVI's default) -> WARN
carplay(); livi_cfg(dashboards=DASH, wirelessAaEnabled=False)
rc, out = run_main()
check("S13p4 Android Auto off -> WARN, passphrase never printed", has(out, "WARN", "无线 Android Auto 关着")
      and not has(out, "OK", "CarPlay 就绪") and not any("SELFTEST-PASS" in l for l in out) and rc == 10, cp(out))
carplay(); livi_cfg(dashboards=DASH)
rc, out = run_main()
check("S13p5 no wirelessAaEnabled key (LIVI's default off) -> WARN", has(out, "WARN", "无线 Android Auto 关着"), cp(out))
carplay()
rc, out = run_main()
check("S13p6 no LIVI config at all -> not judged, OK without the AA words", has(out, "OK", "CarPlay 就绪")
      and not has(out, "OK", "Android Auto") and not has(out, "WARN", "CarPlay"), cp(out))
carplay(); put("/home/user/.config/LIVI/config.json", "{not json")
rc, out = run_main()
check("S13p3 unreadable LIVI config -> no CarPlay WARN", not has(out, "WARN", "CarPlay"), cp(out))
# projection asked of the phones (10-20): 1600x1000 at 270 dpi; LIVI's 1152x720 gives Android Auto its 720p tier
carplay(); livi_cfg(dashboards=DASH, wirelessAaEnabled=True, projectionWidth=1152, projectionHeight=720, projectionDpi=0)
rc, out = run_main()
check("S13p7 projection 1152x720 dpi 0 -> WARN naming the size, passphrase never printed",
      has(out, "WARN", "投屏是 1152x720、0 dpi") and not has(out, "OK", "CarPlay 就绪")
      and not any("SELFTEST-PASS" in l for l in out) and rc == 10, cp(out))
carplay(); livi_cfg(dashboards=DASH, wirelessAaEnabled=True, projectionDpi=270)
rc, out = run_main()
check("S13p8 1600x1000 at 10-20's 270 dpi (10.0.0: the iPhone draws a size larger) -> WARN",
      has(out, "WARN", "投屏是 1600x1000、270 dpi") and has(out, "WARN", "大一号"), cp(out))
carplay(); put("/home/user/.config/LIVI/config.json", json.dumps({"dashboard": OFF, "wirelessAaEnabled": True,
               "projectionWidth": 1600, "projectionHeight": 1000, "carPlayVehicleClimate": False}))
rc, out = run_main()
check("S13p8b no projectionDpi key (LIVI's 0) -> OK", has(out, "OK", "CarPlay 就绪") and not has(out, "WARN", "CarPlay"), cp(out))
# 10.0.0's vehicle climate (10-23): on or absent in a 10.0.0 file -> WARN; a 9.4.0 file is not judged on it
carplay(); livi_cfg(dashboard=OFF, wirelessAaEnabled=True, carPlayVehicleClimate=True)
rc, out = run_main()
check("S13p13 vehicle climate on -> WARN 时钟, passphrase never printed", has(out, "WARN", "车辆空调开着")
      and not has(out, "OK", "CarPlay 就绪") and not any("SELFTEST-PASS" in l for l in out) and rc == 10, cp(out))
carplay(); put("/home/user/.config/LIVI/config.json", json.dumps({"dashboard": OFF, "wirelessAaEnabled": True, **PROJ}))
rc, out = run_main()
check("S13p14 no carPlayVehicleClimate key in a 10.0.0 file -> WARN", has(out, "WARN", "车辆空调开着"), cp(out))
carplay(); put("/home/user/.config/LIVI/config.json", json.dumps({"dashboards": DASH, "wirelessAaEnabled": True, **PROJ}))
rc, out = run_main()
check("S13p15 a 9.4.0 file without the key -> climate not judged", not has(out, "WARN", "车辆空调"), cp(out))
carplay(); put("/home/user/.config/LIVI/config.json", json.dumps({"dashboards": DASH, "wirelessAaEnabled": True}))
rc, out = run_main()
check("S13p9 no projection keys (LIVI fits 720p itself) -> WARN 默认", has(out, "WARN", "投屏是 默认x默认、默认 dpi")
      and not has(out, "WARN", "无线 Android Auto 关着"), cp(out))
carplay(); S["active"]["y700-carplay-test-guard.timer"] = "active"
rc, out = run_main()
check("S13o test-guard timer left -> note in the OK line", has(out, "OK", "实测自恢复定时器还挂着") and not has(out, "WARN", "CarPlay"))
# keep_awake (10-20): the launcher's screen hold while the phone's frames come in
carplay(busy=True)
rc, out = run_main()
check("S13q busy, frames, holder 2 min, PowerDevil honours it -> OK 屏幕保持亮着",
      has(out, "OK", "屏幕保持亮着") and not has(out, "WARN", "CarPlay"), cp(out))
carplay(); put("/usr/local/bin/y700-carplay", builtins.open(realos.path.join(LIVI_SRC, "y700-carplay"), "rb").read()
                                              .replace(b"--while-frames", b"--x"))
rc, out = run_main()
check("S13q2 launcher without keep_awake -> WARN, also idle", has(out, "WARN", "启动器没有保持亮屏"), cp(out))
carplay(); realos.remove(tr("/usr/bin/kde-inhibit"))
rc, out = run_main()
check("S13q3 no kde-inhibit -> WARN", has(out, "WARN", "没装 kde-inhibit"), cp(out))
carplay(busy=True); S["has_inhibition"] = "(false,)"
rc, out = run_main()
check("S13q4 holder up but PowerDevil has no screen inhibition -> WARN", has(out, "WARN", "PowerDevil 却没认"), cp(out))
carplay(busy=True); S["has_inhibition"], S["held_s"] = "(false,)", "4"
rc, out = run_main()
check("S13q5 holder 4 s old (PowerDevil waits ~5 s) -> not judged, no WARN", not has(out, "WARN", "CarPlay"), cp(out))
carplay(busy=True); S["holder"] = ""
rc, out = run_main()
check("S13q6 frames but no holder yet -> note only", has(out, "OK", "保持亮屏还没接上") and not has(out, "WARN", "CarPlay"), cp(out))
carplay(busy=True); realos.remove(tr(AWAKE_STAMP))
rc, out = run_main()
check("S13q7 busy, no keep_awake stamp -> WARN 循环没在跑", has(out, "WARN", "保持亮屏的循环没在跑"), cp(out))
carplay(busy=True); put(AWAKE_STAMP, "", mtime=time.time() - 90)
rc, out = run_main()
check("S13q8 stamp 90 s old -> WARN 循环没在跑", has(out, "WARN", "保持亮屏的循环没在跑"), cp(out))
carplay(busy=True); put(GST_LOG, "x\n", mtime=time.time() - 120)
rc, out = run_main()
check("S13q9 phone gone 2 min, holder still there -> WARN 还没放", has(out, "WARN", "秒没发画面，保持亮屏却还没放"), cp(out))
carplay(busy=True); put(GST_LOG, "x\n", mtime=time.time() - 120); S["holder"] = ""
rc, out = run_main()
check("S13q10 phone gone, LIVI open, hold released -> no WARN (the panel may sleep)",
      not has(out, "WARN", "CarPlay") and not has(out, "OK", "屏幕保持亮着"), cp(out))
# Android Auto with a still picture (10-20): no frame for 2 min, but its session on 5277 is up -> the hold is right
AA_SS = "0      0      10.10.0.1:5277      10.10.0.21:42520\n"
carplay(busy=True); put(GST_LOG, "x\n", mtime=time.time() - 120); S["aa_ss"] = AA_SS
rc, out = run_main()
check("S13q11 AA session, still picture, hold up -> OK 屏幕保持亮着, no 还没放 WARN",
      has(out, "OK", "安卓手机的 Android Auto 连着，屏幕保持亮着") and not has(out, "WARN", "CarPlay"), cp(out))
carplay(busy=True); put(GST_LOG, "x\n", mtime=time.time() - 120); S["aa_ss"], S["holder"] = AA_SS, ""
rc, out = run_main()
check("S13q12 AA session, no holder yet -> note only", has(out, "OK", "Android Auto 连着，保持亮屏还没接上")
      and not has(out, "WARN", "CarPlay"), cp(out))

# ---- S14 LIVI version baseline: /opt/livi -> livi-9.4.0; an old state without the key -> INFO once (and --save keeps it);
# a different version -> CHANGED; the same -> silent
def livi(**kw):
    base_tree(); archived(); state(prev_boot=PREV_ID, **kw)
    put("/opt/livi-9.4.0/resources/core/livi-core", "bin"); put("/opt/livi", "link"); LINKS["/opt/livi"] = "/opt/livi-9.4.0"
livi()
rc, out = run_main(save=True)
check("S14a old state without livi -> INFO 开始监视", has(out, "INFO", "开始监视 LIVI 版本 livi-9.4.0") and not has(out, "CHANGED", "LIVI"))
saved = json.loads(builtins.open(tr(mod.STATE), encoding="utf-8").read())
check("S14a --save stores livi", saved.get("livi") == "livi-9.4.0", saved.get("livi"))
rc, out = run_main()
check("S14b same version -> silent", not any("LIVI livi" in l or "开始监视 LIVI" in l for l in out))
livi(livi="livi-9.3.0")
rc, out = run_main(); show("S14c LIVI upgraded", out, pref=("CHANGED",))
check("S14c changed version -> CHANGED, exit 10", has(out, "CHANGED", "LIVI livi-9.3.0 -> livi-9.4.0") and rc == 10)
base_tree(); archived(); state(prev_boot=PREV_ID)
rc, out = run_main()
check("S14d no /opt/livi, no key -> silent", not any("LIVI" in l for l in out))

# ---- S15 refresh rate follows video (linux/display/refresh-auto): the daemon's D-Bus status; off the bus, stuck below
# the base rate with no video asking, or the unit dead -> WARN; a video holding 60 Hz -> OK
def fine(**kw):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    S.update(kw)
    return run_main()
rc, out = fine()
check("S15a status at base -> OK, exit 0", has(out, "OK", "刷新率守护在跑：基准 120 Hz，现在 120 Hz") and rc == 0)
rc, out = fine(refresh_status="")                     # active but not on the session bus: gdbus prints only to stderr
check("S15b no D-Bus answer -> WARN, exit 10", has(out, "WARN", "D-Bus 状态读不出来") and rc == 10)
rc, out = fine(refresh_status=refresh_status(cur_hz=60))
check("S15c stuck at 60 Hz with no video -> WARN", has(out, "WARN", "面板停在 60 Hz") and rc == 10)
rc, out = fine(refresh_status=refresh_status(cur_hz=60, expected_hz=60, video_target=60, players={"mpv-3120": {"pid": 3120}}))
check("S15d a video holding 60 Hz -> OK", has(out, "OK", "视频要 60 Hz") and not has(out, "WARN", "刷新率"))
base_tree(); archived(); state(prev_boot=PREV_ID); S["active"]["y700-refresh-auto.service"] = "failed"
rc, out = run_main()
check("S15e unit failed -> WARN, status not read", has(out, "WARN", "刷新率跟随视频的守护是 failed") and not has(out, "WARN", "D-Bus"))
# Rust since 11-03: the Python version back, a panic's restarts, KWin's screen events lost -> WARN (status still read)
RA_UNIT = "/home/user/.config/systemd/user/y700-refresh-auto.service"
RA = {RA_UNIT: "[Service]\nExecStart=/usr/local/libexec/y700-refresh-auto\n"}
out = ts(files=RA)
check("S15f Rust, KWin events -> OK only", has(out, "OK", "刷新率守护在跑") and not has(out, "WARN", "刷新率"), out)
out = ts(files={RA_UNIT: "[Service]\nExecStart=/usr/bin/python3 %h/.local/bin/y700-refresh-auto\n"})
check("S15g the Python version back -> WARN", has(out, "WARN", "刷新率守护跑的是 Python 版") and has(out, "OK", "刷新率守护在跑"), out)
out = ts(files=RA, nrestarts={"y700-refresh-auto.service": "6"})
check("S15h 6 automatic restarts -> WARN", has(out, "WARN", "刷新率守护自动重启了 6 次"), out)
out = ts(files=RA, ra_kwin="no KWin screen events (the compositor closed the connection); checking the screen every second while below the base")
check("S15i KWin's events lost and not back -> WARN", has(out, "WARN", "刷新率守护收不到 KWin 的熄屏事件"), out)
out = ts(files=RA, ra_kwin="KWin screen events back")
check("S15j lost and back again -> no WARN", not has(out, "WARN", "刷新率"), out)
# ---- S16 volume keys (linux/audio): kded6 must have waited for the Lenovo tuning sink; no drop-in, a timed-out or
# missing wait, or the guard having had to restart kded6 -> WARN; the owner's own default kept -> OK
rc, out = fine()
check("S16a waited for the tuned sink -> OK", has(out, "OK", "音量键对准联想调音") and rc == 0)
base_tree(); archived(); state(prev_boot=PREV_ID); realos.remove(tr(KDED6_WAIT))
rc, out = run_main()
check("S16b no wait drop-in -> WARN, exit 10", has(out, "WARN", "kded6 没有“等联想调音”的开机等待") and rc == 10)
rc, out = fine(kded6_wait="tuned sink not the default after 12 s - starting plasmashell anyway")
check("S16c wait timed out -> WARN", has(out, "WARN", "kded6 没等到联想调音（tuned sink not the default"))
rc, out = fine(kded6_wait="")
check("S16d no wait line this boot -> WARN", has(out, "WARN", "没有等待记录"))
rc, out = fine(kded6_heals="2")
check("S16e guard restarted kded6 twice -> WARN", has(out, "WARN", "音量键本次开机绑错过 2 次"))
rc, out = fine(kded6_wait="owner's default 'alsa_output.usb-headset' kept; tuned sink present after 1.50 s")
check("S16f owner's default kept -> OK", has(out, "OK", "音量键对准联想调音") and not has(out, "WARN", "音量键"))

# ---- S17 armed is not effective (10-17 18:24 to the 10-18 reboot): the flight recorder's armed screen-off rows of
# the last 30 min with ~0 system-domain entries -> WARN naming the last entry; ~20/s -> OK; <10 armed min -> INFO;
# rows of a kernel without allow_system_off (aso=-) or with the screen on never count; a recorder restart's gap neither
def rec_rows(n, t0, sys_use, cl0=None, dpms="Off", aco="Y", aso="Y", step=10.0):
    """n slow-mode flight-recorder rows from uptime t0, pd= increments of sys_use per row (cl0 defaults to the same)."""
    out = []
    for i in range(n):
        t = t0 + i * step
        at = time.strftime("%H:%M:%S", time.gmtime(t + 3600 * 5))
        c0 = sys_use if cl0 is None else cl0
        out.append(f"t={t:.1f} at={at} up={t:.1f} bat=-310mW dpms={dpms} wifi=up/+0 gov=teo aco={aco} aso={aso} dl=off busy=0.4 "
                   f"ctxt=90 irqt=170 irq=arch_timer:140,IPI1:20,ipcc_0:10 c0=wfi:10,ret:60,rej:2 c1=wfi:2,ret:20,rej:0 "
                   f"pd=cl0:{c0}/3,cl1:{c0 + 20}/1,sys:{sys_use}/1 qs=apss:{sys_use}/+900,cxsd:0/+0,aosd:0/+0,ddr:0/+0\n")
    return "".join(out)
def rec(body):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    put(f"/var/log/y700-flightrec/flightrec-{BOOT8}.log",
        f"HEADER boot={BOOT8} at=2026-10-18 05:50:00 kernel={KERNEL} interval=10.0 sync=5 pstore_archived=7 aco=N aso=N dl=off\n" + body,
        mtime=NOW - 3)
    return run_main()
rc, out = rec(rec_rows(240, 1000, 200))                                # 40 armed min at 20/s
check("S17a 20/s armed -> OK, exit 0", has(out, "OK", "熄屏省电生效：最近 30 分钟") and has(out, "OK", "系统域 20.0 次/秒") and rc == 0)
rc, out = rec(rec_rows(120, 1000, 200) + rec_rows(60, 2200, 0, dpms="On", aco="N", aso="N") + rec_rows(240, 2800, 0, cl0=0))
show("S17b armed but stuck", out, pref=("WARN",))
check("S17b stuck after a healthy stretch -> WARN with the last entry, exit 10",
      has(out, "WARN", "熄屏省电开着但没生效") and has(out, "WARN", "系统域 0.0 次/秒") and has(out, "WARN", "最后一次进系统域是 05:36:30")
      and has(out, "WARN", "y700-whoawake 20") and has(out, "WARN", "plasma-plasmashell") and rc == 10, [l for l in out if "熄屏省电" in l])
rc, out = rec(rec_rows(240, 1000, 0, cl0=0))
check("S17c never entered this boot -> WARN says so", has(out, "WARN", "一次都没进过系统域"))
rc, out = rec(rec_rows(50, 1000, 0))
check("S17d 8 armed min -> INFO, no verdict", has(out, "INFO", "只有 8 分钟") and not has(out, "WARN", "熄屏省电"))
rc, out = rec(rec_rows(240, 1000, 0, aso="-") + rec_rows(240, 4000, 0, dpms="On"))
check("S17e aso=- or screen on never count", has(out, "INFO", "只有 0 分钟") and not has(out, "WARN", "熄屏省电"))
rc, out = rec(rec_rows(31, 1000, 0) + "STOP t=1305.0 at=05:21:45 signal\n" + rec_rows(30, 1310, 0))
check("S17f a recorder STOP breaks the row chain (590 s, not 600)", has(out, "INFO", "只有 9 分钟"), [l for l in out if "熄屏省电" in l])
rc, out = rec(rec_rows(31, 1000, 0) + rec_rows(30, 1400, 0))
check("S17g a >30 s gap between rows not counted (590 s, not 690)", has(out, "INFO", "只有 9 分钟"), [l for l in out if "熄屏省电" in l])
# 10-22: a stuck stretch, the screen woken once, then a healthy screen-off: the 30 armed minutes are still mostly the
# stuck stretch, but the latest screen-off enters the system domain -> OK + INFO naming the stuck stretch, exit 0
STUCK_ON = rec_rows(240, 1000, 0, cl0=0) + rec_rows(30, 3400, 0, dpms="On", aco="N", aso="N")
rc, out = rec(STUCK_ON + rec_rows(3, 3700, 270))
show("S17h stuck, then healthy", out, pref=("WARN", "OK", "INFO"))
check("S17h stuck stretch, then a healthy screen-off -> OK latest + INFO history, no WARN, exit 0",
      has(out, "OK", "最近一次熄屏 06:01:40–06:02:00 系统域 27.0 次/秒") and has(out, "INFO", "卡住过：05:16:50–05:56:30（40 分钟")
      and not has(out, "WARN", "熄屏省电") and rc == 0, [l for l in out if "熄屏" in l])
rc, out = rec(STUCK_ON + rec_rows(1, 3700, 270))
check("S17i the healthy screen-off is a single row -> still WARN", has(out, "WARN", "熄屏省电开着但没生效")
      and has(out, "WARN", "最后一次进系统域是 06:01:40") and not has(out, "OK", "最近一次熄屏"), [l for l in out if "熄屏" in l])
rc, out = rec(STUCK_ON + rec_rows(240, 3700, 200))
check("S17j 40 healthy minutes after an earlier stuck stretch -> OK on the window + INFO history",
      has(out, "OK", "熄屏省电生效：最近 30 分钟") and has(out, "INFO", "卡住过") and not has(out, "WARN", "熄屏省电"),
      [l for l in out if "熄屏" in l])
rc, out = rec(rec_rows(240, 1000, 200))
check("S17k healthy all along -> no stuck INFO", not has(out, "INFO", "卡住过"), [l for l in out if "熄屏" in l])

# ---- S18 Chromium's frame-callback begin-frame source (linux/power/chromium-bfs.py): silent until installed; then the
# Claude wrapper, every Chrome Exec line of the three launchers and a running Chrome / Claude GPU process must carry it
BFS = "WaylandExternalBeginFrameSource"
CHROME_EXEC = "Exec=/usr/bin/google-chrome-stable --ozone-platform=wayland --enable-features=WebRtcPipeWireCamera{} %U\n"
def bfs(wrapper=True, launcher="," + BFS, desk="," + BFS, gpu=None):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    if wrapper:
        put("/usr/local/bin/claude-desktop", "#!/bin/sh\nexec /usr/lib/claude-desktop/claude-desktop --enable-features=" + BFS + ' "$@"\n')
    if launcher is not None:
        put("/home/user/.local/share/applications/google-chrome.desktop",
            "[Desktop Entry]\n" + CHROME_EXEC.format(launcher) + "[Desktop Action new-window]\n" + CHROME_EXEC.format(launcher))
    if desk is not None:
        put("/home/user/Desktop/google-chrome.desktop", "[Desktop Entry]\n" + CHROME_EXEC.format(desk))
    if gpu is not None:                 # a running GPU process: (exe, cmdline)
        put("/proc/4242/cmdline", gpu[1]); LINKS["/proc/4242/exe"] = gpu[0]
    return run_main()
rc, out = fine()
check("S18a not installed -> no line, exit 0", not any("新帧源" in l for l in out) and rc == 0)
rc, out = bfs()
check("S18b installed -> OK, exit 0", has(out, "OK", "带 WaylandExternalBeginFrameSource 启动") and rc == 0)
rc, out = bfs(wrapper=False)
check("S18c wrapper gone -> WARN, exit 10", has(out, "WARN", "/usr/local/bin/claude-desktop 没了") and rc == 10)
rc, out = bfs(desk="")
check("S18d a launcher's Exec without it -> WARN names it",
      has(out, "WARN", "~/Desktop/google-chrome.desktop 有启动行不带开关") and not has(out, "WARN", "applications/google-chrome"))
rc, out = bfs(launcher=None, desk=None)
check("S18e wrapper only, launchers absent -> OK", has(out, "OK", "带 WaylandExternalBeginFrameSource 启动"))
rc, out = bfs(gpu=("/usr/lib/claude-desktop/claude-desktop", "/usr/lib/claude-desktop/claude-desktop\0--type=gpu-process\0--enable-features=Foo\0"))
check("S18f running Claude GPU process without it -> WARN", has(out, "WARN", "正在跑的 Claude 没带开关"))
rc, out = bfs(gpu=("/opt/google/chrome/chrome", "/opt/google/chrome/chrome --ozone-platform=wayland --enable-features=Foo," + BFS + " "))
check("S18g running Chrome browser with it (title rewritten, spaces) -> OK", has(out, "OK", "带 WaylandExternalBeginFrameSource 启动") and rc == 0)
rc, out = bfs(gpu=("/opt/google/chrome/chrome", "/opt/google/chrome/chrome --type=gpu-process --field-trial-handle=3,i,1 --enable-features=Foo "))
check("S18i Chrome GPU process without it (Finch carries it) -> still OK", has(out, "OK", "带 WaylandExternalBeginFrameSource 启动") and rc == 0)
rc, out = bfs(gpu=("/opt/google/chrome/chrome", "/opt/google/chrome/chrome --ozone-platform=wayland --enable-features=Foo "))
check("S18j running Chrome browser without it -> WARN", has(out, "WARN", "正在跑的 Chrome 没带开关"))
rc, out = bfs(wrapper=False, launcher="", desk="")
check("S18h undone (no wrapper, no feature anywhere) -> silent", not any("新帧源" in l for l in out))

# ---- S19 (10-19 audit) a file read in main() itself, outside guard(), that fails between exists() and open() - the
# ath12k version while CarPlay's settle reloads the module, a permission or a decode error - must cost one WARN, not
# the whole run (main()'s except printed a lone ERROR line, exit 1, and --save did not happen); an iw that timed out
# ("... after 20 seconds" contains "on") is not "power save on"
for path, exc in (("/sys/module/ath12k/version", FileNotFoundError(2, "No such file or directory")),
                  ("/etc/drirc", PermissionError(13, "Permission denied")),
                  ("/usr/local/share/y700-osk/oskgate.kwin-version", UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid start byte")),
                  ("/sys/class/devfreq/ddr/polling_interval", OSError(5, "Input/output error")),
                  ("/home/user/.config/powerdevilrc", PermissionError(13, "Permission denied"))):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    FAILOPEN[path] = exc
    try:
        rc, out = run_main()
    except Exception as e:                            # what __main__ turns into a lone "ERROR ..." line and exit 1
        rc, out = 1, [f"ERROR {e!r}"]
    FAILOPEN.clear()
    check(f"S19 {path} unreadable -> the run goes on (no lone ERROR, exit != 1)",
          rc != 1 and not any(l.startswith("ERROR") for l in out) and has(out, "OK", "内核是我们编的"), f"rc={rc} {out[-2:]}")
rc, out = fine(power_save="ERROR Command ['iw', 'dev', 'wlp1s0', 'get', 'power_save'] timed out after 20 seconds")
check("S19f iw timed out -> not 'power save on'", not has(out, "OK", "Wi-Fi 省电模式开着") and has(out, "WARN", "Wi-Fi 省电"),
      str([l for l in out if "省电" in l]))

# ---- S20 120 fps streaming floor (linux/streaming, 2026-10-20): y700-kwin-uclamp keeps KWin at uclamp.min 512 and the
# Moonlight launchers go through ~/.local/bin/y700-moonlight; silent when the service is not installed
ML_GOOD = "[Desktop Entry]\nExec=/home/user/.local/bin/y700-moonlight\n"
def stream(launchers=ML_GOOD, **kw):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    if launchers is not None:
        put("/home/user/.local/share/applications/com.moonlight_stream.Moonlight.desktop", launchers)
        put("/home/user/Desktop/com.moonlight_stream.Moonlight.desktop", launchers)
    for k, v in kw.items():             # merge into base_tree's dicts (its "enabled" holds sleep.target: masked)
        S[k] = {**S.get(k, {}), **v} if isinstance(v, dict) else v
    return run_main()
rc, out = stream()
check("S20a floor held, launchers right -> OK, exit 0", has(out, "OK", "KWin 13 个线程 uclamp.min 512") and rc == 0)
rc, out = stream(enabled={"y700-kwin-uclamp.service": "not-found"})
check("S20b not installed -> no line", not any("KWin" in l and "uclamp" in l for l in out) and rc == 0,
      f"rc={rc} {[l for l in out if l[:4] in ('WARN', 'CHAN') or 'uclamp' in l]}")
rc, out = stream(active={"y700-kwin-uclamp.service": "failed"})
check("S20c service down -> WARN, exit 10", has(out, "WARN", "y700-kwin-uclamp 没在跑") and rc == 10)
SLEPT, real_sleep = [], time.sleep
time.sleep = SLEPT.append              # the recheck waits 6 s for the daemon's rescan; record instead of waiting
LOW = "kwin_wayland 2901: 14 threads, 1 below 512: uclamp.min 512 0"
rc, out = stream(kwin_uclamp=[LOW, LOW])
check("S20d a thread still below the floor after the recheck -> WARN", has(out, "WARN", "KWin 有线程不在地板上") and SLEPT == [6],
      f"slept {SLEPT}")
SLEPT.clear()
rc, out = stream(kwin_uclamp=[LOW, "kwin_wayland 2901: 14 threads, 0 below 512: uclamp.min " + "512 " * 14])
check("S20f a brand-new thread floored by the rescan -> OK, exit 0", has(out, "OK", "KWin 14 个线程 uclamp.min 512") and rc == 0
      and SLEPT == [6], f"rc={rc} slept {SLEPT} {[l for l in out if 'KWin' in l]}")
time.sleep = real_sleep
# ---- S20g-i touch boost (10-21): GPU min_freq back at its floor = OK; stuck at the boost clock after the 11 s wait = WARN
GMIN = "/sys/class/devfreq/3d00000.gpu/min_freq"
def boost(minf, conf=None, **kw):
    SLEPT.clear()
    time.sleep = SLEPT.append
    try:
        base_tree(); archived(); state(prev_boot=PREV_ID)
        put("/home/user/.local/share/applications/com.moonlight_stream.Moonlight.desktop", ML_GOOD)
        put("/home/user/Desktop/com.moonlight_stream.Moonlight.desktop", ML_GOOD)
        put(GMIN, minf + "\n")
        if conf is not None:
            put("/etc/default/y700-kwin-uclamp", conf)
        for k, v in kw.items():
            S[k] = {**S.get(k, {}), **v} if isinstance(v, dict) else v
        return run_main()
    finally:
        time.sleep = real_sleep
rc, out = boost("160000000")
check("S20g GPU floor at 160 MHz -> OK names the boost clock", has(out, "OK", "触摸 boost 待命：GPU 最低 160 MHz，边缘手势时 600 MHz")
      and rc == 0 and SLEPT == [], f"rc={rc} slept {SLEPT} {[l for l in out if 'boost' in l]}")
rc, out = boost("600000000")
check("S20h stuck at 600 MHz after the wait -> WARN, exit 10", has(out, "WARN", "GPU 最低频卡在 600 MHz") and rc == 10
      and SLEPT == [11], f"rc={rc} slept {SLEPT}")
rc, out = boost("600000000", conf="UCLAMP_MIN=512\nBOOST_GPU_MHZ=0\n")
check("S20i boost off in the config -> no line", not any("boost" in l or "GPU 最低频" in l for l in out) and rc == 0,
      f"rc={rc} {[l for l in out if 'GPU' in l]}")
rc, out = stream(launchers="[Desktop Entry]\nExec=/usr/bin/flatpak run com.moonlight_stream.Moonlight\n")
check("S20e launcher overwritten -> WARN names it", has(out, "WARN", "Moonlight 启动项没走抬频启动器") and rc == 10)

# ---- S23 ChatGPT's screen keyboard (10-22, linux/daily/chatgpt-wayland-ime.sh): silent without the deb's entry; the
# override and the desktop icon must be the deb's entry with the IME switches on its Exec line; a running ChatGPT
# browser process without them is a WARN, a child process (--type=) is not "running"
CG_SYS = "[Desktop Entry]\nName=ChatGPT\nExec=chatgpt %U\nIcon=chatgpt\nType=Application\nMimeType=x-scheme-handler/codex;\n"
CG_FLAGS = "--ozone-platform=wayland --enable-wayland-ime --wayland-text-input-version=3"
CG_GOOD = CG_SYS.replace("Exec=chatgpt %U", "Exec=chatgpt " + CG_FLAGS + " %U")
def chatgpt(sys_entry=CG_SYS, override=CG_GOOD, desk=CG_GOOD, running=None):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    if sys_entry is not None:
        put("/usr/share/applications/chatgpt.desktop", sys_entry)
    if override is not None:
        put("/home/user/.local/share/applications/chatgpt.desktop", override)
    if desk is not None:
        put("/home/user/Desktop/chatgpt.desktop", desk)
    if running is not None:             # the browser process's cmdline (NUL-separated, as /proc has it)
        put("/proc/4343/cmdline", running); LINKS["/proc/4343/exe"] = "/usr/lib/chatgpt/ChatGPT"
    try:
        return run_main()
    finally:
        LINKS.pop("/proc/4343/exe", None)
rc, out = fine()
cg = [l for l in out if "ChatGPT" in l and "/etc/drirc" not in l]      # the drirc line names it since 10-23
check("S23a ChatGPT not installed -> no line, exit 0", not cg and rc == 0, cg)
rc, out = chatgpt()
check("S23b override and icon right, nothing running -> OK, exit 0", has(out, "OK", "ChatGPT 启动项带 Wayland IME 参数") and rc == 0,
      f"rc={rc} {[l for l in out if 'ChatGPT' in l]}")
rc, out = chatgpt(override=None)
check("S23c override gone -> WARN names it, exit 10", has(out, "WARN", "~/.local/share/applications/chatgpt.desktop 没了") and rc == 10)
rc, out = chatgpt(desk=CG_SYS)
check("S23d icon is the deb's entry -> WARN names the icon only",
      has(out, "WARN", "~/Desktop/chatgpt.desktop 的启动行不带 IME 参数") and not has(out, "WARN", "applications/chatgpt.desktop"))
rc, out = chatgpt(sys_entry=CG_SYS.replace("Icon=chatgpt", "Icon=chatgpt-new"))
check("S23e deb entry changed under the override -> WARN (rerun the script)", has(out, "WARN", "和 deb 的桌面项对不上") and rc == 10)
rc, out = chatgpt(running="/usr/lib/chatgpt/ChatGPT\0--ozone-platform=wayland\0--enable-wayland-ime\0--wayland-text-input-version=3\0")
check("S23f running with the switches -> OK says so", has(out, "OK", "正在跑的也带") and rc == 0)
rc, out = chatgpt(running="/usr/lib/chatgpt/ChatGPT\0")
check("S23g running without them -> WARN, exit 10", has(out, "WARN", "正在跑的 ChatGPT 没带 IME 参数") and rc == 10)
rc, out = chatgpt(running="/usr/lib/chatgpt/ChatGPT\0--type=gpu-process\0")
check("S23h only a child process seen -> OK, not counted as running",
      has(out, "OK", "ChatGPT 启动项带 Wayland IME 参数") and not has(out, "OK", "正在跑的也带") and rc == 0)

# ---- S24 the control centre's pills under a finger (10-22, linux/dock/tests/pill-drag-run.sh): the last verdict,
# stamped with the sha256 (12) of the Pill.qml it tested, against the installed /usr/local/share copy
PILL_QML = "/usr/local/share/y700-control-center/qml/Pill.qml"
PILL_SRC = "import QtQuick\nItem { id: pill }\n"
PILL_HASH = hashlib.sha256(PILL_SRC.encode()).hexdigest()[:12]
PILL_LAST = "/var/lib/y700/pill-drag-last.txt"
PILL_OK = "2026-10-22 13:38:50 OK 6 gestures, open 0 tap 30 30 drag +20 48 pinned, back 20 80 rest 80 drag -30 52 volume tap 50 50"
PILL_BAD = "2026-10-22 13:39:30 FAIL drag +20: 97 % wanted 48 %; pinned, back 20: 94 % wanted 80 % | open 0 tap 30 30 drag +20 97"
def pill(last=None, qml=PILL_SRC):
    files = {} if qml is None else {PILL_QML: qml}
    if last is not None:
        files[PILL_LAST] = last + "\n"
    return ts(files=files)
out = pill()
check("S24a installed, never run -> INFO", has(out, "INFO", "控制中心胶囊滑杆自检还没跑过"), [l for l in out if "胶囊" in l])
out = pill(PILL_OK + " pill " + PILL_HASH)
check("S24b last run passed on the installed Pill.qml -> OK with its time", has(out, "OK", "控制中心胶囊滑杆") and has(out, "OK", "2026-10-22 13:38:50 通过"),
      [l for l in out if "胶囊" in l])
out = pill(PILL_BAD + " pill " + PILL_HASH)
check("S24c last run failed on the installed one -> WARN quoting the gesture", has(out, "WARN", "控制中心胶囊滑杆自检上次没过") and has(out, "WARN", "drag +20: 97 %"))
# the old Pill.qml's red run (its stamp is the old hash) is stale once the new one is installed: a rerun, not a failure
out = pill(PILL_BAD + " pill 84dc3714714d")
check("S24d stale FAIL from the Pill.qml before -> INFO rerun naming both, no WARN", has(out, "INFO", "不是现在装的 Pill.qml") and has(out, "INFO", PILL_HASH)
      and has(out, "INFO", "84dc3714714d") and not has(out, "WARN", "胶囊"))
out = pill(PILL_OK + " pill unknown")
check("S24e verdict for pill unknown -> INFO rerun, not OK", has(out, "INFO", "不是现在装的 Pill.qml") and not has(out, "OK", "胶囊"))
out = pill(PILL_OK + " pill " + PILL_HASH, qml=None)
check("S24f control centre not installed -> no pill line", not any("胶囊" in l for l in out))

# ---- S25 the volume pill when the curtain opens (10-22, linux/dock/tests/vol-open-run.sh): the last verdict, stamped
# with the sha256 (12) of the control centre binary it tested (the volume reading is compiled in)
CC_BIN = "/usr/local/bin/y700-control-center"
CC_ELF = "\x7fELF fake control centre\n"
CC_HASH = hashlib.sha256(CC_ELF.encode()).hexdigest()[:12]
VOL_LAST = "/var/lib/y700/vol-open-last.txt"
VOL_OK = "2026-10-22 14:31:07 OK 4 steps, open 80 drag 62/62 slow-read 62->44/44 live 70 watchers 1/0"
VOL_BAD = ("2026-10-22 14:20:41 FAIL open after the keys set 80: the pill 40.0 % (a stale level: the volume waits for the"
           " pipeline); drag -68 px at once: sound 22 %, pill 22.1 %, wanted 61.8 % (80 - 18) | open 40 drag 22/22")
def vol(last=None, cc=CC_ELF):
    files = {} if cc is None else {CC_BIN: cc}
    if last is not None:
        files[VOL_LAST] = last + "\n"
    return ts(files=files)
out = vol()
check("S25a installed, never run -> INFO", has(out, "INFO", "控制中心开帘音量自检还没跑过"), [l for l in out if "开帘音量" in l])
out = vol(VOL_OK + " cc " + CC_HASH)
check("S25b last run passed on the installed binary -> OK with its time", has(out, "OK", "控制中心开帘就是当前音量")
      and has(out, "OK", "2026-10-22 14:31:07 通过"), [l for l in out if "音量" in l])
out = vol(VOL_BAD + " cc " + CC_HASH)
check("S25c last run failed on the installed one -> WARN quoting the step", has(out, "WARN", "控制中心开帘音量自检上次没过")
      and has(out, "WARN", "the pill 40.0 %"))
# the old binary's red run (the one before the fix) is stale once the new one is installed: a rerun, not a failure
out = vol(VOL_BAD + " cc 7acf5d408718")
check("S25d stale FAIL from the binary before -> INFO rerun naming both, no WARN", has(out, "INFO", "不是现在装的控制中心")
      and has(out, "INFO", CC_HASH) and has(out, "INFO", "7acf5d408718") and not has(out, "WARN", "开帘音量"))
out = vol(VOL_OK + " cc unknown")
check("S25e verdict for cc unknown -> INFO rerun, not OK", has(out, "INFO", "不是现在装的控制中心") and not has(out, "OK", "开帘"))
out = vol(VOL_OK + " cc " + CC_HASH, cc=None)
check("S25f control centre not installed -> no volume-open line", not any("开帘" in l for l in out))

# ---- S26a-h the game numbers (linux/games/hud, 10-22): the unit runs `--sampler` and the status bar shows them
# (HudLine.qml in an app, HudWidget.qml on the desktop); the old unit (the GTK bar) beside such a bar is every
# number twice, the new unit with a bar that cannot show them is numbers nobody sees
HUD_UNIT = "/home/user/.config/systemd/user/y700-hud-overlay.service"
HUD_BIN = "/home/user/.local/bin/y700-hud-overlay"
HUD_QML = "/usr/local/share/y700-shellbar/qml/HudLine.qml"
UNIT_OLD = "[Service]\nExecStart=%h/.local/bin/y700-hud-overlay\nRestart=on-failure\n"
UNIT_NEW = ("[Service]\nExecStart=%h/.local/bin/y700-hud-overlay --sampler\n"
            "ExecStopPost=/bin/rm -f %t/y700-hud.txt %t/y700-hud.txt.kv\nRestart=on-failure\n")
HUD_ELF = b"\x7fELF\x02\x01\x01"
def hud_lines(out):
    return [l for l in out if "性能浮层" in l]
out = ts()
check("S26a no HUD unit -> no line", not hud_lines(out), hud_lines(out))
out = ts(files={HUD_UNIT: UNIT_OLD, HUD_BIN: HUD_ELF})
check("S26b old unit, a status bar without the numbers -> OK (the GTK bar is the only display)",
      has(out, "OK", "性能浮层是 Rust 版") and not has(out, "WARN", "性能浮层"), hud_lines(out))
out = ts(files={HUD_UNIT: UNIT_OLD, HUD_BIN: HUD_ELF, HUD_QML: "Row {}\n"})
check("S26c old unit beside a status bar that shows them -> WARN every number twice",
      has(out, "WARN", "旧的 GTK 横条") and has(out, "WARN", "games/hud/install.sh"), hud_lines(out))
out = ts(files={HUD_UNIT: UNIT_NEW, HUD_BIN: HUD_ELF})
check("S26d sampler unit, a status bar without HudLine.qml -> WARN nobody sees them",
      has(out, "WARN", "只采样不显示") and has(out, "WARN", "y700-shellbar/install.sh"), hud_lines(out))
out = ts(files={HUD_UNIT: UNIT_NEW, HUD_BIN: HUD_ELF, HUD_QML: "Row {}\n"})
check("S26e sampler unit + status bar -> OK naming the bar and the widget",
      has(out, "OK", "Rust 采样器") and has(out, "OK", "桌面小组件") and not has(out, "WARN", "性能浮层"), hud_lines(out))
out = ts(files={HUD_UNIT: UNIT_NEW, HUD_BIN: "#!/usr/bin/python3\n", HUD_QML: "Row {}\n"})
check("S26f the binary is a script -> WARN half-done install", has(out, "WARN", "不是编译好的 Rust 程序"), hud_lines(out))
out = ts(files={HUD_UNIT: UNIT_NEW, HUD_BIN: HUD_ELF, HUD_QML: "Row {}\n"}, hud_fails="3")
check("S26g sampling panics this boot -> WARN with the count", has(out, "WARN", "采样出错 3 次"), hud_lines(out))
out = ts(files={HUD_UNIT: UNIT_NEW, HUD_BIN: HUD_ELF, HUD_QML: "Row {}\n"}, nrestarts={"y700-hud-overlay.service": "9"})
check("S26h the sampler restarted 9 times -> WARN it crashed (no GPU self-heal in it)",
      has(out, "WARN", "重启了 9 次") and has(out, "WARN", "重启就是崩了") and not has(out, "WARN", "GPU 卡死"), hud_lines(out))

# ---- S27 failed units (10-22: a run-once unit that deleted its own file stayed "failed", system degraded, unnoticed)
rc, out = fine()
check("S27a no failed unit -> OK", has(out, "OK", "没有失败的系统或用户服务") and rc == 0)
rc, out = fine(failed_sys="y700-glass-post.service not-found failed failed y700-glass-post.service")
check("S27b a failed system unit -> WARN naming it, exit 10",
      has(out, "WARN", "有失败的服务：系统 y700-glass-post.service") and has(out, "WARN", "reset-failed") and rc == 10)
rc, out = fine(failed_user="app-foo@1.service loaded failed failed foo\nbar.service loaded failed failed bar")
check("S27c failed user units -> WARN naming both", has(out, "WARN", "用户 app-foo@1.service、用户 bar.service"))
rc, out = fine(failed_user="ERROR timed out after 20 seconds")
check("S27d user scope unanswerable -> INFO, not WARN, not OK",
      has(out, "INFO", "查不了用户的失败服务") and not has(out, "WARN", "失败的服务") and not has(out, "OK", "没有失败的"))
# 11-03: the two that WARNed were KDE app launches (a pairing wizard that exits 1 on success, a shortcut pressed too fast)
LAUNCH = "app-%s@%s.service loaded failed failed x"
apps_failed = "\n".join([LAUNCH % ("bluedevil\\x2dwizard", "296d9d1b42104c94ad369b517f20118d")]
                        + [LAUNCH % ("kbd\\x2dbattery\\x2dnotify", f"{i:032x}") for i in range(12)])
rc, out = fine(failed_user=apps_failed)
check("S27e only KDE app launches failed -> one INFO per app with counts, OK, no WARN, exit 0",
      has(out, "INFO", "bluedevil-wizard ×1、kbd-battery-notify ×12") and has(out, "OK", "没有失败的系统或用户服务")
      and not has(out, "WARN", "失败的服务") and rc == 0)
rc, out = fine(failed_user=apps_failed + "\nbar.service loaded failed failed bar")
check("S27f an app launch next to a real failed unit -> the real one still WARNs, the launch stays INFO",
      has(out, "WARN", "有失败的服务：用户 bar.service") and not has(out, "WARN", "bluedevil")
      and has(out, "INFO", "bluedevil-wizard ×1") and rc == 10)

# ---- S28 GPU hangs across boots since the last --save (10-23: the daily run was stuck from 10-20 and the 10-19 hangs, in
# an earlier boot, were never reported by the this-boot-only check). The kernel lines are the 10-19 ones (y12), shortened.
def hang_lines(t, boot, comm, argv0, rest="--type=gpu-process"):
    pre = "msm_dpu 9801000.display-controller: [drm:recover_worker] *ERROR* 44050a31: "
    task = f"offending task: {comm} ({argv0} {rest}" if argv0 else f"offending task: {comm}"
    return [(t, boot, pre + "hangcheck recover!"), (t + 0.001, boot, pre + task)]
CHATGPT_1019 = sum((hang_lines(NOW - 20000 + 2 * i, PREV_ID, "ChatGPT", "/usr/lib/chatgpt/ChatGPT") for i in range(3)), []) + \
    hang_lines(NOW - 19560, PREV_ID, "steamweb:gdrv0", "/home/user/.local/share/Steam/steamrtarm64/steamwebhelper", "--type=zygote")
DRIRC_CHROME_ONLY = ('<driconf><device driver="loader" kernel_driver="msm"><application name="Google Chrome" executable="chrome">'
                     '<option name="dri_driver" value="zink" /></application></device></driconf>')
def gpu(rows=(), drirc=None, **kw):
    base_tree(); archived(); state(prev_boot=PREV_ID, **{k: kw.pop(k) for k in list(kw) if k == "checked_at"})
    if drirc is not None:
        put("/etc/drirc", drirc)
    S["kernel_journal"] = list(rows)
    S.update(kw)
    return run_main()
def gpu_lines(out):
    return [l for l in out if "GPU" in l and ("卡死" in l or "内核日志" in l)]
rc, out = gpu()
check("S28a no hangs since the last --save -> OK over both boots kept, exit 0",
      has(out, "OK", "以来 GPU 没有卡死（查了 2 次开机的内核日志）") and not has(out, "WARN", "GPU 卡死") and rc == 0, gpu_lines(out))
check("S28a the repo's drirc -> OK names chrome, ChatGPT and steamwebhelper, same list as the repo's",
      has(out, "OK", "chrome、ChatGPT、steamwebhelper 走 zink（/etc/drirc，和仓库的名单一致）") and not has(out, "WARN", "/etc/drirc"))
rc, out = gpu(CHATGPT_1019, drirc=DRIRC_CHROME_ONLY)
show("S28b hangs in the previous boot, drirc without ChatGPT", out)
check("S28b hang in an earlier boot after checked_at -> WARN naming each program by its executable, with its boot, exit 10",
      has(out, "WARN", "以来 GPU 卡死 4 次：ChatGPT 3 次（") and has(out, "WARN", "steamwebhelper 1 次（")
      and has(out, "WARN", "开机 -1") and not has(out, "WARN", "steamweb:gdrv0") and rc == 10, gpu_lines(out))
check("S28b hint: add them to /etc/drirc like ChatGPT, README section named",
      has(out, "WARN", "ChatGPT、steamwebhelper 还走 freedreno GL：照 ChatGPT 的做法在 /etc/drirc 加一段 executable=\"ChatGPT\"")
      and has(out, "WARN", "README『Chrome 让 GPU 卡死』"), gpu_lines(out))
check("S28b drirc without ChatGPT / steamwebhelper -> its own WARN naming both, with how to roll one back for real",
      has(out, "WARN", "/etc/drirc 里没有 ChatGPT、steamwebhelper→zink") and has(out, "WARN", "仓库 linux/gpu/drirc 和体检的 DRIRC_ZINK 都删掉它")
      and not has(out, "OK", "走 zink（/etc/drirc"))
rc, out = gpu([(t - 70000, b, m) for t, b, m in CHATGPT_1019])
check("S28c hangs before checked_at -> not reported, OK", has(out, "OK", "以来 GPU 没有卡死") and not has(out, "WARN", "GPU 卡死")
      and rc == 0, gpu_lines(out))
rc, out = gpu(CHATGPT_1019, gpu_journal="sh: 1: journalctl: not found\nrc=127")
check("S28d journal unavailable -> INFO, neither OK nor WARN", has(out, "INFO", "查不了上次体检") and has(out, "INFO", "journalctl: not found")
      and not has(out, "OK", "GPU 没有卡死") and not has(out, "WARN", "GPU 卡死") and rc == 0, gpu_lines(out))
# 10-31 audit C4: the --save after a failed read moved checked_at on, and the window's hangs were never seen again
base_tree(); archived(); state(prev_boot=PREV_ID)
S["kernel_journal"], S["gpu_journal"] = list(CHATGPT_1019), "sh: 1: journalctl: not found\nrc=127"
run_main(save=True)
saved = json.loads(builtins.open(tr(mod.STATE), encoding="utf-8").read())
S.pop("gpu_journal")
rc, out = run_main(save=True)
check("S28d2 a failed read, --save, then a working journal -> the window still starts at the old checked_at: WARN, exit 10",
      saved.get("gpu_since") == NOW - 86400 and saved["checked_at"] > NOW - 60 and has(out, "WARN", "GPU 卡死 4 次")
      and has(out, "WARN", f"上次体检（{time.strftime('%m-%d %H:%M', time.localtime(NOW - 86400))}）以来") and rc == 10,
      (saved.get("gpu_since"), gpu_lines(out)))
saved = json.loads(builtins.open(tr(mod.STATE), encoding="utf-8").read())
rc, out = run_main()
check("S28d3 after a read that worked the window moves on -> no gpu_since saved, those hangs not reported again",
      "gpu_since" not in saved and has(out, "OK", "以来 GPU 没有卡死"), (saved.get("gpu_since"), gpu_lines(out)))
rc, out = gpu(gpu_journal="Failed to open journal directory: Permission denied\nrc=1")
check("S28e exit 1 with an error said -> INFO (exit 1 alone is \"nothing matched\")", has(out, "INFO", "Permission denied")
      and not has(out, "OK", "GPU 没有卡死"), gpu_lines(out))
rc, out = gpu(CHATGPT_1019, checked_at=None)
check("S28f no checked_at: this boot only, as before -> a hang in the previous boot is not counted",
      has(out, "OK", "本次开机 GPU 没有卡死") and not has(out, "WARN", "GPU 卡死"), gpu_lines(out))
DRIRC_OLD = builtins.open(DRIRC_SRC, "rb").read()
def gpu_drirc_at(mtime, rows, **kw):
    """gpu() with the repo's drirc last changed at `mtime`"""
    base_tree(); archived(); state(prev_boot=PREV_ID, **kw)
    put("/etc/drirc", DRIRC_OLD, mtime=mtime)
    S["kernel_journal"] = list(rows)
    return run_main()
rc, out = gpu_drirc_at(NOW - 5 * 86400, hang_lines(NOW - 100, CUR_ID, "ChatGPT", "/usr/lib/chatgpt/ChatGPT"), checked_at=None)
check("S28g no checked_at, a hang this boot (after ChatGPT's 10-23) -> WARN 本次开机; the zink hint with its day, not the drirc one",
      has(out, "WARN", "本次开机 GPU 卡死 1 次：ChatGPT 1 次（") and has(out, "WARN", "ChatGPT（10-23 起） 已在 /etc/drirc 走 zink")
      and not has(out, "WARN", "还走 freedreno GL") and not has(out, "WARN", "那天之前") and rc == 10, gpu_lines(out))
# the "from before zink" hint goes by each program's own day in DRIRC_ZINK, never by /etc/drirc's mtime (review 10-23: with
# the mtime, adding ChatGPT on 10-23 made a 10-19 Chrome hang look pre-zink). Real wall-clock times, as on the tablet.
def T(s):
    return time.mktime(time.strptime(s, "%Y-%m-%d %H:%M"))
SINCE_1012, DRIRC_1023 = T("2026-10-12 00:00"), T("2026-10-23 00:11")          # /etc/drirc as installed on 10-23
CHATGPT_1019_REAL = sum((hang_lines(T("2026-10-19 17:53") + 2 * i, PREV_ID, "ChatGPT", "/usr/lib/chatgpt/ChatGPT") for i in range(3)), []) + \
    hang_lines(T("2026-10-19 18:00") + 40, PREV_ID, "steamweb:gdrv0", "/home/user/.local/share/Steam/steamrtarm64/steamwebhelper",
               "--type=zygote")
rc, out = gpu_drirc_at(DRIRC_1023, CHATGPT_1019_REAL, checked_at=SINCE_1012)
show("S28o the 10-19 hangs, drirc of 10-23", out)
check("S28o the 10-19 ChatGPT / steamwebhelper hangs, both added 10-23 -> still WARN, hint: before their day",
      has(out, "WARN", "GPU 卡死 4 次：ChatGPT 3 次（10-19 17:53，开机 -1）") and has(out, "WARN", "steamwebhelper 1 次（10-19 18:00，开机 -1）")
      and has(out, "WARN", "ChatGPT（10-23 加入）、steamwebhelper（10-23 加入） 的卡死都在加进 /etc/drirc 那天之前")
      and not has(out, "WARN", "已在 /etc/drirc 走 zink") and not has(out, "WARN", "还走 freedreno GL"), gpu_lines(out))
CHROME_1019 = hang_lines(T("2026-10-19 12:00"), PREV_ID, "chrome", "/opt/google/chrome/chrome")
rc, out = gpu_drirc_at(DRIRC_1023, CHROME_1019, checked_at=SINCE_1012)
check("S28r a Chrome hang on 10-19, after its own 10-14, drirc file changed 10-23 -> not called pre-zink, the already-zink hint",
      has(out, "WARN", "chrome 1 次（10-19 12:00") and has(out, "WARN", "chrome（10-14 起） 已在 /etc/drirc 走 zink")
      and not has(out, "WARN", "那天之前") and not has(out, "WARN", "还走 freedreno GL"), gpu_lines(out))
rc, out = gpu_drirc_at(DRIRC_1023, CHATGPT_1019_REAL[:2], checked_at=SINCE_1012)
check("S28s a ChatGPT hang on 10-19, before its 10-23 -> pre-zink hint, not the already-zink one",
      has(out, "WARN", "ChatGPT（10-23 加入） 的卡死都在加进 /etc/drirc 那天之前") and not has(out, "WARN", "已在 /etc/drirc 走 zink"),
      gpu_lines(out))
rc, out = gpu_drirc_at(DRIRC_1023, CHROME_1019 + CHATGPT_1019_REAL[:2], checked_at=SINCE_1012)
check("S28t both in one run -> Chrome already-zink, ChatGPT pre-zink, each by its own day",
      has(out, "WARN", "chrome（10-14 起） 已在 /etc/drirc 走 zink") and has(out, "WARN", "ChatGPT（10-23 加入） 的卡死都在加进")
      and not has(out, "WARN", "chrome（10-14 加入）") and not has(out, "WARN", "ChatGPT（10-23 起）"), gpu_lines(out))
rc, out = gpu_drirc_at(DRIRC_1023, hang_lines(T("2026-10-23 00:05"), CUR_ID, "ChatGPT", "/usr/lib/chatgpt/ChatGPT"), checked_at=SINCE_1012)
check("S28u a ChatGPT hang on 10-23 itself (the day counts as after) -> the already-zink hint that asks to look",
      has(out, "WARN", "ChatGPT（10-23 起） 已在 /etc/drirc 走 zink") and not has(out, "WARN", "那天之前"), gpu_lines(out))
# "offending task: <comm> (<cmdline>)": comm may hold spaces, argv[0] may be /proc/self/exe, a cut line may have no "("
rc, out = gpu(hang_lines(NOW - 100, CUR_ID, "Isolated Web Co", "/usr/lib/firefox/firefox", "-contentproc -isForBrowser"))
check("S28p comm with spaces -> named by argv[0] (firefox), not \"Isolated\"; the drirc hint names executable=\"firefox\"",
      has(out, "WARN", "GPU 卡死 1 次：firefox 1 次（") and has(out, "WARN", "executable=\"firefox\"")
      and has(out, "WARN", "exec -a /x/firefox eglinfo -B") and not has(out, "WARN", "Isolated"), gpu_lines(out))
rc, out = gpu(hang_lines(NOW - 100, CUR_ID, "Isolated Web Co", None))
check("S28p2 comm with spaces and no command line -> the whole comm, no executable= suggestion, says to look it up",
      has(out, "WARN", "GPU 卡死 1 次：Isolated Web Co 1 次（") and has(out, "WARN", "Isolated Web Co 只记了线程名")
      and not has(out, "WARN", "还走 freedreno GL"), gpu_lines(out))
rc, out = gpu(hang_lines(NOW - 100, CUR_ID, "signal-desktop", "/proc/self/exe", "--type=gpu-process"))
check("S28q argv[0] /proc/self/exe -> named by its comm, says so; no executable=\"exe\" drirc hint",
      has(out, "WARN", "GPU 卡死 1 次：signal-desktop 1 次（") and has(out, "WARN", "signal-desktop 的命令行 argv[0] 是 /proc/self/exe")
      and has(out, "WARN", "MESA_LOADER_DRIVER_OVERRIDE=zink") and not has(out, "WARN", "exe 1 次")
      and not has(out, "WARN", "executable=\"exe\"") and not has(out, "WARN", "还走 freedreno GL"), gpu_lines(out))
S["gpu_journal"] ="\n".join(json.dumps({"__REALTIME_TIMESTAMP": str(int(NOW * 1e6)), "_BOOT_ID": CUR_ID, "MESSAGE": m}) for m in (
    "msm: offending task: Web Content (/usr/lib/firefox/firefox -contentproc)", "msm: offending task: chrome (/opt/google/chrome/chrome)",
    "msm: offending task: foo (/usr/bin/foo --a (b))", "msm: offending task: unknown")) + "\nrc=0"
h = mod.gpu_hangs(NOW - 60, BOOT8)
S.pop("gpu_journal")
check("S28p3 gpu_hangs parses each offending-task shape: spaces in comm, argv[0] alone in the parens, parens later on, unknown",
      sorted(h["progs"]) == ["chrome", "firefox", "foo", "未知"] and not h["procexe"] and not h["nocmd"], sorted(h["progs"]))
# the installed /etc/drirc against the repo's list, both ways
DRIRC_ROLLED = DRIRC_OLD.decode().replace('executable="steamwebhelper"', 'executable="steamwebhelper-off"')
rc, out = gpu(drirc=DRIRC_ROLLED.replace("</device>", '<application name="x" executable="foo"><option name="dri_driver" value="zink" />'
                                                    "</application></device>"))
check("S28v /etc/drirc rolled back on the tablet only, and one program added there only -> a WARN each, no OK",
      has(out, "WARN", "/etc/drirc 里没有 steamwebhelper→zink") and has(out, "WARN", "有意撤掉的话，仓库 linux/gpu/drirc 和体检的 DRIRC_ZINK 都删掉它")
      and has(out, "WARN", "/etc/drirc 比仓库多了 steamwebhelper-off、foo→zink") and has(out, "WARN", "加入日期")
      and not has(out, "OK", "走 zink（/etc/drirc") and rc == 10, [l for l in out if "drirc" in l])
# the repo's two halves of the list agree: linux/gpu/drirc's programs and dates = DRIRC_ZINK, and the file is valid XML
import xml.dom.minidom
src = DRIRC_OLD.decode()
dated = {n: (re.search(rf"^  {re.escape(n)}\s.*?Added (\d{{4}}-\d{{2}}-\d{{2}})\.", src, re.M | re.S) or [None, None])[1]
         for n in mod.DRIRC_ZINK}
try:
    xml.dom.minidom.parseString(DRIRC_OLD); xml_ok = True
except Exception as e:
    xml_ok = repr(e)
check("S28w DRIRC_ZINK = the programs linux/gpu/drirc zinks, with the same \"Added\" days; the file parses as XML",
      sorted(mod.zink_programs(src)) == sorted(mod.DRIRC_ZINK) and dated == mod.DRIRC_ZINK and xml_ok is True
      and "<application" not in src.split("-->")[0] and mod.DRIRC_ZINK["chrome"] == "2026-10-14",
      f"{mod.zink_programs(src)} {dated} {xml_ok}")
# the Mesa follow-ups name all three programs on zink (review 10-23: they named Chrome only)
check("S28x PACKAGES libgl1-mesa-dri names Chrome, ChatGPT and steamwebhelper and the rollback in both places",
      all(s in mod.PACKAGES["libgl1-mesa-dri"] for s in ("Chrome", "ChatGPT", "steamwebhelper", "DRIRC_ZINK", "hangcheck")),
      mod.PACKAGES["libgl1-mesa-dri"])
base_tree(); archived(); state(pkgs=dict({p: "1.0" for p in mod.PACKAGES}, **{"libgl1-mesa-dri": "0.9"}), tb323fu_mesa="mesa-2026.10.06.3")
rc, out = run_main()
mesa_lines = [l for l in out if l.startswith("CHANGED") and ("Mesa" in l)]
check("S28x CHANGED Ubuntu Mesa GL and tb323fu Mesa -> both name Chrome, ChatGPT and steamwebhelper; tb323fu's says how to check",
      len(mesa_lines) == 2 and all(all(s in l for s in ("Chrome", "ChatGPT", "steamwebhelper")) for l in mesa_lines)
      and any("libvulkan_freedreno" in l and "hangcheck" in l for l in mesa_lines), mesa_lines)
rc, out = gpu([(NOW - 300, CUR_ID, "msm_dpu 9801000.display-controller: [drm:recover_worker] *ERROR* 44050a31: hangcheck recover!")]
              + hang_lines(NOW - 200, CUR_ID, "unknown", None))
check("S28h a hang without an offending task and one \"offending task: unknown\" -> 未知 2 次, no drirc hint",
      has(out, "WARN", "GPU 卡死 2 次：未知 2 次") and not has(out, "WARN", "还走 freedreno GL"), gpu_lines(out))
rc, out = gpu(sum((hang_lines(NOW - 3000 + i, CUR_ID, "kwin_wayland", "/usr/bin/kwin_wayland", "--xwayland") for i in range(300)), []))
check("S28i a hang storm -> capped read, says 至少; the desktop itself gets no drirc hint",
      has(out, "WARN", f"GPU 卡死 至少 {mod.GPU_HANG_CAP // 2} 次：kwin_wayland {mod.GPU_HANG_CAP // 2} 次") and has(out, "WARN", "是桌面本身")
      and not has(out, "WARN", "还走 freedreno GL"), gpu_lines(out))
rc, out = gpu(hang_lines(NOW - 100, CUR_ID, "Telegram", "/app/bin/Telegram", "-workdir"))
check("S28j a flatpak program -> the flatpak hint, not /etc/drirc", has(out, "WARN", "Telegram 1 次") and has(out, "WARN", "flatpak 程序")
      and not has(out, "WARN", "还走 freedreno GL"), gpu_lines(out))
check("S28j (default boots) the oldest boot kept starts before checked_at -> no retention INFO", not has(out, "INFO", "内核日志最早只留到"),
      gpu_lines(out))
rc, out = gpu(boots_json=json.dumps(BOOTS_JSON[1:]), checked_at=NOW - 30 * 86400)
check("S28k checked_at older than the journal kept -> INFO says the gap, still OK for what is there",
      has(out, "INFO", "内核日志最早只留到开机 0（") and has(out, "INFO", " 起）") and has(out, "OK", "以来 GPU 没有卡死（查了 1 次开机"),
      gpu_lines(out))
# since 10-16 every boot's first entry reads 07-28 05:44 (the early clock): not a start; judged by its end, conservatively
EARLY = int((NOW - 80 * 86400) * 1e6)
rc, out = gpu(boots_json=json.dumps([dict(b, first_entry=EARLY) for b in BOOTS_JSON]))
check("S28m oldest boot with an early-clock first entry, ending after checked_at -> INFO by its end",
      has(out, "INFO", "内核日志最早只留到开机 -1（") and has(out, "INFO", " 结束）"), gpu_lines(out))
rc, out = gpu(boots_json=json.dumps([dict(BOOTS_JSON[0], first_entry=EARLY, last_entry=int((NOW - 2 * 86400) * 1e6)), BOOTS_JSON[1]]))
check("S28n oldest boot (early-clock start) ended before checked_at -> no INFO", not has(out, "INFO", "内核日志最早只留到")
      and has(out, "OK", "以来 GPU 没有卡死（查了 1 次开机"), gpu_lines(out))
rc, out = gpu([(NOW - 100, CUR_ID, "msm_dpu 9801000.display-controller: hangcheck detected gpu lockup rb 0!")]
              + hang_lines(NOW - 99, CUR_ID, "chrome", "/opt/google/chrome/chrome"))
check("S28l the hangcheck timer's two lines for one hang count once", has(out, "WARN", "GPU 卡死 1 次：chrome 1 次"), gpu_lines(out))

# ---- S29 熄屏不锁屏 (owner, 10-24): PowerDevil's lock-before-turn-off and battery dim / off timeouts follow KWin's tablet
# mode unless written out (the 08:59 unplug locked every power-key press); kscreenlockerrc's two locks default to on
def nolock(pdrc=PDRC_GOOD, klrc=KLRC_GOOD, fail=None):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    for p, v in (("/home/user/.config/powerdevilrc", pdrc), ("/home/user/.config/kscreenlockerrc", klrc)):
        if v is None:
            realos.remove(tr(p))
        else:
            put(p, v)
    if fail:
        FAILOPEN[fail] = PermissionError(13, "Permission denied")
    try:
        return run_main()
    finally:
        FAILOPEN.clear()
def nolock_lines(out):
    return [l for l in out if "锁屏" in l]
rc, out = nolock()
check("S29a the 10-24 16:45 files -> OK, exit 0", has(out, "OK", "熄屏不锁屏：") and not has(out, "WARN", "锁屏") and rc == 0,
      f"rc={rc} {nolock_lines(out)}")
rc, out = nolock(PDRC_1015)
show("S29b the 10-24 morning's powerdevilrc", out)
check("S29b the morning's file (keys unset) -> WARN names the three profiles and both battery timeouts, how to apply, exit 10",
      has(out, "WARN", "：AC 熄屏前锁屏没关；Battery 熄屏前锁屏没关；Battery 闲置变暗、熄屏时间没写死（平板模式下会缩短）；"
                       "LowBattery 熄屏前锁屏没关；LowBattery 闲置变暗、熄屏时间没写死") and has(out, "WARN", "refreshStatus")
      and not has(out, "OK", "熄屏不锁屏") and rc == 10, nolock_lines(out))
rc, out = nolock(PDRC_GOOD.replace("LockBeforeTurnOffDisplay=false\nTurnOffDisplayWhenIdle", "LockBeforeTurnOffDisplay=true\nTurnOffDisplayWhenIdle"))
check("S29c AC set to lock -> WARN names AC only", has(out, "WARN", "：AC 熄屏前锁屏没关（README") and rc == 10, nolock_lines(out))
rc, out = nolock(PDRC_GOOD.replace("[Battery][Display]\nDimDisplayIdleTimeoutSec=120\n", "[Battery][Display]\nDimDisplayWhenIdle=false\n")
                 .replace("TurnOffDisplayIdleTimeoutSec=300\n", "TurnOffDisplayWhenIdle=false\n"))
check("S29d battery dim and off disabled outright -> WARN names both as never (11-01: the screen then stays on)",
      has(out, "WARN", "：Battery 闲置不变暗、不熄屏（「从不」：KDE 电量页打开时会这样写）（README") and rc == 10, nolock_lines(out))
rc, out = nolock(PDRC_GOOD.replace("TurnOffDisplayIdleTimeoutSec=300\n", ""))
check("S29e battery off timeout missing -> WARN names that one only", has(out, "WARN", "：Battery 闲置熄屏时间没写死（平板模式下会缩短）（README")
      and rc == 10, nolock_lines(out))
rc, out = nolock(klrc=None)
check("S29f no kscreenlockerrc (both locks at their default, on) -> WARN names both",
      has(out, "WARN", "：kscreenlocker 闲置自动锁屏没关；kscreenlocker 唤醒后锁屏没关（README") and rc == 10, nolock_lines(out))
rc, out = nolock(klrc=KLRC_GOOD.replace("Autolock=false", "Autolock=true"))
check("S29g Autolock=true -> WARN names the idle lock only", has(out, "WARN", "：kscreenlocker 闲置自动锁屏没关（README") and rc == 10,
      nolock_lines(out))
rc, out = nolock(pdrc=None)
check("S29h no powerdevilrc (every default) -> WARN, not INFO", has(out, "WARN", "：AC 熄屏前锁屏没关；") and not has(out, "INFO", "熄屏不锁屏查不了"),
      nolock_lines(out))
rc, out = nolock(fail="/home/user/.config/powerdevilrc")
check("S29i powerdevilrc unreadable -> INFO, neither OK nor WARN", has(out, "INFO", "熄屏不锁屏查不了：powerdevilrc 读不出来")
      and not has(out, "OK", "熄屏不锁屏") and not has(out, "WARN", "熄屏会锁屏"), nolock_lines(out))
rc, out = nolock(PDRC_GOOD.replace("LockBeforeTurnOffDisplay=false\nTurnOffDisplayIdleTimeoutSec=120\n",
                                   "TurnOffDisplayIdleTimeoutSec=120\n[LowBattery][Display][Extra]\nLockBeforeTurnOffDisplay=false\n"))
check("S29j the key under another group ([LowBattery][Display][Extra]) does not count -> WARN names LowBattery only",
      has(out, "WARN", "：LowBattery 熄屏前锁屏没关（README") and rc == 10, nolock_lines(out))
# review 10-24: KConfig reads False / no / off / 0 as false and drops an immutable marker [$i]; a BOM is not part of the header
rc, out = nolock("﻿" + PDRC_GOOD.replace("LockBeforeTurnOffDisplay=false\nTurnOffDisplayWhenIdle", "LockBeforeTurnOffDisplay=False\nTurnOffDisplayWhenIdle")
                 .replace("[Battery][Display]\n", "[Battery][Display][$i]\n")
                 .replace("LockBeforeTurnOffDisplay=false\nTurnOffDisplayIdleTimeoutSec=120", "LockBeforeTurnOffDisplay[$i]=0\nTurnOffDisplayIdleTimeoutSec=120"),
                 KLRC_GOOD.replace("Autolock=false", "Autolock=no").replace("LockOnResume=false", "LockOnResume=OFF"))
check("S29k False / [$i] group / Key[$i]=0 / BOM / no / OFF -> all read as off, OK", has(out, "OK", "熄屏不锁屏：") and rc == 0,
      f"rc={rc} {nolock_lines(out)}")
rc, out = nolock(PDRC_GOOD.replace("LockBeforeTurnOffDisplay=false\nTurnOffDisplayWhenIdle", "LockBeforeTurnOffDisplay=1\nTurnOffDisplayWhenIdle")
                 .replace("[Battery][Display]\nDimDisplayIdleTimeoutSec=120\nLockBeforeTurnOffDisplay=false",
                          "[Battery][Display]\nDimDisplayIdleTimeoutSec=120\nLockBeforeTurnOffDisplay="))
check("S29l =1 and an empty value are not off -> WARN names AC and Battery", has(out, "WARN", "：AC 熄屏前锁屏没关；Battery 熄屏前锁屏没关（README")
      and rc == 10, nolock_lines(out))
# 11-01: the file KDE's power page left on 10-30 20:12 (it saves [AC]'s "never" into all three profiles on open)
NEVER_DISP = ("DimDisplayIdleTimeoutSec=0\nDimDisplayWhenIdle=false\nLockBeforeTurnOffDisplay=false\n"
              "TurnOffDisplayIdleTimeoutSec=0\nTurnOffDisplayWhenIdle=false\n\n")
rc, out = nolock("".join(f"[{p}][Display]\n{NEVER_DISP}[{p}][SuspendAndShutdown]\nAutoSuspendAction=0\nPowerButtonAction=128\n\n"
                         for p in ("AC", "Battery", "LowBattery")))
show("S29m the file KDE's power page wrote", out)
check("S29m all three profiles never -> WARN names Battery and LowBattery, not AC (AC never is the plan)",
      has(out, "WARN", "：Battery 闲置不变暗、不熄屏（「从不」：KDE 电量页打开时会这样写）；LowBattery 闲置不变暗、不熄屏（")
      and not has(out, "WARN", "：AC ") and rc == 10, nolock_lines(out))
rc, out = nolock(PDRC_GOOD.replace("[LowBattery][Display]\n", "[LowBattery][Display]\nTurnOffDisplayWhenIdle=false\n"))
check("S29n low battery screen-off never, its dim pinned -> WARN names that one only",
      has(out, "WARN", "：LowBattery 闲置不熄屏（「从不」") and not has(out, "WARN", "不变暗") and rc == 10, nolock_lines(out))

# ---- S30a-k libcamera with our rear AF + lens power patches, held (10-29, linux/camera/): version, 0005's string in the
# library, the hold, Ubuntu's candidate, and the rear lens powered while the rear sensor is not streaming
LC_LIB = "/usr/lib/aarch64-linux-gnu/libcamera.so.0.7"
LC_LENS, LC_REAR = "/sys/bus/i2c/devices/5-000c/power/runtime_status", "/sys/bus/i2c/devices/5-0056/power/runtime_status"
LC_GOOD_LIB = b"\x7fELF\x02\x01\x01" + b"\0" * 32 + b"Failed to open the focus lens, autofocus disabled: " + b"\0" * 32
LC_LISTS = "/var/lib/apt/lists/ports.ubuntu.com_ubuntu-ports_dists_resolute-security_main_binary-arm64_Packages"
def lc(lib=LC_GOOD_LIB, lens="suspended\n", rear="suspended\n", installed=True, ver=LC_VER, sleep_to=None, lists_days=2, **kw):
    SLEPT.clear()
    time.sleep = (lambda s: (SLEPT.append(s), put(LC_LENS, sleep_to))) if sleep_to else SLEPT.append
    try:
        base_tree(); archived(); state(prev_boot=PREV_ID)
        for path, data in ((LC_LIB, lib), (LC_LENS, lens), (LC_REAR, rear),
                           ("/root/libcamera-y700/install-state.txt", "libcamera0.7 0.7.0-1ubuntu2\n" if installed else None)):
            if data is not None:
                put(path, data)
        if lists_days is not None:
            put(LC_LISTS, "Package: libcamera0.7\n", mtime=NOW - lists_days * 86400)
        S["pkgs"] = {"libcamera0.7": ver}
        S.update(kw)
        return run_main()
    finally:
        time.sleep = real_sleep
def lc_lines(out):
    return [l for l in out if "libcamera" in l]
rc, out = lc()
check("S30a our build, marked, held, no newer candidate, lens off -> OK", has(out, "OK", f"libcamera {LC_VER} 带着对焦和镜头补丁、hold 着")
      and has(out, "OK", "（apt 列表 2 天前刷新）；镜头 suspended") and not has(out, "WARN", "libcamera") and SLEPT == [], lc_lines(out))
rc, out = lc(lists_days=40)
check("S30l apt lists 40 days old -> WARN (a new libcamera would not show)", has(out, "WARN", "apt 列表 40 天没刷新")
      and not has(out, "OK", "带着对焦") and rc == 10, lc_lines(out))
rc, out = lc(lists_days=None)
check("S30m no apt lists -> WARN", has(out, "WARN", "apt 列表不在"), lc_lines(out))
rc, out = lc(installed=False, ver="0.7.0-1ubuntu2")
check("S30b never installed here (no install-state.txt) -> no libcamera line", lc_lines(out) == [], lc_lines(out))
rc, out = lc(ver="0.7.0-1ubuntu2")
check("S30c Ubuntu's build back -> WARN, exit 10", has(out, "WARN", "libcamera0.7 是 0.7.0-1ubuntu2，不是我们编的 +y700 版") and rc == 10,
      lc_lines(out))
rc, out = lc(lib=b"\x7fELF\x02\x01\x01" + b"\0" * 64)
check("S30d library without 0005's string -> WARN", has(out, "WARN", "没有补丁 0005 的字符串") and not has(out, "OK", "带着对焦"), lc_lines(out))
rc, out = lc(lib=None)
check("S30e library missing -> WARN (no string)", has(out, "WARN", "没有补丁 0005 的字符串"), lc_lines(out))
rc, out = lc(holds="libcamera-ipa\nlibcamera-tools")
check("S30f libcamera0.7 not held -> WARN", has(out, "WARN", "libcamera0.7 没 hold") and rc == 10, lc_lines(out))
rc, out = lc(lc_policy="libcamera0.7:\n  Installed: 0.7.0-1ubuntu2+y700.1\n  Candidate: 0.7.0-1ubuntu2.1\n", lc_newer="newer")
check("S30g Ubuntu's 0.7.0-1ubuntu2.1 behind the hold -> WARN names it", has(out, "WARN", "Ubuntu 出了 0.7.0-1ubuntu2.1，被 hold 挡住了")
      and rc == 10, lc_lines(out))
rc, out = lc(lens="active\n")
check("S30h lens powered, rear sensor idle, still after 2 s -> WARN leak", has(out, "WARN", "镜头却上着电：0005 修的漏电回来了")
      and SLEPT == [2] and rc == 10, f"slept {SLEPT} {lc_lines(out)}")
rc, out = lc(lens="active\n", sleep_to="suspended\n")
check("S30i lens off again after 2 s (a CameraManager starting) -> OK", has(out, "OK", "镜头 suspended") and SLEPT == [2]
      and not has(out, "WARN", "libcamera"), f"slept {SLEPT} {lc_lines(out)}")
rc, out = lc(lens="active\n", rear="active\n")
check("S30j rear camera streaming -> OK, no wait", has(out, "OK", "镜头 active（后摄正在出流）") and SLEPT == [], f"slept {SLEPT} {lc_lines(out)}")
rc, out = lc(lens=None)
check("S30k lens runtime_status missing -> WARN", has(out, "WARN", "读不到 /sys/bus/i2c/devices/5-000c/power/runtime_status"), lc_lines(out))

# ---- S31a-p X11 apps' scale (10-29, README "Steam 字太小"): Xft.dpi in the live Xwayland database and in ~/.Xresources
# equals int(kwinrc [Xwayland] Scale x 96); a running Steam drew at the scale its GPU log's display line says
XRES, STEAM_GPU_LOG = "/home/user/.Xresources", "/home/user/.local/share/Steam/logs/webhelper_gpu.txt"
def steam_log(scale):
    return (f"[2026-10-29 19:41:02] GPU process started\n[2026-10-29 19:41:03] Display[33] bounds=[0,0 1608x1008], "
            f"workarea=[0,28 1608x589], scale={scale}\n[2026-10-29 19:41:04] ThreadSetForceDeviceScaleFactors 1.89062 x 1\n")
def xft(scale="1.9", xres="! y700 (10-29)\nXft.dpi: 182\n", xwayland=True, steam=None, log=None, **kw):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    S["kread"] = {"Scale": scale} if scale is not None else {}
    S["pids"] = {k: v for k, v in (("Xwayland", "4242" if xwayland else ""), ("steam", "222707" if steam else ""))}
    if xres is not None:
        put(XRES, xres)
    if log is not None or steam:
        put(STEAM_GPU_LOG, log if log is not None else steam_log(steam))
    S.update(kw)
    return run_main()
def xft_lines(out):
    return [l for l in out if "X11 程序缩放" in l]
rc, out = xft(steam="1.89062")
check("S31a live db + ~/.Xresources 182, Steam at 1.89 -> OK, xrdb run with the session's DISPLAY/XAUTHORITY",
      has(out, "OK", "X11 程序缩放：实时库和 ~/.Xresources 的 Xft.dpi 都是 182（= Xwayland 缩放 1.9 × 96），Steam 按 1.89062 倍画")
      and not has(out, "WARN", "X11") and S["xrdb_calls"] == [
          "env DISPLAY=:0 XAUTHORITY=/run/user/1000/xauth_qGEGkm sh -c xrdb -query; echo xrdb-rc=$?"],
      f"{xft_lines(out)} {S.get('xrdb_calls')}")
rc, out = xft(xrdb="*customization:\t-color\nxrdb-rc=0")
check("S31b live db lost Xft.dpi (10-29) -> WARN names the kcminit fix, exit 10",
      has(out, "WARN", "实时库里没有 Xft.dpi（要 182），之后打开的 Steam 会画小") and has(out, "WARN", "kcminit kcm_fonts_init kcm_style_init")
      and rc == 10, xft_lines(out))
rc, out = xft(xrdb=XRDB_GOOD.replace("182", "96"))
check("S31c live db says 96 -> WARN", has(out, "WARN", "实时库里 Xft.dpi 是 96（要 182）") and rc == 10, xft_lines(out))
rc, out = xft(xres=None)
check("S31d no ~/.Xresources -> WARN (no backstop)", has(out, "WARN", "~/.Xresources 里没有 Xft.dpi") and rc == 10, xft_lines(out))
rc, out = xft(xres="! y700\nXcursor.size: 45\n")
check("S31e ~/.Xresources without the line -> WARN", has(out, "WARN", "~/.Xresources 里没有 Xft.dpi"), xft_lines(out))
rc, out = xft(xres="Xft.dpi: 154\n")
check("S31f ~/.Xresources 154 after a scale change -> WARN names both", has(out, "WARN", "~/.Xresources 写的 Xft.dpi 是 154，显示缩放 1.9 要 182")
      and rc == 10, xft_lines(out))
rc, out = xft(scale="1.75", xres="Xft.dpi: 168\n", xrdb=XRDB_GOOD.replace("182", "168"))
check("S31g scale 1.75 -> wants 168 -> OK", has(out, "OK", "都是 168（= Xwayland 缩放 1.75 × 96）"), xft_lines(out))
rc, out = xft(scale=None, xres=None)
check("S31h no kwinrc [Xwayland] Scale (kreadconfig6 says 'true') -> no line", xft_lines(out) == [], xft_lines(out))
rc, out = xft(scale="", xres=None)
check("S31i empty Scale -> no line", xft_lines(out) == [], xft_lines(out))
rc, out = xft(scale="1", xres=None, xrdb="*customization:\t-color\nxrdb-rc=0")
check("S31j scale 1 -> no line (1x without Xft.dpi is right)", xft_lines(out) == [], xft_lines(out))
rc, out = xft(xwayland=False)
check("S31k Xwayland not running -> OK on the file, xrdb never run (it would start Xwayland)",
      has(out, "OK", "~/.Xresources 的 Xft.dpi 是 182（= Xwayland 缩放 1.9 × 96），Xwayland 没在跑，实时库没查")
      and "xrdb_calls" not in S, xft_lines(out))
rc, out = xft(sd_env="WAYLAND_DISPLAY=wayland-0\nXDG_SESSION_TYPE=wayland")
check("S31l no DISPLAY in the session env -> INFO + OK on the file, no xrdb", has(out, "INFO", "读不到 Xwayland 的资源库")
      and has(out, "OK", "~/.Xresources 的 Xft.dpi 是 182") and "xrdb_calls" not in S, xft_lines(out))
rc, out = xft(xrdb="xrdb-rc=1")
check("S31m xrdb cannot connect -> INFO, not a WARN", has(out, "INFO", "读不到 Xwayland 的资源库") and not has(out, "WARN", "X11"),
      xft_lines(out))
rc, out = xft(steam="1")
check("S31n Steam running at 1x -> WARN restart Steam, exit 10", has(out, "WARN", "正在跑的 Steam 按 1 倍画（它启动时库里还没有 Xft.dpi）")
      and rc == 10, xft_lines(out))
rc, out = xft(log=steam_log("1"))
check("S31o Steam not running, old 1x log -> OK without a Steam part", has(out, "OK", "都是 182")
      and not any("Steam 按" in l for l in out), xft_lines(out))
rc, out = xft(steam="1.89062", log="[2026-10-29] GPU process started\n")
check("S31p Steam running, no display line in the log -> OK without a Steam part", has(out, "OK", "都是 182")
      and not any("Steam 按" in l for l in out), xft_lines(out))

# ---- S32a-j Steam's UI on the GPU with zink's render-pass tracking off (10-30, README "Steam 界面花屏"): the launcher
# (the repo's own file) exports ZINK_DEBUG=norp, and the running steamwebhelper browser process (no --type=) has it in
# its environment; or it runs with --disable-gpu (Y700_STEAM_UI=cpu)
STEAM_LAUNCHER = "/home/user/.local/bin/steam-arm64"
STEAM_WH = "/home/user/.local/share/Steam/steamrtarm64/steamwebhelper"
REPO_LAUNCHER = builtins.open(realos.path.join(HERE, "..", "linux", "games", "steam-arm64"), "rb").read()
WH_BROWSER = ["--enable-features=PlatformHEVCDecoderSupport,V4L2VideoDecode"]
WH_CPU = WH_BROWSER + ["--disable-gpu-compositing", "--disable-gpu"]
WH_ENV = ["HOME=/home/user", "GTK_IM_MODULE=fcitx", "ZINK_DEBUG=norp", "MANGOHUD=1"]
def scpu(launcher=REPO_LAUNCHER, procs=((227015, WH_BROWSER, WH_ENV), (227026, ["--type=zygote"], WH_ENV))):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    if launcher is not None:
        put(STEAM_LAUNCHER, launcher)
    for pid, args, env in procs:
        put(f"/proc/{pid}/cmdline", "\0".join([STEAM_WH] + list(args)) + "\0")
        if env is not None:
            put(f"/proc/{pid}/environ", "\0".join(env) + "\0")
        LINKS[f"/proc/{pid}/exe"] = STEAM_WH
    return run_main()
def scpu_lines(out):
    return [l for l in out if "Steam 界面" in l or "Steam 启动器" in l]
GPU_OK = "Steam 界面走 GPU、关了 zink 的渲染通道跟踪（启动器带 ZINK_DEBUG=norp"
rc, out = scpu()
check("S32a repo launcher, browser process with ZINK_DEBUG=norp -> OK", has(out, "OK", GPU_OK + "，正在跑的也是）")
      and not has(out, "WARN", "Steam 界面"), scpu_lines(out))
rc, out = scpu(launcher=REPO_LAUNCHER.replace(b"*) export ZINK_DEBUG=norp ;;", b"*) ;;"))
check("S32b launcher without the export (still named in its comments) -> WARN, exit 10",
      has(out, "WARN", "~/.local/bin/steam-arm64 不带 ZINK_DEBUG=norp") and rc == 10, scpu_lines(out))
rc, out = scpu(procs=((227015, WH_BROWSER, WH_ENV[:2]), (227026, ["--type=zygote"], WH_ENV[:2])))
check("S32c running browser process on the GPU without ZINK_DEBUG -> WARN restart Steam",
      has(out, "WARN", "正在跑的 Steam 界面走 GPU 但没关 zink 的渲染通道跟踪") and rc == 10, scpu_lines(out))
rc, out = scpu(procs=((227015, WH_BROWSER, ["ZINK_DEBUG=rp"]),))
check("S32d ZINK_DEBUG=rp (a substring of norp) -> still WARN", has(out, "WARN", "没关 zink 的渲染通道跟踪"), scpu_lines(out))
rc, out = scpu(procs=((227015, WH_BROWSER, ["ZINK_DEBUG=nobgc,norp"]),))
check("S32e ZINK_DEBUG with norp in a list -> OK", has(out, "OK", GPU_OK + "，正在跑的也是）"), scpu_lines(out))
rc, out = scpu(procs=((227015, WH_CPU, WH_ENV[:2]),))
check("S32f running with --disable-gpu (Y700_STEAM_UI=cpu) -> OK, CPU drawing", has(out, "OK", "Steam 界面由 CPU 绘制（Y700_STEAM_UI=cpu")
      and not has(out, "WARN", "Steam 界面"), scpu_lines(out))
rc, out = scpu(procs=((227015, WH_CPU[:2], WH_ENV[:2]),))
check("S32g only --disable-gpu-compositing, no norp -> WARN (not the switch's --disable-gpu)",
      has(out, "WARN", "没关 zink 的渲染通道跟踪"), scpu_lines(out))
rc, out = scpu(procs=())
check("S32h Steam not running -> OK on the launcher alone", has(out, "OK", GPU_OK + "）"), scpu_lines(out))
rc, out = scpu(procs=((227026, ["--type=zygote"], WH_ENV[:2]), (227015, WH_BROWSER, None)))
check("S32i zygote without norp, browser environ unreadable -> OK on the launcher alone", has(out, "OK", GPU_OK + "）")
      and not has(out, "WARN", "Steam 界面"), scpu_lines(out))
rc, out = scpu(launcher=None)
check("S32j no launcher -> no line", scpu_lines(out) == [], scpu_lines(out))

# ---- S33a-z the battery page (10-30, linux/power/battery/DESIGN.md section 7): y700-batteryd (a systemd user unit of user)
# running with no automatic restart since the last --save, its ledger written within 40 min and at most 20 MiB with the
# foreground logs (16 MiB + a day's growth before the next prune), flightrec's energy line at most 60 s old by
# CLOCK_MONOTONIC (taken when two reads agree), and the report's diag (coefficients to recalibrate: INFO while they are
# the uncalibrated priors, WARN once calibrated; a timeout is INFO, an exit with no output WARN). Silent where the page
# is not installed
BATTERYD = "/home/user/.config/systemd/user/y700-batteryd.service"
LEDGER = "/home/user/.local/state/y700-battery"
ENERGY = "/run/y700-flightrec/energy"
REPORT = "/usr/local/bin/y700-battery-report"
BD = "y700-batteryd.service"


def energy_line(t_ms=4995000, boot=BOOT8):
    """acc.rs render() with a newline: t= and lbt= CLOCK_MONOTONIC ms, every number 13 wide, lb signed."""
    zeros = " ".join(f"{k}={0:013}" for k in ("n", "ton", "toff", "don", "doff", "dton", "dtoff", "chg", "tchg", "tz",
                                              "tzero", "gap", "bl"))
    return f"v1 boot={boot} t={t_ms:013} {zeros} lb={412:+013} lbt={t_ms:013} dpms=Off pw=dis\n"


def big(path, size, mtime):
    real = tr(path)
    realos.makedirs(realos.path.dirname(real), exist_ok=True)
    with builtins.open(real, "wb") as f:
        f.truncate(size)
    realos.utime(real, (mtime, mtime))


def batt(unit=True, ledger=True, ledger_age=100, energy=True, report=True, save=False, base=None, bd_state=None,
         uptime=None, bigs=(), rep=None, prev_age=86400, **kw):
    """A tablet with the battery page installed and healthy; each argument breaks one thing. base: the baseline's
    "batteryd" entry; ledger_age / prev_age: how long ago this boot's / the previous boot's part was written; bigs:
    (path, size) of extra files; rep: the report's stdout; kw goes to the scenario table S."""
    base_tree(); archived()
    state(prev_boot=PREV_ID, **({} if base is None else {"batteryd": base}))
    if unit:
        put(BATTERYD, "[Unit]\nDescription=y700 battery page recorder\n")
    if ledger:
        put(f"{LEDGER}/boots.txt", f"{PREV8}\n{BOOT8}\n")
        put(f"{LEDGER}/lock", "")
        put(f"{LEDGER}/b-{PREV8}.jsonl", '{"k":"H"}\n', mtime=NOW - prev_age)
        put(f"{LEDGER}/b-{BOOT8}.jsonl", '{"k":"S"}\n', mtime=time.time() - ledger_age)   # NOW is the selftest's start
        put(f"{LEDGER}/fg-{BOOT8}.log", "fg\n", mtime=NOW - 30)
    if energy:
        put(ENERGY, energy_line() if energy is True else energy)
    if report:
        put(REPORT, "#!/usr/bin/python3 -I\n")
    if bd_state:
        S["active"][BD] = bd_state
    if uptime is not None:
        put("/proc/uptime", f"{uptime:.2f} 1.00\n")
    for p, size in bigs:
        big(p, size, NOW - 86400)
    if rep is not None:
        S["report"] = rep
    S.update(kw)
    return run_main(save)


def batt_lines(out):
    return [l for l in out if any(w in l for w in ("电池页", "batteryd", "电量累计", "y700-flightrec/energy"))]


def saved_batteryd():
    return json.load(builtins.open(tr(mod.STATE), encoding="utf-8")).get("batteryd", "absent")


check("S33 energy fixture is acc.rs's 321 bytes + newline", len(energy_line()) == 322, len(energy_line()))
rc, out = batt(unit=False)
check("S33a no y700-batteryd unit -> no line, report not run, exit 0",
      batt_lines(out) == [] and "report_calls" not in S and rc == 0, (rc, batt_lines(out)))
rc, out = batt(save=True); show("S33b battery page healthy", out, pref=("OK", "WARN", "INFO"))
check("S33b all fine -> four OK lines, exit 0",
      has(out, "OK", "y700-batteryd 在跑，本次开机没有自动重启过") and has(out, "OK", "s 前写过，账本加前台日志共 0.0 MiB（≤20 MiB）")
      and has(out, "OK", "飞行记录器的电量累计 5 s 前更新过") and has(out, "OK", "电池页系数不用重标（7 天里没算清的中位数 8 %")
      and rc == 0, (rc, batt_lines(out)))
check("S33b report run as user under coreutils timeout, with a backstop",
      S.get("report_calls") == [(["timeout", "30", REPORT, "--json"], True, 40)], S.get("report_calls"))
check("S33b --save keeps NRestarts with this boot", saved_batteryd() == {"boot8": BOOT8, "nrestarts": 0}, saved_batteryd())
rc, out = batt(save=True, nrestarts={BD: "2"})
check("S33c restarts but no baseline -> INFO into the baseline, exit 0",
      has(out, "INFO", "y700-batteryd 本次开机已自动重启 2 次：记入基线") and rc == 0
      and saved_batteryd() == {"boot8": BOOT8, "nrestarts": 2}, (rc, batt_lines(out), saved_batteryd()))
rc, out = batt(base={"boot8": BOOT8, "nrestarts": 2}, nrestarts={BD: "5"})
check("S33d same boot, NRestarts 2 -> 5 -> WARN 3, exit 10",
      has(out, "WARN", "y700-batteryd 自上次体检以来自动重启了 3 次（本次开机共 5 次）") and rc == 10, (rc, batt_lines(out)))
rc, out = batt(base={"boot8": BOOT8, "nrestarts": 2}, nrestarts={BD: "2"})
check("S33e same boot, NRestarts unchanged -> OK, exit 0",
      has(out, "OK", "自上次体检以来没有自动重启（本次开机共 2 次）") and rc == 0, (rc, batt_lines(out)))
rc, out = batt(base={"boot8": "deadbeef", "nrestarts": 7}, nrestarts={BD: "1"})
check("S33f another boot's baseline (7) and 1 now -> WARN 1", has(out, "WARN", "自动重启了 1 次（本次开机共 1 次）"),
      batt_lines(out))
rc, out = batt(base={"boot8": "deadbeef", "nrestarts": 7}, nrestarts={BD: "0"})
check("S33g another boot's baseline and 0 now -> OK", has(out, "OK", "没有自动重启（本次开机共 0 次）") and rc == 0,
      (rc, batt_lines(out)))
rc, out = batt(base={"boot8": BOOT8, "nrestarts": 5}, nrestarts={BD: "1"})
check("S33h counter reset this boot (5 -> 1: a manual restart) -> WARN 1 since",
      has(out, "WARN", "自动重启了 1 次（本次开机共 1 次）"), batt_lines(out))
rc, out = batt(bd_state="failed", ledger_age=9000)
check("S33i y700-batteryd failed -> WARN, the stale ledger not WARNed again, exit 10",
      has(out, "WARN", "y700-batteryd 是 failed（enabled）") and not has(out, "WARN", "没写入") and rc == 10, (rc, batt_lines(out)))
rc, out = batt(save=True, base={"boot8": BOOT8, "nrestarts": 3}, nrestarts={BD: ""})
check("S33j NRestarts unreadable -> INFO, baseline kept as it was",
      has(out, "INFO", "读不到它的重启次数") and saved_batteryd() == {"boot8": BOOT8, "nrestarts": 3},
      (batt_lines(out), saved_batteryd()))
rc, out = batt(ledger_age=3000)
check("S33k ledger last written 50 min ago -> WARN, exit 10",
      has(out, "WARN", "电池页账本已 50 分钟没写入") and rc == 10, (rc, batt_lines(out)))
rc, out = batt(ledger_age=time.time() - 1000)
check("S33l this boot's part has a 1970 mtime, up 5000 s -> WARN (the previous boot's part is a day old)",
      has(out, "WARN", "电池页账本已 24 小时没写入"), batt_lines(out))
rc, out = batt(ledger_age=time.time() - 1000, uptime=3000)
check("S33m the same, up 3000 s (the clock was just set) -> INFO", has(out, "INFO", "时钟还没对上")
      and not has(out, "WARN", "没写入"), batt_lines(out))
rc, out = batt(ledger_age=9 * 86400, prev_age=10 * 86400)
check("S33m2 every part a week old -> WARN in days", has(out, "WARN", "电池页账本已 9 天没写入"), batt_lines(out))
rc, out = batt(ledger=False)
check("S33n no ledger part at all -> WARN", has(out, "WARN", "一份账本（b-*.jsonl）都没有"), batt_lines(out))
rc, out = batt(bigs=((f"{LEDGER}/b-{PREV8}.1.jsonl", 21 << 20),))
check("S33o ledger parts over 20 MiB -> WARN, exit 10",
      has(out, "WARN", "电池页账本加前台日志共 21.0 MiB，超过 20 MiB（16 MiB 上限加一天的余量）") and rc == 10,
      (rc, batt_lines(out)))
rc, out = batt(bigs=((f"{LEDGER}/b-{PREV8}.1.jsonl", 17 << 20),))
check("S33o2 17 MiB: over the 16 MiB cap until the next daily prune -> still OK, exit 0",
      has(out, "OK", "s 前写过，账本加前台日志共 17.0 MiB（≤20 MiB）") and rc == 0, (rc, batt_lines(out)))
rc, out = batt(bigs=((f"{LEDGER}/fg-{PREV8}.1.log", 21 << 20),))
check("S33p foreground logs count too -> WARN", has(out, "WARN", "超过 20 MiB（16 MiB 上限加一天的余量）"), batt_lines(out))
rc, out = batt(bigs=((f"{LEDGER}/b-{PREV8}.1.jsonl", 15 << 20), (f"{LEDGER}/boots.txt.tmp", 6 << 20)))
check("S33q 15 MiB of parts and a 6 MiB file ledger.rs does not prune -> OK 15.0 MiB",
      has(out, "OK", "s 前写过，账本加前台日志共 15.0 MiB") and rc == 0, (rc, batt_lines(out)))
rc, out = batt(mono=5100.0)
check("S33r energy line 105 s old while flightrec runs -> WARN, exit 10",
      has(out, "WARN", "电量累计 /run/y700-flightrec/energy 已 105 s 没更新") and rc == 10, (rc, batt_lines(out)))
rc, out = batt(mono=5055.0)
check("S33s energy line 60 s old -> still OK (<= 60)", has(out, "OK", "电量累计 60 s 前更新过"), batt_lines(out))
rc, out = batt(energy=False)
check("S33t no energy file while flightrec runs (an old recorder) -> WARN", has(out, "WARN", "没有 /run/y700-flightrec/energy"),
      batt_lines(out))
base_tree(); archived(); state(prev_boot=PREV_ID); put(BATTERYD, "[Unit]\n"); S["active"]["y700-flightrec"] = "inactive"
rc, out = run_main()
check("S33u flightrec not running -> no energy line (the recorder's own line says it)",
      not any("电量累计" in l or "y700-flightrec/energy" in l for l in out), batt_lines(out))
rc, out = batt(energy=energy_line(boot=PREV8))
check("S33v energy line of another boot -> WARN", has(out, "WARN", f"是另一次开机的（boot={PREV8}"), batt_lines(out))
rc, out = batt(energy="v2 something else\n")
check("S33w energy line not v1 -> WARN", has(out, "WARN", "认不出"), batt_lines(out))


def torn(*reads):
    """batt() with the energy file's successive reads given (the first open()s return these, in order)."""
    base_tree(); archived(); state(prev_boot=PREV_ID)
    put(BATTERYD, "[Unit]\n"); put(f"{LEDGER}/b-{BOOT8}.jsonl", "{}\n", mtime=NOW - 100); put(ENERGY, energy_line())
    FLAKY[ENERGY] = [r.encode() for r in reads]
    return run_main()


rc, out = torn(energy_line(t_ms=1000), energy_line(), energy_line())
check("S33x a torn first read, then two equal ones -> the agreed (fresh) line, OK",
      has(out, "OK", "电量累计 5 s 前更新过") and FLAKY[ENERGY] == [], (batt_lines(out), FLAKY[ENERGY]))
rc, out = torn(energy_line(t_ms=1000), energy_line(), energy_line(t_ms=1000), energy_line())
check("S33x2 no two reads agree in 4 -> INFO, no verdict", has(out, "INFO", "连读 4 次都不一样")
      and not has(out, "WARN", "电量累计") and not has(out, "OK", "电量累计"), batt_lines(out))
RECAL = "电池页系数要重标："
PRIORS = {"version": 1, "calibrated": False, "date": None, "source": "package"}   # coeffs-v1.json as shipped
rc, out = batt(rep=report_doc(unexplained_median_7d=0.3))
check("S33y 7-day unexplained median 30 % -> WARN recalibrate, exit 10",
      has(out, "WARN", RECAL + "7 天里各放电段「没算清」的中位数 30 %（>20 %）") and rc == 10, (rc, batt_lines(out)))
rc, out = batt(rep=report_doc(unexplained_median_7d=0.2))
check("S33y2 median exactly 20 % -> OK", has(out, "OK", "电池页系数不用重标（7 天里没算清的中位数 20 %") and rc == 0,
      (rc, batt_lines(out)))
rc, out = batt(rep=report_doc(floor_off_learned_mw=336.0))
check("S33z calibrated, learned 336 mW vs the model's 240 for the same segments (40 %) -> WARN recalibrate, exit 10",
      has(out, "WARN", RECAL + "账本里学到的熄屏功率 336 mW，模型对同样这些段算出 240 mW（差 40 %，>25 %）（系数 v2。")
      and rc == 10, (rc, batt_lines(out)))
rc, out = batt(rep=report_doc(floor_off_learned_mw=170.0))
check("S33z2 calibrated, learned 170 mW, 29 % below the model -> WARN too", has(out, "WARN", "差 29 %") and rc == 10,
      (rc, batt_lines(out)))
rc, out = batt(rep=report_doc(floor_off_learned_mw=290.0))
check("S33z3 calibrated, like with like within 25 % (290 vs 240, 21 %) -> OK, exit 0",
      has(out, "OK", "熄屏功率学到 290 mW、模型算 240 mW") and rc == 0, (rc, batt_lines(out)))
rc, out = batt(rep=report_doc(coeffs=PRIORS, floor_off_learned_mw=369.0, coeff_age_days=None))
check("S33z3b uncalibrated priors, learned 369 mW (real-1030's first screen-off window) vs 240 (54 %) -> INFO, exit 0",
      has(out, "INFO", RECAL + "账本里学到的熄屏功率 369 mW，模型对同样这些段算出 240 mW（差 54 %，>25 %）"
                       "（系数 v1，还是没标定的先验值：标定前只提示、不报警。")
      and not has(out, "WARN", RECAL) and rc == 0, (rc, batt_lines(out)))
rc, out = batt(rep=report_doc(coeff_age_days=120))
check("S33z4 coefficients 120 days old -> WARN recalibrate", has(out, "WARN", RECAL + "系数是 120 天前定的（>90 天）"),
      batt_lines(out))
rc, out = batt(rep=report_doc(coeff_age_days=90))
check("S33z5 coefficients exactly 90 days old -> OK", has(out, "OK", "系数 90 天") and rc == 0, (rc, batt_lines(out)))
ALL3 = dict(unexplained_median_7d=0.5, floor_off_learned_mw=480.0, coeff_age_days=91)
rc, out = batt(rep=report_doc(coeffs=dict(PRIORS, date="2026-07-31"), **ALL3))
w = [l for l in out if RECAL in l]
check("S33z6 all three on the uncalibrated priors -> one INFO naming each and the priors, no WARN, exit 0",
      len(w) == 1 and w[0].startswith("INFO") and rc == 0
      and all(s in w[0] for s in ("中位数 50 %", "差 100 %", "91 天前", "系数 v1，还是没标定的先验值")), (rc, w))
rc, out = batt(rep=report_doc(**ALL3))
w = [l for l in out if RECAL in l]
check("S33z6b the same three on calibrated coefficients -> one WARN naming each, exit 10",
      len(w) == 1 and w[0].startswith("WARN") and rc == 10 and "先验值" not in w[0]
      and all(s in w[0] for s in ("中位数 50 %", "差 100 %", "91 天前", "系数 v2")), (rc, w))
rc, out = batt(rep=report_doc(unexplained_median_7d=None, floor_off_learned_mw=None, coeff_age_days=None))
check("S33z7 a report too young to judge (nulls) -> OK, not enough data", has(out, "OK", "电池页系数不用重标（数据还不够判断；系数 v2）")
      and rc == 0, (rc, batt_lines(out)))
rc, out = batt(rep=report_doc(segments_flagged_7d=3))
check("S33z8 flagged segments recorded, not judged", has(out, "OK", "7 天里 3 段标了「模型偏高」") and rc == 0, (rc, batt_lines(out)))
rc, out = batt(rep=json.dumps({"v": 1, "error": "报表出错：FileNotFoundError: 找不到系数文件"}, ensure_ascii=False), report_rc=2)
check("S33z9 the report's error document (exit 2) -> WARN with its reason",
      has(out, "WARN", "电池页报表出错：报表出错：FileNotFoundError: 找不到系数文件") and rc == 10, (rc, batt_lines(out)))
rc, out = batt(rep="", report_rc=124)
check("S33z10 no output, coreutils timeout's 124 (it prints only at the end) -> INFO, exit 0",
      has(out, "INFO", "电池页报表 30 s 内没出结果（timeout 到点停了它）") and rc == 0, (rc, batt_lines(out)))
rc, out = batt(report_rc=None)
check("S33z11 run_rc()'s own backstop timeout -> INFO, exit 0", has(out, "INFO", "30 s 内没出结果（40 s 的后备超时到了）")
      and rc == 0, (rc, batt_lines(out)))
rc, out = batt(rep="", report_rc=1, report_err="Traceback (most recent call last):\n  File \"/usr/local/bin/y700-battery-report\""
               ", line 28, in <module>\nModuleNotFoundError: No module named 'y700_battery.ranges'\n")
check("S33z11b python died before cli.main (exit 1, nothing on stdout) -> WARN with the exit code and the last stderr line",
      has(out, "WARN", "电池页报表没输出就退出了（退出码 1：ModuleNotFoundError: No module named 'y700_battery.ranges'）")
      and not has(out, "INFO", "没出结果") and rc == 10, (rc, batt_lines(out)))
rc, out = batt(rep="", report_rc=127, report_err="timeout: failed to run command '/usr/local/bin/y700-battery-report': "
                                                 "No such file or directory")
check("S33z11c could not be started (127) -> WARN", has(out, "WARN", "（退出码 127：timeout: failed to run command") and rc == 10,
      (rc, batt_lines(out)))
rc, out = batt(rep="", report_rc=126)
check("S33z11d exit 126 with an empty stderr -> WARN says so", has(out, "WARN", "（退出码 126：stderr 也是空的）"),
      batt_lines(out))
rc, out = batt(rep="Traceback (most recent call last):")
check("S33z12 output not JSON -> WARN", has(out, "WARN", "电池页报表的输出不是 JSON"), batt_lines(out))
rc, out = batt(rep=json.dumps({"v": 1, "now": 1}))
check("S33z13 JSON without diag -> WARN", has(out, "WARN", "没有 diag 块"), batt_lines(out))
rc, out = batt(report=False)
check("S33z14 report not installed -> not run, no coefficient line, the rest still checked",
      "report_calls" not in S and not any("系数" in l for l in out) and has(out, "OK", "y700-batteryd 在跑")
      and rc == 0, (rc, batt_lines(out)))
orig = mod.read_agreed
mod.read_agreed = lambda p, tries=4: 1 / 0
rc, out = batt()
mod.read_agreed = orig
check("S33z15 a battery check that raises -> one guard WARN, the next battery check still runs",
      has(out, "WARN", "检查「电池页电量累计」出错") and has(out, "OK", "电池页系数不用重标"), batt_lines(out))

# ---- S34a-c y700-cx-auto disabled: the owner's own --disable is INFO (exit 0), the daemon's fail-safe after a reset is
# WARN (exit 10). The maintainer's daily job (not published) relies on this since 10-31: it no longer notifies on the status page's
# cx_disabled=yes when the checklist ran. The two reason lines are what linux/power/cx-auto/src/main.rs writes
def cx_auto(disabled=None):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    put("/etc/systemd/system/y700-cx-auto.service", "[Unit]\n")
    if disabled:
        put("/var/lib/y700/cx-auto.disabled", disabled)
    return run_main()
rc, out = cx_auto("2026-10-31 09:00:00 the owner: y700-cx-auto --disable\n")
check("S34a the owner's --disable -> INFO, exit 0", has(out, "INFO", "CX 自动省电已被手动停用") and not has(out, "WARN", "CX 自动省电")
      and rc == 0, (rc, [l for l in out if l.startswith(("WARN", "CHANGED"))]))
rc, out = cx_auto("2026-10-31 03:00:00 the previous boot ended while armed (armed at: 02:10) - a reset? not arming again\n")
check("S34b the fail-safe after a reset -> WARN, exit 10", has(out, "WARN", "CX 自动省电已停用：") and rc == 10, rc)
rc, out = cx_auto()
check("S34c not disabled, running -> OK", has(out, "OK", "CX 自动省电在跑") and rc == 0, rc)

# ---- S35a-c the baseline file (10-31 audit C6; 10-19 audit C7): STATE was truncated and rewritten in place, so a reset
# or a full disk mid-write left an empty or half file, and a baseline that does not parse was taken for a first run (INFO,
# exit 0: a day's CHANGED gone, nobody told)
for bad in ("", '{"pkgs": {"kwin-wayland": "1.'):
    base_tree(); archived(); state(prev_boot=PREV_ID)
    put(mod.STATE, bad)
    rc, out = run_main()
    check(f"S35a a baseline that does not parse ({len(bad)} B) -> WARN 基线坏了, not INFO 第一次运行, exit 10",
          has(out, "WARN", "checklist-state.json 坏了") and not has(out, "INFO", "第一次运行") and rc == 10,
          (rc, [l for l in out if "基线" in l or "第一次" in l]))


class DiskFull:
    """json for main() whose dump writes half the baseline and then fails like a full disk"""
    def __getattr__(self, n):
        return getattr(json, n)

    @staticmethod
    def dump(obj, f, **kw):
        f.write(json.dumps(obj, **kw)[:40])
        raise OSError(28, "No space left on device")


base_tree(); archived(); state(prev_boot=PREV_ID)
before = builtins.open(tr(mod.STATE), encoding="utf-8").read()
mod.json = DiskFull()
try:
    run_main(save=True)
    raised = None
except OSError as e:
    raised = e
finally:
    mod.json = json
check("S35b the disk fills mid --save -> the run fails (exit 1 at the top) and the old baseline is still there, whole",
      raised is not None and builtins.open(tr(mod.STATE), encoding="utf-8").read() == before, raised)
base_tree(); archived(); state(prev_boot=PREV_ID)
rc, out = run_main(save=True)
rc, out = run_main()
check("S35c a --save that works -> no .tmp left, the next run compares against it",
      not realos.path.exists(tr(mod.STATE + ".tmp")) and not has(out, "INFO", "第一次运行") and not has(out, "WARN", "坏了"),
      [l for l in out if "基线" in l or "第一次" in l])

# ---- S36 (11-01) kernel y16: the download_mode line reads 1058's "SDI disable" line; the watchdog bark names a bite
why = mod.classify_console("systemd[1]: Started foo.service\nkernel: watchdog0: pretimeout event\n")
check("S36a the bark line in a console tail is named as a watchdog bite", bool(why) and "看门狗" in why[0], why)
KERNEL = "7.3.0-tb323fu-t52-y16"
for name, log, kind, sub in (("SDI off", "qcom_scm firmware:scm: download mode off, SDI disable: 0", "OK", "SDI 也关了"),
                             ("SDI not off", "qcom_scm firmware:scm: download mode off, SDI disable: -22", "WARN", "SDI 没关掉"),
                             ("no line", "", "WARN", "1058 没生效")):
    base_tree(); archived(); state(prev_boot=PREV_ID); S["sdi_log"] = log
    rc, out = run_main()
    check(f"S36b y16, {name} -> {kind} {sub}", has(out, kind, sub) and not has(out, "OK", "转储模式已退出（"),
          [l for l in out if "转储" in l or "SDI" in l])
base_tree(download_mode="full"); archived(); state(prev_boot=PREV_ID)
S["sdi_log"] = "qcom_scm firmware:scm: download mode off, SDI disable: 0"
rc, out = run_main()
check("S36c y16, download_mode still full after 5000 s -> its WARN, the SDI line not even read",
      has(out, "WARN", "download_mode 是 full") and not has(out, "OK", "SDI") and not S.get("sdi_asked"), S.get("sdi_asked"))
KERNEL = "7.3.0-tb323fu-t52-y15"
base_tree(); archived(); state(prev_boot=PREV_ID)
rc, out = run_main()
check("S36d y15, no SDI line -> the old OK, no SDI WARN", has(out, "OK", "转储模式已退出（") and not has(out, "WARN", "SDI"),
      [l for l in out if "转储" in l or "SDI" in l])
KERNEL = "7.3.0-rc4-tb323fu-t49-y9"

# ---- S37 (11-01) kernel y17: the initramfs's e2fsck of the roots, every boot since the last --save and this one, and
# the root's ext4 state. The journal's answer per boot: its "Linux version" line, then the matching lines in order
Y16K, Y17K = "7.3.0-tb323fu-t52-y16", "7.3.0-tb323fu-t52-y17"
MARKED = "Filesystem state:         clean with errors\nFS Error count:           1\n"
W_ERR = "EXT4-fs (sda15): warning: mounting fs with errors, running e2fsck is recommended"


def fsck_log(rel, *rcs, between=(), after=(), what=None):
    """journalctl -k -b ID -g FSCK_GREP for one boot: the journal-only result, `between`, the full result, `after`
    (rcs: one or two exits; what: the full run's text)"""
    w = {0: "clean", 1: "errors fixed", 4: "ERRORS LEFT, needs e2fsck -f by hand", 8: "e2fsck could not check it", 32: "stopped"}
    out = [f"Linux version {rel} (root@x) (clang version 18.1.3) #1 SMP PREEMPT"]
    for k, rc in enumerate(rcs):
        out.append(f" fsck baldur-root (/dev/sda15): exit {rc} ({what if what and k == len(rcs) - 1 else w[rc]}), {k + 1} s")
        if k == 0:
            out += list(between)
    return "\n".join(out + list(after))


def fsck_case(logs, ids, kernel=Y17K, saved=None, tune=None):
    global KERNEL
    KERNEL = kernel
    base_tree(); archived(); state(prev_boot=PREV_ID, boot8=(saved or ids[0])[:8])
    S["sdi_log"] = "qcom_scm firmware:scm: download mode off, SDI disable: 0"
    S["boots_json"] = boots_json(*ids)
    S["journal_tail"] = CLEAN_TAIL
    S["fsck_logs"] = logs
    if tune is not None:
        S["tune2fs"] = tune
    rc, out = run_main()
    KERNEL = "7.3.0-rc4-tb323fu-t49-y9"
    return rc, out, [l for l in out if "磁盘检查" in l or "ext4" in l or "e2fsck" in l]


rc, out, fl = fsck_case({MID1_ID: fsck_log(Y17K, 0, 0), "0": fsck_log(Y17K, 0, 0)}, (SAVED_ID, MID1_ID, CUR_ID))
show("S37a y17, every boot clean", fl)
check("S37a two clean y17 boots since the --save -> one OK for both, the root's state OK, no WARN about them",
      has(out, "OK", "开机磁盘检查：2 次开机") and has(out, "OK", "ext4 状态 clean") and not any(l.startswith("WARN") for l in fl)
      and SAVED_ID not in S["fsck_asked"][:1], (fl, S.get("fsck_asked")))
rc, out, fl = fsck_case({SAVED_ID: fsck_log(Y16K), "0": fsck_log(Y17K, 0, 1, between=[W_ERR])}, (SAVED_ID, CUR_ID))
check("S37b the first y17 boot after a y16 one repairs the old mark (its remount,rw complained before the full check) "
      "-> INFO 头一次, no WARN", has(out, "INFO", "头一次带开机磁盘检查") and not any(l.startswith("WARN") for l in fl), fl)
rc, out, fl = fsck_case({MID1_ID: fsck_log(Y17K, 0, 0), "0": fsck_log(Y17K, 0, 1)}, (SAVED_ID, MID1_ID, CUR_ID))
check("S37c a repair after a checked boot -> WARN 修了根分区, exit 10", has(out, "WARN", "的磁盘检查修了根分区") and rc == 10, fl)
rc, out, fl = fsck_case({MID1_ID: fsck_log(Y17K, 0, 1), "0": fsck_log(Y17K, 0, 0)}, (SAVED_ID, MID1_ID, CUR_ID), saved=MID1_ID)
check("S37d a repair in the boot the last --save ran in -> not reported again, this boot's OK",
      not has(out, "WARN", "修了根分区") and not has(out, "INFO", "头一次") and has(out, "OK", "开机磁盘检查：1 次开机"), fl)
for name, rcs, what, sub in (("errors left", (0, 4), None, "有修不了的错误"), ("stopped", (0, 32), None, "没做完"),
                             ("clean at the limit", (0, 0), "clean at the 600 s limit", "没做完"),
                             ("fixed at the limit", (0, 1), "errors fixed at the 600 s limit", "没做完"),
                             ("could not check", (0, 8), None, "没做完")):
    rc, out, fl = fsck_case({MID1_ID: fsck_log(Y17K, 0, 0), "0": fsck_log(Y17K, *rcs, what=what)}, (SAVED_ID, MID1_ID, CUR_ID))
    check(f"S37e {name} -> WARN {sub}", has(out, "WARN", sub) and rc == 10, fl)
rc, out, fl = fsck_case({MID1_ID: fsck_log(Y17K), "0": fsck_log(Y17K, 0, 0)}, (SAVED_ID, MID1_ID, CUR_ID))
check("S37f an earlier y17 boot with no result line -> WARN naming that boot", any(l.startswith("WARN") and MID1_ID[:8] in l
      and "没有磁盘检查的结果行" in l for l in fl) and has(out, "OK", "开机磁盘检查：1 次开机"), fl)
rc, out, fl = fsck_case({"0": ""}, (SAVED_ID, CUR_ID))
check("S37f this boot's log lost its Linux version line and has no result -> its kernel from uname, WARN",
      has(out, "WARN", f"本次开机跑的是 {Y17K}") and not has(out, "OK", "开机磁盘检查"), fl)
rc, out, fl = fsck_case({"0": fsck_log(Y17K) + "\n fsck baldur-root (/dev/sda15): no e2fsck in this image, not checked"},
                        (SAVED_ID, CUR_ID))
check("S37g no e2fsck in the image -> WARN 没有 e2fsck (not the no-result one)", has(out, "WARN", "initramfs 里没有 e2fsck")
      and not has(out, "WARN", "没有磁盘检查的结果行"), fl)
rc, out, fl = fsck_case({MID1_ID: fsck_log(Y17K, 0, 0), "0": fsck_log(Y17K, 0, 0, after=[
    "EXT4-fs error (device sda15): ext4_lookup:1820: inode #2: comm ls: deleted inode referenced: 12"])}, (SAVED_ID, MID1_ID, CUR_ID))
check("S37h an ext4 error after the full check -> WARN 检查完以后, not counted clean", has(out, "WARN", "检查完以后内核又报了根分区的 ext4 问题 1 次")
      and has(out, "OK", "开机磁盘检查：1 次开机"), fl)
rc, out, fl = fsck_case({"0": fsck_log(Y16K)}, (SAVED_ID, CUR_ID), kernel=Y16K, tune=MARKED)
check("S37i y16, the root still marked -> WARN naming the state and the count, this kernel does not check; no fsck lines",
      has(out, "WARN", "ext4 状态是「clean with errors」，记着 1 次错误：这个内核开机不查") and not has(out, "OK", "开机磁盘检查")
      and not has(out, "WARN", "结果行"), fl)
rc, out, fl = fsck_case({MID1_ID: fsck_log(Y17K, 0, 0), "0": fsck_log(Y17K, 0, 0)}, (SAVED_ID, MID1_ID, CUR_ID), tune=MARKED)
check("S37j y17, marked during this boot -> WARN, the next boot's e2fsck -p fixes it",
      has(out, "WARN", "下次开机 initramfs 的 e2fsck -p 会修"), fl)
rc, out, fl = fsck_case({PREV_ID: fsck_log(Y17K, 0, 0), "0": fsck_log(Y17K, 0, 1)}, (PREV_ID, CUR_ID), saved=CUR_ID)
check("S37l a repair at this boot, the last --save already ran in it -> not reported again (11-01 review), rc 0",
      not any(l.startswith("WARN") for l in fl) and rc == 0 and "0" not in S.get("fsck_asked", []), (rc, fl, S.get("fsck_asked")))
rc, out, fl = fsck_case({"0": fsck_log(Y17K, 0, 0)}, (SAVED_ID, CUR_ID), tune="")
check("S37k tune2fs says nothing -> INFO, neither OK nor WARN", has(out, "INFO", "读不到根分区") and not has(out, "WARN", "ext4 状态"), fl)
KERNEL = "7.3.0-rc4-tb323fu-t49-y9"

shutil.rmtree(ROOT, ignore_errors=True)
print(f"\n{len(FAILS)} failures", FAILS)
sys.exit(1 if FAILS else 0)
