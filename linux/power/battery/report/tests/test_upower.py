"""upower.py: GetHistory / .dat parsing, the battery's .dat names, clock correction against the ledger, merging.

Run: tools/venv/Scripts/python -X utf8 -I -B -m unittest discover -s linux/power/battery/report/tests -t linux/power/battery/report
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

REPORT = Path(__file__).resolve().parents[1]
if str(REPORT) not in sys.path:
    sys.path.insert(0, str(REPORT))

from tests.fixtures import synth  # noqa: E402
from tests.fixtures.synth import B_FAKE, C_FAKE, C_REAL, D, D_FAKE, T0  # noqa: E402
from y700_battery import ledger, upower  # noqa: E402
from y700_battery.types import Ledger, LiveBattery, Sources, UpPoint  # noqa: E402

REAL = REPORT / "tests" / "fixtures" / "real-1030"
HAVE_REAL = (REAL / "state").is_dir() and (REAL / "upower-charge.json").is_file()
NOW = T0 + 60000.0
MONO_NOW = 500.0


def busctl(points):
    """GetHistory as busctl --json=short prints it: newest first"""
    return json.dumps({"type": "a(udu)", "data": [[[t, v, s] for t, v, s in reversed(points)]]})


def dat(points):
    words = {0: "unknown", 1: "charging", 2: "discharging", 4: "fully-charged"}
    return "".join("%d\t%.3f\t%s\n" % (t, v, words[s]) for t, v, s in points)


def src(charge=None, rate=None, dats=None):
    return Sources(now=NOW, tz_offset_min=480, from_dir=None, state_dir="", boot_id=None, mono_now=None,
                   battery=LiveBattery(pct=None, status="unknown", plugged=False), upower_charge_json=charge,
                   upower_rate_json=rate, upower_dat=dats or {})


class TestParse(unittest.TestCase):
    def test_gethistory(self):
        pts = [(1793000000, 50.0, 2), (1793000100, 49.0, 2), (1793000200, 49.0, 1)]
        out = upower.parse_gethistory(busctl(pts))
        self.assertEqual(out, [UpPoint(t=float(t), value=v, state=s) for t, v, s in pts])

    def test_gethistory_bad(self):
        self.assertEqual(upower.parse_gethistory(""), [])
        self.assertEqual(upower.parse_gethistory("Call failed: No such object"), [])
        self.assertEqual(upower.parse_gethistory('{"type":"a(udu)","data":[]}'), [])
        self.assertEqual(upower.parse_gethistory('{"type":"a(udu)","data":[[[1,2],[1793000000,5,9],'
                                                 '[1793000001,5,2]]]}'), [UpPoint(1793000001.0, 5.0, 2)])

    @unittest.skipUnless(HAVE_REAL, "tests/fixtures/real-1030 capture not present (not published)")
    def test_real_gethistory(self):
        ch = upower.parse_gethistory((REAL / "upower-charge.json").read_text(encoding="utf-8"))
        rt = upower.parse_gethistory((REAL / "upower-rate.json").read_text(encoding="utf-8"))
        self.assertEqual((len(ch), len(rt)), (140, 3748))
        # oldest first: upowerd's start marker, then the boot's first reading; newest last
        self.assertEqual(ch[0], UpPoint(1793202219.0, 0.0, 0))
        self.assertEqual(ch[1], UpPoint(1793202219.0, 68.0, 2))
        self.assertEqual(ch[-1], UpPoint(1793313408.0, 76.0, 0))
        self.assertAlmostEqual(rt[0].value + rt[1].value, 4.197694, places=6)

    def test_dat(self):
        text = ("1793000000\t50.000\tdischarging\n"
                "1793000100\t51.000\tcharging\n"
                "\n"
                "x\ty\tz\n"
                "1793000200\t52\t4\n"
                "1793000300\t53\tbogus\n"
                "1793000400\t100.000\tfully-charged\n")
        self.assertEqual(upower.parse_dat(text), [UpPoint(1793000000.0, 50.0, 2), UpPoint(1793000100.0, 51.0, 1),
                                                  UpPoint(1793000200.0, 52.0, 4), UpPoint(1793000400.0, 100.0, 4)])

    def test_dat_kind(self):
        self.assertEqual(upower.dat_kind("history-charge-BAT0-33.dat"), ("charge", "BAT0-33"))
        self.assertEqual(upower.dat_kind("history-rate-BAT0.dat"), ("rate", "BAT0"))
        self.assertIsNone(upower.dat_kind("history-time-full-BAT0.dat"))
        self.assertIsNone(upower.dat_kind("history-charge-.dat"))
        self.assertIsNone(upower.dat_kind("history-charge-BAT0.dat.bak"))


class TestDatNames(unittest.TestCase):
    NAMES = ["history-charge-Li_ion_1_0-33.dat", "history-charge-Li_ion_1_0-40.dat", "history-rate-Li_ion_1_0-33.dat",
             "history-time-full-Li_ion_1_0-33.dat", "history-charge-Li_ion_1_0.dat",
             "history-charge-_org_bluez_hci0_dev_1.dat", "history-rate-_org_bluez_hci0_dev_1-5.dat",
             "history-charge-generic_id.dat", "history-charge-generic_id-3.dat", "history-charge-Mouse.dat",
             "history-charge-Li_ion_1_0_extra-2.dat"]

    def test_with_model(self):
        # up-device.c: g_strdelimit turns the model's space, '.', '/' ... into '_'
        self.assertEqual(upower.battery_dat_names(self.NAMES, "Li ion 1.0"),
                         ["history-charge-Li_ion_1_0-33.dat", "history-charge-Li_ion_1_0-40.dat",
                          "history-charge-Li_ion_1_0.dat", "history-rate-Li_ion_1_0-33.dat"])

    def test_without_model(self):
        # the design-energy suffix marks the battery; Bluetooth (native path, leading '_') and generic_id never match
        self.assertEqual(upower.battery_dat_names(self.NAMES, None),
                         ["history-charge-Li_ion_1_0-33.dat", "history-charge-Li_ion_1_0-40.dat",
                          "history-charge-Li_ion_1_0.dat", "history-charge-Li_ion_1_0_extra-2.dat",
                          "history-rate-Li_ion_1_0-33.dat"])
        self.assertEqual(upower.battery_dat_names(self.NAMES, " x "), upower.battery_dat_names(self.NAMES, None))


class TestClean(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            synth.standard(d)
            cls.led = ledger.read_dir(d)
        ledger.assign_clocks(cls.led, D, NOW, MONO_NOW)

    def test_eras(self):
        e = upower._eras(self.led)
        got = [(round(x.lo - T0, 6), round(x.hi - T0, 6), round(x.shift, 6)) for x in e]
        self.assertEqual(got, [(-120.0, 5900.0, 0.0),                # A: synced from its first line, so the slack
                               (5800.0, 6800.0, 100.0),               # B: chained after A, raw clock 100 s behind
                               (7000.0, 7045.0, 3600.0),              # C before the K step
                               (10645.0, 13020.0, 0.0),               # C after it
                               (50000.0, float("inf"), 9500.0)])      # D, the current boot: open-ended

    def test_clean(self):
        P = [(T0 - 3000, 50, 2),        # before the ledger: kept as recorded
             (T0 - 4000, 49, 2),        # going back: dropped
             (T0 - 60, 51, 1),          # upowerd's first points come before the recorder: A's slack
             (T0 + 1000, 60, 1),
             (T0 + 900, 59, 1),         # back in time inside A: no later era has it, dropped
             (T0 + 5890, 80, 4),
             (B_FAKE + 50, 79, 2),      # B's fake clock is behind A's last point: the next era, shifted by +100
             (B_FAKE + 500, 75, 2),
             (C_FAKE - 10, 70, 2),      # between B's last line and C's mono 0: dropped
             (C_FAKE + 30, 69, 2),      # C before its K step: corrected by the step
             (C_FAKE + 100, 68, 2),     # a raw time no era claims (a step the ledger never saw): dropped
             (C_REAL + 100, 67, 2),
             (1000, 66, 2),             # the RTC's 1970
             (D_FAKE + 100, 60, 2),     # the current, never-synced boot: anchored at now
             (D_FAKE + 200, 0, 0)]      # upowerd's start marker
        pts = [UpPoint(float(t), float(v), s) for t, v, s in P]
        kept, dropped = upower.clean(pts, self.led)
        self.assertEqual(dropped, 6)
        self.assertEqual([(round(p.t - T0, 6), p.value) for p in kept],
                         [(-3000.0, 50.0), (-60.0, 51.0), (1000.0, 60.0), (5890.0, 80.0), (5950.0, 79.0),
                          (6400.0, 75.0), (10630.0, 69.0), (10700.0, 67.0), (59600.0, 60.0)])
        self.assertEqual([p.state for p in kept], [2, 1, 1, 4, 2, 2, 2, 2, 2])

    def test_no_ledger(self):
        pts = [UpPoint(1.75e9, 50, 2), UpPoint(1.749e9, 49, 2), UpPoint(1.751e9, 48, 2), UpPoint(5.0, 1, 2)]
        kept, dropped = upower.clean(pts, Ledger(dir=""))
        self.assertEqual(([p.t for p in kept], dropped), ([1.75e9, 1.751e9], 2))

    def test_load_merges_dbus_and_dat(self):
        # D-Bus only has what upowerd saw since its start; the .dat files go further back. Same point in both: once.
        dbus_pts = [(T0 + 1000, 60.0, 2), (T0 + 1600, 59.0, 2)]
        dat_old = [(T0 - 50, 62.0, 2), (T0 + 400, 61.0, 2), (T0 + 1000, 60.0, 2)]
        dat_old2 = [(T0 + 300, 61.5, 2), (T0 + 200, 61.6, 2)]       # second file, its last point goes back: dropped
        h = upower.load(src(charge=busctl(dbus_pts), rate=busctl([(T0 + 1000, 1.5, 2)]),
                            dats={"history-charge-BAT-33.dat": dat(dat_old), "history-charge-BAT-40.dat": dat(dat_old2),
                                  "history-rate-BAT-33.dat": dat([(T0 + 1000, 1.5, 2), (T0 + 1200, 1.4, 2)]),
                                  "history-time-full-BAT-33.dat": "1793000000\t1\tcharging\n"}), self.led)
        self.assertEqual(h.source, "dbus+dat")
        self.assertEqual([(p.t - T0, p.value) for p in h.charge],
                         [(-50.0, 62.0), (300.0, 61.5), (400.0, 61.0), (1000.0, 60.0), (1600.0, 59.0)])
        self.assertEqual([(p.t - T0, p.value) for p in h.rate], [(1000.0, 1.5), (1200.0, 1.4)])
        self.assertEqual(h.dropped, 1)

    def test_load_sources(self):
        one = [(T0 + 1000, 60.0, 2)]
        self.assertEqual(upower.load(src(charge=busctl(one)), self.led).source, "dbus")
        self.assertEqual(upower.load(src(dats={"history-charge-BAT-33.dat": dat(one)}), self.led).source, "dat")
        h = upower.load(src(charge="Failed to connect to bus", dats={}), self.led)
        self.assertEqual((h.source, h.charge, h.rate, h.dropped), ("none", [], [], 0))

    @unittest.skipUnless(HAVE_REAL, "tests/fixtures/real-1030 capture not present (not published)")
    def test_real_capture(self):
        led = ledger.read_dir(str(REAL / "state"))
        ledger.assign_clocks(led, "f8a52698", 1793315500.0, None)
        h = upower.load(src(charge=(REAL / "upower-charge.json").read_text(encoding="utf-8"),
                            rate=(REAL / "upower-rate.json").read_text(encoding="utf-8")), led)
        self.assertEqual(h.source, "dbus")
        # The recorder started 31 h after the boot (m 113185): every point since upowerd's start belongs to this boot,
        # back to its mono 0 (t0 = 1793202220.90) and the 1.9 s before it. Only the two start markers go.
        self.assertEqual((len(h.charge), len(h.rate), h.dropped), (139, 3747, 2))
        self.assertEqual((h.charge[0].t, h.charge[0].value), (1793202219.0, 68.0))
        self.assertEqual((h.charge[-1].t, h.charge[-1].value), (1793313408.0, 76.0))
        self.assertEqual(h.rate[-1].t, 1793315479.0)        # after the ledger's newest line: the boot is still on
        self.assertTrue(all(a.t <= b.t for a, b in zip(h.rate, h.rate[1:])))


if __name__ == "__main__":
    unittest.main()
