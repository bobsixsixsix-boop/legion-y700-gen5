"""Tests for y700_battery.acc_ref, the reference of y700-flightrec's energy accumulator (linux/power/flightrec/src/acc.rs).
Run on Win11 from the repo root (DESIGN.md section 8; -t linux/power/battery/report works too):
    tools/venv/Scripts/python -X utf8 -I -B -m unittest discover -s linux/power/battery/report/tests
The shared cases are linux/power/flightrec/fixtures/acc/cases.txt; acc.rs's tests (cargo test on the tablet) run the
same file and assert the same hand-computed numbers as HandComputed below (energies in uJ, times in ms)."""
import importlib.util
import gzip
import sys
import unittest
from pathlib import Path

REPORT = Path(__file__).resolve().parents[1]         # without -t, discover puts only tests/ on sys.path
if str(REPORT) not in sys.path:
    sys.path.insert(0, str(REPORT))
from y700_battery import acc_ref  # noqa: E402
from y700_battery.acc_ref import Acc  # noqa: E402

POWER = REPORT.parents[1]                            # report -> battery -> power
FIXTURE = POWER / "flightrec" / "fixtures" / "acc" / "cases.txt"
MAKE = FIXTURE.parent / "make-fixtures.py"
LOGS = POWER.parents[1] / "runs" / "diag" / "flightrec"   # not in git: those tests skip without it
REQUIRED = ("690a169c-66030", "690a169c-66620", "690a169c-66870", "974b286c-21327")


def cases():
    runners, fails = acc_ref.check_cases(FIXTURE.read_text(encoding="utf-8"))
    return runners, fails


class SharedFixtures(unittest.TestCase):
    def test_every_case_matches(self):
        runners, fails = cases()
        self.assertEqual(fails, [])
        self.assertEqual(len(runners), 14)

    def test_required_excerpts_present(self):
        runners, _ = cases()
        for name in REQUIRED:
            self.assertIn(name, runners)

    def test_time_partition(self):
        # every ms between the first and the last line of a count is in exactly one energy-side bucket
        runners, _ = cases()
        for name, run in runners.items():
            st = run.st
            with self.subTest(case=name):
                self.assertEqual(st.dton + st.dtoff + st.tchg + st.tzero + sum(st.pend) + st.gap, st.t - run.t0)
                self.assertLessEqual(st.ton + st.toff, st.t - run.t0)

    def test_roundtrip(self):
        runners, _ = cases()
        for name, run in runners.items():
            line = run.st.render()
            with self.subTest(case=name):
                self.assertEqual(len(line), acc_ref.WIDTH)
                back = Acc.parse(line, run.st.boot)
                self.assertIsNotNone(back)
                self.assertEqual(back.render(), line)


class HandComputed(unittest.TestCase):
    """the numbers worked out by hand from the inputs (acc.rs asserts the same)"""

    @classmethod
    def setUpClass(cls):
        cls.runners, _ = cases()

    def st(self, name):
        return self.runners[name].st

    def test_690a169c_66030_backfill(self):
        # 66000.2 +118, 66010.2 +1003, 66020.2 +626 (On), 58 missing lines (two On), 66610.2 +153 (Off)
        s = self.st("690a169c-66030")
        self.assertEqual((s.don, s.dton, s.ton), (5_605_000 + 8_145_000 + 7_790_000, 40_000, 40_000))
        self.assertEqual((s.doff, s.dtoff, s.toff), (222_015_000, 570_000, 570_000))   # 389.5 mW x 570 s
        self.assertEqual((s.tzero, s.gap, s.pend, s.n, s.pw), (0, 0, [0, 0], 62, "dis"))
        self.assertEqual(s.bl, 410 * 40_000)

    def test_pw_debounce(self):
        s = self.st("pw-debounce")
        self.assertEqual((s.don, s.doff, s.chg), (1_525_000, 3_525_000, 3_000_000))
        self.assertEqual((s.ton, s.toff, s.dton, s.dtoff, s.tchg, s.tzero), (20_000, 100_000, 20_000, 40_000, 30_000, 30_000))
        self.assertEqual((s.bl, s.lb, s.pw, s.on), (1_000_000, -100.0, "chg", False))

    def test_gap_dt(self):
        s = self.st("gap-dt")
        self.assertEqual((s.gap, s.ton, s.dton, s.don), (360_000, 40_000, 40_000, 27_000_000))
        self.assertEqual((s.bl, s.lb, s.pw, s.n), (70_000_000, 900.0, "dis", 7))

    def test_missing_30min(self):
        s = self.st("missing-30min")
        self.assertEqual((s.gap, s.doff, s.dtoff, s.toff), (1_900_000, 375_000_000, 1_850_000, 3_750_000))
        self.assertEqual((s.pend, s.n, s.lbt), ([0, 0], 76, 3_850_000))

    def test_zero_plugged(self):
        s = self.st("zero-plugged")
        self.assertEqual((s.chg, s.tchg, s.doff, s.dtoff), (104_000_000, 40_000, 10_000_000, 30_000))
        self.assertEqual((s.tzero, s.toff, s.gap, s.pw), (60_000, 130_000, 0, "dis"))

    def test_boot_start(self):
        s = self.st("boot-start")
        self.assertEqual((s.tzero, s.doff, s.dtoff, s.toff, s.lb), (20_000, 8_500_000, 30_000, 50_000, 350.0))

    def test_restart_same_boot(self):
        s = self.st("restart-same-boot")
        self.assertEqual((s.n, s.t, s.don, s.doff, s.dtoff, s.toff), (4, 50_000, 5_000_000, 12_000_000, 30_000, 30_000))
        self.assertEqual((s.bl, s.pw), (2_000_000, "unk"))

    def test_restart_new_boot(self):
        s = self.st("restart-new-boot")
        self.assertEqual((s.boot, s.n, s.t, s.don, s.ton, s.lb), ("bbbb2222", 1, 70_000, 0, 0, 100.0))

    def test_64370_plugged_vs_discharging(self):
        # the same 50 zero lines: on the charger they are tzero one by one; as a missing run after lb = -8315 the
        # mean (-8315+127)/2 is negative, so the run (510 s with its closing step) is tzero too, not discharge
        p, d = self.st("690a169c-64370-plugged"), self.st("690a169c-64370-dischg")
        self.assertEqual(p.tzero, 500_000)
        self.assertEqual(d.tzero, 510_000)
        self.assertEqual(p.doff - d.doff, 635_000)        # (0+127)/2 x 10 s, only when the zeros were real
        self.assertEqual(p.chg, d.chg)


class Rules(unittest.TestCase):
    def test_classify(self):
        self.assertEqual(acc_ref.classify(-0.0, False, None)[0], acc_ref.MISSING)
        self.assertEqual(acc_ref.classify(-0.0, True, None)[0], acc_ref.MISSING)
        self.assertEqual(acc_ref.classify(-0.0, True, "Discharging")[0], acc_ref.MISSING)
        self.assertEqual(acc_ref.classify(-0.0, True, "")[0], acc_ref.MISSING)
        self.assertEqual(acc_ref.classify(0.0, True, "Full")[0], acc_ref.ZERO)
        self.assertEqual(acc_ref.classify(-0.0, True, "Not charging")[0], acc_ref.ZERO)
        self.assertEqual(acc_ref.classify(312.4, True, None), (acc_ref.VALID, 312.4))
        self.assertEqual(acc_ref.classify(312.4, False, None)[0], acc_ref.MISSING)
        self.assertEqual(acc_ref.classify(float("nan"), True, None)[0], acc_ref.MISSING)

    def test_rounding(self):
        self.assertEqual((acc_ref.ms(66030.2), acc_ref.ms(0.0005), acc_ref.ms(-1.0)), (66_030_200, 1, 0))
        self.assertEqual((acc_ref.uj(2.5), acc_ref.uj(2.4999), acc_ref.uj(-3.0)), (3, 2, 0))
        self.assertEqual((acc_ref.mw_int(-0.5), acc_ref.mw_int(0.5), acc_ref.mw_int(-0.0)), (-1, 1, 0))

    def test_edge_only_on_change(self):
        a = Acc("edgetest")
        a.begin("Off")
        due = [a.step(10.0 * i, 300.0, True, None, "Off", None) for i in range(1, 8)]
        self.assertEqual(due, [False, False, True, False, False, False, False])   # pw unk -> dis at the 3rd
        self.assertTrue(a.step(80.0, 300.0, True, None, "On", 900))
        self.assertFalse(a.step(90.0, 300.0, True, None, "?", None))
        self.assertTrue(a.step(100.0, 300.0, True, None, "Off", None))
        self.assertEqual(a.edge(100.0), "v1 t=100.0 dpms=Off pw=dis")


class Format(unittest.TestCase):
    def test_fresh_line(self):
        line = Acc("3f2a9c1e-77d0-4b1e").render()
        self.assertEqual(line, "v1 boot=3f2a9c1e t=0000000000000 n=0000000000000 ton=0000000000000 "
                               "toff=0000000000000 don=0000000000000 doff=0000000000000 dton=0000000000000 "
                               "dtoff=0000000000000 chg=0000000000000 tchg=0000000000000 tz=0000000000000 "
                               "tzero=0000000000000 gap=0000000000000 bl=0000000000000 lb=+000000000000 "
                               "lbt=0000000000000 dpms=Off pw=unk")
        self.assertEqual(len(line), acc_ref.WIDTH)

    def test_width_fixed_at_the_limits(self):
        a = Acc("noboot")
        self.assertEqual(a.boot, "noboot--")
        a.on, a.pw = True, "chg"
        a.t, a.n, a.don, a.chg, a.bl, a.gap = 10 ** 15, 10 ** 14, 10 ** 20, 5, 10 ** 13, 10 ** 13 - 1
        a.lb, a.lbt = -3.0e15, 1
        line = a.render()
        self.assertEqual(len(line), acc_ref.WIDTH)
        self.assertIn(" t=9999999999999 ", line)
        self.assertIn(" chg=0000000000000 ", line)          # 5 uJ is 0 mJ
        self.assertIn(" lb=-999999999999 ", line)
        self.assertIn(" dpms=On  pw=chg", line)

    def test_parse_rejects(self):
        good = Acc("abcd1234").render()
        self.assertIsNotNone(Acc.parse(good, "abcd1234"))
        self.assertIsNotNone(Acc.parse(good + "\n", "abcd1234-5678"))   # the boot is cut to 8 like the line's
        self.assertIsNone(Acc.parse(good, "abcd9999"))
        self.assertIsNone(Acc.parse("v2" + good[2:], "abcd1234"))
        self.assertIsNone(Acc.parse(good.replace(" gap=0000000000000", ""), "abcd1234"))
        self.assertIsNone(Acc.parse(good.replace("dpms=Off", "dpms=?  "), "abcd1234"))
        self.assertIsNone(Acc.parse(good.replace("pw=unk", "pw=xyz"), "abcd1234"))
        self.assertIsNone(Acc.parse(good.replace("n=0000000000000", "n=10000000000000"), "abcd1234"))
        self.assertIsNone(Acc.parse(good.replace("n=0000000000000", "n=00000000000_0"), "abcd1234"))
        # u64::from_str takes any number of leading zeros; int() would raise past 4300 digits
        self.assertEqual(Acc.parse(good.replace("n=0000000000000", "n=" + "0" * 5000 + "7"), "abcd1234").n, 7)
        self.assertIsNone(Acc.parse(good.replace("n=0000000000000", "n=1" + "0" * 5000), "abcd1234"))
        self.assertIsNone(Acc.parse(good.replace("lb=+000000000000", "lb=-1" + "0" * 5000), "abcd1234"))
        self.assertIsNone(Acc.parse("", "abcd1234"))
        self.assertIsNone(Acc.parse("garbage", "abcd1234"))

    def test_resume_keeps_the_open_run(self):
        a = Acc("runtest1")
        a.step(10.0, 400.0, True, None, "On", 10)
        a.step(20.0, -0.0, False, None, "On", 10)
        b = Acc.parse(a.render(), "runtest1")
        self.assertEqual((b.pend, b.lb, b.lbt, b.t), ([0, 10_000], 400.0, 10_000, 20_000))
        b.step(30.0, 200.0, True, None, "On", 10)
        self.assertEqual((b.don, b.dton, b.pend), (300 * 20_000, 20_000, [0, 0]))


@unittest.skipUnless((LOGS / "flightrec-690a169c.log.gz").exists() and (LOGS / "flightrec-974b286c.log.gz").exists(),
                     "runs/diag/flightrec logs are not here (not in git)")
class FromLogs(unittest.TestCase):
    def test_zero_reading_counts(self):
        # DESIGN.md section 2: -0mW 178 (974b286c) / 232 (690a169c) lines, +0mW none
        for boot, want in (("974b286c", 178), ("690a169c", 232)):
            with gzip.open(LOGS / ("flightrec-%s.log.gz" % boot), "rt", encoding="utf-8", errors="replace") as f:
                data = [l for l in f if l.startswith("t=")]
            self.assertEqual(sum(" bat=-0mW " in l for l in data), want)
            self.assertEqual(sum(" bat=+0mW " in l for l in data), 0)

    def test_fixture_is_what_make_fixtures_builds(self):
        spec = importlib.util.spec_from_file_location("make_fixtures", MAKE)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.assertEqual(mod.build(LOGS), FIXTURE.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
