"""Tests for y700_battery.model: every DESIGN section 4 formula, step terms, reconciliation and the
per-range attribution, with the expected numbers worked out by hand from coeffs-v1.json.

Scenarios reuse tests/test_ranges.py's World (types.py objects only, fixed UTC+8 clock); FakeApps
stands in for apps.AppIndex with the same four methods model.py calls.
Run: tools/venv/Scripts/python -X utf8 -I -B -m unittest discover -s linux/power/battery/report/tests -t linux/power/battery/report
"""

import math
import sys
import unittest
from fnmatch import fnmatchcase
from pathlib import Path

REPORT = Path(__file__).resolve().parents[1]
if str(REPORT) not in sys.path:
    sys.path.insert(0, str(REPORT))

from tests.test_ranges import CUR8, DAY, H, NOW, World, fr  # noqa: E402
from y700_battery import model as M  # noqa: E402
from y700_battery import ranges as R  # noqa: E402
from y700_battery.types import (KERNEL, Coeffs, Consumed, ExitFix, FgEvent, FrDelta,  # noqa: E402
                                Resolved, UnitLife)

# ledger keys of the scenarios
ROOT = ("/", 1)
USER = ("/user.slice", 2)
SYSS = ("/system.slice", 3)
INIT = ("/init.scope", 4)
NM = ("s/NetworkManager.service", 5)
APPS = ("u/app.slice", 6)
FOO = ("u/app.slice/app-foo.service", 7)
SESS = ("u/session.slice", 8)
KWIN = (M.KWIN_KEY, 9)
LOGIN = ("l/session-2.scope", 10)
BAR = ("u/app.slice/app-bar.service", 11)
STEAM = ("u/app.slice/app-steam.service", 12)

# hand values from coeffs-v1.json
K0 = 1500 * 0.5 ** 2.2                    # kappa with no busy time: little cluster at fmax/2 = 326.457 mW
G205 = 2500 * (205 / 1200) ** 2           # g(205 MHz) = 72.96 mW
E_FULL = 8.394 * 3.87 * 3600              # 8394000 uAh * 3.87 V = 116945.208 J
KWIN_LBL = "窗口合成（KWin）"
XW_LBL = "X11 兼容层（Xwayland）"
KERN_LBL = "内核与中断"


class FakeApps:
    """apps.AppIndex stand-in: two known apps, rules.json ui/sys globs and labels."""
    KNOWN = {FOO[0]: ("foo", "Foo"), BAR[0]: ("bar", "Bar"), STEAM[0]: ("steam-arm64", "Steam")}
    WINDOWS = {"steam_app_1": "示例游戏(Sample)", "steam": "Steam"}

    def __init__(self, rules):
        self.rules = rules
        self.calls = []

    def label(self, key):
        return next((n for g, n in self.rules.labels if fnmatchcase(key, g)), key)

    def resolve(self, key, alive=True, fg_classes=()):
        self.calls.append((key, alive, tuple(fg_classes)))
        for kind, globs in (("ui", self.rules.ui), ("sys", self.rules.sys)):
            if any(fnmatchcase(key, g) for g in globs):
                return Resolved(kind, self.label(key), self.label(key), None, "rule")
        if key in self.KNOWN:
            i, n = self.KNOWN[key]
            return Resolved("app", i, n, "icon-" + i, "exact")
        if key.startswith("u/app.slice/") and not alive:
            return Resolved("closed", "#closed", M.CLOSED_NAME, None, "default")
        return Resolved("sys", self.label(key), self.label(key), None, "default")

    def is_desktop_class(self, cls):
        return (cls or "") in self.rules.desktop_classes

    def is_x11(self, cls):
        return bool(cls) and any(fnmatchcase(cls, g) for g in self.rules.x11_classes)

    def window_name(self, cls, title=None):
        return self.WINDOWS.get(cls, title or cls or "")


def world(pct=50, **kw) -> World:
    w = World(pct=pct, **kw)
    w.apps = FakeApps(w.rules)
    return w


def item(res, iid):
    return next((x for x in res.items if x.id == iid), None)


class Close(unittest.TestCase):
    def close(self, got, want, rel=1e-9, msg=None):
        self.assertIsNotNone(got, msg)
        self.assertLessEqual(abs(got - want), rel * max(1.0, abs(want)), f"{msg}: {got!r} != {want!r}")


class Formulas(Close):
    def setUp(self):
        self.c = World().coeffs

    def test_backlight_piecewise_and_clamped(self):
        b = self.c.b_points
        self.assertEqual(M.backlight_mw(b, 2048), 1620)
        self.close(M.backlight_mw(b, 1638.5), 250 + 1370 * 0.75)          # 1277.5
        self.close(M.backlight_mw(b, 300), (300 - 41) / 369 * 250)       # 175.47
        self.assertEqual((M.backlight_mw(b, 20), M.backlight_mw(b, 41), M.backlight_mw(b, 5000)), (0, 0, 3370))

    def test_cpu_gpu_wake(self):
        c = self.c
        self.close(M.cpu_mw(c, 0, 3628.8), 1500)
        self.close(M.cpu_mw(c, 1, 2304), 3000 * 0.5 ** 2.2)              # 652.9 mW
        cl = [(1000, 18144000, 10000), (3000, 46080000, 10000)]          # 1814.4 MHz little, 4608 big
        self.close(M.kappa_mw(c, cl), (1000 * K0 + 3000 * 3000) / 4000)
        self.close(M.kappa_mw(c, []), K0)
        self.close(M.kappa_mw(c, [(0, 0, 10000), (0, 0, 10000)]), K0)
        self.close(M.gpu_mw(c, 600), 625)
        self.close(M.gpu_mj(c, 2_000_000_000, 1_200_000_000), 1250)       # 2 s at 600 MHz
        self.assertEqual(M.gpu_mj(c, 0, 5), 0.0)
        self.close(M.wake_mw(c, 130), 150 * (1 - math.exp(-1)))         # 94.82 mW
        self.assertEqual(M.wake_mw(c, 0), 0.0)
        self.close(M.wake_mw(c, 1e6), 150)

    def test_coeff_defaults_when_a_key_is_missing(self):
        c = Coeffs(version=1, calibrated=False, date=None, source="dev", path="x")
        self.assertEqual((M.coeff(c, "F_off"), M.coeff(c, "R0")), (147.0, 130.0))
        self.assertEqual(M.backlight_mw(c.b_points, 2048), 1620)

    def test_reconcile_three_branches(self):
        self.assertEqual(M.reconcile(1000, 300, 500), (1.0, 1.0, 200, False))   # other = E - Fix - Soft
        self.assertEqual(M.reconcile(1000, 600, 800), (1.0, 0.5, 0.0, False))   # lambda 0.5 is not < 0.5
        self.assertEqual(M.reconcile(1000, 600, 1000), (1.0, 0.4, 0.0, True))   # lambda 0.4 -> 模型偏高
        self.assertEqual(M.reconcile(1000, 1500, 500), (0.5, 0.5, 0.0, True))   # Fix > E: scale both
        self.assertEqual(M.reconcile(0, 0, 0), (1.0, 1.0, 0, False))

    def test_e_full_and_brightness_hint(self):
        w = World()
        inp = w.inputs()
        self.close(M.e_full_j(inp), E_FULL)
        # mean level 2048: B(2048) - B(1638.5) = 342.5 mW -> 1233 J/h of 116945 J = 1.05 %/h
        h = M.brightness_hint(inp, 2048)
        self.close(h, 342.5 * 3.6 / E_FULL * 100)
        self.assertEqual(round(h, 2), 1.05)
        self.close(M.brightness_hint(inp, 300), (300 - 41) / 369 * 250 * 3.6 / E_FULL * 100)
        w.src.battery.charge_full_uah = None
        self.assertEqual(M.e_full_j(w.inputs()), 34 * 3600)

    def test_percentile(self):
        self.assertEqual(M.percentile([4, 1, 3, 2], 0.25), 1.75)
        self.assertEqual(M.percentile([4, 1, 3, 2], 0.5), 2.5)
        self.assertEqual(M.percentile([7], 0.25), 7)
        self.assertIsNone(M.percentile([], 0.5))


def terms_world(fg=None, pkt=5000):
    """One 600 s screen-on step (f = 0.8, mean backlight 2048, both clusters busy) with every kind of
    cgroup in it, then a 1800 s screen-off step."""
    w = world()
    w.rates(NOW - 4 * H, NOW, 2).charge(NOW - 4 * H, 60, 2)
    b = w.boot()
    t0 = NOW - H
    on = w.step(b, t0, t0 + 600, 1, FrDelta(ton=600000, dton=480000, don=1_500_000, bl=2048 * 600000),
                cl=[(1000, 18144000, 10000), (3000, 46080000, 10000)],
                cpu={ROOT: 200_000_000, USER: 120_000_000, SYSS: 50_000_000, INIT: 5_000_000,
                     NM: 30_000_000, APPS: 100_000_000, FOO: 60_000_000, SESS: 15_000_000,
                     KWIN: 12_000_000, LOGIN: 1_000_000},
                gpu={FOO: (2_000_000_000, 1_200_000_000), KWIN: (1_000_000_000, 300_000_000),
                     BAR: (1_000_000_000, 600_000_000)},
                x_ticks=300, pkt=pkt)
    off = w.step(b, t0 + 600, t0 + 2400, 0, FrDelta(toff=1_800_000, dtoff=1_800_000, doff=360_000),
                 ctx=1800 * 130, cpu={FOO: 3_000_000}, wk={KERNEL: 300, FOO: 100})
    off.wk_since_m = off.ma
    w.lives[CUR8][FOO] = UnitLife(FOO, CUR8, on.ma, off.mb)
    w.snap(b, t0, cg={FOO: 1_000_000_000})
    w.snap(b, t0 + 600, cg={FOO: 1_060_000_000})
    if fg is not None:
        b.fg.append(FgEvent(m=on.ma, kind="fg", pid=fg[0], key=FOO[0] if fg[0] else None, cls=fg[1],
                            new_usage=1_000_000_000 if fg[0] else None))
    return w, on, off


class StepTerms(Close):
    def test_screen_on_step_every_term(self):
        w, on, _ = terms_world()
        inp = w.inputs()
        t = M._model(inp).terms(CUR8, 0)
        K = (1000 * K0 + 3000 * 3000) / 4000
        f = 0.8
        self.assertEqual(t.e, 1_500_000)
        self.close(t.F, 330 * 480)                          # F_on * discharging on-time
        self.close(t.S, 480 * (600 + 1620))                 # Don * (D_on + B(2048))
        want = {
            ("sys", KERN_LBL): f * K * 25,                  # / - user - system - init = 200-120-50-5
            ("sys", "其他系统服务"): f * K * 20,             # system.slice - s/* = 50 - 30
            ("sys", "其他后台服务"): f * K * 4,              # user.slice - (app 100 + session 15 + l/ 1)
            (M.CLOSED_ID, None): f * K * 40,                # app.slice - its known children
            ("sys", "桌面后台服务"): f * K * 3,              # session.slice - KWin
            ("sys", "systemd"): f * K * 5,
            ("sys", "网络（NetworkManager、wpa_supplicant）"): f * K * 30,
            ("sys", "登录会话"): f * K * 1,
            ("app:foo", None): f * (K * 60 + 1250),         # CPU + 2 s of GPU at 600 MHz
            ("app:bar", None): f * 625,                     # GPU only: 1 s at 600 MHz
            ("ui", KWIN_LBL): f * K * (12 - 3) + 0.05 * 480 * G205,
            ("other", M.FG_UNKNOWN_PART): f * (K * 3 + 156.25),   # Xwayland, foreground unknown
            ("wifi", None): f * 0.2 * 5000,
        }
        self.assertEqual(set(t.soft), set(want))
        for k, v in want.items():
            self.close(t.soft[k][0], v, msg=str(k))
            self.assertEqual(t.soft[k][1], 0.0, k)          # nothing known to be foreground
        self.close(t.cpu["sys"], 25 + 20 + 4 + 3 + 5 + 30 + 1)
        self.close(t.cpu["app:foo"], 60)
        self.close(t.cpu["ui"], 9)
        self.assertEqual((t.gpu["app:foo"], t.gpu["app:bar"]), (2.0, 1.0))
        self.close(t.gpu["ui"], 0.05 * 600)                 # busy s over the on-time; Don only in the energy
        self.assertEqual((t.off, t.wake, t.wk_fallback), (False, {}, False))

    def test_wifi_capped(self):
        w, _, _ = terms_world(pkt=2_000_000)
        t = M._model(w.inputs()).terms(CUR8, 0)
        self.close(t.soft[("wifi", None)][0], 0.8 * 300 * 600)     # 0.2 * 2e6 = 400 J > 300 mW * 600 s

    def test_xwayland_goes_to_the_foreground_x11_app(self):
        w, _, _ = terms_world(fg=(100, "steam"))
        t = M._model(w.inputs()).terms(CUR8, 0)
        K = (1000 * K0 + 3000 * 3000) / 4000
        xw = 0.8 * (K * 3 + 156.25)
        app = 0.8 * (K * 60 + 1250)
        e, fg = t.soft[("app:foo", None)]
        self.close(e, app + xw)
        self.close(fg, app + xw)                            # all its step CPU was in the foreground
        self.assertNotIn(("other", M.FG_UNKNOWN_PART), t.soft)
        self.close(t.cpu["app:foo"], 63)
        self.assertEqual(t.gpu["app:foo"], 3.0)             # its 2 s + KWin's 1 s

    def test_xwayland_on_the_desktop_is_ui(self):
        w, _, _ = terms_world(fg=(0, ""))
        t = M._model(w.inputs()).terms(CUR8, 0)
        K = (1000 * K0 + 3000 * 3000) / 4000
        self.close(t.soft[("ui", XW_LBL)][0], 0.8 * (K * 3 + 156.25))
        self.close(t.cpu["ui"], 9 + 3)
        self.assertEqual(t.soft[("app:foo", None)][1], 0.0)  # foo was not foreground

    def test_screen_off_wake_split_by_wk(self):
        w, _, off = terms_world()
        t = M._model(w.inputs()).terms(CUR8, 1)
        W = 150 * (1 - math.exp(-1)) * 1800                 # R = 234000 / 1800 = 130 /s
        self.assertTrue(t.off)
        self.close(t.F, 147 * 1800)
        self.assertEqual(t.S, 0.0)
        self.close(t.soft[("sys", KERN_LBL)][0], W * 300 / 400)
        self.close(t.soft[("app:foo", None)][0], K0 * 3 + W * 100 / 400)
        self.assertEqual(t.soft[("app:foo", None)][1], 0.0)  # screen off: never foreground
        self.assertEqual(t.wake, {"sys": 300.0, "app:foo": 100.0})
        self.assertFalse(t.wk_fallback)

    def test_screen_off_without_wk_splits_by_cpu(self):
        w, _, off = terms_world()
        off.wk, off.wk_since_m = None, None
        off.cpu = {FOO: 3_000_000, NM: 1_000_000}
        t = M._model(w.inputs()).terms(CUR8, 1)
        W = 150 * (1 - math.exp(-1)) * 1800
        self.assertTrue(t.wk_fallback)
        self.close(t.soft[("app:foo", None)][0], K0 * 3 + W * 3 / 4)
        self.close(t.soft[("sys", "网络（NetworkManager、wpa_supplicant）")][0], K0 * 1 + W / 4)
        self.assertEqual(t.wake, {})
        off.cpu = {}
        t = M._model(w.inputs()).terms(CUR8, 1)
        self.assertEqual(set(t.soft), {("sys", KERN_LBL)})  # no CPU at all: the kernel
        self.close(t.soft[("sys", KERN_LBL)][0], W)

    def test_wk_written_later_covers_earlier_steps(self):
        w = world()
        w.rates(NOW - 4 * H, NOW, 2).charge(NOW - 4 * H, 60, 2)
        b = w.boot()
        t0 = NOW - H
        a = w.step(b, t0, t0 + 600, 0, fr(off_s=600, p_mw=200))
        c = w.step(b, t0 + 600, t0 + 1200, 0, fr(off_s=600, p_mw=200), wk={KERNEL: 60})
        c.wk_since_m = a.ma
        d = w.step(b, t0 + 1200, t0 + 1800, 0, fr(off_s=600, p_mw=200), wk={KERNEL: 10})
        d.wk_since_m = d.ma + 100                           # does not reach back to its own start
        m = M._model(w.inputs())
        self.assertEqual([m.cover(CUR8, i) for i in range(3)], [1, 1, None])
        self.assertEqual(m.terms(CUR8, 0).wake, {"sys": 30.0})   # 600 s of the 1200 s the counts cover
        self.assertTrue(m.terms(CUR8, 2).wk_fallback)

    def test_exit_fix_adds_to_the_step_holding_the_exit(self):
        w, on, _ = terms_world()
        cons = Consumed(unit="app-foo.service", cpu_usec=0, boot8=CUR8, m=0.0, w=0.0)
        w.fixes += [ExitFix(cons, FOO, FOO[0], CUR8, on.ma + 100, 5_000_000),
                    ExitFix(cons, None, "u/app.slice/app-gone.service", CUR8, on.ma + 200, 2_000_000),
                    ExitFix(cons, FOO, FOO[0], CUR8, NOW - 1, 9_000_000)]       # after the last snapshot
        t = M._model(w.inputs()).terms(CUR8, 0)
        K = (1000 * K0 + 3000 * 3000) / 4000
        self.close(t.soft[("app:foo", None)][0], 0.8 * (K * 65 + 1250))
        # never seen by the ledger: (key, -1), no life -> gone -> 已关闭的程序. app.slice's own counter
        # already holds every dead child's CPU, so both fixes come out of its leftover:
        # rest 100 - 65 - 2 = 33, plus the gone unit's 2
        self.close(t.soft[(M.CLOSED_ID, None)][0], 0.8 * K * (33 + 2))


class Foreground(Close):
    def make(self):
        w = world()
        w.rates(NOW - 4 * H, NOW, 2).charge(NOW - 4 * H, 60, 2)
        b = w.boot()
        st = w.step(b, NOW - 2000, NOW - 1000, 1, fr(on_s=1000, p_mw=1000))
        w.lives[CUR8][FOO] = UnitLife(FOO, CUR8, st.ma, st.mb)
        return w, b, st.ma

    def test_unknown_before_first_line_after_stop_and_after_refresh_auto_went_away(self):
        w, b, m0 = self.make()
        b.fg += [FgEvent(m=m0 + 100, kind="fg", pid=7, key=FOO[0], cls="foo"),
                 FgEvent(m=m0 + 500, kind="stop"),
                 FgEvent(m=m0 + 600, kind="start"),
                 FgEvent(m=m0 + 700, kind="fg", pid=0, cls="plasmashell")]
        w.lives[CUR8][(M.REFRESH_KEY, 20)] = UnitLife((M.REFRESH_KEY, 20), CUR8, m0, m0 + 300, gone_m=m0 + 300)
        got = [(f.a - m0, f.b - m0, f.what) for f in M._model(w.inputs()).fg(CUR8)]
        self.assertEqual(got, [(0, 100, "unknown"), (100, 300, "app"), (300, 500, "unknown"),
                               (500, 600, "unknown"), (600, 700, "unknown"), (700, 2000, "desktop")])

    def test_fg_classes_most_foreground_first(self):
        w, b, m0 = self.make()
        b.fg += [FgEvent(m=m0, kind="fg", pid=7, key=FOO[0], cls="steam"),
                 FgEvent(m=m0 + 100, kind="fg", pid=7, key=FOO[0], cls="steam_app_1"),
                 FgEvent(m=m0 + 900, kind="fg", pid=0, cls="")]
        m = M._model(w.inputs())
        self.assertEqual(m.fg_classes, {FOO[0]: ["steam_app_1", "steam"]})
        m.item_of(FOO, CUR8)
        self.assertEqual(w.apps.calls, [(FOO[0], True, ("steam_app_1", "steam"))])


def steam_world(fixes=()):
    """600 s screen-on with Steam's game (200 s), Steam itself (100 s), then the desktop (300 s);
    the game used 30 + 10 of Steam's 60 CPU s while foreground. 100 s uncovered tail."""
    w = world(pct=50)
    t0 = NOW - 700
    w.rates(t0, NOW, 2, every=300).charge(t0, 51, 2)
    b = w.boot()
    st = w.step(b, t0, t0 + 600, 1, fr(on_s=600, p_mw=1500), cpu={STEAM: 60_000_000, KWIN: 10_000_000},
                x_ticks=600)
    m0 = st.ma
    w.snap(b, t0, cg={STEAM: 1_000_000_000})
    w.snap(b, t0 + 600, cg={STEAM: 1_060_000_000})
    w.lives[CUR8][STEAM] = UnitLife(STEAM, CUR8, m0, m0 + 600)
    b.fg += [FgEvent(m=m0, kind="fg", pid=100, key=STEAM[0], cls="steam_app_1", new_usage=1_000_000_000),
             FgEvent(m=m0 + 200, kind="fg", pid=100, key=STEAM[0], cls="steam", new_usage=1_030_000_000,
                     prev_usage=1_030_000_000),
             FgEvent(m=m0 + 300, kind="fg", pid=0, cls="", prev_usage=1_040_000_000)]
    cons = Consumed(unit="app-steam.service", cpu_usec=0, boot8=CUR8, m=0.0, w=0.0)
    for m_exit, extra in fixes:
        w.fixes.append(ExitFix(cons, STEAM, STEAM[0], CUR8, m0 + m_exit, extra))
    return w


class Attribution(Close):
    def test_screen_floor_app_ui_other_and_buckets(self):
        """24h: gap until -2 h, 1 h screen-on at 4 W / backlight 2048, 59 min off at 150 mW, 1 min tail."""
        w = world(pct=50)
        w.rates(NOW - 2 * H, NOW, 2).charge(NOW - 2 * H, 60, 2)
        b = w.boot()
        s0 = w.step(b, NOW - 2 * H, NOW - H, 1, fr(on_s=H, p_mw=4000, level=2048), cpu={FOO: 600_000_000})
        s1 = w.step(b, NOW - H, NOW - 60, 0, fr(off_s=3540, p_mw=150))
        w.lives[CUR8][FOO] = UnitLife(FOO, CUR8, s0.ma, s1.mb)
        inp = w.inputs()
        rng = R.build(inp)["24h"]
        res, det = M.attribute_detail(rng, inp)
        self.assertEqual(rng.state, "ok")
        self.assertEqual((res.on_s, res.off_s, res.uncovered_s, res.charger_s, res.gap_s),
                         (3600, 3600, 60, 0, 22 * H))
        self.close(res.used_pct_raw, 10.0)                  # 60 % -> 50 %, all of it discharge
        self.assertEqual(res.used_pct_basis, "pct")
        self.close(res.e_full_j, E_FULL)
        screen = 3600 * (600 + 1620) / 1000
        floor_on, floor_off = 330 * 3.6, 147 * 3.54
        app = K0 * 600 / 1000
        ui = 0.05 * 3600 * G205 / 1000
        other = (14400 - floor_on - screen - app - ui) + (531 - floor_off)
        got = {x.id: x.e_j for x in res.items}
        want = {"screen": screen, "floor": floor_on + floor_off, "app:foo": app, "ui": ui, "other": other}
        self.assertEqual(set(got), set(want))
        for k, v in want.items():
            self.close(got[k], v, msg=k)
        self.close(sum(got.values()), 14400 + 531)          # every measured J lands somewhere
        self.assertEqual([x.id for x in res.items], ["screen", "other", "floor", "app:foo", "ui"])
        # buckets: 08:00 local is bt[23] = NOW - 1860; the on hour [-7200, -3600] falls 1740 s into
        # bt[21] and 1860 s into bt[22]
        scr = item(res, "screen")
        self.close(scr.buckets_j[21], screen * 1740 / 3600)
        self.close(scr.buckets_j[22], screen * 1860 / 3600)
        self.assertEqual(sum(1 for v in scr.buckets_j if v), 2)
        fl = item(res, "floor")
        self.close(fl.buckets_j[23], floor_off * 1800 / 3540)
        for x in res.items:
            self.assertEqual(len(x.buckets_j), 24)
            self.close(sum(x.buckets_j), x.e_j, msg=x.id)
        a = item(res, "app:foo")
        self.assertEqual((a.kind, a.name, a.icon), ("app", "Foo", "icon-foo"))
        self.close(a.bg_j, app)
        self.assertEqual((a.fg_j, a.off_j, a.fg_s, a.bg_s, a.cpu_s, a.gpu_s, a.wake_off_n, a.windows),
                         (0.0, 0.0, 0.0, 7140.0, 600.0, None, None, []))
        self.assertFalse(res.fg_known)                      # an hour on screen without an fg line
        self.assertEqual(a.note, M.FG_UNKNOWN_NOTE)
        u = item(res, "ui")
        self.assertEqual((u.parts[0][0], u.cpu_s, u.gpu_s), (KWIN_LBL, None, 180.0))
        self.close(res.brightness_hint_pct_h, 342.5 * 3.6 / E_FULL * 100)
        self.close(res.unexplained_frac, other / (14400 + 531))
        self.assertEqual((res.model_high_segments, res.learned_floor_off_mw), (0, None))
        self.assertEqual([(g.segments, g.flagged) for g in det], [(1, False), (1, False)])

    def test_foreground_background_windows_and_steam(self):
        w = steam_world()
        inp = w.inputs()
        rng = R.build(inp)["24h"]
        res = M.attribute(rng, inp)
        self.assertEqual(rng.state, "ok")
        self.assertTrue(res.fg_known)
        s = item(res, "app:steam-arm64")
        # Steam: 60 CPU s, 40 of them foreground; Xwayland's 6 s: 300 of 600 s an X11 window was front
        self.close(s.e_j, (60 + 3) * K0 / 1000)
        self.close(s.fg_j, (40 + 3) * K0 / 1000)
        self.close(s.bg_j, 20 * K0 / 1000)
        self.assertEqual((s.off_j, s.fg_s, s.bg_s, s.cpu_s), (0.0, 300.0, 300.0, 63.0))
        self.assertEqual(s.windows, [("示例游戏(Sample)", 200.0), ("Steam", 100.0)])
        self.assertEqual(s.note, M.STEAM_NOTE)
        u = item(res, "ui")
        self.assertEqual([p for p, _ in u.parts], [KWIN_LBL, XW_LBL])
        self.close(dict(u.parts)[KWIN_LBL], (4 * K0 + 30 * G205) / 1000)    # KWin 10 s minus Xwayland 6 s
        self.close(dict(u.parts)[XW_LBL], 3 * K0 / 1000)
        self.assertEqual((u.cpu_s, u.gpu_s), (7.0, 30.0))
        # D = 51 -> 50 % = 1 < 3: percentages from energy; the 100 s tail counts as its % drop
        self.assertEqual(res.used_pct_basis, "energy")
        self.close(res.used_pct_raw, 900 / E_FULL * 100 + 1 / 7, rel=1e-6)
        self.assertIsNone(item(res, "unrecorded"))           # state ok: no unrecorded row

    def test_exit_fix_and_alive_time(self):
        w = steam_world(fixes=[(500, 5_000_000)])
        inp = w.inputs()
        res = M.attribute(R.build(inp)["24h"], inp)
        s = item(res, "app:steam-arm64")
        self.close(s.e_j, (65 + 3) * K0 / 1000)
        self.close(s.fg_j, (65 * 40 / 65 + 3) * K0 / 1000)  # fg CPU 40 of 65 s
        self.assertEqual((s.fg_s, s.bg_s), (300.0, 200.0))   # exited at +500 s

    def test_short_screen_on_reconciled_with_nearest_and_model_high(self):
        """A on 30 min at 3 W, off 30 min at 100 mW (< F_off: 模型偏高), B on 200 s at 100 mW,
        off 1600 s at 200 mW with 2 s of foo CPU."""
        def make(merge_s=300):
            w = world(pct=55)
            t0 = NOW - 5500
            w.rates(t0, NOW, 2, every=600).charge(t0, 60, 2)
            b = w.boot()
            w.step(b, t0, t0 + 1800, 1, fr(on_s=1800, p_mw=3000))
            w.step(b, t0 + 1800, t0 + 3600, 0, fr(off_s=1800, p_mw=100))
            w.step(b, t0 + 3600, t0 + 3800, 1, fr(on_s=200, p_mw=100))
            w.step(b, t0 + 3800, t0 + 5400, 0, fr(off_s=1600, p_mw=200), cpu={FOO: 2_000_000})
            w.rules.short_on_merge_s = merge_s
            inp = w.inputs()
            return inp, M.attribute_detail(R.build(inp)["24h"], inp)
        inp, (res, det) = make()
        self.assertEqual([(g.segments, g.flagged) for g in det], [(2, False), (1, True), (1, False)])
        g = det[0]
        self.close(g.e_j, 5420)
        self.close(g.fix_j, 660 + 1200)                     # F_on * 2000 s + D_on * 2000 s (backlight 0)
        self.close(g.soft_j, 0.05 * 2000 * G205 / 1000)
        self.close(g.other_j, 5420 - 1860 - 0.05 * 2000 * G205 / 1000)
        self.close(det[1].scale_fix, 180000 / 264600)        # E / Fix
        self.assertEqual(res.model_high_segments, 1)
        self.close(item(res, "floor").e_j, 594 + 66 + 180 + 235.2)
        self.close(item(res, "screen").e_j, 1200)
        self.close(item(res, "other").e_j, g.other_j + (320 - 235.2 - 2 * K0 / 1000))
        foo = item(res, "app:foo")
        self.close(foo.e_j, 2 * K0 / 1000)
        self.close(foo.off_j, foo.e_j)                       # screen-off CPU is background, off
        self.assertEqual((foo.fg_j, foo.fg_s), (0.0, 0.0))
        self.close(res.used_pct_raw, 5.0)
        # without the merge the 200 s segment is reconciled alone: Fix 186 J > E 20 J
        inp, (res, det) = make(merge_s=100)
        self.assertEqual([(g.segments, g.flagged) for g in det], [(1, False), (1, True), (1, True), (1, False)])
        self.assertEqual(res.model_high_segments, 2)

    def test_partial_gets_unrecorded_from_the_drop(self):
        w = world(pct=50)
        w.rates(NOW - 10 * H, NOW, 2).charge(NOW - 10 * H, 80, 2)       # 3 %/h
        b = w.boot()
        w.step(b, NOW - 5 * H, NOW - 4 * H, 1, cov=False)
        w.step(b, NOW - 4 * H, NOW - H, 0, fr(off_s=3 * H, p_mw=150))
        inp = w.inputs()
        rng = R.build(inp)["24h"]
        res = M.attribute(rng, inp)
        self.assertEqual(rng.state, "partial")
        u = item(res, "unrecorded")
        self.close(u.e_j, 21 * E_FULL / 100, rel=1e-6)      # 7 h uncovered at 3 %/h
        self.close(sum(u.buckets_j), u.e_j)
        self.assertEqual((res.on_s, res.off_s, res.uncovered_s), (H, 3 * H + H, 7 * H))
        self.close(res.used_pct_raw, 30.0, rel=1e-6)

    def test_unrecorded_floor_when_the_percent_did_not_move(self):
        w = world(pct=50)
        w.rates(NOW - 2 * H, NOW, 2)                        # no charge points: % flat at sysfs 50
        b = w.boot()
        w.step(b, NOW - H, NOW - 60, 0, fr(off_s=3540, p_mw=200))
        inp = w.inputs()
        rng = R.build(inp)["24h"]
        res = M.attribute(rng, inp)
        self.assertEqual(rng.state, "partial")              # [-2 h, -1 h] has no ledger
        unrec = (3600 + 60) * 147 / 1000                     # F_off * s as a lower bound
        self.close(item(res, "unrecorded").e_j, unrec)
        self.assertEqual(res.used_pct_basis, "energy")
        self.close(res.used_pct_raw, (708 + unrec) / E_FULL * 100)

    def test_no_split_states_have_no_items(self):
        w = world(pct=80, status="not_charging")
        w.rates(NOW - 2 * DAY, NOW, 5).charge(NOW - 2 * DAY, 80, 5)
        inp = w.inputs()
        rng = R.build(inp)["24h"]
        res = M.attribute(rng, inp)
        self.assertEqual((rng.state, res.items, res.charger_s), ("all_charger", [], DAY))

    def test_step_half_on_the_charger_counts_only_its_unplugged_share(self):
        """Unplug at t inside a 1800 s screen-off step that sat on the charger its first 1500 s (10-31 on the
        tablet: Steam 247 s / 2.0 M wakeups since full where ~215 s / 1.62 M were right). The energy deltas only
        run while discharging, but CPU s and wakeups were counted over all 1800 s: 300 / 1800 of them are ours."""
        w = world(pct=90)
        t = NOW - 2 * H
        w.rates(NOW - 4 * H, t - 600, 1).rates(t - 600, t, 4).rates(t, NOW, 2)
        w.charge(NOW - 4 * H, 80, 1).charge(t - 600, 100, 4).charge(t + 60, 100, 2)
        b = w.boot()
        s0 = w.step(b, t - 1500, t + 300, 0, FrDelta(toff=1_800_000, dtoff=300_000, doff=60_000,
                                                     tchg=1_500_000, chg=150_000),
                    cpu={FOO: 18_000_000}, wk={FOO: 1800})
        s1 = w.step(b, t + 300, NOW, 0, fr(off_s=6600, p_mw=200), cpu={FOO: 66_000_000}, wk={FOO: 6600})
        s0.wk_since_m, s1.wk_since_m = s0.ma, s1.ma
        w.lives[CUR8][FOO] = UnitLife(FOO, CUR8, s0.ma, s1.mb)
        inp = w.inputs()
        rngs = R.build(inp)
        self.assertEqual((rngs["since_full"].anchor, rngs["since_full"].start), ("full", t))
        for key in ("since_full", "24h"):
            res = M.attribute(rngs[key], inp)
            a = item(res, "app:foo")
            self.close(a.cpu_s, 18 * 300 / 1800 + 66, msg=key)
            self.close(a.wake_off_n, 1800 * 300 / 1800 + 6600, msg=key)
            self.close(a.e_j, K0 * a.cpu_s / 1000, msg=key)  # no ctx -> W = 0: CPU energy agrees with CPU s


class LearnedFloorAndDiag(Close):
    def make(self):
        w = world(pct=50)
        t0 = NOW - 5 * H - 100
        w.rates(t0, NOW, 2).charge(t0, 60, 2)
        b = w.boot()
        for k, p in enumerate((150, 160, 170, 180, 200)):
            w.step(b, t0 + k * H, t0 + (k + 1) * H, 0, fr(off_s=H, p_mw=p))
        w.led.bytes = 12345
        return w

    def test_floor_p25_and_diag(self):
        w = self.make()
        inp = w.inputs()
        rngs = R.build(inp)
        res = {k: M.attribute(r, inp) for k, r in rngs.items()}
        self.close(res["7d"].learned_floor_off_mw, 160)     # P25 of 150..200 mW
        d = M.diag(inp, res)
        # other / E per hour: (E - 529.2 J) / E for 150, 160, 170, 180, 200 mW -> median at 170 mW
        self.close(d.unexplained_median_7d, (612 - 529.2) / 612)
        self.assertEqual((d.floor_off_learned_mw, d.floor_off_model_mw), (res["7d"].learned_floor_off_mw, 147.0))
        self.assertEqual((d.coeff_age_days, d.ledger_bytes, d.segments_flagged_7d), (0, 12345, 0))
        self.close(d.ledger_newest_age_s, 100)
        self.assertIsNone(d.energy_age_s)

    def test_model_floor_is_the_model_on_the_same_segments(self):
        # what the model says for those screen-off segments before reconciliation: F_off + W at 130 wakeups/s
        # (A * (1 - 1/e)), ~95 mW over F_off alone, which a calm night measures every time
        w = world(pct=50)
        t0 = NOW - 5 * H - 100
        w.rates(t0, NOW, 2).charge(t0, 60, 2)
        b = w.boot()
        for k, p in enumerate((150, 300, 320, 340, 400)):
            w.step(b, t0 + k * H, t0 + (k + 1) * H, 0, fr(off_s=H, p_mw=p), ctx=130 * H)
        inp = w.inputs()
        res = {k: M.attribute(r, inp) for k, r in R.build(inp).items()}
        self.close(res["7d"].learned_floor_off_mw, 300, 1e-6)
        self.close(res["7d"].model_floor_off_mw, 147 + 150 * (1 - math.exp(-1)), 1e-6)
        d = M.diag(inp, res)
        self.assertEqual((d.floor_off_learned_mw, d.floor_off_model_mw),
                         (res["7d"].learned_floor_off_mw, res["7d"].model_floor_off_mw))
        # fewer than 4 segments of >= 20 min: nothing learned, the model side falls back to F_off
        w = world(pct=50)
        w.rates(t0, NOW, 2).charge(t0, 60, 2)
        b = w.boot()
        w.step(b, t0, t0 + 3 * H, 0, fr(off_s=3 * H, p_mw=300), ctx=390 * H)
        inp = w.inputs()
        res = {k: M.attribute(r, inp) for k, r in R.build(inp).items()}
        self.assertEqual((res["7d"].learned_floor_off_mw, res["7d"].model_floor_off_mw), (None, None))
        self.assertEqual(M.diag(inp, res).floor_off_model_mw, 147.0)

    def test_diag_coeff_age_in_local_days_and_energy_age(self):
        w = World(now=NOW + 16 * H)        # 2026-10-31 00:31 local, still 10-30 in UTC
        w.coeffs.date = "2026-10-20"
        w.src.energy = "v1 boot=0123abcd t=1234567890 don=5 doff=7"
        w.src.mono_now = 1234600.0
        d = M.diag(w.inputs(), {})
        self.assertEqual((d.coeff_age_days, d.segments_flagged_7d, d.unexplained_median_7d), (11, 0, None))
        self.close(d.energy_age_s, 1234600.0 - 1234567.890)
        self.assertIsNone(d.ledger_newest_age_s)
        w.src.energy_age_s = 5.0
        self.assertEqual(M.diag(w.inputs(), {}).energy_age_s, 5.0)


class RemainTime(Close):
    def test_mean_of_the_last_day_skips_charger_and_gap(self):
        w = World(pct=78)
        w.rates(NOW - 6 * H, NOW - 2 * H, 2).rates(NOW - 2 * H, NOW - H, 1).rates(NOW - H, NOW, 2)
        w.charge(NOW - 5 * H, 70, 2).charge(NOW - 2 * H, 64, 1).charge(NOW - H, 80, 2)
        r = M.remain(w.inputs())
        # before -6 h nothing is known (gap), [-2 h, -1 h] plugged: [-6 h, -2 h] 70 -> 64 and [-1 h, now]
        # 80 -> 78, 8 % in 5 h of discharge -> 78 / 1.6 %/h
        self.close(r.h, 48.75)
        self.assertEqual(r.basis_h, 24)

    def test_only_the_last_24_hours(self):
        w = World(pct=50)
        w.rates(NOW - 30 * H, NOW, 2).charge(NOW - 30 * H, 100, 2).charge(NOW - DAY, 70, 2)
        # 20 % in the 24 h window (the 30 % fall before it does not count) -> 50 / (20 / 24)
        self.close(M.remain(w.inputs()).h, 60.0)

    def test_none_when_plugged_too_little_or_flat(self):
        w = World(pct=78, status="charging")
        w.rates(NOW - 6 * H, NOW, 1).charge(NOW - 6 * H, 50, 1)
        self.assertIsNone(M.remain(w.inputs()))
        w = World(pct=78)
        w.rates(NOW - 6 * H, NOW - 3000, 1).rates(NOW - 3000, NOW, 2).charge(NOW - 3000, 80, 2)
        self.assertIsNone(M.remain(w.inputs()))                # 50 min of discharge < 1 h
        w = World(pct=78)
        w.rates(NOW - 6 * H, NOW, 2)                           # no charge points: the % never moved
        self.assertIsNone(M.remain(w.inputs()))


if __name__ == "__main__":
    unittest.main()
