"""ledger.py against synthetic ledgers written the way y700-batteryd and refresh-auto write them (tests/fixtures/synth.py)
and against the real 10-30 capture (tests/fixtures/real-1030; not in the public tree, that test skips).

Run: tools/venv/Scripts/python -X utf8 -I -B -m unittest discover -s linux/power/battery/report/tests -t linux/power/battery/report
"""

import dataclasses
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPORT = Path(__file__).resolve().parents[1]
if str(REPORT) not in sys.path:
    sys.path.insert(0, str(REPORT))

from tests.fixtures import synth  # noqa: E402
from tests.fixtures.synth import (A, APPS, B, C, CLAUDE, D, FGD, INIT, KWIN, NM, ROOT, SESS, SHELL, STEAM,  # noqa: E402
                                  SYS, T0, TG_DOCK, TG_FLAT, USR, Flight, Rec)
from y700_battery import ledger  # noqa: E402
from y700_battery.types import KERNEL, Fr  # noqa: E402

REAL = REPORT / "tests" / "fixtures" / "real-1030"
UU = "/user.slice/user-1000.slice/user@1000.service"
NOW = T0 + 60000.0
MONO_NOW = 500.0


def expected_cpu(log: list[dict]) -> list[dict]:
    """Per step of one boot: what the cg deltas must be, straight from the usages synth wrote. A unit's counter carries
    over every snapshot of the boot (so across H lines and recorder restarts); a unit seen for the first time after the
    boot's first snapshot counts its whole usage."""
    last: dict = {}
    out = []
    for i, s in enumerate(log):
        d = {}
        for u, v in s["units"].items():
            if v is None:
                continue
            base = last.get(u)
            dv = v - base if base is not None and v >= base else v
            if dv > 0:
                d[u] = dv
            last[u] = v
        if i:
            out.append(d)
    return out


class StandardCase(unittest.TestCase):
    """The four-boot scenario of synth.standard(), parsed once"""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.f = synth.standard(cls.tmp.name)
        cls.led = ledger.read_dir(cls.tmp.name)
        ledger.assign_clocks(cls.led, D, NOW, MONO_NOW)
        cls.boot = {b.boot8: b for b in cls.led.boots}
        cls.steps = {b8: ledger.steps(b) for b8, b in cls.boot.items()}
        cls.lives = {b8: ledger.lives(b) for b8, b in cls.boot.items()}

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def step(self, b8, ma):
        for s in self.steps[b8]:
            if s.ma == ma:
                return s
        self.fail("no step from %s in %s" % (ma, b8))


class TestReadDir(StandardCase):
    def test_boots_in_boots_txt_order(self):
        self.assertEqual([b.boot8 for b in self.led.boots], [A, B, C, D])

    def test_heads_across_parts(self):
        a = self.boot[A]
        self.assertEqual([(h.why, h.part) for h in a.heads], [("start", 0), ("part", 1), ("start", 1)])
        self.assertEqual(a.boot, self.f["recs"][A].boot)
        self.assertEqual([s.m for s in a.snaps], [100.0, 400.0, 700.0, 2500.0, 2600.0, 3000.0, 4000.0, 4300.0,
                                                  4600.0, 4900.0, 5200.0, 5300.0, 5600.0, 5900.0])
        self.assertEqual([s.head for s in a.snaps], [0] * 5 + [1] * 6 + [2] * 3)

    def test_head_line(self):
        h = self.boot[A].heads[0]
        self.assertEqual((h.part, h.m, h.w, h.sync, h.why), (0, 100.0, T0 + 100.0, True, "start"))
        self.assertEqual(h.units[1], ROOT)
        self.assertEqual(h.units[2], KWIN)
        self.assertEqual(h.units[3], SYS)
        # U lines after the first S of the head still belong to it (later groups announce new units)
        self.assertEqual(h.units[12], CLAUDE)

    def test_units_renumbered_after_restart(self):
        ids1, ids2 = self.f["ids"][A]
        self.assertNotEqual(ids1[CLAUDE], ids2[CLAUDE])
        self.assertEqual(self.boot[A].heads[2].units[ids2[CLAUDE]], CLAUDE)
        self.assertEqual(self.boot[A].heads[2].units[3], CLAUDE)    # 3 was /system.slice in the first process
        self.assertEqual(self.boot[A].heads[0].units[3], SYS)

    def test_snap_line(self):
        s = self.boot[A].snaps[0]
        self.assertEqual((s.why, s.m, s.w, s.sync, s.cov, s.dpms, s.pw), ("start", 100.0, T0 + 100.0, True, True, 1, "dis"))
        self.assertIsInstance(s.fr, Fr)
        self.assertEqual((s.fr.t, s.fr.ton, s.fr.don, s.fr.lb), (100000, 1000, 1500, 1500))
        self.assertEqual(s.cg[ROOT], 1_000_000)
        self.assertEqual(s.cg[TG_DOCK], 1000)
        self.assertEqual(len(s.cg), 11)                 # after an H: every unit
        self.assertEqual(s.gpu, {KWIN: (1_000_000_000, 300_000_000)})
        self.assertEqual(s.cl, [(1000, 1_000_000, 5000), (100, 200_000, 5000)])
        self.assertEqual((s.ctx, s.pkt, s.x), (1_000_000, (100, 50), (2941, 1000)))
        self.assertEqual((s.st, s.cap), ("Discharging", 90))
        self.assertIsNone(s.wk)
        self.assertEqual((s.new, s.gone), ([], []))

    def test_changed_only_and_new_gone(self):
        a = self.boot[A]
        s400, s700 = a.snaps[1], a.snaps[2]
        self.assertNotIn(TG_DOCK, s400.cg)              # unchanged since the previous S
        self.assertEqual(s400.new, [CLAUDE])
        self.assertEqual(s700.gone, [TG_DOCK])
        self.assertEqual(s700.edge, 699.5)
        self.assertEqual(s700.wk, {KWIN: 500, CLAUDE: 300, KERNEL: 1000})

    def test_plug_edges(self):
        a = self.boot[A]
        chg = next(s for s in a.snaps if s.m == 2600.0)
        dis = next(s for s in a.snaps if s.m == 4000.0)
        self.assertEqual((chg.why, chg.pw, chg.edge, chg.st, chg.cap), ("pw", "chg", 2598.0, "Charging", 85))
        self.assertEqual((dis.why, dis.pw, dis.edge, dis.st, dis.cap), ("pw", "dis", 3999.0, "Discharging", 95))

    def test_k_line(self):
        c = self.boot[C]
        self.assertEqual(len(c.ksteps), 1)
        k = c.ksteps[0]
        self.assertEqual((k.m, k.sync, k.src, k.step), (45.0, True, "chrony", 3600.0))
        self.assertAlmostEqual(k.w, 45.0 + self.f["C_REAL"], places=2)

    def test_half_lines(self):
        b = self.boot[B]
        # the cut group in the middle is one bad line; the H after it (written with a leading "\n") parses
        self.assertEqual(b.bad_lines, 1)
        self.assertEqual([h.why for h in b.heads], ["start", "start"])
        self.assertEqual([s.m for s in b.snaps], [30.0, 330.0, 700.0, 1000.0])
        c = self.boot[C]
        # a cut last line without its "\n"
        self.assertEqual(c.bad_lines, 1)
        self.assertEqual([s.m for s in c.snaps], [20.0, 320.0, 620.0, 2420.0])

    def test_bytes(self):
        total = 0
        for b in self.led.boots:
            size = sum(os.path.getsize(os.path.join(self.tmp.name, n)) for n in os.listdir(self.tmp.name)
                       if n.startswith(("b-%s" % b.boot8, "fg-%s" % b.boot8)))
            self.assertEqual(b.bytes, size, b.boot8)
            total += size
        self.assertEqual(self.led.bytes, total)


class TestFgLog(StandardCase):
    def test_events_across_parts(self):
        ev = self.boot[A].fg
        self.assertEqual([(e.m, e.kind) for e in ev], [(99.0, "start"), (101.0, "fg"), (450.0, "fg"), (600.0, "fg"),
                                                     (2650.0, "fg"), (4400.0, "fg"), (5900.0, "stop")])
        # the garbage line and the unterminated last line
        self.assertEqual(self.boot[A].bad_lines, 2)

    def test_fields(self):
        ev = {e.m: e for e in self.boot[A].fg}
        e = ev[101.0]
        self.assertEqual((e.pid, e.covers, e.new_usage, e.prev_usage), (3315, 1, 300000, None))
        self.assertEqual(e.cgroup, UU + "/session.slice/plasma-plasmashell.service")
        self.assertEqual((e.key, e.cls), (SHELL[0], "plasmashell"))
        self.assertEqual((ev[450.0].prev_usage, ev[450.0].key), (330000, CLAUDE[0]))

    def test_desktop_line(self):
        e = {e.m: e for e in self.boot[A].fg}[600.0]
        self.assertEqual((e.pid, e.covers, e.new_usage, e.prev_usage, e.cgroup, e.key, e.cls),
                         (0, 0, None, None, None, None, ""))

    def test_nested_cgroup_and_class_with_spaces(self):
        e = {e.m: e for e in self.boot[A].fg}[2650.0]
        self.assertEqual(e.cgroup, UU + "/app.slice/app-flatpak-org.telegram.desktop-4120.scope/tray x.scope")
        self.assertEqual(e.key, TG_FLAT[0])             # the outermost unit, as the ledger counts it
        self.assertEqual(e.cls, "Telegram Desktop")

    def test_systemd_escape_stays_in_key(self):
        path = UU + "/app.slice/app-geoclue\\x2ddemo\\x2dagent@autostart.service"
        ev = ledger.read_fg("10.00 77 1 5 6 %s geoclue\n" % path)
        self.assertEqual(ev[0].key, "u/app.slice/app-geoclue\\x2ddemo\\x2dagent@autostart.service")
        self.assertEqual(ev[0].cgroup, UU + "/app.slice/app-geoclue-demo-agent@autostart.service")

    def test_bad_lines(self):
        text = ("1.00 START\n"
                "2.00 -5 1 1 1 - x\n"         # negative pid
                "3.00 5 2 1 1 - x\n"          # covers not 0/1
                "4.00 5 1 -1 1 - x\n"         # negative usage
                "5.00 5 1 1 1 -\n"            # 6 fields
                "abc 5 1 1 1 - x\n"           # m not a number
                "nan 5 1 1 1 - x\n"
                "6.00 5 1 1 1 - a  b\n"       # good: class "a  b"
                "7.00 STOP\n"
                "8.00 5 1")                   # unterminated
        ev, bad = ledger._parse_fg(text)
        self.assertEqual([(e.m, e.kind) for e in ev], [(1.0, "start"), (6.0, "fg"), (7.0, "stop")])
        self.assertEqual(ev[1].cls, "a  b")
        self.assertEqual(bad, 7)


class TestCgroupKey(unittest.TestCase):
    def test_units_rs_cases(self):
        k = lambda p: ledger.cgroup_key(p, 1000)  # noqa: E731
        self.assertEqual(k("/"), "/")
        self.assertEqual(k(""), "/")
        self.assertEqual(k("/init.scope"), "/init.scope")
        self.assertEqual(k("/system.slice"), "/system.slice")
        self.assertEqual(k("/system.slice/y700-flightrec.service"), "s/y700-flightrec.service")
        self.assertEqual(k("/system.slice/system-getty.slice/getty@tty1.service"),
                         "s/system-getty.slice/getty@tty1.service")
        self.assertEqual(k("/system.slice/system-getty.slice"), "/system.slice")
        self.assertEqual(k("/user.slice/user-1000.slice/session-3.scope"), "l/session-3.scope")
        self.assertEqual(k("/user.slice/user-0.slice/session-9.scope"), "/user.slice")
        self.assertEqual(k("/user.slice/user-1000.slice"), "/user.slice")
        self.assertEqual(k(UU + "/session.slice/plasma-kwin_wayland.service"), KWIN[0])
        self.assertEqual(k(UU + "/init.scope"), "u/init.scope")
        self.assertEqual(k(UU + "/app.slice"), "u/app.slice")
        self.assertEqual(k(UU + "/app.slice/app-com.anthropic.Claude-16803.scope"),
                         "u/app.slice/app-com.anthropic.Claude-16803.scope")
        self.assertEqual(k(UU + "/app.slice/app-steam-arm64.service/sub/deeper"), "u/app.slice/app-steam-arm64.service")
        self.assertEqual(k(UU + "/app.slice/app-flatpak-org.telegram.desktop-4120.scope/tray.scope"),
                         "u/app.slice/app-flatpak-org.telegram.desktop-4120.scope")
        self.assertEqual(k(UU + "/app.slice/app-geoclue\\x2ddemo\\x2dagent@autostart.service"),
                         "u/app.slice/app-geoclue\\x2ddemo\\x2dagent@autostart.service")
        self.assertEqual(k("/machine.slice/x.scope"), "/")

    def test_outermost_unit_wins(self):
        # refresh-auto names the innermost unit; the ledger counts the whole subtree for the outer one
        self.assertEqual(ledger.cgroup_key(UU + "/app.slice/app-a.service/app-b.scope/x"), "u/app.slice/app-a.service")

    def test_uid(self):
        # uid None: whatever user the path names, as long as its manager matches
        self.assertEqual(ledger.cgroup_key("/user.slice/user-1001.slice/user@1001.service/app.slice/x.scope"),
                         "u/app.slice/x.scope")
        self.assertEqual(ledger.cgroup_key("/user.slice/user-1001.slice/user@1001.service/app.slice/x.scope", 1000),
                         "/user.slice")
        self.assertEqual(ledger.cgroup_key("/user.slice/user-1001.slice/user@1000.service/app.slice/x.scope"),
                         "/user.slice")
        self.assertEqual(ledger.cgroup_key(UU + "/background.slice"), "u/background.slice")
        self.assertEqual(ledger.cgroup_key(UU + "/other.slice"), "/user.slice")


class TestFileOrder(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def _boot(self, b8, m0=10.0):
        r = Rec(b8, T0, sync=True)
        r.snap(m0, "start", {ROOT: 1, KWIN: 1}, cov=False)
        return r

    def _touch(self, b8, t):
        for n in os.listdir(self.d):
            if n.startswith(("b-%s" % b8, "fg-%s" % b8)):
                os.utime(os.path.join(self.d, n), (t, t))

    def test_boots_txt_beats_mtime_and_unlisted_go_first(self):
        recs = [self._boot(b) for b in ("x1", "y2", "z3", "w4")]
        synth.write(self.d, recs, order=["y2", "x1", "../evil", "y2", ""])
        self._touch("y2", 1_000)        # listed boots: file times do not matter (the RTC starts at 1970)
        self._touch("x1", 2_000)
        self._touch("w4", 3_000)        # unlisted: oldest file first, before every listed boot
        self._touch("z3", 4_000)
        led = ledger.read_dir(self.d)
        self.assertEqual([b.boot8 for b in led.boots], ["w4", "z3", "y2", "x1"])

    def test_numbered_parts_sort_as_numbers(self):
        r = Rec("p1", T0, sync=True)
        for i in range(12):
            if i:
                r.rotate()
                r.fg_rotate()
            r.snap(100.0 + i, "ck" if i else "start", {ROOT: 10 + i})
            r.fg(100.0 + i, 1, 1, i, None, "/", "c%d" % i)
        synth.write(self.d, [r])
        self.assertTrue(os.path.exists(os.path.join(self.d, "b-p1.11.jsonl")))
        self.assertTrue(os.path.exists(os.path.join(self.d, "fg-p1.11.log")))
        b = ledger.read_dir(self.d).boots[0]
        self.assertEqual([s.m for s in b.snaps], [100.0 + i for i in range(12)])
        self.assertEqual([h.part for h in b.heads], list(range(12)))
        # fg: .1 ... .11 oldest first, then the unnumbered live log
        self.assertEqual([e.cls for e in b.fg], ["c%d" % i for i in range(12)])

    def test_other_files_ignored(self):
        synth.write(self.d, [self._boot("q1")])
        for n in ("b-q1.jsonl.tmp", "b-q1.x.jsonl", "b-.jsonl", "notes.txt", "fg-q1.2.log.old", "b-q-1.jsonl"):
            with open(os.path.join(self.d, n), "w", encoding="utf-8", newline="\n") as f:
                f.write("junk\n")
        os.mkdir(os.path.join(self.d, "b-q2.jsonl"))
        led = ledger.read_dir(self.d)
        self.assertEqual([b.boot8 for b in led.boots], ["q1"])
        self.assertEqual(led.boots[0].bad_lines, 0)

    def test_missing_dir(self):
        led = ledger.read_dir(os.path.join(self.d, "nope"))
        self.assertEqual((led.boots, led.bytes), ([], 0))

    def test_line_rules(self):
        r = self._boot("k1")
        good = r.parts[0]
        text = ('{"k":"U","id":1,"p":"/","ino":1}\n'            # before the file's first H: undecodable
                + good
                + '{"k":"Z","x":1}\n'                            # a newer recorder's line kind: skipped quietly
                + '[1,2]\n'
                + '{"k":"S","why":"ck","m":15.0,"w":1.0,"sync":1,"cov":1,"cg":{"1":true},"cl":[]}\n'  # not a number
                + '{"k":"S","why":"ck","m":16.0,"w":1.0,"sync":1,"cov":1,"cg":{},"cl":[[1,2]]}\n'    # short cl
                + r.snap(20.0, "ck", {ROOT: 5, KWIN: 1}, write=False).rstrip("\n"))   # complete, just no "\n" yet
        with open(os.path.join(self.d, "b-k1.jsonl"), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        b = ledger.read_dir(self.d).boots[0]
        self.assertEqual(b.bad_lines, 4)
        self.assertEqual([s.m for s in b.snaps], [10.0, 20.0])


class TestClocks(StandardCase):
    def test_standard(self):
        f = self.f
        a, b, c, d = (self.boot[x] for x in (A, B, C, D))
        self.assertEqual(a.clock, "sync")
        self.assertAlmostEqual(a.offset, T0, places=6)
        # B never synced: mono 0 where A's newest line is (not at its own fake clock B_FAKE)
        self.assertEqual(b.clock, "chained")
        self.assertAlmostEqual(b.offset, T0 + 5900.0, places=6)
        # C stepped by K and synced after: the synced lines decide
        self.assertEqual(c.clock, "sync")
        self.assertAlmostEqual(c.offset, f["C_REAL"], places=6)
        # D, the current boot, never synced: mono_now maps to now
        self.assertEqual(d.clock, "now")
        self.assertAlmostEqual(d.offset, NOW - MONO_NOW, places=6)
        self.assertAlmostEqual(d.t(315.0), NOW - MONO_NOW + 315.0, places=6)

    def test_newest_wall(self):
        self.assertAlmostEqual(ledger.newest_wall(self.led), NOW - MONO_NOW + 315.0, places=6)

    def _led(self, recs, cur=None, now=NOW, mono_now=None):
        with tempfile.TemporaryDirectory() as d:
            synth.write(d, recs)
            led = ledger.read_dir(d)
        ledger.assign_clocks(led, cur, now, mono_now)
        return {b.boot8: b for b in led.boots}

    def test_median_over_synced_lines_only(self):
        r = Rec("s1", 1_700_000_000.0, sync=False)
        for m in (10.0, 20.0, 30.0):
            r.snap(m, "start" if m == 10.0 else "ck", {ROOT: int(m)})
        r.step_clock(35.0, 1000.0, sync=True)
        r.snap(40.0, "ck", {ROOT: 40})
        b = self._led([r])["s1"]
        self.assertEqual(b.clock, "sync")
        self.assertAlmostEqual(b.offset, 1_700_001_000.0, places=6)

    def test_current_boot_without_mono_now(self):
        r = Rec("n1", 1_700_000_000.0, sync=False)
        r.snap(10.0, "start", {ROOT: 1})
        r.snap(70.0, "ck", {ROOT: 2})
        b = self._led([r], cur="n1", now=1_800_000_000.0)["n1"]
        self.assertEqual(b.clock, "now")
        self.assertAlmostEqual(b.t(70.0), 1_800_000_000.0, places=6)

    def test_current_boot_behind_starts_after_placed_boots(self):
        s1 = Rec("s1", 1_750_000_000.0, sync=True)
        s1.snap(10.0, "start", {ROOT: 1})
        s1.snap(500.0, "term", {ROOT: 2})
        for mono_now, now in ((99.0, 1_700_000_099.0), (None, 1_700_000_060.0)):
            n2 = Rec("n2", 1_700_000_000.0, sync=False)     # its clock is behind s1's
            n2.snap(20.0, "start", {ROOT: 1})
            n2.snap(60.0, "ck", {ROOT: 2})
            with tempfile.TemporaryDirectory() as d:
                synth.write(d, [s1, n2])
                led = ledger.read_dir(d)
            got = ledger.assign_clocks(led, "n2", now, mono_now)
            b = led.boots[1]
            self.assertEqual(b.clock, "now")            # still 时间未校准
            self.assertAlmostEqual(b.offset, 1_750_000_500.0, places=6)
            self.assertAlmostEqual(got, 1_750_000_500.0 + (99.0 if mono_now else 60.0), places=6)
        # a clock that is not behind keeps now exactly
        self.assertEqual(ledger.assign_clocks(self.led, D, NOW, MONO_NOW), NOW)

    def test_synced_current_boot_keeps_sync(self):
        r = Rec("c1", 1_750_000_000.0, sync=True)
        r.snap(10.0, "start", {ROOT: 1})
        b = self._led([r], cur="c1", now=1_800_000_000.0, mono_now=99.0)["c1"]
        self.assertEqual((b.clock, b.offset), ("sync", 1_750_000_000.0))

    def test_chains(self):
        lead = Rec("l1", 1_600_000_000.0, sync=False)      # nothing placed before it: ends where s2 starts
        lead.snap(5.0, "start", {ROOT: 1})
        lead.snap(800.0, "term", {ROOT: 2})
        s2 = Rec("s2", 1_750_000_000.0, sync=True)
        s2.snap(10.0, "start", {ROOT: 1})
        s2.snap(500.0, "term", {ROOT: 2})
        u3 = Rec("u3", 1_600_000_000.0, sync=False)
        u3.snap(20.0, "start", {ROOT: 1})
        u3.snap(300.0, "term", {ROOT: 2})
        u4 = Rec("u4", 1_600_000_000.0, sync=False)
        u4.snap(30.0, "start", {ROOT: 1})
        u4.snap(90.0, "term", {ROOT: 2})
        fgonly = Rec("f5", 0.0)
        fgonly.fg_mark(3.0, "START")
        bt = self._led([lead, s2, u3, u4, fgonly])
        self.assertEqual(bt["l1"].clock, "chained")
        self.assertAlmostEqual(bt["l1"].offset, 1_750_000_000.0 - 800.0, places=6)
        self.assertAlmostEqual(bt["u3"].offset, 1_750_000_500.0, places=6)
        self.assertAlmostEqual(bt["u4"].offset, 1_750_000_500.0 + 300.0, places=6)
        self.assertEqual((bt["u4"].clock, bt["f5"].clock, bt["f5"].offset), ("chained", "none", None))
        self.assertEqual(len(bt["f5"].fg), 1)

    def test_nothing_placed(self):
        r = Rec("r1", 1_650_000_000.0, sync=False)
        r.snap(10.0, "start", {ROOT: 1})
        b = self._led([r])["r1"]
        self.assertEqual(b.clock, "chained")
        self.assertAlmostEqual(b.offset, 1_650_000_000.0, places=6)


class TestSteps(StandardCase):
    def test_counts_and_times(self):
        self.assertEqual({b8: len(s) for b8, s in self.steps.items()}, {A: 13, B: 3, C: 3, D: 1})
        s = self.steps[A][0]
        self.assertEqual((s.boot8, s.ma, s.mb), (A, 100.0, 400.0))
        self.assertAlmostEqual(s.ta, T0 + 100.0, places=6)
        self.assertAlmostEqual(s.tb, T0 + 400.0, places=6)
        self.assertAlmostEqual(self.steps[D][0].ta, NOW - MONO_NOW + 15.0, places=6)

    def test_cpu_deltas_paired_by_path_and_inode(self):
        for b8 in (A, B, C, D):
            exp = expected_cpu(self.f["recs"][b8].log)
            self.assertEqual([s.cpu for s in self.steps[b8]], exp, b8)

    def test_restart_pairs_units_across_heads(self):
        s = self.step(A, 5200.0)
        self.assertTrue(s.restart)
        self.assertEqual(s.cpu[CLAUDE], 1_100_000)      # a delta, though Claude's id changed with the restart
        self.assertEqual((s.new, s.gone), ([], []))
        s2 = self.step(A, 5300.0)
        self.assertFalse(s2.restart)
        self.assertEqual(s2.cpu[CLAUDE], 300_000)
        self.assertEqual(s2.cpu[SYS], 1_200_000)

    def test_gpu(self):
        self.assertEqual(self.step(A, 100.0).gpu, {KWIN: (300_000_000, 90_000_000), CLAUDE: (200_000_000, 60_000_000)})
        self.assertEqual(self.step(A, 2500.0).gpu, {})                  # nothing changed
        p = self.step(A, 2600.0)                                        # across the H why=part
        self.assertFalse(p.restart)
        self.assertEqual(p.gpu, {})
        # H why=start: the new process counts from zero, the step across it is unknown, the next one is a delta
        self.assertIsNone(self.step(A, 5200.0).gpu)
        self.assertEqual(self.step(A, 5300.0).gpu, {KWIN: (1_000_000, 200_000), CLAUDE: (2_000_000, 500_000)})
        self.assertIsNone(self.step(B, 330.0).gpu)
        self.assertTrue(self.step(B, 330.0).restart)

    def test_new_gone(self):
        self.assertEqual((self.step(A, 100.0).new, self.step(A, 100.0).gone), ([CLAUDE], []))
        self.assertEqual(self.step(A, 400.0).gone, [TG_DOCK])
        self.assertEqual(self.step(A, 700.0).new, [TG_FLAT])
        # the part head's U table no longer has the flatpak Telegram and has the Steam helper: implicit gone / new
        p = self.step(A, 2600.0)
        self.assertEqual((p.new, p.gone), ([STEAM], [TG_FLAT]))

    def test_state_from_start_snapshot(self):
        self.assertEqual((self.step(A, 400.0).dpms, self.step(A, 700.0).dpms), (1, 0))
        self.assertEqual([self.step(A, m).pw for m in (2500.0, 2600.0, 3000.0, 4000.0)], ["dis", "chg", "chg", "dis"])

    def test_wake(self):
        s = self.step(A, 400.0)
        self.assertEqual(s.wk, {KWIN: 500, CLAUDE: 300, KERNEL: 1000})
        self.assertEqual(s.wk_since_m, 100.0)           # the start baseline was the previous thread scan
        self.assertEqual((self.step(A, 700.0).wk_since_m, self.step(A, 2600.0).wk_since_m), (700.0, 2500.0))
        self.assertEqual(self.step(A, 4000.0).wk, {KWIN: 40, KERNEL: 600})
        self.assertEqual(self.step(A, 4000.0).wk_since_m, 3000.0)
        self.assertIsNone(self.step(A, 100.0).wk)
        self.assertIsNone(self.step(A, 5200.0).wk)
        self.assertEqual(self.step(C, 320.0).wk, {KERNEL: 900})
        self.assertEqual(self.step(C, 320.0).wk_since_m, 20.0)

    def test_counters(self):
        s = self.step(A, 100.0)
        self.assertEqual(s.cl, [(600, 900_000, 3000), (50, 100_000, 3000)])
        self.assertEqual((s.ctx, s.pkt, s.x_ticks), (100_000, 270, 50))
        self.assertIsNone(self.step(A, 5300.0).x_ticks)    # Xwayland's pid changed
        last = self.step(A, 5600.0)
        self.assertIsNone(last.pkt)                         # the interface counters went back
        self.assertEqual(last.x_ticks, 30)

    def test_flightrec_coverage(self):
        self.assertTrue(self.step(A, 4300.0 - 300.0).cov)
        self.assertFalse(self.step(A, 4300.0).cov)          # ends degraded
        mid = self.step(A, 4600.0)
        self.assertFalse(mid.cov)
        self.assertEqual(mid.fr.ton + mid.fr.toff + mid.fr.don, 0)    # stale accumulator: nothing moved
        back = self.step(A, 4900.0)
        self.assertFalse(back.cov)                          # starts degraded
        self.assertEqual(back.fr.gap, 650_000)              # what flightrec missed shows up as gap
        self.assertTrue(self.step(A, 5200.0).cov)
        on = self.step(A, 100.0).fr
        self.assertEqual((on.ton, on.don, on.dton, on.toff), (300_000, 450_000, 300_000, 0))
        chg = self.step(A, 2600.0).fr
        self.assertEqual((chg.chg, chg.tchg, chg.don + chg.doff), (2_000_000, 400_000, 0))

    def test_fr_missing_or_reset(self):
        r = Rec("r9", T0, sync=True)
        f1 = Flight(0.0)
        r.snap(10.0, "start", {ROOT: 1}, fr=f1.run(10.0, False, 300).fr())
        r.snap(20.0, "ck", {ROOT: 2}, fr=f1.run(20.0, False, 300).fr())
        r.snap(30.0, "ck", {ROOT: 3}, cov=False)                       # no fr at all
        r.snap(40.0, "ck", {ROOT: 4}, fr=f1.run(40.0, False, 300).fr())
        r.snap(50.0, "ck", {ROOT: 5}, fr=Flight(45.0).run(50.0, False, 300).fr())   # file reset: counters back
        with tempfile.TemporaryDirectory() as d:
            synth.write(d, [r])
            b = ledger.read_dir(d).boots[0]
        st = ledger.steps(b)
        self.assertIsNotNone(st[0].fr)
        self.assertEqual([s.fr for s in st[1:]], [None, None, None])
        self.assertEqual([s.cov for s in st], [True, False, False, True])

    def test_fr_open_missing_run(self):
        """tz is the open missing run (acc.rs pend), a level: an S that caught one open and the next S after it closed
        (tz back to 0, the time folded into dtoff / tzero / gap) is still a covered step with its fr - ranges counts a
        step as measured only when cov and fr are both set"""
        r = Rec("z1", T0, sync=True)
        f = Flight(0.0)
        r.snap(10.0, "start", {ROOT: 1}, dpms=0, fr=f.run(10.0, False, 300).fr())
        r.snap(14.0, "ck", {ROOT: 2}, dpms=0, fr=f.missing(14.0, False).fr())          # caught open: tz 4000
        r.snap(314.0, "ck", {ROOT: 3}, dpms=0, fr=f.run(314.0, False, 300).fr())       # closed: backfilled
        f.missing(320.0, False)
        r.snap(330.0, "ck", {ROOT: 4}, dpms=1, fr=f.missing(330.0, True, 1000).fr())  # open across dpms
        r.snap(400.0, "ck", {ROOT: 5}, dpms=1, fr=f.run(400.0, True, -2000).fr())     # closed by charging: tzero
        f.missing(410.0, True)
        r.snap(2300.0, "ck", {ROOT: 6}, dpms=1, fr=f.missing(2300.0, True).fr())      # > 30 min with no reading
        r.snap(2310.0, "ck", {ROOT: 7}, dpms=1, fr=f.run(2310.0, True, 1500).fr())    # closed as gap
        with tempfile.TemporaryDirectory() as d:
            synth.write(d, [r])
            b = ledger.read_dir(d).boots[0]
        self.assertEqual([s.fr.tz for s in b.snaps], [0, 4000, 0, 16000, 0, 1_900_000, 0])
        st = ledger.steps(b)
        self.assertTrue(all(s.cov and s.fr is not None for s in st))
        self.assertEqual([s.fr.tz for s in st], [4000, -4000, 16000, -16000, 1_900_000, -1_900_000])
        for s in st:            # every ms of the step is in exactly one bucket, tz included (acc.rs time partition)
            fr = s.fr
            self.assertEqual(fr.dton + fr.dtoff + fr.tchg + fr.tzero + fr.tz + fr.gap, round((s.mb - s.ma) * 1000))
        self.assertEqual((st[1].fr.dtoff, st[1].fr.doff), (304_000, 91_200))       # 300 mW over 300 + 4 s
        self.assertEqual((st[3].fr.tzero, st[3].fr.tchg, st[3].fr.don + st[3].fr.doff), (16_000, 70_000, 0))
        self.assertEqual((st[5].fr.gap, st[5].fr.dton), (1_900_000, 10_000))
        # every real counter going back still voids the step: only tz may fall
        a, z = b.snaps[1].fr, b.snaps[2].fr
        for f in ("ton", "toff", "don", "doff", "dton", "dtoff", "chg", "tchg", "tzero", "gap", "bl"):
            self.assertIsNone(ledger._fr_delta(a, dataclasses.replace(z, **{f: getattr(a, f) - 1})), f)

    def test_inode_change_is_a_new_unit(self):
        r = Rec("i1", T0, sync=True)
        x1, x2 = ("u/app.slice/app-x.scope", 10), ("u/app.slice/app-x.scope", 11)
        r.snap(10.0, "start", {ROOT: 100, x1: 5000})
        r.snap(20.0, "ck", {ROOT: 200, x2: 700})
        r.snap(30.0, "ck", {ROOT: 300, x2: 900})
        with tempfile.TemporaryDirectory() as d:
            synth.write(d, [r])
            b = ledger.read_dir(d).boots[0]
        self.assertEqual(b.snaps[1].new, [x2])
        self.assertEqual(b.snaps[1].gone, [x1])
        st = ledger.steps(b)
        self.assertEqual(st[0].cpu, {ROOT: 100, x2: 700})          # the new cgroup counts from zero
        self.assertEqual(st[1].cpu, {ROOT: 100, x2: 200})
        lv = ledger.lives(b)
        self.assertEqual((lv[x1].last_m, lv[x1].gone_m, lv[x2].first_m, lv[x2].last_m), (10.0, 20.0, 20.0, 30.0))


class TestLives(StandardCase):
    def test_lives(self):
        lv = self.lives[A]
        d = lv[TG_DOCK]
        self.assertEqual((d.first_m, d.last_m, d.gone_m, d.first_usage, d.last_usage), (100.0, 400.0, 700.0, 1000, 1000))
        c = lv[CLAUDE]
        self.assertEqual((c.first_m, c.last_m, c.gone_m, c.first_usage), (400.0, 5900.0, None, 900_000))
        self.assertEqual(c.last_usage, self.f["recs"][A].log[-1]["units"][CLAUDE])
        t = lv[TG_FLAT]
        self.assertEqual((t.first_m, t.last_m, t.gone_m, t.first_usage, t.last_usage), (2500.0, 2600.0, 3000.0, 5000,
                                                                                        1_205_000))
        s = lv[STEAM]
        self.assertEqual((s.first_m, s.last_m, s.gone_m, s.first_usage), (3000.0, 5900.0, None, 70_000))
        self.assertEqual(set(lv), {ROOT, KWIN, SYS, USR, INIT, NM, APPS, SESS, SHELL, FGD, TG_DOCK, CLAUDE, TG_FLAT,
                                   STEAM})
        self.assertEqual(lv[ROOT].boot8, A)


@unittest.skipUnless((REAL / "state").is_dir(), "tests/fixtures/real-1030 capture not present (not published)")
class TestRealCapture(unittest.TestCase):
    def test_real_1030(self):
        led = ledger.read_dir(str(REAL / "state"))
        self.assertEqual([b.boot8 for b in led.boots], ["f8a52698"])
        b = led.boots[0]
        self.assertEqual((len(b.heads), len(b.snaps), len(b.heads[0].units), b.bad_lines), (1, 1, 85, 0))
        self.assertEqual(b.boot, "f8a52698-ed09-4f88-ac85-05831ef0d880")
        s = b.snaps[0]
        self.assertEqual(s.cg[("u/app.slice/y700-refresh-auto.service", 6449)], 6473816)
        self.assertEqual(s.cg[("l/session-c1.scope", 4356)], 102042)
        self.assertIn(("u/app.slice/app-geoclue\\x2ddemo\\x2dagent@autostart.service", 6121), s.cg)
        self.assertEqual((s.fr.toff, s.fr.doff, s.fr.lb), (30000, 11074, 482))
        self.assertEqual([(e.kind, e.key) for e in b.fg],
                         [("start", None), ("fg", "u/session.slice/plasma-plasmashell.service")])
        ledger.assign_clocks(led, "f8a52698", 1793315500.0, None)
        self.assertEqual(b.clock, "sync")
        self.assertAlmostEqual(b.offset, 1793315406.42 - 113185.52, places=4)
        self.assertEqual(ledger.steps(b), [])
        self.assertEqual(len(ledger.lives(b)), 85)


if __name__ == "__main__":
    unittest.main()
