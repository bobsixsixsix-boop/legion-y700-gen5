"""journal.py: "Consumed" messages and their pairing with the ledger units they ended.

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
from tests.fixtures.synth import A, B, CLAUDE, D, FGD, T0, TG_DOCK, TG_FLAT  # noqa: E402
from y700_battery import journal, ledger  # noqa: E402
from y700_battery.types import Consumed  # noqa: E402

REAL = REPORT / "tests" / "fixtures" / "real-1030"
HAVE_REAL = (REAL / "state").is_dir() and (REAL / "journal-consumed.jsonl").is_file()


def jline(unit, nsec, boot, mono_us, real_us=1793000000000000, mid=journal.CONSUMED_ID, **extra):
    d = {"USER_UNIT": unit, "CPU_USAGE_NSEC": str(nsec), "_BOOT_ID": boot, "__MONOTONIC_TIMESTAMP": str(mono_us),
         "__REALTIME_TIMESTAMP": str(real_us), "MESSAGE_ID": mid}
    d.update(extra)
    return json.dumps(d)


class TestParse(unittest.TestCase):
    def test_fields(self):
        c = journal.parse([jline("y700-refresh-auto.service", 6591741000, "F8A52698ED094F88AC8505831EF0D880",
                                 113189787872, 1793315410690500)])
        self.assertEqual(c, [Consumed(unit="y700-refresh-auto.service", cpu_usec=6591741, boot8="f8a52698",
                                      m=113189.787872, w=1793315410.6905)])

    def test_boot_id_dashes(self):
        c = journal.parse([jline("x.service", 1000, "aaaa0001-0000-4000-8000-aaaa00010000", 1_000_000)])
        self.assertEqual((c[0].boot8, c[0].m, c[0].cpu_usec), ("aaaa0001", 1.0, 1))

    def test_skips(self):
        lines = [
            "-- No entries --",
            "",
            "{not json",
            "[1, 2]",
            jline("x.service", 1000, "aaaa0001", 5, mid="0123456789abcdef0123456789abcdef"),     # another message
            json.dumps({"USER_UNIT": "x.service", "_BOOT_ID": "aaaa0001", "__MONOTONIC_TIMESTAMP": "5"}),  # no CPU
            jline("x.service", "abc", "aaaa0001", 5),
            jline("x.service", 1000, "abc", 5),           # boot id too short
            jline("x.service", -5000, "aaaa0001", 5),
            # journalctl writes a non-UTF-8 field as a byte array
            json.dumps({"USER_UNIT": list(b"app-\xe5\x9c\x9f-1.scope"), "CPU_USAGE_NSEC": "2000",
                        "_BOOT_ID": "aaaa0001", "__MONOTONIC_TIMESTAMP": "7000000", "MESSAGE_ID": journal.CONSUMED_ID}),
        ]
        c = journal.parse(lines)
        self.assertEqual([(x.unit, x.cpu_usec, x.m, x.w) for x in c], [("app-土-1.scope", 2, 7.0, 0.0)])

    @unittest.skipUnless(HAVE_REAL, "tests/fixtures/real-1030 capture not present (not published)")
    def test_real(self):
        c = journal.parse((REAL / "journal-consumed.jsonl").read_text(encoding="utf-8").splitlines())
        self.assertEqual(len(c), 47)
        self.assertTrue(all(x.boot8 == "f8a52698" for x in c))
        self.assertEqual(c[0].unit, "plasma-ksplash.service")
        self.assertEqual(c[0].m, 30.19828)


class TestAttach(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            cls.f = synth.standard(d)
            cls.led = ledger.read_dir(d)
        ledger.assign_clocks(cls.led, D, T0 + 60000.0, 500.0)
        cls.lives = {b.boot8: ledger.lives(b) for b in cls.led.boots}

    def c(self, unit, usec, m, boot8=A):
        return Consumed(unit=unit, cpu_usec=usec, boot8=boot8, m=m, w=0.0)

    def name(self, u):
        return u[0].rsplit("/", 1)[-1]

    def test_unit_that_ended(self):
        # the dock Telegram was last seen at 400 with 1000 us, gone by 700, exited at 500 with 3000 us in total
        fx = journal.attach([self.c(self.name(TG_DOCK), 3000, 500.0)], self.led, self.lives)
        self.assertEqual(len(fx), 1)
        self.assertEqual((fx[0].ukey, fx[0].key, fx[0].boot8, fx[0].m_exit, fx[0].extra_usec),
                         (TG_DOCK, TG_DOCK[0], A, 500.0, 2000))

    def test_exit_found_by_head_table(self):
        # the flatpak Telegram vanished at the part head (no "gone"): last seen at 2600 with 1 205 000 us
        fx = journal.attach([self.c(self.name(TG_FLAT), 1_300_000, 2700.0)], self.led, self.lives)
        self.assertEqual((fx[0].ukey, fx[0].extra_usec), (TG_FLAT, 95_000))

    def test_negative_extra_dropped(self):
        self.assertEqual(journal.attach([self.c(self.name(TG_DOCK), 500, 500.0)], self.led, self.lives), [])

    def test_restarted_unit_dropped(self):
        # refresh-auto's unit is alive across this exit: an earlier instance of the same name, not told apart
        self.assertEqual(journal.attach([self.c(self.name(FGD), 9_999_999, 1000.0)], self.led, self.lives), [])

    def test_unit_between_snapshots(self):
        fx = journal.attach([self.c("app-y700-org.kde.dolphin-3315-40.scope", 70_000, 1000.0)], self.led, self.lives)
        self.assertEqual((fx[0].ukey, fx[0].key, fx[0].extra_usec), (None, "u/app.slice/app-y700-org.kde.dolphin-3315-40.scope",
                                                                     70_000))
        # a name the ledger knows from another boot keeps that key
        fx = journal.attach([self.c(self.name(CLAUDE), 5000, 500.0, boot8=B)], self.led, self.lives)
        self.assertEqual((fx[0].ukey, fx[0].key, fx[0].boot8), (None, CLAUDE[0], B))

    def test_no_step_to_go_to(self):
        cs = [self.c(self.name(TG_DOCK), 3000, 50.0),             # before A's first snapshot
              self.c(self.name(TG_DOCK), 3000, 500.0, boot8="eeee0005")]   # a boot the ledger does not have
        self.assertEqual(journal.attach(cs, self.led, self.lives), [])

    @unittest.skipUnless(HAVE_REAL, "tests/fixtures/real-1030 capture not present (not published)")
    def test_real_capture(self):
        led = ledger.read_dir(str(REAL / "state"))
        lives = {b.boot8: ledger.lives(b) for b in led.boots}
        cs = journal.parse((REAL / "journal-consumed.jsonl").read_text(encoding="utf-8").splitlines())
        fx = journal.attach(cs, led, lives)
        # 46 exits are older than the recorder's first snapshot; refresh-auto stopped 4.3 s after it
        self.assertEqual(len(fx), 1)
        self.assertEqual((fx[0].ukey, fx[0].extra_usec), (("u/app.slice/y700-refresh-auto.service", 6449), 117_925))
        self.assertAlmostEqual(fx[0].m_exit, 113189.787872, places=6)


if __name__ == "__main__":
    unittest.main()
