"""End-to-end tests of y700-battery-report (cli.py, the entry script, fit.py, config.py) on captures in the 6b.b
--from layout: the real 10-30 capture against its golden files, synth.py's multi-boot ledger, a 40-day synthetic
ledger (timed; also its fragmented worst case, which holds the perf shortcuts against the plain definitions), every
error path, --fit, and the 1 s vs 10 s integration check on runs/diag/flightrec.

Goldens: tests/fixtures/real-1030.expected.{json,txt} (raw tablet data, not in the public tree: those tests skip), made once by
    tools/venv/Scripts/python -X utf8 -I -B linux/power/battery/report/tests/test_cli.py regen
(in-process, with the package coeffs directory hidden so coeffs.source is "dev" on the PC and on the tablet alike).
Compared field by field, took_ms ignored; the text golden masks the run time and the coeffs file path.
Run: tools/venv/Scripts/python -X utf8 -I -B -m unittest discover -s linux/power/battery/report/tests -t linux/power/battery/report
"""

import contextlib
import gc
import gzip
import io
import json
import math
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

REPORT = Path(__file__).resolve().parents[1]
if str(REPORT) not in sys.path:
    sys.path.insert(0, str(REPORT))

from tests.fixtures import synth  # noqa: E402
from y700_battery import cli, config, contract, fit, model, out, ranges  # noqa: E402
from y700_battery.acc_ref import Acc  # noqa: E402

FIX = REPORT / "tests" / "fixtures"
REAL = FIX / "real-1030"
GOLD_JSON = FIX / "real-1030.expected.json"
GOLD_TXT = FIX / "real-1030.expected.txt"
REAL_NOW = "1793315500"           # 21 s after the capture's newest ledger line
TZ = "480"
ENTRY = REPORT / "y700-battery-report"
BATPAGE = REPORT.parents[2] / "dock" / "tests" / "batpage"
LOGS = REPORT.parents[3] / "runs" / "diag" / "flightrec"    # not in git: that test skips without it
HAVE_REAL = (REAL / "state").is_dir() and GOLD_JSON.is_file()    # the raw 10-30 capture is not published
need_real = unittest.skipUnless(HAVE_REAL, "tests/fixtures/real-1030 capture not present (not published)")
DAY = 86400
NOWHERE = os.path.join(tempfile.gettempdir(), "y700-battery-no-such-dir")


def _perf_limit():
    """Y700_BATTERY_PERF_LIMIT: the 40-day budget in s, 1.0 on the dev PC; install.sh passes the tablet's 1.5"""
    try:
        v = float(os.environ.get("Y700_BATTERY_PERF_LIMIT", "1.0"))
    except ValueError:
        return 1.0
    return v if math.isfinite(v) and v > 0 else 1.0


PERF_LIMIT = _perf_limit()


def run(argv, **patch):
    """cli.main in-process -> (exit code, stdout, stderr). The package coeffs / rules directory and the user's
    ~/.config are hidden unless patched in, so results do not depend on what is installed on the machine."""
    p = {"SHARE_DIR": NOWHERE, "user_dir": lambda env=None: NOWHERE}
    p.update(patch)
    o, e = io.StringIO(), io.StringIO()
    with mock.patch.multiple(config, **p), contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
        rc = cli.main(argv)
    return rc, o.getvalue(), e.getvalue()


def real_args(mode="--json"):
    return [mode, "--from", str(REAL), "--now", REAL_NOW, "--tz-offset", TZ]


def mask_text(txt):
    txt = re.sub(r"用时 \d+ ms", "用时 <ms> ms", txt)
    return txt.replace(os.path.join(config.DEV_DIR, "coeffs-v1.json"), "<dev>/coeffs-v1.json")


def diff(a, b, path="$"):
    """Field-by-field differences between two JSON values (floats equal within 1e-9)."""
    if isinstance(a, dict) and isinstance(b, dict):
        out_ = []
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                out_.append(f"{path}.{k}: only in {'expected' if k in a else 'actual'}")
            else:
                out_ += diff(a[k], b[k], f"{path}.{k}")
        return out_
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return [f"{path}: length {len(a)} != {len(b)}"]
        return [d for i, (x, y) in enumerate(zip(a, b)) for d in diff(x, y, f"{path}[{i}]")]
    if type(a) in (int, float) and type(b) in (int, float) and type(a) is not bool and type(b) is not bool:
        return [] if type(a) is type(b) and abs(a - b) <= 1e-9 else [f"{path}: {a!r} != {b!r}"]
    return [] if a == b and type(a) is type(b) else [f"{path}: {a!r} != {b!r}"]


def regen():
    rc, o, e = run(real_args())
    assert rc == 0, (o, e)
    doc = json.loads(o)
    doc["took_ms"] = 0
    with open(GOLD_JSON, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
    rc, o, e = run(real_args("--text"))
    assert rc == 0, (o, e)
    with open(GOLD_TXT, "w", encoding="utf-8", newline="\n") as f:
        f.write(mask_text(o))


# ---------------------------------------------------------------------------------------------
# Synthetic captures
# ---------------------------------------------------------------------------------------------

def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def battery_txt(pct, status="Discharging", online=0):
    return (f"status={status}\ncapacity={pct}\ncharge_full=8394000\ncharge_full_design=9000000\ncycle_count=18\n"
            f"/sys/class/power_supply/qcom-battmgr-usb/online={online}\n")


def standard_capture(d, d_fake=synth.D_FAKE):
    """synth.standard()'s four boots as a --from capture; the current boot D is unsynced"""
    info = synth.standard(os.path.join(d, "state"), d_fake)
    put(os.path.join(d, "sys", "battery.txt"), battery_txt(58))
    put(os.path.join(d, "mono.txt"), "400\n")
    put(os.path.join(d, "now.txt"), "%.2f\n" % (info["D_FAKE"] + 400))
    put(os.path.join(d, "tz-offset.txt"), "480\n")
    return info


def days_capture(d, days=40, full=True, now_k=200, per_snap=18, fg=False):
    """days boots of 288 five-minute snapshots (about 220 KB of ledger a day, 90 app units of which per_snap move
    each time), screen on 8-12 h and 19-22 h after boot, plugged for the last hour of each boot: to 100 % when
    full, else stopping at 90 % (never a full charge in the whole capture). UPower charge / rate histories every
    5 min. The last boot is the current one, cut at snapshot now_k.
    fg: also refresh-auto's fg log (a window switch 20 s after every screen-on snapshot, among two heavy apps, a
    third one as an X11 game, another app and the desktop) and a 90 s look at the screen every 30 min while off on
    battery (about 30 short screen-on segments a day), the fragmented worst case of the 2026-10-30 perf review."""
    rnd = random.Random(7)
    units = [("u/app.slice/app-org.example.App%02d-%x.scope" % (i, 4096 + i), 1000 + i) for i in range(90)]
    heavy = set(units[:3])          # three apps worth a few % each, the other 87 end up in apps_rest
    put(os.path.join(d, "desktop-files.txt"), "".join(
        "== /usr/share/applications/org.example.App%02d.desktop\nType=Application\nName=应用 %02d\nExec=app%02d\n"
        "Icon=app%02d\n" % (i, i, i, i) for i in range(90)))
    base = [synth.ROOT, synth.KWIN, synth.SYS, synth.USR, synth.APPS, synth.SESS, synth.SHELL, synth.FGD]
    use = {u: 1000 for u in units + base}
    t0 = 1793320260 - days * DAY
    top = 100.0 if full else 90.0
    recs, charge, rate = [], [], []
    pct = top
    picks = [(units[0], "org.example.App00"), (units[1], "org.example.App01"), (units[2], "steam_app_42"),
             (units[10], "org.example.App10"), (None, "plasmashell")]
    for b in range(days):
        r = synth.Rec("b%07d" % b, t0 + b * DAY, sync=True)
        fl = synth.Flight(0.0)
        last = now_k if b == days - 1 else 288
        if fg:
            r.fg_mark(5.0, "START")
        fg_u = None
        for k in range(last):
            m = 10.0 + k * 300
            hour = k * 300 // 3600
            on = 1 if (8 <= hour < 12 or 19 <= hour < 22) else 0
            chg = k >= 276
            for u in rnd.sample(units, per_snap):
                use[u] += rnd.randint(1, 2_000_000) * (15 if u in heavy else 1) * (2 if on else 1)
            for u in base:
                use[u] += rnd.randint(1000, 50000)
            mw = -5000 if chg else (1800 if on else 350)
            r.snap(m, "start" if k == 0 else "ck", dict(use), dpms=on, pw="chg" if chg else "dis",
                   fr=fl.run(m, bool(on), mw, 1200).fr(),
                   cl=[[k * 60000, k * 300000 * 1800, k * 300000], [k * 9000, k * 300000 * 2400, k * 300000]],
                   ctx=k * 3000,
                   pkt=(k * 40, k * 20), x=(1, k), wk={"-k": 5, units[k % 90]: 3} if not on else None,
                   st=("Charging" if chg else "Discharging") if k in (0, 276) else None,
                   cap=int(pct) if k in (0, 276) else None)
            if fg and on:
                u, cls = picks[k % len(picks)]
                was = use[fg_u] if fg_u is not None else None
                if u is None:
                    r.fg(m + 20, 0, 1, None, was, None, cls)
                else:
                    r.fg(m + 20, 4000 + k % 7, 1, use[u], was, u[0], cls)
                fg_u = u
            elif fg and not chg and k % 6 == 3 and k < last - 1:
                fg_u = None
                for dm, dp in ((100, 1), (190, 0)):
                    q, was_on = k + dm / 300, dp == 0
                    r.snap(m + dm, "dpms", dict(use), dpms=dp, pw="dis",
                           fr=fl.run(m + dm, was_on, 1800 if was_on else 350, 1200).fr(),
                           cl=[[int(q * 60000), int(q * 300000 * 1800), int(q * 300000)],
                               [int(q * 9000), int(q * 300000 * 2400), int(q * 300000)]],
                           ctx=int(q * 3000), pkt=(int(q * 40), int(q * 20)), x=(1, k))
                    if dp:
                        r.fg(m + dm + 5, 4100, 1, use[units[3]], None, units[3][0], "org.example.App03")
            w = t0 + b * DAY + m
            pct = min(top, pct + 6.0) if chg else max(1.0, pct - (0.35 if on else 0.05))
            charge.append([int(w), round(pct, 1), 1 if chg and pct < 100 else 4 if pct >= 100 else 2])
            rate.append([int(w), abs(mw) / 1000, 1 if chg else 2])
            if len(r.parts[-1]) > 4 << 20:
                r.rotate()
        recs.append(r)
    synth.write(os.path.join(d, "state"), recs)
    put(os.path.join(d, "sys", "battery.txt"), battery_txt(int(pct)))
    for n, pts in (("upower-charge.json", charge), ("upower-rate.json", rate)):
        put(os.path.join(d, n), json.dumps({"type": "a(udu)", "data": [pts[::-1]]}))
    mono = 10 + (now_k - 1) * 300 + 60
    put(os.path.join(d, "mono.txt"), "%d\n" % mono)
    put(os.path.join(d, "now.txt"), "%d\n" % (t0 + (days - 1) * DAY + mono))
    put(os.path.join(d, "tz-offset.txt"), "480\n")
    st = os.path.join(d, "state")
    return sum(os.path.getsize(os.path.join(st, n)) for n in os.listdir(st))


class TmpDir(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="y700-cli-")
        self.addCleanup(shutil.rmtree, self.tmp, True)


# ---------------------------------------------------------------------------------------------
# The real capture
# ---------------------------------------------------------------------------------------------

@need_real
class Golden(unittest.TestCase):
    def test_json_matches_golden(self):
        rc, o, e = run(real_args())
        self.assertEqual(rc, 0, e)
        doc = json.loads(o)
        self.assertEqual(contract.validate(doc), [])
        with open(GOLD_JSON, encoding="utf-8") as f:
            want = json.load(f)
        doc["took_ms"] = want["took_ms"] = 0
        self.assertEqual(diff(want, doc), [])

    def test_text_matches_golden(self):
        rc, o, e = run(real_args("--text"))
        self.assertEqual(rc, 0, e)
        self.assertEqual(mask_text(o), GOLD_TXT.read_text(encoding="utf-8"))

    def test_what_the_golden_says(self):
        # the capture holds 94 s of ledger: every range is "刚开始记录", the rest comes from UPower
        with open(GOLD_JSON, encoding="utf-8") as f:
            d = json.load(f)
        self.assertEqual((d["now"], d["tz_offset_min"], d["coeffs"]["source"]), (1793315500, 480, "dev"))
        self.assertEqual(d["battery"], {"pct": 76, "status": "discharging", "plugged": False, "health_pct": 93,
                                        "cycles": 18})
        self.assertTrue(d["rec"]["running"])
        for k in contract.RANGE_KEYS:
            self.assertEqual(d["ranges"][k]["state"], "empty")
            self.assertEqual(d["ranges"][k]["empty"]["title"], "刚开始记录")
        self.assertTrue(d["ranges"]["since_full"]["sub"].startswith("上次充满：昨天 "))
        # nothing itemised yet: data_from marks the ledger's first snapshot (the screen unknown before it)
        self.assertEqual({d["ranges"][k]["data_from"] for k in contract.RANGE_KEYS}, {1793315406})
        self.assertEqual(d["remain"]["basis_h"], 24)

    def test_entry_script(self):
        # the real entry point: python3 -I, the package found beside the script, UTF-8 on stdout
        p = subprocess.run([sys.executable, "-X", "utf8", "-I", "-B", str(ENTRY)] + real_args(),
                           capture_output=True, timeout=120)
        self.assertEqual(p.returncode, 0, p.stderr.decode("utf-8", "replace"))
        doc = json.loads(p.stdout.decode("utf-8"))
        self.assertEqual(contract.validate(doc), [])
        self.assertTrue(ENTRY.read_text(encoding="utf-8").startswith("#!/usr/bin/python3 -I\n"))
        p = subprocess.run([sys.executable, "-X", "utf8", "-I", "-B", str(ENTRY), "--nope"], capture_output=True,
                           timeout=120)
        self.assertEqual(p.returncode, 2)
        self.assertTrue(contract.is_error(json.loads(p.stdout.decode("utf-8"))))


class Canned(unittest.TestCase):
    def test_batpage_fixtures_still_validate(self):
        names = sorted(BATPAGE.glob("*.json"))
        self.assertGreaterEqual(len(names), 7)
        for p in names:
            with open(p, encoding="utf-8") as f:
                self.assertEqual(contract.validate(json.load(f)), [], p.name)


# ---------------------------------------------------------------------------------------------
# Synthetic ledgers
# ---------------------------------------------------------------------------------------------

class Standard(TmpDir):
    def test_json(self):
        standard_capture(self.tmp)
        rc, o, e = run(["--from", self.tmp])
        self.assertEqual(rc, 0, e)
        d = json.loads(o)
        self.assertEqual(contract.validate(d), [])
        self.assertEqual(d["now"], int(synth.D_FAKE + 400))
        self.assertTrue(d["rec"]["clock_unsynced"])
        self.assertEqual(d["rec"]["since"], int(synth.T0 + 100))
        sf = d["ranges"]["since_full"]
        self.assertEqual((sf["state"], sf["title"]), ("partial", "自 10-26 起（之前没有记录）"))
        kinds = [b["kind"] for b in sf["banners"]]
        self.assertEqual(kinds[:4], ["degraded", "gap", "unknown_time", "clock_unsynced"])
        self.assertEqual(sum(it["pct"] for it in sf["items"]), sf["used_pct"])
        self.assertIn("unrecorded", [it["kind"] for it in sf["items"]])
        for k in ("24h", "7d"):
            self.assertNotIn("unknown_time", [b["kind"] for b in d["ranges"][k]["banners"]])

    def test_current_clock_behind(self):
        # D's clock 90 days behind (no network since boot, PID 1's early clock): D starts at C's newest line and now
        # moves with it. Before 10-31 every past boot was "in the future": since 07-28, 24h / 7d only this boot.
        info = standard_capture(self.tmp, synth.T0 - 90 * DAY)
        rc, o, e = run(["--from", self.tmp])
        self.assertEqual(rc, 0, e)
        d = json.loads(o)
        self.assertEqual(contract.validate(d), [])
        self.assertEqual(d["now"], int(info["C_REAL"] + 2420 + 400))
        self.assertTrue(d["rec"]["clock_unsynced"])
        self.assertEqual((d["rec"]["since"], d["rec"]["last_write_age_s"]), (int(synth.T0 + 100), 85))
        self.assertEqual(d["ranges"]["since_full"]["title"], "自 10-26 起（之前没有记录）")
        for k in ("24h", "7d"):
            self.assertIn("degraded", [b["kind"] for b in d["ranges"][k]["banners"]])    # A's flightrec gap

    def test_text(self):
        standard_capture(self.tmp)
        rc, o, e = run(["--text", "--from", self.tmp])
        self.assertEqual(rc, 0, e)
        self.assertIn("对账组", o)
        self.assertIn("λ_soft", o)
        self.assertIn("[降级]", o)
        self.assertTrue(o.endswith("自检：通过\n"))

    def test_now_and_tz_override(self):
        standard_capture(self.tmp)
        rc, o, e = run(["--from", self.tmp, "--now", "1793100000", "--tz-offset", "-300"])
        self.assertEqual(rc, 0, e)
        d = json.loads(o)
        self.assertEqual((d["now"], d["tz_offset_min"]), (1793100000, -300))
        self.assertEqual(contract.validate(d), [])


class FortyDays(unittest.TestCase):
    """DESIGN 8: a 40-day ledger runs in under PERF_LIMIT s (Y700_BATTERY_PERF_LIMIT: 1.0 on the dev PC by
    default, install.sh passes the tablet's 1.5)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="y700-cli-40d-")
        cls.size = days_capture(os.path.join(cls.tmp, "full"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, True)

    def test_runs_in_under_a_second(self):
        self.assertGreater(self.size, 30 * 200_000)
        best, doc = None, None
        for _ in range(3):
            t = time.perf_counter()
            rc, o, e = run(["--from", os.path.join(self.tmp, "full")])
            el = time.perf_counter() - t
            self.assertEqual(rc, 0, e)
            best = el if best is None else min(best, el)
            doc = json.loads(o)
        self.assertEqual(contract.validate(doc), [])
        self.assertLess(best, PERF_LIMIT)

    def test_what_it_shows(self):
        rc, o, e = run(["--from", os.path.join(self.tmp, "full")])
        d = json.loads(o)
        sf, d7 = d["ranges"]["since_full"], d["ranges"]["7d"]
        self.assertEqual((sf["state"], sf["title"]), ("ok", "自上次充满"))
        self.assertTrue(sf["sub"].startswith("上次充满：昨天 08:31，之后用掉 "))
        self.assertTrue(d7["sub"].endswith("充电 7 次"))
        self.assertEqual(len(d7["bands"]["charger"]), 7)
        self.assertLessEqual(max(len(r["curve"]) for r in d["ranges"].values()), contract.MAX_CURVE)
        rest = [it for it in d7["items"] if it["kind"] == "apps_rest"]
        self.assertEqual(len(rest), 1)
        self.assertEqual(rest[0]["name"], "其他应用（87 个）")
        self.assertEqual(len(rest[0]["parts"]), 87)
        apps = [it["id"] for it in d7["items"] if it["kind"] == "app"]
        self.assertEqual(sorted(apps), ["app:org.example.App%02d" % i for i in range(3)])
        # 87 apps open all day: apps_rest's time is the union of theirs, never more than the range's discharge
        for k, r in d["ranges"].items():
            for it in r["items"]:
                if it["kind"] in ("app", "apps_rest"):
                    self.assertLessEqual(it["fg_s"] + it["bg_s"], r["on_s"] + r["off_s"] + 1, (k, it["id"]))

    def test_no_full_charge_in_40_days(self):
        # the worst case: since_full spans all 40 days and every app is above 0.5 %, so all 90 are items.
        # Measured 2026-10-30 on the dev PC: 1.9-2.1 s, 1.1-1.2 s after the perf-1..6 fixes (model.attribute_detail
        # is ~2/3 of it); only a loose bound here, scaled with PERF_LIMIT like the one above
        d40 = os.path.join(self.tmp, "nofull")
        days_capture(d40, full=False)
        t = time.perf_counter()
        rc, o, e = run(["--from", d40])
        self.assertLess(time.perf_counter() - t, 6.0 * PERF_LIMIT)
        self.assertEqual(rc, 0, e)
        d = json.loads(o)
        self.assertEqual(contract.validate(d), [])
        sf = d["ranges"]["since_full"]
        self.assertEqual(sf["title"], "自 09-20 起（之前没有记录）")
        self.assertTrue(sf["sub"].startswith("09-20 起没充满过，用掉 "))

    @need_real
    def test_collector_off_during_the_run(self):
        # perf-1: the cyclic GC only rescanned the parsed ledger for nothing (11-15 % of a 40-day run). Off while
        # the report runs, the caller's setting back afterwards (in-process callers like these tests)
        seen = []
        real = model.attribute_detail

        def spy(rng, inp):
            seen.append(gc.isenabled())
            return real(rng, inp)
        try:
            for before in (True, False):
                (gc.enable if before else gc.disable)()
                with mock.patch.object(model, "attribute_detail", spy):
                    rc, o, e = run(real_args())
                self.assertEqual(rc, 0, e)
                self.assertEqual(gc.isenabled(), before)
        finally:
            gc.enable()
        self.assertEqual(seen, [False] * 6)


class Fragmented(unittest.TestCase):
    """The worst case of the 2026-10-30 perf review (days_capture fg=True): 40 days without a full charge, a
    foreground log and about 30 short screen-ons a day. Timed like FortyDays, and the shortcuts of perf-2..6 held
    against the plain definitions they replaced: the report's output must not move by a bit."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="y700-cli-frag-")
        days_capture(cls.tmp, full=False, fg=True)
        with mock.patch.multiple(config, SHARE_DIR=NOWHERE, user_dir=lambda env=None: NOWHERE):
            cls.inp = cli.load_inputs(cls.tmp, None, 480)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, True)

    def since_full(self):
        return ranges.build(self.inp)["since_full"]

    def test_runs_in_time(self):
        # measured 2026-10-30 on the dev PC: 1.7 s here (took_ms 1.4 s on its own), 3.1 s before the perf-1..6 fixes
        t = time.perf_counter()
        rc, o, e = run(["--from", self.tmp])
        el = time.perf_counter() - t
        self.assertEqual(rc, 0, e)
        d = json.loads(o)
        self.assertEqual(contract.validate(d), [])
        self.assertLess(el, 6.0 * PERF_LIMIT)
        # the fg log is read: the X11 game's window class gives its app the Steam note
        notes = {it["id"]: it.get("note") for it in d["ranges"]["since_full"]["items"]}
        self.assertEqual(notes.get("app:org.example.App02"), model.STEAM_NOTE)

    def test_short_screen_ons_join_the_nearest(self):
        # perf-5: only the previous and the next screen-on segment are looked at. The groups must be the ones the
        # scan over all of them made, the first one found winning a tie
        rng = self.since_full()
        _, groups = model.attribute_detail(rng, self.inp)
        segs = [s for s in rng.segments if s.kind in ("on", "off") and s.boot8 is not None]
        parent = list(range(len(segs)))

        def find(x):
            while parent[x] != x:
                x = parent[x]
            return x
        ons = [k for k, s in enumerate(segs) if s.kind == "on"]
        on = [segs[k] for k in ons]
        # what lets the model take the shortcut: in time order, each longer than 0, none overlapping
        self.assertTrue(all(x.a < x.b for x in on) and all(x.b <= y.a for x, y in zip(on, on[1:])))
        short = [k for k in ons if segs[k].b - segs[k].a < self.inp.rules.short_on_merge_s]
        for k in short:
            s = segs[k]
            best = min((j for j in ons if j != k), key=lambda j: max(0.0, segs[j].a - s.b, s.a - segs[j].b))
            parent[find(k)] = find(best)
        want: dict = {}
        for k in range(len(segs)):
            want.setdefault(find(k), []).append(k)
        self.assertGreater(len(short), 1000)
        self.assertEqual(sorted((g.a, g.b, g.segments) for g in groups),
                         sorted((min(segs[k].a for k in g), max(segs[k].b for k in g), len(g)) for g in want.values()))

    def test_plug_session_power(self):
        # perf-2: _fr_mean_mw bisects each boot's steps instead of scanning all of them once per plug session.
        # The same number for every session and windows around them; a boot whose steps do not run forward in
        # time is still scanned whole
        inp = self.inp
        ranges.build(inp)
        ends = ranges._step_ends(inp)
        self.assertEqual(set(ends), set(inp.steps))
        wins = []
        for s in inp.sessions:
            b = inp.src.now if s.b is None else s.b
            wins += [(s.a, b), (s.a - 3600, s.a + 1), (b - 1, b), (b, s.a)]
        lo = min(st[0].ta for st in inp.steps.values() if st)
        hi = max(st[-1].tb for st in inp.steps.values() if st)
        rnd = random.Random(3)
        wins += [(x, x + rnd.uniform(0, 3 * DAY)) for x in (rnd.uniform(lo - DAY, hi) for _ in range(20))]
        got = [ranges._fr_mean_mw(inp, a, b, ends) for a, b in wins]
        self.assertEqual(got, [ranges._fr_mean_mw(inp, a, b) for a, b in wins])
        self.assertGreater(len([g for g in got if g is not None]), 80)
        b8 = next(iter(inp.steps))
        odd = SimpleNamespace(steps=dict(inp.steps))
        odd.steps[b8] = odd.steps[b8][::-1]
        ends = ranges._step_ends(odd)
        self.assertNotIn(b8, ends)
        self.assertEqual([ranges._fr_mean_mw(odd, a, b, ends) for a, b in wins],
                         [ranges._fr_mean_mw(odd, a, b) for a, b in wins])

    def test_leaf_classes(self):
        # perf-3: _compute sorts the leaves into its cgroup sums in one pass, by a class cached per key, instead of
        # five scans: (PID 1, under system.slice, right under the user slice, the u_parents it is under)
        M = model._model(self.inp)
        app, ses = M.u_parents.index("u/app.slice"), M.u_parents.index("u/session.slice")
        for key, want in (("/init.scope", (True, False, False, ())),
                          ("s/NetworkManager.service", (False, True, False, ())),
                          ("u/app.slice/app-org.example.App00-1000.scope", (False, False, False, (app,))),
                          (model.KWIN_KEY, (False, False, False, (ses,))),
                          ("u/pipewire.service", (False, False, True, ())),
                          ("l/session-2.scope", (False, False, True, ())),
                          ("u/app.slicex.scope", (False, False, True, ())),
                          ("/user.slice", (False, False, False, ()))):
            self.assertEqual(M.leaf_class(key), want, key)

    def test_lookups_once_per_step_and_segment(self):
        # perf-4 / perf-6: a segment's bucket shares and a step's foreground stretches do not depend on the item,
        # so they are made once, not once per app (tens of thousands of calls over weeks)
        rng = self.since_full()
        model._MODEL.clear()
        with mock.patch.object(ranges, "spread", wraps=ranges.spread) as sp, \
                mock.patch.object(model._Model, "fg_overlap", autospec=True,
                                  side_effect=model._Model.fg_overlap) as fo:
            model.attribute_detail(rng, self.inp)
        M = model._model(self.inp)
        on_steps = sum(1 for b8, i in M._terms if self.inp.steps[b8][i].dpms == 1)
        on_segs = sum(1 for s in rng.segments if s.kind == "on")
        self.assertGreater(on_steps, 1000)
        self.assertLessEqual(sp.call_count, len(rng.segments))
        self.assertLessEqual(fo.call_count, on_steps + on_segs)


# ---------------------------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------------------------

class Errors(TmpDir):
    def err_doc(self, argv, **patch):
        rc, o, e = run(argv, **patch)
        self.assertEqual(rc, 2)
        doc = json.loads(o)
        self.assertTrue(contract.is_error(doc))
        self.assertEqual(contract.validate(doc), [])
        return doc["error"], e

    def test_usage(self):
        msg, _ = self.err_doc(["--bogus"])
        self.assertEqual(msg, "报表出错：UsageError: unrecognized arguments: --bogus")
        msg, _ = self.err_doc(["--json", "--text"])
        self.assertTrue(msg.startswith("报表出错：UsageError: "))
        msg, _ = self.err_doc(["--tz-offset", "9999"])
        self.assertEqual(msg, "报表出错：UsageError: --tz-offset 超出 -720..840：9999")
        msg, _ = self.err_doc(["--now", "nan"])
        self.assertTrue(msg.startswith("报表出错：UsageError: --now"))

    def test_help(self):
        rc, o, e = run(["--help"])
        self.assertEqual(rc, 0)
        self.assertIn("--from", o)

    def test_missing_capture(self):
        msg, _ = self.err_doc(["--from", os.path.join(self.tmp, "nope")])
        self.assertTrue(msg.startswith("报表出错：FileNotFoundError: 采集目录里没有 state/"))

    @need_real
    def test_missing_coeffs_and_rules(self):
        msg, _ = self.err_doc(real_args(), DEV_DIR=self.tmp)
        self.assertEqual(msg, "找不到系数文件")
        shutil.copy(os.path.join(config.DEV_DIR, "coeffs-v1.json"), self.tmp)
        msg, _ = self.err_doc(real_args(), DEV_DIR=self.tmp)
        self.assertEqual(msg, "找不到 rules.json")

    @need_real
    def test_bad_coeffs_file_is_skipped(self):
        for n in ("coeffs-v1.json", "rules.json"):
            shutil.copy(os.path.join(config.DEV_DIR, n), self.tmp)
        put(os.path.join(self.tmp, "coeffs-v7.json"), '{"version": 7, "coeffs": ')
        rc, o, e = run(real_args(), DEV_DIR=self.tmp)
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(o)["coeffs"]["version"], 1)
        self.assertIn("跳过坏的系数文件", e)

    def test_zero_divisor_coeffs_file_is_skipped(self):
        # a hand-edited divisor (or V_nom) at 0 is a bad file like the one above, not 「报表出错：ZeroDivisionError」
        for n in ("coeffs-v1.json", "rules.json"):
            shutil.copy(os.path.join(config.DEV_DIR, n), self.tmp)
        cap = os.path.join(self.tmp, "cap")         # screen-off wakeups, GPU and both CPU clusters: every divisor
        standard_capture(cap)
        v1 = json.loads(Path(config.DEV_DIR, "coeffs-v1.json").read_text(encoding="utf-8"))
        for k in ("fmax_little", "fmax_big", "g_fref_mhz", "R0", "ctx_per_wake", "V_nom"):
            with self.subTest(k=k):
                d = json.loads(json.dumps(v1))
                d["version"] = 7
                d["coeffs"][k]["value"] = 0
                put(os.path.join(self.tmp, "coeffs-v7.json"), json.dumps(d))
                rc, o, e = run(["--from", cap], DEV_DIR=self.tmp)
                self.assertEqual(rc, 0, o)
                self.assertEqual(json.loads(o)["coeffs"]["version"], 1)
                self.assertIn("跳过坏的系数文件", e)
                d["coeffs"][k]["value"] = -1
                with self.assertRaises(ValueError):
                    config.parse_coeffs(json.dumps(d), "dev", "p")

    @need_real
    def test_self_check_failure(self):
        real = out.to_json

        def broken(rep):
            d = real(rep)
            d["ranges"]["24h"]["used_pct"] += 1
            d["battery"]["pct"] = 101
            return d
        with mock.patch.object(out, "to_json", broken):
            msg, e = self.err_doc(real_args())
        self.assertTrue(msg.startswith("报表自检没通过："))
        self.assertIn("battery.pct", e)
        self.assertIn("ranges.24h.used_pct", e)

    @need_real
    def test_uncaught_exception(self):
        with mock.patch.object(model, "attribute_detail", side_effect=RuntimeError("boom")):
            msg, e = self.err_doc(real_args())
        self.assertEqual(msg, "报表出错：RuntimeError: boom")
        self.assertIn("Traceback", e)

    @need_real
    def test_reader_gone(self):
        # `y700-battery-report --text | head -1`: the pipe closes under the one write. Not the report's failure:
        # exit 0, no traceback, no second document
        class Gone(io.BytesIO):
            def write(self, b):
                raise BrokenPipeError(32, "Broken pipe")

        class Pipe:
            buffer = Gone()

            def flush(self):
                pass

            def fileno(self):
                raise io.UnsupportedOperation("fileno")

        e = io.StringIO()
        quiet = mock.patch.multiple(config, SHARE_DIR=NOWHERE, user_dir=lambda env=None: NOWHERE)
        with quiet, mock.patch.object(sys, "stdout", Pipe()), contextlib.redirect_stderr(e):
            for mode in ("--text", "--json"):
                self.assertEqual(cli.main(real_args(mode)), 0)
        self.assertEqual(e.getvalue(), "")

    def test_package_that_does_not_import(self):
        # the entry script beside a half-copied package: still one error document and exit 2, the traceback on
        # stderr for the journal
        for src, kind in (("def main(:\n", "SyntaxError"), ("from . import nope\n", "ImportError")):
            with self.subTest(kind=kind):
                d = os.path.join(self.tmp, kind)
                put(os.path.join(d, "y700_battery", "__init__.py"), "")
                put(os.path.join(d, "y700_battery", "cli.py"), src)
                shutil.copy(ENTRY, d)
                p = subprocess.run([sys.executable, "-X", "utf8", "-I", "-B", os.path.join(d, ENTRY.name)],
                                   capture_output=True, timeout=120)
                self.assertEqual(p.returncode, 2)
                doc = json.loads(p.stdout.decode("utf-8"))
                self.assertEqual(contract.validate(doc), [])
                self.assertTrue(doc["error"].startswith("报表出错：" + kind + ": "), doc["error"])
                self.assertIn("Traceback", p.stderr.decode("utf-8", "replace"))


class Config(TmpDir):
    def test_lookup_order(self):
        user, share = os.path.join(self.tmp, "user"), os.path.join(self.tmp, "share")
        for d in (user, share):
            os.makedirs(d)
        src = Path(config.DEV_DIR, "coeffs-v1.json").read_text(encoding="utf-8")
        put(os.path.join(share, "coeffs-v1.json"), src)
        put(os.path.join(user, "coeffs-v2.json"), src.replace('"version": 1', '"version": 2', 1))
        put(os.path.join(user, "coeffs-v10.json"), src.replace('"version": 1', '"version": 10', 1))
        with mock.patch.multiple(config, SHARE_DIR=share, user_dir=lambda env=None: user):
            c = config.load_coeffs(from_mode=False)
            self.assertEqual((c.version, c.source), (10, "user"))
            c = config.load_coeffs(from_mode=True)         # --from never looks at ~/.config
            self.assertEqual((c.version, c.source), (1, "package"))
        self.assertEqual(c.values["F_on"], 330.0)
        self.assertEqual(c.b_points[0], (41.0, 0.0))

    def test_user_dir(self):
        self.assertEqual(config.user_dir({"XDG_CONFIG_HOME": "/x/cfg"}), os.path.join("/x/cfg", "y700-battery"))
        self.assertTrue(config.user_dir({"XDG_CONFIG_HOME": "rel"}).endswith(os.path.join(".config",
                                                                                         "y700-battery")))

    def test_parse_errors(self):
        for text in ('[]', '{"version": 0, "coeffs": {}}', '{"version": 1, "coeffs": {"B": {"value": [[1, 2]]}}}',
                     '{"version": 1, "coeffs": {"F_on": {"value": "x"}}}', '{"version": 1, "date": "30.10."}'):
            with self.assertRaises(ValueError):
                config.parse_coeffs(text, "dev", "p")
        with self.assertRaises(ValueError):
            config.parse_rules('{"min_split_s": -1}')
        r = config.parse_rules(Path(config.DEV_DIR, "rules.json").read_text(encoding="utf-8"))
        self.assertEqual(r.min_split_s, 300)
        self.assertTrue(r.labels)

    def test_health_pct(self):
        from y700_battery.types import LiveBattery
        self.assertEqual(cli.health_pct(LiveBattery(pct=1, status="unknown", plugged=False, charge_full_uah=8394000,
                                                    charge_full_design_uah=9000000)), 93)
        self.assertIsNone(cli.health_pct(LiveBattery(pct=1, status="unknown", plugged=False)))


# ---------------------------------------------------------------------------------------------
# --fit
# ---------------------------------------------------------------------------------------------

def py_lstsq(cols, y):
    """least squares by the normal equations (tests only: stands in for numpy here)"""
    n = len(cols)
    a = [[sum(x * z for x, z in zip(cols[i], cols[j])) for j in range(n)] + [sum(x * v for x, v in zip(cols[i], y))]
         for i in range(n)]
    for i in range(n):
        p = max(range(i, n), key=lambda r: abs(a[r][i]))
        a[i], a[p] = a[p], a[i]
        if abs(a[i][i]) < 1e-12:
            continue
        for r in range(n):
            if r != i:
                f = a[r][i] / a[i][i]
                a[r] = [x - f * z for x, z in zip(a[r], a[i])]
    return [a[i][n] / a[i][i] if abs(a[i][i]) >= 1e-12 else 0.0 for i in range(n)]


def have_numpy():
    try:
        import numpy  # noqa: F401
        return True
    except ImportError:
        return False


class Fit(TmpDir):
    def test_num_keeps_four_digits(self):
        # one decimal turned k_pkt 0.2 x 0.7 into 0.1, and a small coefficient into a 0 taken as real
        self.assertEqual((fit._num(0.2 * 0.7), fit._num(0.0123456), fit._num(0.04)), (0.14, 0.01235, 0.04))
        self.assertEqual((fit._num(147.0), fit._num(12345.6), fit._num(0.0)), (147, 12350, 0.0))
        self.assertIs(type(fit._num(147.0)), int)

    def test_nnls(self):
        cols = [[1.0, 0.0, 1.0, 2.0], [0.0, 1.0, 1.0, 1.0]]
        y = [2 * c0 + 0.5 * c1 for c0, c1 in zip(*cols)]
        self.assertEqual([round(v, 9) for v in fit.nnls(cols, y, py_lstsq)], [2.0, 0.5])
        y = [2 * c0 - 1.0 * c1 for c0, c1 in zip(*cols)]       # the free solution has a negative weight
        x = fit.nnls(cols, y, py_lstsq)
        self.assertEqual(x[1], 0.0)
        self.assertGreater(x[0], 0.0)

    def test_solve_bounds_and_ties(self):
        # Pg only has data in rows 6-11, where nothing else does: fixing it at x1 leaves the other fits alone
        rows = [(0, 600, 600.0, 0.0)] * 12
        a = [1.0 + i % 3 for i in range(6)] + [0.0] * 6
        b = [2.0 * v for v in a]                                # parallel to a: cannot be told apart
        c = [0.0] * 6 + [1.0 + (i * 7) % 5 for i in range(6)]
        g = [0.5 + (i * 5) % 4 for i in range(6)] + [0.0] * 6
        e = [1.2 * a[i] + 1.2 * b[i] + 3.0 * c[i] + 0.9 * g[i] for i in range(12)]
        dm = {"rows": [(r[0], r[1], r[2], ej) for r, ej in zip(rows, e)],
              "cols": {"F_on": a, "D_on": b, "Pg": c, "A": g, "k_pkt": [0.0] * 12}, "base": [0.0] * 12}
        sol = fit.solve(dm, py_lstsq)
        self.assertFalse(sol["accepted"]["Pg"])                 # x3 is outside x0.5..x2
        self.assertEqual(sol["scales"]["Pg"], 1.0)
        self.assertIn("拟合出 ×3.000，超出", sol["reasons"]["Pg"])
        self.assertTrue(sol["accepted"]["F_on"] and sol["accepted"]["D_on"] and sol["accepted"]["A"])
        self.assertAlmostEqual(sol["scales"]["F_on"], 1.2, places=9)
        self.assertAlmostEqual(sol["scales"]["A"], 0.9, places=9)
        self.assertEqual(sol["scales"]["F_on"], sol["scales"]["D_on"])
        self.assertIn("分不开", sol["reasons"]["D_on"])
        self.assertFalse(sol["accepted"]["k_pkt"])
        self.assertIn("没有它的数据", sol["reasons"]["k_pkt"])
        self.assertLess(sol["rmse_after_mw"], sol["rmse_before_mw"])

    def test_fit_on_a_ledger(self):
        days_capture(self.tmp, days=4, per_snap=10)
        with mock.patch.multiple(config, SHARE_DIR=NOWHERE, user_dir=lambda env=None: NOWHERE):
            inp = cli.load_inputs(self.tmp, None, 480)
            res = fit.fit(inp, lstsq=py_lstsq)
        self.assertGreaterEqual(res["rows"], fit.MIN_ROWS)
        doc = res["doc"]
        self.assertEqual((doc["version"], doc["date"]), (2, "2026-10-30"))
        text = fit.format_fit(res)
        c = config.parse_coeffs(text, "user", "x")               # the suggestion loads as a coeffs file
        for k, p in res["coeffs"].items():
            self.assertTrue(fit.LO <= p["scale"] <= fit.HI, k)
            self.assertEqual(p["accepted"], "超出" not in p["reason"] and "没有" not in p["reason"], k)
            changed = p["accepted"] and abs(p["scale"] - 1) > 1e-4
            if k == "B":
                self.assertEqual([list(x) for x in c.b_points], p["suggest"] if changed else p["current"])
            else:
                self.assertEqual(model.coeff(c, k), p["suggest"] if changed else p["current"], k)
        self.assertEqual(doc["calibrated"], any(p["accepted"] for p in res["coeffs"].values()))
        self.assertIn("_fit", doc)
        self.assertIn("建议的系数文件", fit.summary(res))

    @need_real
    def test_too_few_rows(self):
        with mock.patch.multiple(config, SHARE_DIR=NOWHERE, user_dir=lambda env=None: NOWHERE):
            inp = cli.load_inputs(str(REAL), float(REAL_NOW), 480)
        with self.assertRaises(fit.FitError):
            fit.fit(inp, lstsq=py_lstsq)

    @need_real
    @unittest.skipIf(have_numpy(), "numpy is installed here")
    def test_cli_without_numpy(self):
        rc, o, e = run(real_args("--fit"))
        self.assertEqual(rc, 2)
        self.assertEqual(json.loads(o), {"v": 1, "error": "--fit 要 numpy"})
        self.assertIn("--fit 要 numpy", e)

    @unittest.skipUnless(have_numpy(), "numpy is not installed here")
    def test_cli_with_numpy(self):
        days_capture(self.tmp, days=4, per_snap=10)
        rc, o, e = run(["--fit", "--from", self.tmp])
        self.assertEqual(rc, 0, e)
        self.assertEqual(json.loads(o)["version"], 2)


# ---------------------------------------------------------------------------------------------
# 1 s vs 10 s integration (DESIGN 8)
# ---------------------------------------------------------------------------------------------

LINE = re.compile(r"^t=(\S+) at=\S+ up=\S+ bat=([+-]\d+)mW dpms=(\S+) ")


def fast_windows(rows, n=300):
    """windows of n + 1 consecutive 1 s lines (5 min) inside the logs' fast-mode stretches"""
    stretch = [rows[0]]
    for r in rows[1:] + [None]:
        if r is not None and 0.5 <= r[0] - stretch[-1][0] <= 1.5:
            stretch.append(r)
            continue
        for i in range(0, len(stretch) - n, n):
            w = stretch[i:i + n + 1]
            if w[-1][0] - w[0][0] <= n + 10:
                yield w
        if r is not None:
            stretch = [r]


def energy(rows):
    a = Acc("ab12cd34")
    a.begin(rows[0][2])
    for t, mw, dpms in rows:
        # the logs do not carry the battery status: a 0 counts as a missing reading (status Discharging)
        a.step(t, float(mw), True, "Discharging", dpms, 410 if dpms == "On" else None)
    return a


@unittest.skipUnless((LOGS / "flightrec-690a169c.log.gz").exists(), "runs/diag/flightrec not present")
class OneVsTenSeconds(unittest.TestCase):
    """The recorder integrates flightrec's 10 s samples. Against the 1 s samples of the two logs, over 5-min
    windows without charging: measured 2026-10-30 p90 4.3 % (974b286c, 12 windows), 3.7 % (690a169c, 168 windows),
    3.7 % for all 180 (median 1.2-1.5 %)."""

    def test_p90_and_zero_counts(self):
        errs = []
        for boot, zeros in (("974b286c", 178), ("690a169c", 232)):
            rows, nz = [], 0
            with gzip.open(LOGS / ("flightrec-%s.log.gz" % boot), "rt", encoding="utf-8", errors="replace") as f:
                for ln in f:
                    m = LINE.match(ln)
                    if m:
                        rows.append((float(m.group(1)), int(m.group(2)), m.group(3)))
                        nz += m.group(2) == "-0"
            self.assertEqual(nz, zeros, boot)      # the readings flightrec logged as -0 mW (no value)
            mine = []
            for w in fast_windows(rows):
                if any(mw < 0 for _, mw, _ in w):
                    continue
                a1, a10 = energy(w), energy(w[::10])
                e1, e10 = a1.don + a1.doff, a10.don + a10.doff
                if e1 > 0 and a1.chg == 0 and a10.chg == 0:
                    mine.append(abs(e10 - e1) / e1)
            self.assertGreater(len(mine), 10, boot)
            errs += mine
        errs.sort()
        p90 = errs[int(math.ceil(0.9 * len(errs))) - 1]
        self.assertEqual(len(errs), 180)
        self.assertLess(p90, 0.06)
        self.assertGreater(p90, 0.01)


if __name__ == "__main__":
    if sys.argv[1:] == ["regen"]:
        regen()
    else:
        unittest.main()
