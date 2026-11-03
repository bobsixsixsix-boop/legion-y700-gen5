"""Tests for y700_battery.ranges: plug timeline, the three ranges, segments, bands and bucket grids.

Every scenario is built from types.py objects (no ledger.py / upower.py needed) around a fixed NOW,
local time 2026-10-30 08:31:00 at UTC+8; the expected numbers are worked out by hand next to each
assertion. World / fr / load_rules / load_coeffs are reused by test_model.py.
Run: tools/venv/Scripts/python -X utf8 -I -B -m unittest discover -s linux/power/battery/report/tests -t linux/power/battery/report
"""

import json
import sys
import time
import unittest
from pathlib import Path

REPORT = Path(__file__).resolve().parents[1]
if str(REPORT) not in sys.path:
    sys.path.insert(0, str(REPORT))

from y700_battery import cli, ranges  # noqa: E402
from y700_battery.types import (Boot, Coeffs, FrDelta, Head, History, Inputs, Ledger,  # noqa: E402
                                LiveBattery, Rules, Snap, Sources, Step, UpPoint)

BATTERY = REPORT.parent
TZ = 480                       # UTC+8, never the host's zone
NOW = 1793320260               # 2026-10-30 08:31:00 local
H = 3600
DAY = 86400
CUR8 = "aaaaaaaa"
OFF = NOW - 100000             # wall = mono + OFF for the current boot


def load_rules() -> Rules:
    d = json.loads((BATTERY / "rules.json").read_text(encoding="utf-8"))
    r = Rules()
    for k in ("full_pct", "loose_plug_merge_s", "just_full_s", "weak_charger_mw", "weak_charger_drop_pct",
              "d_min_pct", "apps_min_pct", "segment_max_s", "short_on_merge_s", "min_split_s", "aliases",
              "launcher_prefixes", "parents", "ui", "sys", "desktop_classes", "x11_classes", "hidden_ok"):
        setattr(r, k, d[k])
    r.labels = [(g, n) for g, n in d["labels"]]
    return r


def load_coeffs() -> Coeffs:
    d = json.loads((BATTERY / "coeffs-v1.json").read_text(encoding="utf-8"))
    vals = {k: float(v["value"]) for k, v in d["coeffs"].items() if k != "B"}
    return Coeffs(version=d["version"], calibrated=d["calibrated"], date=d["date"], source="dev",
                  path="coeffs-v1.json", values=vals,
                  b_points=[(float(x), float(y)) for x, y in d["coeffs"]["B"]["value"]])


def fr(on_s: float = 0.0, off_s: float = 0.0, p_mw: float = 0.0, level: float = 0.0,
       e_mj: float = None) -> FrDelta:
    """Accumulator deltas of a step that discharged the whole time at p_mw (or e_mj in total)."""
    ton, toff = int(on_s * 1000), int(off_s * 1000)
    e = p_mw * (on_s + off_s) if e_mj is None else e_mj
    share = on_s / (on_s + off_s) if on_s + off_s > 0 else 0.0
    return FrDelta(ton=ton, toff=toff, don=int(round(e * share)), doff=int(round(e * (1 - share))),
                   dton=ton, dtoff=toff, bl=int(level * ton))


class World:
    """A hand-made Inputs: UPower points, sysfs now, ledger boots with steps and snapshots."""

    def __init__(self, pct=None, status="discharging", plugged=None, now=NOW, charge_full=8394000):
        if plugged is None:
            plugged = status in ("charging", "full", "not_charging")
        bat = LiveBattery(pct=pct, status=status, plugged=plugged, charge_full_uah=charge_full)
        self.src = Sources(now=now, tz_offset_min=TZ, from_dir=None, state_dir="", boot_id=None,
                           mono_now=None, battery=bat)
        self.hist = History(source="dbus")
        self.led = Ledger(dir="")
        self.steps: dict = {}
        self.lives: dict = {}
        self.fixes: list = []
        self.apps = None
        self.coeffs = load_coeffs()
        self.rules = load_rules()

    def rate(self, t, state, w=1.0):
        self.hist.rate.append(UpPoint(float(t), w, state))
        return self

    def rates(self, a, b, state, every=1800):
        t = a
        while t < b:
            self.rate(t, state)
            t += every
        return self

    def charge(self, t, pct, state):
        self.hist.charge.append(UpPoint(float(t), float(pct), state))
        return self

    def boot(self, boot8=CUR8, off=OFF, clock="sync", current=True) -> Boot:
        b = Boot(boot8=boot8, boot=boot8 + "-0000-4000-8000-000000000001", clock=clock, offset=float(off))
        b.heads.append(Head(boot=b.boot, part=0, m=0.0, w=float(off), sync=True, why="start"))
        self.led.boots.append(b)
        self.steps[boot8] = []
        self.lives[boot8] = {}
        if current:
            self.src.boot_id = b.boot
        return b

    def snap(self, b: Boot, t, **kw) -> Snap:
        m = float(t) - b.offset
        for s in b.snaps:
            if abs(s.m - m) < 1e-9:
                for k, v in kw.items():
                    setattr(s, k, v)
                return s
        s = Snap(why=kw.pop("why", "ck"), m=m, w=float(t), sync=True, head=0, cov=kw.pop("cov", True), **kw)
        b.snaps.append(s)
        b.snaps.sort(key=lambda x: x.m)
        return s

    def step(self, b: Boot, ta, tb, dpms, frd=None, cov=True, **kw) -> Step:
        st = Step(boot8=b.boot8, ma=ta - b.offset, mb=tb - b.offset, ta=float(ta), tb=float(tb), dpms=dpms,
                  pw="dis", cov=cov, fr=frd, **kw)
        lst = self.steps[b.boot8]
        lst.append(st)
        lst.sort(key=lambda s: s.ta)
        self.snap(b, ta, dpms=dpms, cov=cov)
        if not any(abs(s.m - st.mb) < 1e-9 for s in b.snaps):
            self.snap(b, tb, dpms=dpms, cov=cov)
        return st

    def inputs(self) -> Inputs:
        self.hist.rate.sort(key=lambda p: p.t)
        self.hist.charge.sort(key=lambda p: p.t)
        return Inputs(src=self.src, coeffs=self.coeffs, rules=self.rules, ledger=self.led, history=self.hist,
                      steps=self.steps, lives=self.lives, fixes=self.fixes, apps=self.apps)


def world_a(end_dis=NOW, pct=40, **kw) -> World:
    """Full charge 80 -> 100 % [-20 h, -18 h]; discharge to 60 %; a non-full charge 60 -> 80 %
    [-10 h, -8 h] (DESIGN 5 case 8); discharge until end_dis. No ledger."""
    w = World(pct=pct, **kw)
    w.rates(NOW - 20 * H, NOW - 18.5 * H, 1).rates(NOW - 18.5 * H, NOW - 18 * H, 4)
    w.rates(NOW - 18 * H, NOW - 10 * H, 2).rates(NOW - 10 * H, NOW - 8 * H, 1).rates(NOW - 8 * H, end_dis, 2)
    w.charge(NOW - 20 * H, 80, 1).charge(NOW - 18.5 * H, 100, 4).charge(NOW - 18 * H, 100, 2)
    w.charge(NOW - 10 * H - 60, 60, 2).charge(NOW - 10 * H + 60, 60, 1)
    w.charge(NOW - 8 * H - 60, 80, 1).charge(NOW - 8 * H + 60, 80, 2)
    return w


def d_sum(rng) -> float:
    return sum(s.d_pct for s in rng.segments if s.kind in ranges.DISCHARGE)


def seconds(rng, kind) -> float:
    return sum(s.b - s.a for s in rng.segments if s.kind == kind)


class Invariants(unittest.TestCase):
    """Shape rules of JSON v1 that a Range must already satisfy (contract.py checks the JSON)."""

    def check(self, rng):
        self.assertLess(rng.start, rng.end)
        self.assertLessEqual(rng.end, NOW)
        prev = rng.start
        for s in rng.segments:
            self.assertAlmostEqual(s.a, prev, places=6)
            self.assertLess(s.a, s.b)
            self.assertLessEqual(s.b - s.a, 3600 + 1e-6)
            prev = s.b
        self.assertAlmostEqual(prev, rng.end, places=6)
        for k, ivs in rng.bands.items():
            last = None
            for a, b in ivs:
                self.assertIsInstance(a, int)
                self.assertLess(a, b)
                self.assertGreaterEqual(a, rng.start)
                self.assertLessEqual(b, rng.end)
                if last is not None:
                    self.assertGreater(a, last, f"{k} bands touch or overlap")
                last = b
        for t, p in rng.curve:
            self.assertTrue(rng.start <= t <= rng.end)
            self.assertEqual(round(p, 1), p)
        bs, bt = rng.bucket_s, rng.bucket_t
        self.assertEqual(ranges.bucket_grid(rng.key, rng.start, rng.end, TZ), (bs, bt))


class BucketGrid(unittest.TestCase):
    def test_24h_last_bucket_is_the_local_hour_of_end(self):
        bs, bt = ranges.bucket_grid("24h", NOW - DAY, NOW, TZ)
        # NOW is 08:31 local -> last bucket 08:00 local = NOW - 1860
        self.assertEqual(bs, 3600)
        self.assertEqual(len(bt), 24)
        self.assertEqual(bt[-1], NOW - 1860)
        self.assertEqual(bt[0], NOW - 1860 - 23 * H)
        self.assertEqual((bt[0] + TZ * 60) % 3600, 0)

    def test_7d_last_bucket_is_the_local_day_of_end(self):
        bs, bt = ranges.bucket_grid("7d", NOW - 7 * DAY, NOW, TZ)
        midnight = NOW - (8 * H + 31 * 60)           # 2026-10-30 00:00 local
        self.assertEqual((bs, len(bt), bt[-1], bt[0]), (DAY, 7, midnight, midnight - 6 * DAY))

    def test_since_full_smallest_size_that_fits_48(self):
        # 1000 s from 08:14:20 to 08:31:00 local: 900 s buckets 08:00, 08:15, 08:30
        bs, bt = ranges.bucket_grid("since_full", NOW - 1000, NOW, TZ)
        self.assertEqual((bs, bt), (900, [NOW - 1860, NOW - 960, NOW - 60]))
        # 2 days: hourly would need 49 buckets (08:00 .. 08:00), 2 h needs 25
        bs, bt = ranges.bucket_grid("since_full", NOW - 2 * DAY, NOW, TZ)
        self.assertEqual((bs, len(bt), bt[0]), (7200, 25, NOW - 1860 - 2 * DAY))
        # 30 days: daily, 31 local days
        bs, bt = ranges.bucket_grid("since_full", NOW - 30 * DAY, NOW, TZ)
        self.assertEqual((bs, len(bt)), (DAY, 31))
        self.assertTrue(bt[0] <= NOW - 30 * DAY < bt[0] + bs and bt[-1] < NOW <= bt[-1] + bs)

    def test_since_full_end_on_a_boundary_stays_in_the_bucket_before(self):
        end = NOW - 60                                # 08:30:00 local, a 900 s boundary
        bs, bt = ranges.bucket_grid("since_full", end - 1800, end, TZ)
        self.assertEqual((bs, bt), (900, [end - 1800, end - 900]))

    def test_spread_clamps_outside_into_the_end_buckets(self):
        bt = [1000, 2000, 3000]
        got = ranges.spread(500, 2500, 1000, bt)
        # 500 s before the grid -> bucket 0 (with 1000-2000 of it), 2000-2500 -> bucket 1
        self.assertEqual([(i, round(f, 6)) for i, f in got], [(0, 0.75), (1, 0.25)])
        got = ranges.spread(3500, 4500, 1000, bt)
        self.assertEqual([(i, round(f, 6)) for i, f in got], [(2, 1.0)])


class PlugTimeline(unittest.TestCase):
    def test_sessions_full_and_not_full(self):
        inp = world_a().inputs()
        ses = ranges.plug_timeline(inp)
        self.assertIs(inp.sessions, ses)
        self.assertEqual([(s.a, s.b) for s in ses], [(NOW - 20 * H, NOW - 18 * H), (NOW - 10 * H, NOW - 8 * H)])
        self.assertEqual([s.full for s in ses], [True, False])      # fully-charged seen; max 80 %
        self.assertEqual([s.max_pct for s in ses], [100.0, 80.0])
        self.assertEqual(ses[0].src, "upower")

    def test_loose_cable_under_2_min_is_one_session(self):
        w = World(pct=50)
        w.rates(NOW - 6 * H, NOW - 5 * H, 2).rates(NOW - 5 * H, NOW - 3 * H, 1)
        w.rate(NOW - 3 * H, 2).rates(NOW - 3 * H + 60, NOW - 2 * H, 1)        # 60 s out: merged
        w.rate(NOW - 2 * H, 2).rates(NOW - 2 * H + 200, NOW - H, 1)           # 200 s out: not merged
        w.rates(NOW - H, NOW, 2)
        w.charge(NOW - 6 * H, 50, 2)
        ses = ranges.plug_timeline(w.inputs())
        self.assertEqual([(s.a, s.b) for s in ses],
                         [(NOW - 5 * H, NOW - 2 * H), (NOW - 2 * H + 200, NOW - H)])

    def test_full_by_max_pct_98_but_not_97(self):
        for top, full in ((98, True), (97, False)):
            w = World(pct=90)
            w.rates(NOW - 5 * H, NOW - 4 * H, 2).rates(NOW - 4 * H, NOW - 2 * H, 1).rates(NOW - 2 * H, NOW, 2)
            w.charge(NOW - 4 * H, 70, 1).charge(NOW - 2 * H - 60, top, 1)     # charging, never fully-charged
            ses = ranges.plug_timeline(w.inputs())
            self.assertEqual([s.full for s in ses], [full], top)

    def test_bypass_not_charging_is_not_full(self):
        # ledger st "Not charging" at 80 % (bypass lowers the threshold; it is never read)
        w = World(pct=80, status="not_charging")
        b = w.boot()
        w.step(b, NOW - 2 * H, NOW - H, 1, fr(on_s=H, p_mw=0))
        w.step(b, NOW - H, NOW, 1, fr(on_s=H, p_mw=0))
        w.snap(b, NOW - 2 * H, st="Not charging", cap=80)
        ses = ranges.plug_timeline(w.inputs())
        self.assertEqual(len(ses), 1)
        self.assertEqual((ses[0].a, ses[0].b, ses[0].full, ses[0].src), (NOW - 2 * H, None, False, "sysfs+ledger"))

    def test_dat_still_charging_sysfs_discharging_5_min(self):
        # .dat's last point (written every 10 min) still says charging 7 min ago; sysfs says
        # Discharging now. Without a ledger the change sits at the last plugged reading.
        w = World(pct=99, status="discharging")
        w.hist.source = "dat"
        w.rates(NOW - 3 * H, NOW - 420, 1).rate(NOW - 420, 1)
        w.charge(NOW - 3 * H, 80, 1).charge(NOW - H, 100, 1)
        inp = w.inputs()
        rng = ranges.build(inp)["since_full"]
        self.assertEqual((inp.sessions[-1].a, inp.sessions[-1].b), (NOW - 3 * H, NOW - 420))
        self.assertTrue(inp.sessions[-1].full)
        self.assertFalse(rng.plugged_now)
        self.assertEqual((rng.state, rng.anchor, rng.start, rng.end), ("just_full", "full", NOW - 420, NOW))

    def test_dat_15_min_old_and_ledger_edge_5_min_ago(self):
        # .dat says charging until 15 min ago; the recorder's pw-edge snapshot read Discharging 5 min
        # ago. The ledger edge places the unplug: just_full from -300 s.
        def make(with_edge):
            w = World(pct=99, status="discharging")
            w.hist.source = "dat"
            w.rates(NOW - 3 * H, NOW - 900, 1).rate(NOW - 900, 1)
            w.charge(NOW - 3 * H, 80, 1).charge(NOW - H, 100, 1)
            b = w.boot()
            w.step(b, NOW - 1800, NOW - 300, 1, fr(on_s=1500, p_mw=-2000))
            w.step(b, NOW - 300, NOW - 10, 1, fr(on_s=290, p_mw=1500))
            w.snap(b, NOW - 1800, st="Charging", cap=100)
            if with_edge:
                w.snap(b, NOW - 300, st="Discharging", cap=99, why="pw")
            return w.inputs()
        inp = make(True)
        rng = ranges.build(inp)["since_full"]
        self.assertEqual(inp.sessions[-1].b, NOW - 300)
        self.assertEqual((rng.state, rng.start, rng.anchor_t), ("just_full", NOW - 300, NOW - 300))
        inp = make(False)
        rng = ranges.build(inp)["since_full"]
        self.assertEqual(inp.sessions[-1].b, NOW - 900)
        # [-900, -10] itemised, 10 s tail uncovered -> ok
        self.assertEqual((rng.state, rng.start, rng.anchor), ("ok", NOW - 900, "full"))

    def test_sysfs_wins_over_history(self):
        w = World(pct=50, status="charging")
        w.rates(NOW - 5 * H, NOW - 60, 2).rate(NOW - 60, 2)
        w.charge(NOW - 5 * H, 60, 2)
        inp = w.inputs()
        rngs = ranges.build(inp)
        self.assertEqual((inp.sessions[-1].a, inp.sessions[-1].b), (NOW - 60, None))
        self.assertIn("sysfs", inp.sessions[-1].src)
        self.assertTrue(rngs["24h"].plugged_now)
        self.assertEqual(rngs["24h"].bands["charger"], [(NOW - 60, NOW)])
        self.assertEqual(rngs["since_full"].plug_t, NOW - 60)

    def test_ledger_st_loses_to_upower_on_both_sides(self):
        w = World(pct=50)
        w.rates(NOW - 4 * H, NOW, 2, every=300)
        w.charge(NOW - 4 * H, 60, 2)
        b = w.boot()
        w.step(b, NOW - 2 * H, NOW - H, 0, fr(off_s=H, p_mw=200))
        w.snap(b, NOW - 2 * H + 100, st="Charging", cap=55)      # UPower at -2h and -2h+300 say discharging
        ses = ranges.plug_timeline(w.inputs())
        self.assertEqual(ses, [])

    def test_weak_charger_is_discharge(self):
        w = World(pct=64)
        w.rates(NOW - 4 * H, NOW - 3 * H, 2).rates(NOW - 3 * H, NOW - H, 1).rates(NOW - H, NOW, 2)
        w.charge(NOW - 4 * H, 72, 2).charge(NOW - 3 * H, 70, 1).charge(NOW - H - 1, 66, 1)
        b = w.boot()
        w.step(b, NOW - 4 * H, NOW - 3 * H, 0, fr(off_s=H, p_mw=200))
        w.step(b, NOW - 3 * H, NOW - 2 * H, 1, fr(on_s=H, p_mw=1000))   # +1000 mW on "charging"
        w.step(b, NOW - 2 * H, NOW - H, 1, fr(on_s=H, p_mw=1000))
        w.step(b, NOW - H, NOW, 0, fr(off_s=H, p_mw=200))
        inp = w.inputs()
        rngs = ranges.build(inp)
        s = inp.sessions[0]
        # mean 1000 mW > 50 and 70 -> 66 % (>= 1): weak, never full
        self.assertEqual((s.a, s.b, s.weak, s.full), (NOW - 3 * H, NOW - H, True, False))
        r = rngs["24h"]
        weak = [g for g in r.segments if g.weak_charger]
        self.assertEqual([(g.a, g.b, g.kind) for g in weak], [(NOW - 3 * H, NOW - 2 * H, "on"),
                                                                (NOW - 2 * H, NOW - H, "on")])
        self.assertEqual([g.e_j for g in weak], [3600.0, 3600.0])      # 1000 mW * 3600 s
        self.assertEqual((r.bands["charger"], r.mid_plugs, r.state), ([], 0, "ok"))
        self.assertEqual(r.bands["on"], [(NOW - 3 * H, NOW - H)])


class SinceFull(Invariants):
    def test_case3_anchor_and_case8_mid_plug_drop_is_sum_of_drops(self):
        inp = world_a().inputs()
        rngs = ranges.build(inp)
        r = rngs["since_full"]
        self.check(r)
        self.assertEqual((r.anchor, r.anchor_t, r.start, r.end), ("full", NOW - 18 * H, NOW - 18 * H, NOW))
        self.assertEqual((r.mid_plugs, r.plugged_now, r.full_now, r.plug_t), (1, False, False, None))
        # D = (100 - 60) + (80 - 40) = 80, not first - last = 60
        self.assertAlmostEqual(d_sum(r), 80.0, places=6)
        self.assertEqual(r.bands, {"on": [], "charger": [(NOW - 10 * H, NOW - 8 * H)], "gap": [],
                                   "uncovered": [(NOW - 18 * H, NOW - 10 * H), (NOW - 8 * H, NOW)]})
        self.assertEqual(r.curve, [(NOW - 18 * H, 100.0), (NOW - 10 * H - 60, 60.0), (NOW - 10 * H + 60, 60.0),
                                   (NOW - 8 * H - 60, 80.0), (NOW - 8 * H + 60, 80.0), (NOW, 40.0)])
        self.assertEqual(r.state, "empty")         # no ledger: nothing itemised
        self.assertEqual(seconds(r, "uncovered"), 16 * H)
        self.assertEqual(len([s for s in r.segments if s.kind == "uncovered"]), 16)   # <= 60 min each

    def test_case4_plugged_and_full_shows_previous_round(self):
        w = world_a(end_dis=NOW - 2 * H, pct=100, status="full")
        w.charge(NOW - 2 * H - 60, 50, 2).rates(NOW - 2 * H, NOW - 1800, 1).rates(NOW - 1800, NOW, 4)
        w.charge(NOW - 2 * H + 60, 50, 1).charge(NOW - 1800, 100, 4)
        inp = w.inputs()
        r = ranges.build(inp)["since_full"]
        self.check(r)
        self.assertEqual((r.anchor, r.start, r.end, r.anchor_t, r.plug_t),
                         ("prev_round", NOW - 18 * H, NOW - 2 * H, NOW - 18 * H, NOW - 2 * H))
        self.assertEqual((r.plugged_now, r.full_now, r.mid_plugs), (True, True, 1))
        self.assertAlmostEqual(d_sum(r), 40 + 30, places=6)     # 100 -> 60, 80 -> 50

    def test_case5_plugged_not_full_runs_to_now_with_charger_band(self):
        w = world_a(end_dis=NOW - H, pct=50, status="charging")
        w.charge(NOW - H - 60, 45, 2).rates(NOW - H, NOW, 1).charge(NOW - H + 60, 45, 1)
        r = ranges.build(w.inputs())["since_full"]
        self.check(r)
        self.assertEqual((r.anchor, r.start, r.end, r.plug_t, r.mid_plugs, r.full_now),
                         ("full", NOW - 18 * H, NOW, NOW - H, 1, False))
        self.assertEqual(r.bands["charger"], [(NOW - 10 * H, NOW - 8 * H), (NOW - H, NOW)])

    def test_case6_just_full_under_10_min(self):
        w = World(pct=99)
        w.rates(NOW - 3 * H, NOW - H, 1).rates(NOW - H, NOW - 300, 4).rate(NOW - 300, 2)
        w.charge(NOW - 3 * H, 70, 1).charge(NOW - H, 100, 4).charge(NOW - 280, 99, 2)
        rngs = ranges.build(w.inputs())
        r = rngs["since_full"]
        self.check(r)
        self.assertEqual((r.state, r.anchor, r.start, r.end), ("just_full", "full", NOW - 300, NOW))
        self.assertEqual(rngs["24h"].state, "empty")             # 300 s discharge, nothing itemised

    def test_case7_no_full_in_40_days_starts_at_earliest_data(self):
        w = World(pct=40)
        w.rates(NOW - 50 * DAY, NOW - 50 * DAY + H, 2).charge(NOW - 50 * DAY, 90, 2)
        w.rates(NOW - 10 * H, NOW, 2).charge(NOW - 10 * H, 50, 2)
        r = ranges.build(w.inputs())["since_full"]
        self.check(r)
        self.assertEqual((r.anchor, r.start, r.end, r.anchor_t), ("no_full", NOW - 40 * DAY, NOW, None))
        self.assertEqual(r.bands["gap"], [(NOW - 40 * DAY, NOW - 10 * H)])    # upowerd silent > 3 h
        self.assertEqual((r.bucket_s, len(r.bucket_t)), (DAY, 41))
        # newer data with a bypass session in it: from the first data, the bypass is a mid plug
        w = World(pct=40)
        w.rates(NOW - 5 * DAY, NOW - 3 * DAY, 2).rates(NOW - 3 * DAY, NOW - 2 * DAY, 5)
        w.rates(NOW - 2 * DAY, NOW, 2).charge(NOW - 5 * DAY, 95, 2).charge(NOW - 3 * DAY - 60, 80, 2)
        r = ranges.build(w.inputs())["since_full"]
        self.assertEqual((r.anchor, r.start, r.mid_plugs), ("no_full", NOW - 5 * DAY, 1))

    def test_full_charge_older_than_40_days_is_no_anchor(self):
        # a full charge still in the ledger's oldest part (pruned by part mtime) but past 40 days falls back to
        # case 7 like no full charge at all; 52 days would also need 53 daily buckets, over JSON v1's 48
        for ago, anchor, start, n in ((39, "full", NOW - 39 * DAY, 40), (45, "no_full", NOW - 40 * DAY, 41),
                                      (52, "no_full", NOW - 40 * DAY, 41)):
            w = World(pct=40)
            w.rates(NOW - ago * DAY - 2 * H, NOW - ago * DAY, 1).charge(NOW - ago * DAY - 2 * H, 60, 1)
            w.rate(NOW - ago * DAY - 600, 4).charge(NOW - ago * DAY - 600, 100, 4)
            w.rates(NOW - ago * DAY, NOW - 20 * DAY, 2, every=3 * H).charge(NOW - ago * DAY, 100, 2)
            w.rates(NOW - 20 * DAY, NOW - 20 * DAY + 2 * H, 1).charge(NOW - 20 * DAY + 2 * H, 90, 1)
            w.rates(NOW - 20 * DAY + 2 * H, NOW, 2).charge(NOW - 10 * H, 50, 2)
            r = ranges.build(w.inputs())["since_full"]
            self.check(r)
            self.assertEqual((r.anchor, r.start, r.bucket_s, len(r.bucket_t)), (anchor, start, DAY, n), ago)
            doc, errs = cli.run_json(w.inputs(), time.perf_counter())
            self.assertEqual(errs, [], ago)
            if anchor == "no_full":
                self.assertEqual(doc["ranges"]["since_full"]["title"], "自 09-20 起（之前没有记录）")

    def test_all_charger(self):
        w = World(pct=80, status="not_charging")
        w.rates(NOW - 9 * DAY, NOW, 5).charge(NOW - 9 * DAY, 80, 5)
        rngs = ranges.build(w.inputs())
        for key in ("since_full", "24h", "7d"):
            self.check(rngs[key])
            self.assertEqual(rngs[key].state, "all_charger", key)
        self.assertEqual(rngs["since_full"].start, NOW - 9 * DAY)
        self.assertEqual(rngs["7d"].bands["charger"], [(NOW - 7 * DAY, NOW)])


class Windows(Invariants):
    def test_exact_windows(self):
        rngs = ranges.build(world_a().inputs())
        self.assertEqual((rngs["24h"].start, rngs["24h"].end), (NOW - DAY, NOW))
        self.assertEqual((rngs["7d"].start, rngs["7d"].end), (NOW - 7 * DAY, NOW))
        r = rngs["24h"]
        self.check(r)
        self.check(rngs["7d"])
        # before the first data point: gap; both plug sessions inside
        self.assertEqual(r.bands["gap"], [(NOW - DAY, NOW - 20 * H)])
        self.assertEqual(r.bands["charger"], [(NOW - 20 * H, NOW - 18 * H), (NOW - 10 * H, NOW - 8 * H)])
        self.assertEqual((r.anchor, r.mid_plugs, r.unknown_time_boots, r.charges), ("window", 2, 0, 2))

    def test_charges_count_plug_ins_not_bands(self):
        # a reboot while plugged in: one session drawn as two charger bands around the gap between the boots,
        # counted once (24h / 7d 「充电 N 次」)
        w = World(pct=50)
        w.rates(NOW - 10 * H, NOW - 6 * H, 2).rates(NOW - 6 * H, NOW - 3 * H, 1).rates(NOW - 3 * H, NOW, 2)
        w.charge(NOW - 10 * H, 80, 2).charge(NOW - 6 * H, 68, 1).charge(NOW - 3 * H, 90, 2)
        old = w.boot("bbbbbbbb", off=NOW - 20 * H, current=False)
        w.step(old, NOW - 7 * H, NOW - 5 * H, 0, fr(off_s=2 * H, p_mw=150))
        b = w.boot()
        w.step(b, NOW - 4 * H, NOW, 0, fr(off_s=4 * H, p_mw=150))
        r = ranges.build(w.inputs())["24h"]
        self.check(r)
        self.assertEqual(len(ranges.plug_timeline(w.inputs())), 1)
        self.assertEqual(r.bands["charger"], [(NOW - 6 * H, NOW - 5 * H), (NOW - 4 * H, NOW - 3 * H)])
        self.assertEqual(r.charges, 1)
        # two sessions with nothing but the gap between the boots in between (one discharging reading while
        # the tablet shut down) are one plug-in too; discharge time between them makes them two
        w = World(pct=50)
        w.rates(NOW - 10 * H, NOW - 6 * H, 2).rates(NOW - 6 * H, NOW - 5 * H, 1).rate(NOW - 5 * H, 2)
        w.rates(NOW - 4.5 * H, NOW - 3 * H, 1).rates(NOW - 3 * H, NOW, 2)
        w.charge(NOW - 10 * H, 80, 2).charge(NOW - 6 * H, 68, 1).charge(NOW - 3 * H, 90, 2)
        old = w.boot("bbbbbbbb", off=NOW - 20 * H, current=False)
        w.step(old, NOW - 7 * H, NOW - 5 * H, 0, fr(off_s=2 * H, p_mw=150))
        b = w.boot()
        w.step(b, NOW - 4 * H, NOW, 0, fr(off_s=4 * H, p_mw=150))
        self.assertEqual(len(ranges.plug_timeline(w.inputs())), 2)
        self.assertEqual(ranges.build(w.inputs())["24h"].charges, 1)
        w.boot("cccccccc", off=NOW - 30 * H, current=False)
        w.step(w.led.boots[-1], NOW - 5 * H + 300, NOW - 4.5 * H - 300, 0, fr(off_s=1200, p_mw=150))
        self.assertEqual(ranges.build(w.inputs())["24h"].charges, 2)

    def test_unknown_time_boot_is_gap_in_windows_and_counted_in_since_full(self):
        w = World(pct=50)
        w.rates(NOW - 10 * H, NOW, 2).charge(NOW - 10 * H, 80, 2)
        old = w.boot("bbbbbbbb", off=NOW - 10 * H - 50, clock="chained", current=False)
        w.step(old, NOW - 10 * H, NOW - 9 * H, 0, fr(off_s=H, p_mw=150))
        w.step(old, NOW - 9 * H, NOW - 8 * H, 0, fr(off_s=H, p_mw=150))
        b = w.boot()
        for k in range(6, 0, -1):
            w.step(b, NOW - k * H, NOW - (k - 1) * H, 0 if k > 3 else 1, fr(off_s=H, p_mw=150))
        rngs = ranges.build(w.inputs())
        r = rngs["24h"]
        self.check(r)
        self.assertEqual(r.bands["gap"], [(NOW - DAY, NOW - 6 * H)])
        self.assertEqual(r.unknown_time_boots, 0)
        s = rngs["since_full"]
        self.check(s)
        self.assertEqual((s.anchor, s.start, s.unknown_time_boots), ("no_full", NOW - 10 * H, 1))
        self.assertEqual([(g.a, g.b, g.kind) for g in s.segments[:2]],
                         [(NOW - 10 * H, NOW - 9 * H, "off"), (NOW - 9 * H, NOW - 8 * H, "off")])
        self.assertEqual(s.bands["gap"], [(NOW - 8 * H, NOW - 6 * H)])        # between the boots

    def test_step_cut_by_range_start_is_split_proportionally(self):
        w = World(pct=50)
        w.rates(NOW - 26 * H, NOW, 2).charge(NOW - 26 * H, 90, 2)
        b = w.boot()
        w.step(b, NOW - DAY - 600, NOW - DAY + 600, 0, fr(off_s=1200, p_mw=100))     # 120 J
        w.step(b, NOW - DAY + 600, NOW, 0, fr(off_s=DAY - 600, p_mw=100))
        inp = w.inputs()
        r = ranges.build(inp)["24h"]
        self.check(r)
        # one screen-off stretch of 24 h -> 24 segments of 60 min (DESIGN 4), not cut at steps
        first = r.segments[0]
        self.assertEqual((first.a, first.b, first.kind, first.steps), (NOW - DAY, NOW - DAY + H, "off", [0, 1]))
        self.assertEqual(len(r.segments), 24)
        # half of the 120 J step + 3000 s of the 100 mW step (300 J)
        self.assertAlmostEqual(first.e_j, 60.0 + 300.0, places=6)
        ctx = ranges.context(inp)
        self.assertEqual(ranges.step_weight(ctx, inp.steps[CUR8][0], NOW - DAY, NOW - DAY + H), 0.5)
        self.assertAlmostEqual(sum(g.e_j for g in r.segments), 60.0 + 8580.0, places=6)

    def test_step_weight_leaves_the_plugged_part_out(self):
        w = World(pct=50)
        t = NOW - 2 * H
        w.rates(NOW - 5 * H, t, 2).rate(t, 1).rate(t + 300, 1).rate(t + 600, 2).rates(t + 1800, NOW, 2)
        w.charge(NOW - 5 * H, 60, 2)
        b = w.boot()
        w.step(b, t, t + 1200, 0, fr(off_s=1200, e_mj=60000))    # 60 J, all while unplugged
        w.step(b, t + 1200, NOW, 0, fr(off_s=NOW - t - 1200, p_mw=100))
        inp = w.inputs()
        r = ranges.build(inp)["24h"]
        self.assertEqual(r.bands["charger"], [(t, t + 600)])
        # off [t+600, NOW] = 6600 s -> two 3300 s segments
        seg = next(s for s in r.segments if s.a == t + 600)
        self.assertEqual((seg.b, seg.kind), (t + 3900, "off"))
        # step 0: its unplugged 600 s all inside -> weight 1 -> 60 J; step 1: 2700 / 6000 of 600 J
        self.assertAlmostEqual(seg.e_j, 60.0 + 270.0, places=6)
        self.assertEqual(ranges.step_weight(ranges.context(inp), inp.steps[CUR8][0], t + 600, t + 900), 0.5)
        # counts (CPU s, wakeups) ran all 1200 s, the plugged 600 s included: 300 of 1200
        self.assertEqual(ranges.step_weight(ranges.context(inp), inp.steps[CUR8][0], t + 600, t + 900,
                                            counted=True), 0.25)


class States(Invariants):
    def test_partial_degraded_tail_and_data_from(self):
        w = World(pct=50)
        w.rates(NOW - 10 * H, NOW, 2).charge(NOW - 10 * H, 80, 2)       # 80 -> 50 %: 3 %/h
        b = w.boot()
        w.step(b, NOW - 5 * H, NOW - 4 * H, 1, cov=False)               # degraded, screen on
        w.step(b, NOW - 4 * H, NOW - H, 0, fr(off_s=3 * H, p_mw=150))
        inp = w.inputs()
        r = ranges.build(inp)["24h"]
        self.check(r)
        got = [(s.a, s.b, s.kind, s.degraded) for s in r.segments if s.kind != "gap"]
        self.assertEqual(got[:5], [(NOW - 10 * H + k * H, NOW - 9 * H + k * H, "uncovered", False) for k in range(5)])
        self.assertEqual(got[5], (NOW - 5 * H, NOW - 4 * H, "uncovered", True))
        self.assertEqual(got[-1], (NOW - H, NOW, "uncovered", False))    # after the newest snapshot
        ctx = ranges.context(inp)
        dp = {s.a: ranges.seg_dpms(ctx, s) for s in r.segments if s.kind == "uncovered"}
        self.assertEqual((dp[NOW - 10 * H], dp[NOW - 5 * H], dp[NOW - H]), (None, 1, 0))
        self.assertEqual(r.state, "partial")
        self.assertEqual(r.data_from, NOW - 4 * H)
        self.assertEqual(r.bands["on"], [(NOW - 5 * H, NOW - 4 * H)])
        self.assertEqual(r.bands["uncovered"], [(NOW - 10 * H, NOW - 4 * H), (NOW - H, NOW)])
        self.assertAlmostEqual(d_sum(r), 30.0, places=6)

    def test_empty_when_ledger_just_started(self):
        w = World(pct=50)
        w.rates(NOW - 10 * H, NOW, 2).charge(NOW - 10 * H, 80, 2)
        b = w.boot()
        w.step(b, NOW - 240, NOW, 1, fr(on_s=240, p_mw=2000))
        r = ranges.build(w.inputs())["24h"]
        self.check(r)
        self.assertEqual((r.state, r.data_from), ("empty", NOW - 240))

    def test_ok(self):
        w = World(pct=50)
        w.rates(NOW - 2 * H, NOW, 2).charge(NOW - 2 * H, 60, 2)
        b = w.boot()
        w.step(b, NOW - 2 * H, NOW - H, 1, fr(on_s=H, p_mw=2000))
        w.step(b, NOW - H, NOW - 100, 0, fr(off_s=H - 100, p_mw=200))
        r = ranges.build(w.inputs())["24h"]
        self.check(r)
        self.assertEqual((r.state, r.data_from), ("ok", None))   # 100 s uncovered tail < 300

    def test_partial_on_the_whole_seconds_written(self):
        # 299.7 s uncovered is written as uncovered_s 300 (half up): partial, not an ok whose self-check fails
        # and turns the whole report into the error document; 299.2 s is 299 and stays ok
        for tail, want in ((299.2, "ok"), (299.7, "partial")):
            w = World(pct=40)
            w.rates(NOW - 30 * H, NOW - 26 * H, 1).charge(NOW - 30 * H, 60, 1)
            w.rate(NOW - 26 * H - 600, 4).charge(NOW - 26 * H - 600, 100, 4)
            w.rates(NOW - 26 * H, NOW, 2).charge(NOW - 26 * H, 100, 2).charge(NOW - 10 * H, 50, 2)
            b = w.boot()
            t, end = NOW - 25 * H, NOW - tail
            while t < end:
                w.step(b, t, min(end, t + 300), 1, fr(on_s=min(end, t + 300) - t, p_mw=2000, level=500))
                t += 300
            self.assertEqual(ranges.build(w.inputs())["24h"].state, want, tail)
            doc, errs = cli.run_json(w.inputs(), time.perf_counter())
            self.assertEqual((doc["ranges"]["24h"]["state"], errs), (want, []), tail)

    def test_data_from_marks_the_screen_known_when_nothing_is_itemised(self):
        # the first run: one start snapshot, no covered step yet. Before it nobody recorded the screen, so
        # data_from marks it although nothing is itemised (the page must not draw that time as 熄屏)
        w = World(pct=50)
        w.rates(NOW - 10 * H, NOW, 2).charge(NOW - 10 * H, 80, 2)
        b = w.boot()
        w.snap(b, NOW - 120, why="start", dpms=0)
        r = ranges.build(w.inputs())["24h"]
        self.check(r)
        self.assertEqual((r.state, r.data_from, r.bands["on"]), ("empty", NOW - 120, []))
        self.assertEqual(r.bands["uncovered"], [(NOW - 10 * H, NOW)])
        # no ledger at all: the screen is never known
        w = World(pct=50)
        w.rates(NOW - 10 * H, NOW, 2).charge(NOW - 10 * H, 80, 2)
        self.assertEqual(ranges.build(w.inputs())["24h"].data_from, NOW)
        # degraded from before the start: the steps still say on / off, nothing to mark
        w = World(pct=50)
        w.rates(NOW - 26 * H, NOW, 2).charge(NOW - 26 * H, 80, 2)
        b = w.boot()
        w.step(b, NOW - 25 * H, NOW - 2 * H, 0, cov=False)
        w.step(b, NOW - 2 * H, NOW, 1, cov=False)
        r = ranges.build(w.inputs())["24h"]
        self.assertEqual((r.state, r.data_from, r.bands["on"]), ("empty", None, [(NOW - 2 * H, NOW)]))


class Helpers(unittest.TestCase):
    def test_int_bands_round_drop_empty_merge_touching(self):
        got = ranges.int_bands([(40, 50), (1.4, 10.6), (10.6, 20.2), (30.2, 30.4)])
        self.assertEqual(got, [(1, 20), (40, 50)])

    def test_pct_interpolation_and_drop(self):
        w = World(pct=50)
        w.charge(NOW - 2 * H, 70, 2).charge(NOW - H, 60, 2)
        ctx = ranges.context(w.inputs(), refresh=True)
        self.assertEqual((ctx.pct_at(NOW - 3 * H), ctx.pct_at(NOW - 1.5 * H), ctx.pct_at(NOW)), (70, 65, 50))
        self.assertEqual((ctx.drop(NOW - 2 * H, NOW), ctx.drop(NOW, NOW - 2 * H)), (20, 0.0))
        self.assertIsNone(ranges.context(World(pct=None).inputs(), refresh=True).pct_at(NOW))

    def test_state_0_points_are_ignored(self):
        w = World(pct=50)
        w.rates(NOW - 5 * H, NOW - 3 * H, 2).rates(NOW - 3 * H, NOW - 2 * H, 0).rates(NOW - 2 * H, NOW, 2)
        w.charge(NOW - 5 * H, 60, 2).charge(NOW - 2.5 * H, 55, 0)
        self.assertEqual(ranges.plug_timeline(w.inputs()), [])
        w = World(pct=90, status="charging")
        w.rates(NOW - 3 * H, NOW, 1).rate(NOW - 2 * H + 1, 0).charge(NOW - 3 * H, 60, 1)
        ses = ranges.plug_timeline(w.inputs())
        self.assertEqual([(x.a, x.b) for x in ses], [(NOW - 3 * H, None)])

    def test_curve_has_the_ends_and_gap_edges(self):
        w = World(pct=50)
        w.rates(NOW - 10 * H, NOW - 6 * H, 2).rates(NOW - 2 * H, NOW, 2)      # upowerd silent 4 h
        w.charge(NOW - 10 * H, 80, 2).charge(NOW - 2 * H, 56, 2)
        r = ranges.build(w.inputs())["24h"]
        gap_end = NOW - 2 * H
        self.assertEqual(r.bands["gap"], [(NOW - DAY, NOW - 10 * H), (NOW - 6.5 * H, gap_end)])
        # 80 % at -10 h, 56 % at -2 h: 3 %/h; the silence edge at -6.5 h reads 69.5
        self.assertEqual(r.curve, [(NOW - 10 * H, 80.0), (NOW - 6.5 * H, 69.5), (gap_end, 56.0), (NOW, 50.0)])
        # the % fell across the silence too, but only discharge segments count toward D
        self.assertAlmostEqual(d_sum(r), (80 - 69.5) + (56 - 50), places=6)


if __name__ == "__main__":
    unittest.main()
