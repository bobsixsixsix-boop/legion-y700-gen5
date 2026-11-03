"""Tests for y700_battery.out: Fmt.js twins, largest remainder, curve decimation, and JSON v1 / --text built from
hand-made types.Report objects (no ledger needed), each checked against contract.validate().

Times: NOW is 2026-10-30 08:31:00 at UTC+8 and every call passes TZ explicitly, never the host's zone.
Run: tools/venv/Scripts/python -X utf8 -I -B -m unittest discover -s linux/power/battery/report/tests -t linux/power/battery/report
"""

import math
import sys
import unittest
from pathlib import Path

REPORT = Path(__file__).resolve().parents[1]
if str(REPORT) not in sys.path:
    sys.path.insert(0, str(REPORT))

from y700_battery import contract as C  # noqa: E402
from y700_battery import out  # noqa: E402
from y700_battery import ranges as R  # noqa: E402
from y700_battery.types import (Coeffs, Diag, ItemEnergy, LiveBattery, Range, RangeResult, RecState,  # noqa: E402
                                Remain, Report, Segment)

TZ = 480
NOW = 1793320260                 # 2026-10-30 08:31:00 local
H = 3600
DAY = 86400
T_FMT = 1793319060               # Date.UTC(2026, 9, 30, 0, 11, 0) / 1000 in fmt-test.mjs: 10-30 08:11 at UTC+8
MID = 1793291400                 # 10-30 00:30 at UTC+8
E_FULL = 8394000 / 1e6 * 3.87 * 3600


# ---------------------------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------------------------

def sg(kind, a, b, dpms=None, d=0.0, e=None, degraded=False, boot8="aaaaaaaa"):
    """(Segment, dpms) with times relative to NOW in hours"""
    return (Segment(boot8=None if kind == "gap" else boot8, a=NOW + a * H, b=NOW + b * H, kind=kind, d_pct=d,
                    e_j=e, degraded=degraded), dpms)


def app(name, e, fg=None, off=0.0, icon="firefox", fg_s=600.0, bg_s=300.0, windows=(), note=None, iid=None):
    fg = e * 0.8 if fg is None else fg
    return ItemEnergy(id=iid or "app:" + name, kind="app", name=name, icon=icon, e_j=e, fg_j=fg, bg_j=e - fg,
                      off_j=off, fg_s=fg_s, bg_s=bg_s, cpu_s=120.0, gpu_s=30.0, wake_off_n=12.0,
                      windows=list(windows), note=note)


def comp(kind, e, parts=(), iid=None):
    cpu = 50.0 if kind in ("ui", "sys") else None
    return ItemEnergy(id=iid or kind, kind=kind, name=kind, e_j=e, parts=list(parts), cpu_s=cpu, gpu_s=cpu,
                      wake_off_n=cpu)


def std_items():
    return [comp("screen", 3000), comp("floor", 2000),
            comp("ui", 400, [("窗口合成（KWin）", 300.0), ("桌面（plasmashell）", 100.0)]),
            comp("sys", 300, [("内核与中断", 300.0)]), comp("wifi", 50),
            comp("other", 250, [("前台未知", 20.0)]),
            app("Firefox", 2500, fg=2000, off=100, fg_s=3600, bg_s=600, windows=[("GitHub", 3000.0),
                                                                                  ("YouTube", 600.0)]),
            app("Kate", 40, icon="/usr/share/icons/kate.png"), app("Okular", 30, icon="bad icon!"),
            app("Zero", 0.0)]


def mk(key, segs, state, items=(), used=None, start=None, end=None, fg_known=True, hint=0.8, high=0, **kw):
    """A RangeResult whose segments cover [start, end] (holes become gap), bands and seconds derived from them"""
    if key == "24h":
        start, end = NOW - DAY, NOW
    elif key == "7d":
        start, end = NOW - 7 * DAY, NOW
    start = NOW - 10 * H if start is None else start
    end = NOW if end is None else end
    full, t = [], start
    for s, dp in sorted(segs, key=lambda x: x[0].a):
        if s.a > t:
            full.append((Segment(boot8=None, a=t, b=s.a, kind="gap"), None))
        full.append((s, dp))
        t = s.b
    if t < end:
        full.append((Segment(boot8=None, a=t, b=end, kind="gap"), None))
    rng = Range(key=key, start=start, end=end, state=state, **kw)
    rng.segments = [s for s, _ in full]
    rng.bands = {
        "on": R.int_bands([(s.a, s.b) for s, dp in full if dp == 1 and s.kind != "gap"]),
        "charger": R.int_bands([(s.a, s.b) for s, _ in full if s.kind == "charger"]),
        "gap": R.int_bands([(s.a, s.b) for s, _ in full if s.kind == "gap"]),
        "uncovered": R.int_bands([(s.a, s.b) for s, _ in full if s.kind == "uncovered"]),
    }
    rng.bucket_s, rng.bucket_t = R.bucket_grid(key, start, end, TZ)
    rng.curve = [(float(start), 90.0), (float(end), 70.0)]
    nb = len(rng.bucket_t)
    its = []
    for it in items:
        it.buckets_j = [it.e_j / nb] * nb
        its.append(it)

    def secs(pred):
        return sum(s.b - s.a for s, dp in full if pred(s, dp))
    res = RangeResult(range=rng, items=its, e_full_j=E_FULL,
                      used_pct_raw=sum(s.d_pct for s, _ in full) if used is None else used,
                      on_s=secs(lambda s, dp: s.kind in ("on", "off", "uncovered") and dp == 1),
                      off_s=secs(lambda s, dp: s.kind in ("on", "off", "uncovered") and dp == 0),
                      uncovered_s=secs(lambda s, dp: s.kind == "uncovered"),
                      charger_s=secs(lambda s, dp: s.kind == "charger"),
                      gap_s=secs(lambda s, dp: s.kind == "gap"),
                      brightness_hint_pct_h=hint, model_high_segments=high, fg_known=fg_known)
    return res


def ok_range(key="since_full", **kw):
    segs = [sg("on", -9, -6, 1, 10.0, 3 * 1500 * 3.6), sg("off", -6, -1, 0, 8.0, 5 * 400 * 3.6),
            sg("on", -1, 0, 1, 12.0, 1500 * 3.6)]
    kw.setdefault("anchor", "full" if key == "since_full" else "window")
    if key == "since_full":
        kw.setdefault("anchor_t", float(NOW - 9 * H))
    return mk(key, segs, "ok", std_items(), **kw)


def report(since=None, h24=None, d7=None, rec=None, bat=None, coeffs=None, remain=Remain(h=9.24, basis_h=24)):
    rec = rec or RecState(running=True, degraded=False, since=float(NOW - 9 * H), last_write_age_s=30.0,
                          fg_log=True, clock_unsynced=False)
    bat = bat or LiveBattery(pct=70, status="discharging", plugged=False, charge_full_uah=8394000,
                             charge_full_design_uah=9000000, cycles=18)
    coeffs = coeffs or Coeffs(version=1, calibrated=False, date="2026-10-30", source="dev", path="/x/coeffs-v1.json",
                              values={"F_off": 147.0, "F_on": 330.0, "D_on": 600.0})
    return Report(now=NOW + 0.7, tz_offset_min=TZ, took_ms=12, rec=rec, battery=bat, health_pct=93, coeffs=coeffs,
                  ranges={"since_full": since or ok_range(), "24h": h24 or ok_range("24h"),
                          "7d": d7 or ok_range("7d")},
                  remain=remain,
                  diag=Diag(unexplained_median_7d=0.12345, floor_off_learned_mw=151.26, floor_off_model_mw=147.0,
                            coeff_age_days=0, ledger_bytes=1234, ledger_newest_age_s=30.4, energy_age_s=2.6,
                            segments_flagged_7d=1))


class Base(unittest.TestCase):
    def doc(self, rep):
        d = out.to_json(rep)
        self.assertEqual(C.validate(d), [])
        return d

    def kinds(self, r):
        return [b["kind"] for b in r["banners"]]


# ---------------------------------------------------------------------------------------------
# Fmt.js twins (same vectors as page/tests/fmt-test.mjs)
# ---------------------------------------------------------------------------------------------

class FmtTwins(unittest.TestCase):
    def test_dur(self):
        for s, want in ((0, "不到 1 分"), (59, "不到 1 分"), (59.99, "不到 1 分"), (60, "1 分"), (3599, "59 分"),
                        (3600, "1 小时"), (7230, "2 小时"), (7260, "2 小时 1 分"), (548999, "152 小时 29 分"),
                        (-5, "不到 1 分")):
            self.assertEqual(out.dur(s), want, s)

    def test_clocks_in_two_zones(self):
        self.assertEqual(out.clock(T_FMT, 480), "08:11")
        self.assertEqual(out.day_clock(T_FMT, 480), "30日 08:11")
        self.assertEqual(out.mmdd(T_FMT, 480), "10-30")
        self.assertEqual(out.clock(T_FMT, -300), "19:11")
        self.assertEqual(out.day_clock(T_FMT, -300), "29日 19:11")
        self.assertEqual(out.mmdd(T_FMT, -300), "10-29")
        self.assertEqual(out.clock(T_FMT, 330), "05:41")
        self.assertEqual(out.clock(T_FMT + 59.9, 480), "08:11")       # seconds never round up

    def test_rel(self):
        self.assertEqual(out.rel(T_FMT - 3600, T_FMT, 480), "今天 07:11")
        self.assertEqual(out.rel(T_FMT - DAY, T_FMT, 480), "昨天 08:11")
        self.assertEqual(out.rel(T_FMT - 2 * DAY, T_FMT, 480), "28日 08:11")
        self.assertEqual(out.rel(MID - 2400, MID, 480), "昨天 23:50")


# ---------------------------------------------------------------------------------------------
# Numbers
# ---------------------------------------------------------------------------------------------

class LargestRemainder(unittest.TestCase):
    def test_adds_up(self):
        for raws, total in (([3.3, 3.3, 3.4], 10), ([0.4, 0.4, 0.2], 1), ([5.0, 0.0, 2.5], 7), ([1e-9, 1.0], 3)):
            got = out.largest_remainder(raws, total)
            self.assertEqual(sum(got), total)
            for g, r in zip(got, raws):
                self.assertLessEqual(abs(g - r * total / sum(raws)), 1.0)

    def test_ties_go_to_the_earlier_index(self):
        self.assertEqual(out.largest_remainder([1.0, 1.0, 1.0], 2), [1, 1, 0])
        self.assertEqual(out.largest_remainder([0.5, 0.5], 1), [1, 0])

    def test_nothing_to_share(self):
        self.assertEqual(out.largest_remainder([0.0, 0.0], 5), [0, 0])
        self.assertEqual(out.largest_remainder([1.0, 2.0], 0), [0, 0])
        self.assertEqual(out.largest_remainder([], 3), [])


class Decimate(unittest.TestCase):
    def test_short_curve_untouched(self):
        pts = [(i * 60, 100 - i * 0.1) for i in range(400)]
        self.assertEqual(out.decimate(pts), pts)

    def test_straight_line_keeps_its_ends(self):
        pts = [(i * 60, 100 - i * 0.05) for i in range(1000)]
        self.assertEqual(out.decimate(pts), [pts[0], pts[-1]])

    def test_limit_ends_kept_points_and_shape(self):
        # a slow discharge with a 20-point charging spike in the middle and gap edges to keep
        pts = []
        for i in range(5000):
            p = 100 - i * 0.015 + (20 if 2500 <= i < 2520 else 0) + 0.3 * math.sin(i / 7)
            pts.append((i * 30, round(min(100.0, p), 1)))
        keep = {pts[1234][0], pts[4321][0]}
        got = out.decimate(pts, keep=keep)
        self.assertLessEqual(len(got), 400)
        self.assertGreater(len(got), 50)
        self.assertEqual(got[0], pts[0])
        self.assertEqual(got[-1], pts[-1])
        self.assertTrue(keep <= {t for t, _ in got})
        self.assertEqual([t for t, _ in got], sorted(t for t, _ in got))
        self.assertTrue(set(got) <= set(pts))
        self.assertTrue(any(2500 * 30 <= t < 2520 * 30 for t, _ in got))     # the spike survives
        # every dropped point lies near the kept polyline (RDP tolerance well under 2 % of the axis)
        xs = [t for t, _ in got]
        import bisect
        worst = 0.0
        for t, p in pts:
            j = bisect.bisect_left(xs, t)
            if xs[min(j, len(xs) - 1)] == t:
                continue
            (t0, p0), (t1, p1) = got[j - 1], got[j]
            worst = max(worst, abs(p - (p0 + (p1 - p0) * (t - t0) / (t1 - t0))))
        self.assertLess(worst, 2.0)

    def test_more_kept_points_than_room(self):
        pts = [(i, float(i % 2)) for i in range(1000)]
        got = out.decimate(pts, n_max=10, keep={t for t, _ in pts})
        self.assertEqual(len(got), 10)
        self.assertEqual((got[0], got[-1]), (pts[0], pts[-1]))


# ---------------------------------------------------------------------------------------------
# JSON v1
# ---------------------------------------------------------------------------------------------

class OkRange(Base):
    def test_valid_and_adds_up(self):
        d = self.doc(report())
        self.assertEqual(d["now"], NOW)
        self.assertEqual((d["took_ms"], d["battery"]["health_pct"], d["remain"]), (12, 93, {"h": 9.2, "basis_h": 24}))
        self.assertEqual(d["diag"]["unexplained_median_7d"], 0.123)
        self.assertEqual((d["diag"]["ledger_newest_age_s"], d["diag"]["energy_age_s"]), (30, 3))
        r = d["ranges"]["since_full"]
        self.assertEqual((r["state"], r["used_pct"], r["used_pct_raw"]), ("ok", 30, 30.0))
        self.assertEqual(sum(it["pct"] for it in r["items"]), 30)
        self.assertEqual(round(sum(it["pct_raw"] for it in r["items"]) * 100), 3000)    # exact in hundredths
        self.assertEqual(sum(c["pct"] for c in r["composition"]), 30)
        self.assertEqual([c["kind"] for c in r["composition"]],
                         ["screen", "apps", "ui", "sys", "wifi", "floor", "other"])
        self.assertEqual(r["coverage"], 1.0)
        raws = [it["pct_raw"] for it in r["items"]]
        self.assertEqual(raws, sorted(raws, reverse=True))

    def test_apps_rest_and_dropped_zero(self):
        rng = ok_range()
        # open time: the union of the members' stretches, per boot (Kate's and Okular's overlap 900 s on aaaaaaaa)
        rng.alive_iv = {"app:Kate": [("aaaaaaaa", 0.0, 1500.0)],
                        "app:Okular": [("aaaaaaaa", 600.0, 1800.0), ("bbbbbbbb", 0.0, 100.0)]}
        r = self.doc(report(since=rng))["ranges"]["since_full"]
        ids = [it["id"] for it in r["items"]]
        self.assertNotIn("app:Zero", ids)
        self.assertNotIn("app:Kate", ids)
        rest = next(it for it in r["items"] if it["kind"] == "apps_rest")
        self.assertEqual(rest["name"], "其他应用（2 个）")
        self.assertEqual(rest["icon"], "application-x-executable")
        self.assertEqual([p[0] for p in rest["parts"]], ["Kate", "Okular"])
        self.assertAlmostEqual(sum(p[1] for p in rest["parts"]), rest["pct_raw"], places=6)
        self.assertEqual(rest["explain"], out.EXPLAIN["apps_rest"])
        # bg_s = 1900 s open - 1200 s in front, not the members' 300 + 300
        self.assertEqual((rest["fg_s"], rest["bg_s"], rest["cpu_s"], rest["wake_off_n"]), (1200, 700, 240, 24))
        self.assertEqual(rest["split"]["fg"] + rest["split"]["bg"], rest["pct"])

    def test_single_small_app_stays_listed(self):
        items = [i for i in std_items() if i.name != "Okular"]
        segs = [sg("on", -9, -6, 1, 10.0, 1.0), sg("off", -6, -1, 0, 8.0, 1.0), sg("on", -1, 0, 1, 12.0, 1.0)]
        rng = mk("since_full", segs, "ok", items, anchor="full", anchor_t=float(NOW - 9 * H))
        r = self.doc(report(since=rng))["ranges"]["since_full"]
        kate = next(it for it in r["items"] if it["id"] == "app:Kate")
        self.assertLess(kate["pct_raw"], 0.5)
        self.assertFalse(any(it["kind"] == "apps_rest" for it in r["items"]))
        self.assertEqual(kate["icon"], "file:///usr/share/icons/kate.png")

    def test_app_fields(self):
        r = self.doc(report())["ranges"]["since_full"]
        ff = next(it for it in r["items"] if it["id"] == "app:Firefox")
        self.assertEqual((ff["name"], ff["icon"], ff["role"], ff["fg_s"], ff["bg_s"]),
                         ("Firefox", "firefox", "accent", 3600, 600))
        self.assertEqual(ff["windows"], [["GitHub", 3000], ["YouTube", 600]])
        self.assertEqual(ff["split"]["fg"] + ff["split"]["bg"], ff["pct"])
        self.assertAlmostEqual(ff["split_raw"]["fg"], round(ff["pct_raw"] * 0.8, 2), places=2)
        self.assertAlmostEqual(ff["split_raw"]["off"], round(ff["pct_raw"] * 0.04, 2), places=2)
        self.assertIsNone(ff["explain"])
        self.assertAlmostEqual(sum(ff["buckets"]), ff["pct_raw"], delta=0.002 * len(ff["buckets"]) + 0.02)

    def test_components(self):
        r = self.doc(report())["ranges"]["since_full"]
        by = {it["id"]: it for it in r["items"]}
        self.assertEqual(by["screen"]["name"], "屏幕")
        self.assertEqual(by["screen"]["hint"], "亮度每调低 10%，亮屏每小时约少用 0.8% 电量")
        self.assertEqual(r["brightness_hint_pct_h"], 0.8)
        self.assertEqual(by["wifi"]["name"], "Wi‑Fi（粗估）")
        self.assertEqual(by["ui"]["parts"][0][0], "窗口合成（KWin）")
        self.assertEqual(by["ui"]["cpu_s"], 50)
        self.assertIsNone(by["floor"]["cpu_s"])
        self.assertEqual(by["other"]["parts"], [["前台未知", round(20 * 30 / 8570, 2)]])
        for it in r["items"]:
            if it["kind"] not in ("app", "apps_rest"):
                self.assertEqual(it["explain"], out.EXPLAIN[it["kind"]])
                self.assertEqual(it["icon"], C.ICON_OF_KIND[it["kind"]])

    def test_titles(self):
        d = self.doc(report())
        self.assertEqual((d["ranges"]["since_full"]["title"], d["ranges"]["since_full"]["sub"]),
                         ("自上次充满", "上次充满：昨天 23:31，之后用掉 30%"))
        self.assertEqual(d["ranges"]["24h"]["sub"], "过去 24 小时用掉 30%")
        self.assertEqual(d["ranges"]["7d"]["sub"], "过去 7 天一共用掉 30%（约 0.3 次满电），充电 0 次")
        self.assertEqual(d["ranges"]["7d"]["footnote"], "估算 · 未校准")


class Partial(Base):
    def rng(self, **kw):
        segs = [sg("uncovered", -9, -6, 1, 9.0), sg("on", -6, -3, 1, 9.0, 3 * 1500 * 3.6),
                sg("off", -3, 0, 0, 3.0, 3 * 400 * 3.6)]
        items = std_items() + [comp("unrecorded", 9.0 * E_FULL / 100)]
        return mk("since_full", segs, "partial", items, anchor="full", anchor_t=float(NOW - 9 * H),
                  data_from=float(NOW - 6 * H), **kw)

    def test_unrecorded_and_coverage(self):
        r = self.doc(report(since=self.rng()))["ranges"]["since_full"]
        unrec = next(it for it in r["items"] if it["kind"] == "unrecorded")
        tot = 8570 + 9.0 * E_FULL / 100
        self.assertAlmostEqual(r["coverage"], round(1 - 9.0 * E_FULL / 100 / tot, 3))
        self.assertAlmostEqual(unrec["pct_raw"], (1 - r["coverage"]) * 21.0, delta=0.05)
        self.assertEqual(r["data_from"], NOW - 6 * H)
        self.assertEqual(r["data_from_text"], "从 " + out.day_clock(NOW - 6 * H, TZ) + " 起才有按应用的记录")
        self.assertEqual(r["composition"][-1]["kind"], "unrecorded")

    def test_degraded_banner(self):
        segs = [sg("uncovered", -9, -6, 1, 9.0, degraded=True), sg("on", -6, -3, 1, 9.0, 3 * 1500 * 3.6),
                sg("off", -3, 0, 0, 3.0, 3 * 400 * 3.6)]
        rng = mk("since_full", segs, "partial", std_items() + [comp("unrecorded", 9.0 * E_FULL / 100)],
                 anchor="full", anchor_t=float(NOW - 9 * H))
        r = self.doc(report(since=rng))["ranges"]["since_full"]
        b = next(x for x in r["banners"] if x["kind"] == "degraded")
        self.assertEqual(b["text"], "有 3 小时只按电量百分比粗算（飞行记录器没在记电流），这几段不分应用")


class NoSplit(Base):
    def test_just_full(self):
        rng = mk("since_full", [sg("on", -0.1, 0, 1, 0.0, 300.0)], "just_full", start=NOW - 360,
                 anchor="full", anchor_t=float(NOW - 360))
        r = self.doc(report(since=rng))["ranges"]["since_full"]
        self.assertEqual(r["sub"], "刚充满：" + out.clock(NOW - 360, TZ) + " 拔下")
        self.assertEqual(r["empty"], {"title": "刚充满", "text": "拔掉充电器后开始统计这一轮。", "action": "show_24h"})
        self.assertEqual((r["items"], r["composition"]), ([], []))

    def test_all_charger(self):
        bat = LiveBattery(pct=80, status="charging", plugged=True)
        rng = mk("24h", [sg("charger", -24, 0, 1)], "all_charger", anchor="window")
        rep = report(h24=rng, bat=bat, remain=None)
        r = self.doc(rep)["ranges"]["24h"]
        self.assertEqual(r["sub"], "过去 24 小时一直插着充电器")
        self.assertEqual(r["empty"]["title"], "一直插着充电器")
        self.assertIsNone(r["empty"]["action"])
        self.assertEqual(self.kinds(r), ["charger_now"])
        self.assertEqual(r["banners"][0]["text"], "正在充电")

    def test_empty_texts(self):
        # just started: data_from (or rec.since) in the text
        rng = mk("since_full", [sg("on", -0.05, 0, 1, 0.0, 100.0)], "empty", start=NOW - 900,
                 anchor="no_full")
        r = self.doc(report(since=rng))["ranges"]["since_full"]
        self.assertEqual(r["empty"]["title"], "刚开始记录")
        self.assertEqual(r["empty"]["text"], "从 " + out.day_clock(NOW - 9 * H, TZ) + " 起记各应用的用电，用一阵子再来看。")
        self.assertEqual(r["title"], "自 10-30 起（之前没有记录）")
        self.assertEqual(r["sub"], "10-30 起没充满过，用掉 0%")
        # no ledger at all
        rec = RecState(running=False, degraded=False, since=None, last_write_age_s=None, fg_log=False)
        rng = mk("since_full", [sg("uncovered", -2, 0, None, 3.0)], "empty", anchor="no_full")
        r = self.doc(report(since=rng, rec=rec))["ranges"]["since_full"]
        self.assertEqual(r["empty"]["title"], "还没有记录")
        self.assertEqual(self.kinds(r)[0], "recorder_off")
        # flightrec not integrating dominates
        rng = mk("since_full", [sg("uncovered", -2, 0, 1, 3.0, degraded=True)], "empty", anchor="no_full")
        r = self.doc(report(since=rng))["ranges"]["since_full"]
        self.assertEqual(r["empty"]["title"], "没有分项记录")
        self.assertEqual(r["banners"][0]["text"], "飞行记录器没在记电流：总耗电按电量百分比粗算，不分应用")
        self.assertEqual(r["coverage"], 0.0)

    def test_ok_without_items_becomes_empty(self):
        rng = mk("since_full", [sg("on", -2, 0, 1, 2.0, 100.0)], "ok", [comp("screen", 0.0)], anchor="full",
                 anchor_t=float(NOW - 2 * H))
        r = self.doc(report(since=rng))["ranges"]["since_full"]
        self.assertEqual((r["state"], r["items"]), ("empty", []))


class TitlesBannersFootnote(Base):
    def test_prev_round_and_mid_plugs(self):
        rng = ok_range(anchor="prev_round", anchor_t=float(NOW - 9 * H), plug_t=float(NOW - H / 2))
        bat = LiveBattery(pct=100, status="full", plugged=True)
        r = self.doc(report(since=rng, bat=bat, remain=None))["ranges"]["since_full"]
        self.assertEqual(r["title"], "上一轮")
        self.assertEqual(r["sub"], "上一轮：29日 23:31 拔下 → 30日 08:01 插上，用掉 30%")
        self.assertEqual(r["banners"][-1]["text"], "已充满 · 正在用充电器")
        rng = ok_range(mid_plugs=2)
        r = self.doc(report(since=rng))["ranges"]["since_full"]
        self.assertTrue(r["sub"].endswith("之后用掉 30%，中间插电 2 次"))

    def test_charger_texts(self):
        for status, plugged, want in (("not_charging", True, "插着充电器 · 没在充电（停在上限）"),
                                      ("discharging", True, "插着充电器")):
            bat = LiveBattery(pct=60, status=status, plugged=plugged)
            d = self.doc(report(bat=bat, remain=Remain(h=3.0)))
            self.assertIsNone(d["remain"])
            self.assertEqual(d["ranges"]["7d"]["banners"][-1]["text"], want)

    def test_banner_order_and_texts(self):
        segs = [sg("uncovered", -9, -8, 0, 2.0, degraded=True), sg("on", -6, -3, 1, 9.0, 3 * 1500 * 3.6),
                sg("off", -3, 0, 0, 3.0, 3 * 400 * 3.6, boot8="cccccccc")]
        rng = mk("since_full", segs, "partial", std_items() + [comp("unrecorded", 2.0 * E_FULL / 100)],
                 anchor="no_full", unknown_time_boots=1, fg_known=False)
        rec = RecState(running=False, degraded=True, since=float(NOW - 9 * H), last_write_age_s=4000.0,
                       fg_log=False, clock_unsynced=True)
        bat = LiveBattery(pct=60, status="charging", plugged=True)
        r = self.doc(report(since=rng, rec=rec, bat=bat, remain=None))["ranges"]["since_full"]
        self.assertEqual(self.kinds(r), ["recorder_off", "degraded", "gap", "unknown_time", "clock_unsynced",
                                         "fg_off", "charger_now"])
        texts = {b["kind"]: b["text"] for b in r["banners"]}
        self.assertEqual(texts["gap"], "有 3 小时没记录（关机或重启）")
        self.assertEqual(texts["unknown_time"], "有 1 次开机的时间不明，曲线上接在前一次后面")
        self.assertEqual(texts["fg_off"], "前台记录没开（refresh-auto 没在运行），这段分不出前台后台")
        # clock_unsynced only where the current boot (the newest segment's, cccccccc here) is in the range
        d = self.doc(report(since=rng, rec=rec, bat=bat, remain=None))
        self.assertIn("clock_unsynced", self.kinds(d["ranges"]["since_full"]))
        self.assertNotIn("clock_unsynced", self.kinds(d["ranges"]["7d"]))

    def test_footnote(self):
        c = Coeffs(version=3, calibrated=True, date="2026-11-02", source="user", path="/u/coeffs-v3.json")
        d = self.doc(report(coeffs=c, since=ok_range(high=2)))
        self.assertEqual(d["ranges"]["since_full"]["footnote"], "估算 · 11-02 校准 · 有 2 段估算偏高，已按实测压低")
        self.assertEqual(d["ranges"]["24h"]["footnote"], "估算 · 11-02 校准")
        self.assertEqual(d["coeffs"], {"version": 3, "calibrated": True, "date": "2026-11-02", "source": "user"})

    def test_24h_charges_and_7d_full_count(self):
        segs = [sg("on", -20, -10, 1, 30.0, 10.0), sg("charger", -10, -9, 1), sg("off", -9, -5, 0, 5.0, 10.0),
                sg("charger", -5, -4, 1), sg("on", -4, 0, 1, 10.0, 10.0)]
        rng = mk("24h", segs, "ok", std_items(), anchor="window", charges=2)
        r = self.doc(report(h24=rng))["ranges"]["24h"]
        self.assertEqual(r["sub"], "过去 24 小时用掉 45%，充电 2 次")
        # the count is plug-ins (Range.charges), not charger bands: a reboot on the charger splits one band in two
        rng = mk("24h", segs, "ok", std_items(), anchor="window", charges=1)
        r = self.doc(report(h24=rng))["ranges"]["24h"]
        self.assertEqual((len(r["bands"]["charger"]), r["sub"]), (2, "过去 24 小时用掉 45%，充电 1 次"))
        segs = [sg("on", -150, -10, 1, 230.0, 10.0), sg("charger", -10, -9, 1), sg("on", -9, 0, 1, 20.0, 10.0)]
        rng = mk("7d", segs, "ok", std_items(), anchor="window", charges=1)
        r = self.doc(report(d7=rng))["ranges"]["7d"]
        self.assertEqual(r["sub"], "过去 7 天一共用掉 250%（约 2.5 次满电），充电 1 次")


class Curve(Base):
    def test_long_curve_is_decimated_with_gap_edges(self):
        rng = ok_range("7d")
        start = NOW - 7 * DAY
        rng.range.curve = [(float(start + i * 300), round(90 - (i % 288) * 0.25, 1)) for i in range(7 * 288)]
        rng.range.curve[-1] = (float(NOW), rng.range.curve[-1][1])
        r = self.doc(report(d7=rng))["ranges"]["7d"]
        self.assertLessEqual(len(r["curve"]), 400)
        ts = {p[0] for p in r["curve"]}
        for a, b in r["bands"]["gap"]:
            for t in (a, b):
                if any(abs(p[0] - t) < 1 for p in rng.range.curve):
                    self.assertIn(t, ts)
        self.assertEqual(r["curve"][0][0], start)
        self.assertEqual(r["curve"][-1][0], NOW)


class Text(Base):
    def test_text_breakdown(self):
        rep = report(since=Partial().rng())
        txt = out.to_text(rep)
        self.assertIn("== 自上次充满 [since_full] state=partial", txt)
        self.assertIn("屏幕", txt)
        self.assertIn("其他应用（2 个）", txt)
        self.assertIn("→ 其他应用", txt)
        self.assertIn(" Wh ", txt)
        self.assertIn(" mW", txt)
        self.assertIn("coverage", txt)
        self.assertTrue(txt.endswith("自检：通过\n"))
        self.assertIn("剩余：约 9.2 小时（按过去一天的放电）", txt)
        self.assertIn("熄屏段功率 P25 实测 151.3 mW / 同段模型 147.0 mW", txt)
        self.assertIn("亮度提示 0.8 %/h", txt)
        self.assertIn("充电 0 次", txt)
        rng = ok_range("24h", hint=None, charges=3)
        txt = out.to_text(report(h24=rng))
        self.assertIn("亮度提示 — · 中间插电 0 · 充电 3 次", txt)
        bad = out.to_json(rep)
        bad["ranges"]["24h"]["used_pct"] += 1
        self.assertIn("自检没通过（", out.to_text(rep, doc=bad, errors=C.validate(bad)))


if __name__ == "__main__":
    unittest.main()
