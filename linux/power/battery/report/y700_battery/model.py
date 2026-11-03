"""Attribution model and reconciliation (DESIGN.md section 4), per range: energies in J.

Pipeline per Range (ranges.build made the segments):
- every itemised segment (kind on/off) takes its steps' terms weighted by ranges.step_weight (the CPU / GPU s
  and wakeup counts with counted=True: they ran the whole step, plugged part included);
- terms per step: Fix = F + S (floor, screen), Soft = apps, KWin, Xwayland, kernel, cgroup
  leftovers, Wi-Fi and (screen off) the wake term W;
- segments are reconciled in groups (a screen-on segment < short_on_merge_s joins the nearest
  screen-on one), giving "other" (没算清的部分) or scaling the model down (模型偏高);
- uncovered segments become the "unrecorded" item: their % drop in J (D * E_full / 100), or, when
  the % did not move, F_off * duration as a lower bound;
- percentages are NOT made here: out.py turns J into points with used_pct_raw / sum(e_j) and does
  largest remainder, <1%, apps_rest and every sentence (6b.d 模块分界上的约定).

Units inside: step terms in mJ (mW * s), converted to J when they reach items.
Formulas (coeffs-v1.json names; T* are s of the step, f = discharge time / time):
  F = F_on*Don + F_off*Doff                       S = Don*(D_on + B(bl/ton))
  kappa = sum_c b_c*P_c(fbar_c)/sum_c b_c,  P_c(f) = Pmax_c*(f/fmax_c)^cpu_exp
  app u = f*(kappa*cpu_u + sum engine_s*g(cycles/engine_ns)),  g(f) = Pg*(f/g_fref_mhz)^g_exp
  KWin = f*kappa*(cpu_kwin - cpu_xw) + r_kwin*Don*g(kwin_gpu_mhz)            -> ui
  Xwayland = f*(kappa*cpu_xw + GPU of the KWin cgroup)  -> foreground X11 app, else ui
  kernel = f*kappa*(root - user.slice - system.slice - init.scope)           -> sys
  Wi-Fi = f*min(k_pkt*pkt, P_wifi_max*T)
  screen off: W = A*(1 - exp(-R/R0))*Doff, R = ctx/ctx_per_wake/T, split by wk (-k = kernel)
"""

from __future__ import annotations

import bisect
import datetime
import fnmatch
import math
import re
from dataclasses import dataclass, field
from typing import Any, Optional

from . import ranges as R
from .types import (KERNEL, Diag, Inputs, ItemEnergy, Range, RangeResult, Remain, Resolved, Segment,
                    Step, UKey)

KWIN_KEY = "u/session.slice/plasma-kwin_wayland.service"
REFRESH_KEY = "u/app.slice/y700-refresh-auto.service"
XW_LABEL = "#xwayland"
CLOSED_ID = "app:#closed"
CLOSED_NAME = "已关闭的程序（认不出）"
FG_UNKNOWN_PART = "前台未知"
STEAM_NOTE = "游戏和 Steam 本身合在一起算，下面按窗口列前台时长。"
FG_UNKNOWN_NOTE = "有一段时间不知道它在不在前台，那段的用电算在了后台里。"
E_FULL_FALLBACK_J = 34.0 * 3600     # 续航速查: about 34 Wh
FLOOR_LEARN_MIN_S = 1200            # 6b.a diag: screen-off segments >= 20 min
FLOOR_LEARN_MIN_N = 4
REMAIN_BASIS_H = 24                 # 6b.a remain: the mean drain of the last day's discharge
REMAIN_MIN_S = 3600
BRIGHT_STEP = 409.5                 # 10 % of the 0..4095 backlight range
FG_UNKNOWN_MAX_S = 300              # more screen-on time than this with unknown fg -> fg_known False

COMPONENTS = {  # id -> (kind, name, icon); out.py owns the final names and icons (6b.d)
    "screen": ("screen", "屏幕", "video-display"),
    "floor": ("floor", "基本耗电（开着机就有）", "battery"),
    "ui": ("ui", "系统界面", "preferences-desktop"),
    "sys": ("sys", "系统后台", "preferences-system"),
    "wifi": ("wifi", "Wi‑Fi（粗估）", "network-wireless"),
    "other": ("other", "没算清的部分", "help-about"),
    "unrecorded": ("unrecorded", "没记到是谁用的", "dialog-information"),
}
LABEL_FALLBACK = {KERNEL: "内核与中断", XW_LABEL: "X11 兼容层（Xwayland）",
                  KWIN_KEY: "窗口合成（KWin）"}
COEFF_DEFAULTS = {  # coeffs-v1.json values, only used when a coeffs file lacks a key
    "F_on": 330.0, "F_off": 147.0, "D_on": 600.0, "Pmax_little": 1500.0, "Pmax_big": 3000.0,
    "fmax_little": 3628.8, "fmax_big": 4608.0, "cpu_exp": 2.2, "Pg": 2500.0, "g_fref_mhz": 1200.0,
    "g_exp": 2.0, "r_kwin": 0.05, "kwin_gpu_mhz": 205.0, "A": 150.0, "R0": 130.0,
    "ctx_per_wake": 1.0, "k_pkt": 0.2, "P_wifi_max": 300.0, "V_nom": 3.87,
}
B_DEFAULT = [(41.0, 0.0), (410.0, 250.0), (2048.0, 1620.0), (4095.0, 3370.0)]


# ---------------------------------------------------------------------------------------------
# Formulas (each one tested on its own)
# ---------------------------------------------------------------------------------------------

def coeff(inp_or_c: Any, name: str) -> float:
    c = inp_or_c.coeffs if hasattr(inp_or_c, "coeffs") else inp_or_c
    v = c.values.get(name)
    return float(COEFF_DEFAULTS[name] if v is None else v)


def backlight_mw(points: list[tuple[float, float]], level: float) -> float:
    """B(l): piecewise linear through points, clamped to the end values outside them."""
    pts = points or B_DEFAULT
    if level <= pts[0][0]:
        return pts[0][1]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if level <= x1:
            return y0 + (y1 - y0) * (level - x0) / (x1 - x0) if x1 > x0 else y1
    return pts[-1][1]


def cpu_mw(c: Any, cluster: int, f_mhz: float) -> float:
    """P_c(f) = Pmax_c * (f / fmax_c)^cpu_exp; cluster 0 = cpu0-5 (policy0), 1 = cpu6-7 (policy6)."""
    pmax, fmax = (("Pmax_little", "fmax_little"), ("Pmax_big", "fmax_big"))[min(cluster, 1)]
    return coeff(c, pmax) * (max(0.0, f_mhz) / coeff(c, fmax)) ** coeff(c, "cpu_exp")


def kappa_mw(c: Any, cl: list[tuple[int, int, int]]) -> float:
    """CPU price of one busy second: busy-weighted mean of P_c at each cluster's mean frequency.
    No busy time at all: the little cluster at half its top speed (the CPU terms are ~0 then)."""
    num = den = 0.0
    for ci, (busy, mhz_ms, t_ms) in enumerate(cl[:2]):
        if busy <= 0 or t_ms <= 0:
            continue
        num += busy * cpu_mw(c, ci, mhz_ms / t_ms)
        den += busy
    if den > 0:
        return num / den
    return cpu_mw(c, 0, coeff(c, "fmax_little") / 2)


def gpu_mw(c: Any, f_mhz: float) -> float:
    """g(f) = Pg * (f / g_fref_mhz)^g_exp."""
    return coeff(c, "Pg") * (max(0.0, f_mhz) / coeff(c, "g_fref_mhz")) ** coeff(c, "g_exp")


def gpu_mj(c: Any, engine_ns: int, cycles: int) -> float:
    """GPU energy of (engine_ns, cycles) deltas: busy s * g(mean clock), mean clock = cycles/ns."""
    if engine_ns <= 0:
        return 0.0
    return engine_ns / 1e9 * gpu_mw(c, cycles / engine_ns * 1000.0)


def wake_mw(c: Any, rate: float) -> float:
    """A * (1 - exp(-R / R0)): the wake cost at R wakeups/s (per s of screen-off discharge)."""
    return coeff(c, "A") * (1.0 - math.exp(-max(0.0, rate) / coeff(c, "R0")))


def reconcile(e: float, fix: float, soft: float) -> tuple[float, float, float, bool]:
    """DESIGN 4 对账 -> (fix scale, soft scale, other, flagged 模型偏高)."""
    if fix + soft <= e:
        return 1.0, 1.0, e - fix - soft, False
    if fix <= e:
        lam = (e - fix) / soft
        return 1.0, lam, 0.0, lam < 0.5
    k = e / (fix + soft) if fix + soft > 0 else 0.0
    return k, k, 0.0, True


def e_full_j(inp: Inputs) -> float:
    """E_full = charge_full * V_nom (J); 34 Wh when sysfs has no charge_full."""
    cf = inp.src.battery.charge_full_uah
    if not cf or cf <= 0:
        return E_FULL_FALLBACK_J
    return cf / 1e6 * coeff(inp, "V_nom") * 3600.0


def brightness_hint(inp: Inputs, level: float) -> float:
    """% per hour of screen-on saved by 10 % less backlight at mean level l."""
    pts = inp.coeffs.b_points or B_DEFAULT
    d_mw = backlight_mw(pts, level) - backlight_mw(pts, max(0.0, level - BRIGHT_STEP))
    return d_mw / 1000.0 * 3600.0 / e_full_j(inp) * 100.0


def percentile(xs: list[float], q: float) -> Optional[float]:
    """Linear-interpolated percentile (numpy's default), q in 0..1."""
    if not xs:
        return None
    s = sorted(xs)
    pos = q * (len(s) - 1)
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


# ---------------------------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------------------------

class _FallbackApps:
    """Used only when Inputs.apps is None (no .desktop data at all): rules.json globs, and an
    app.slice unit is an app named after its unit."""

    def __init__(self, rules: Any) -> None:
        self.rules = rules

    def _label(self, key: str) -> str:
        for glob, name in self.rules.labels:
            if fnmatch.fnmatchcase(key, glob):
                return name
        return key

    def resolve(self, key: str, alive: bool, fg_classes: Any) -> Resolved:
        for kind, globs in (("ui", self.rules.ui), ("sys", self.rules.sys)):
            if any(fnmatch.fnmatchcase(key, g) for g in globs):
                return Resolved(kind, self._label(key), self._label(key), None, "rule")  # type: ignore[arg-type]
        if key.startswith("u/app.slice/"):
            if not alive:
                return Resolved("closed", "#closed", CLOSED_NAME)
            unit = key.split("/", 2)[2]
            return Resolved("app", unit, unit)
        return Resolved("sys", self._label(key), self._label(key), None, "default")

    def is_desktop_class(self, cls: str) -> bool:
        return cls in self.rules.desktop_classes

    def is_x11(self, cls: str) -> bool:
        return any(fnmatch.fnmatchcase(cls, g) for g in self.rules.x11_classes)

    def window_name(self, cls: str, title: Optional[str]) -> str:
        return title or cls


@dataclass(slots=True)
class _Fg:
    """One foreground stretch of a boot, mono s. what: app | desktop | unknown."""
    a: float
    b: float
    what: str
    uk: Optional[UKey] = None
    cls: str = ""


@dataclass(slots=True)
class _Terms:
    """Model terms of one step, mJ (weights applied later)."""
    e: float = 0.0
    F: float = 0.0
    S: float = 0.0
    soft: dict = field(default_factory=dict)      # (item id, part) -> [mJ, fg mJ]
    cpu: dict = field(default_factory=dict)       # item id -> s
    gpu: dict = field(default_factory=dict)       # item id -> s
    wake: dict = field(default_factory=dict)      # item id -> wakeups (screen off only)
    off: bool = False
    wk_fallback: bool = False
    bl: float = 0.0
    ton: float = 0.0


@dataclass(slots=True)
class _SegAcc:
    seg: Segment
    t: _Terms
    flagged: bool = False


@dataclass(slots=True)
class _Item:
    e: float = 0.0
    fg: float = 0.0
    off: float = 0.0
    parts: dict = field(default_factory=dict)
    buckets: list = field(default_factory=list)
    cpu: Optional[float] = None
    gpu: Optional[float] = None
    wake: Optional[float] = None
    unknown_fg: float = 0.0


@dataclass(slots=True)
class GroupDetail:
    """One reconciliation group (for --text / diag)."""
    a: float
    b: float
    segments: int
    e_j: float
    fix_j: float
    soft_j: float
    other_j: float
    scale_fix: float
    scale_soft: float
    flagged: bool


def _add(d: dict, k: Any, v: float) -> None:
    d[k] = d.get(k, 0.0) + v


class _Model:
    def __init__(self, inp: Inputs) -> None:
        self.inp = inp
        self.ctx = R.context(inp)
        self.c = inp.coeffs
        self.rules = inp.rules
        self.apps = inp.apps if inp.apps is not None else _FallbackApps(inp.rules)
        self.parents = set(inp.rules.parents)
        self.u_parents = [p for p in inp.rules.parents if p.startswith("u/")]
        self.boots = {b.boot8: b for b in inp.ledger.boots}
        self.meta: dict[str, tuple[str, str, Optional[str]]] = {
            k: v for k, v in COMPONENTS.items()}
        self.meta[CLOSED_ID] = ("app", CLOSED_NAME, None)
        self._res: dict[tuple[str, bool], tuple[str, Optional[str]]] = {}
        self._labels: dict[str, str] = {}
        self._fg: dict[str, list[_Fg]] = {}
        self._fg_a: dict[str, list[float]] = {}
        self._series: dict[tuple[str, UKey], tuple[list[float], list[float]]] = {}
        self._terms: dict[tuple[str, int], _Terms] = {}
        self._cover: dict[str, list[Optional[int]]] = {}
        self._kcls: dict[str, tuple[bool, bool, bool, tuple[int, ...]]] = {}
        # window classes per ledger key, most foreground time first: AppIndex.resolve takes the
        # first class that names an app, so a launcher's own window must not beat the game's
        fg_secs: dict[str, dict[str, float]] = {}
        for b in inp.ledger.boots:
            evs = sorted(b.fg, key=lambda x: x.m)
            last_m = b.snaps[-1].m if b.snaps else None
            for k, e in enumerate(evs):
                if e.kind != "fg" or not e.key:
                    continue
                nxt = evs[k + 1].m if k + 1 < len(evs) else (last_m if last_m is not None else e.m)
                d = fg_secs.setdefault(e.key, {})
                d[e.cls] = d.get(e.cls, 0.0) + max(0.0, nxt - e.m)
        self.fg_classes: dict[str, list[str]] = {
            k: sorted(v, key=lambda c, v=v: (-v[c], c)) for k, v in fg_secs.items()}
        self.lives_by_key: dict[tuple[str, str], list] = {}
        for b8, lv in inp.lives.items():
            for uk, life in lv.items():
                self.lives_by_key.setdefault((b8, uk[0]), []).append(life)
        for v in self.lives_by_key.values():
            v.sort(key=lambda x: x.first_m)
        self.fixes: dict[tuple[str, int], dict[UKey, int]] = {}
        self.exit_m: dict[tuple[str, UKey], float] = {}
        for fx in inp.fixes:
            steps = inp.steps.get(fx.boot8, [])
            mbs = [s.mb for s in steps]
            i = bisect.bisect_left(mbs, fx.m_exit)
            uk = fx.ukey if fx.ukey is not None else (fx.key, -1)
            self.exit_m[(fx.boot8, uk)] = fx.m_exit
            if i < len(steps) and steps[i].ma <= fx.m_exit and fx.extra_usec > 0:
                _add(self.fixes.setdefault((fx.boot8, i), {}), uk, fx.extra_usec)
            # after the boot's last snapshot: no step holds it yet (the next report will)

    # -- names ---------------------------------------------------------------------------------

    def label(self, key: str) -> str:
        if key not in self._labels:
            name = next((n for g, n in self.rules.labels if fnmatch.fnmatchcase(key, g)), None)
            self._labels[key] = name or LABEL_FALLBACK.get(key, key)
        return self._labels[key]

    def item_of(self, uk: UKey, boot8: Optional[str]) -> tuple[str, Optional[str]]:
        """(item id, part name) of a ledger unit."""
        if uk == KERNEL:
            return "sys", self.label(KERNEL)
        key = uk[0]
        if key in self.parents:
            return "sys", self.label(key)
        life = self.inp.lives.get(boot8 or "", {}).get(uk)
        alive = life is not None and life.gone_m is None
        ck = (key, alive)
        if ck not in self._res:
            if key == KWIN_KEY:
                self._res[ck] = ("ui", self.label(KWIN_KEY))
            else:
                r = self.apps.resolve(key, alive, list(self.fg_classes.get(key, [])))
                if r.kind == "app":
                    iid = "app:" + r.id
                    self.meta.setdefault(iid, ("app", r.name, r.icon))
                    self._res[ck] = (iid, None)
                elif r.kind == "closed":
                    self._res[ck] = (CLOSED_ID, None)
                else:
                    self._res[ck] = (r.kind, r.name)
        return self._res[ck]

    # -- foreground ----------------------------------------------------------------------------

    def ukey_for(self, boot8: str, key: Optional[str], m: float) -> Optional[UKey]:
        if not key:
            return None
        lives = self.lives_by_key.get((boot8, key), [])
        best = None
        for lf in lives:
            if lf.first_m <= m + 1e-6:
                best = lf
        if best is None and lives:
            best = lives[0]
        return best.ukey if best is not None else (key, -1)

    def mono_end(self, boot8: str) -> Optional[float]:
        b = self.boots.get(boot8)
        if b is None or not b.snaps:
            return None
        end = b.snaps[-1].m
        cur8 = self.inp.src.boot_id.replace("-", "")[:8] if self.inp.src.boot_id else None
        if boot8 == cur8 and b.offset is not None:
            end = max(end, self.ctx.now - b.offset)
        return end

    def fg(self, boot8: str) -> list[_Fg]:
        """Foreground stretches of a boot: between consecutive fg lines; after START / STOP, before
        the first line, and after refresh-auto's unit went away (no STOP written) it is unknown."""
        if boot8 in self._fg:
            return self._fg[boot8]
        b = self.boots.get(boot8)
        out: list[_Fg] = []
        end = self.mono_end(boot8)
        if b is not None and end is not None:
            evs = [(e.m, 0, e) for e in b.fg]
            for lf in self.inp.lives.get(boot8, {}).values():
                if lf.ukey[0] == REFRESH_KEY and lf.gone_m is not None:
                    evs.append((lf.gone_m, 1, None))
            evs.sort(key=lambda x: (x[0], x[1]))
            t = min([b.snaps[0].m] + [x[0] for x in evs])
            cur = _Fg(0, 0, "unknown")
            for m, _, e in evs:
                if m > t:
                    out.append(_Fg(t, m, cur.what, cur.uk, cur.cls))
                    t = m
                if e is None or e.kind != "fg":
                    cur = _Fg(0, 0, "unknown")
                elif e.pid == 0 or self.apps.is_desktop_class(e.cls):
                    cur = _Fg(0, 0, "desktop", None, e.cls)
                else:
                    uk = self.ukey_for(boot8, e.key, e.m)
                    cur = _Fg(0, 0, "app", uk, e.cls) if uk is not None else _Fg(0, 0, "unknown")
            if end > t:
                out.append(_Fg(t, end, cur.what, cur.uk, cur.cls))
        self._fg[boot8] = out
        return out

    def fg_overlap(self, boot8: str, a: float, b: float) -> list[tuple[_Fg, float]]:
        """Foreground stretches overlapping mono [a, b], with the overlap; time no stretch covers
        is reported as an unknown stretch."""
        out = []
        covered = 0.0
        fgs = self.fg(boot8)
        if boot8 not in self._fg_a:
            self._fg_a[boot8] = [f.a for f in fgs]
        # stretches are sorted and do not overlap: start at the last one beginning before a
        # (a week has thousands of them and this runs per app per screen-on step)
        for k in range(max(0, bisect.bisect_right(self._fg_a[boot8], a) - 1), len(fgs)):
            f = fgs[k]
            if f.a >= b:
                break
            ov = R.overlap(f.a, f.b, a, b)
            if ov > 0:
                out.append((f, ov))
                covered += ov
        if b - a - covered > 1e-6:
            out.append((_Fg(a, b, "unknown"), b - a - covered))
        return out

    def series(self, boot8: str, uk: UKey) -> tuple[list[float], list[float]]:
        """usage_usec of one unit over mono time: snapshot values (carried forward while the unit
        lives, so an unlisted = unchanged unit stays flat) plus the fg log's readings."""
        k = (boot8, uk)
        if k in self._series:
            return self._series[k]
        b = self.boots.get(boot8)
        pts: list[tuple[float, float]] = []
        if b is not None:
            val = None
            for s in b.snaps:
                if uk in s.cg:
                    val = s.cg[uk]
                if val is not None:
                    pts.append((s.m, float(val)))
                if uk in s.gone:
                    val = None
            prev: Optional[UKey] = None
            for e in sorted(b.fg, key=lambda x: x.m):
                if e.kind != "fg":
                    prev = None
                    continue
                if prev == uk and e.prev_usage is not None:
                    pts.append((e.m, float(e.prev_usage)))
                cur = self.ukey_for(boot8, e.key, e.m) if e.key else None
                if cur == uk and e.new_usage is not None:
                    pts.append((e.m, float(e.new_usage)))
                prev = cur
        pts.sort()
        self._series[k] = ([p[0] for p in pts], [p[1] for p in pts])
        return self._series[k]

    def usage_at(self, boot8: str, uk: UKey, m: float) -> float:
        ms, us = self.series(boot8, uk)
        if not ms:
            return 0.0
        i = bisect.bisect_right(ms, m)
        if i == 0:
            return us[0]
        if i == len(ms):
            return us[-1]
        m0, m1, u0, u1 = ms[i - 1], ms[i], us[i - 1], us[i]
        return u1 if m1 <= m0 else u0 + (u1 - u0) * (m - m0) / (m1 - m0)

    def fg_frac(self, boot8: str, st: Step, uk: UKey, delta_us: float,
                shares: Optional[list[tuple[_Fg, float]]] = None) -> float:
        """Share of a unit's step CPU used while it was foreground (the step is screen-on). Only the
        foreground stretches inside this step count, so CPU across a screen-off edge stays out.
        shares: fg_overlap(boot8, st.ma, st.mb) when the caller already has it (it is the same for every unit)."""
        cpu = secs = 0.0
        if shares is None:
            shares = self.fg_overlap(boot8, st.ma, st.mb)
        for f, ov in shares:
            if f.what == "app" and f.uk == uk:
                x, y = max(f.a, st.ma), min(f.b, st.mb)
                cpu += max(0.0, self.usage_at(boot8, uk, y) - self.usage_at(boot8, uk, x))
                secs += ov
        if delta_us > 0:
            return min(1.0, cpu / delta_us)
        span = st.mb - st.ma
        return min(1.0, secs / span) if span > 0 else 0.0

    # -- step terms ----------------------------------------------------------------------------

    def cover(self, boot8: str, i: int) -> Optional[int]:
        """Index of the step whose end snapshot holds the wake counts covering step i."""
        if boot8 not in self._cover:
            steps = self.inp.steps.get(boot8, [])
            cov: list[Optional[int]] = [None] * len(steps)
            nxt: Optional[int] = None
            for j in range(len(steps) - 1, -1, -1):
                if steps[j].wk is not None:
                    nxt = j
                if nxt is not None:
                    since = steps[nxt].wk_since_m
                    if since is None or since <= steps[j].ma + 1e-6:
                        cov[j] = nxt
            self._cover[boot8] = cov
        cov = self._cover[boot8]
        return cov[i] if 0 <= i < len(cov) else None

    def leaf_class(self, key: str) -> tuple[bool, bool, bool, tuple[int, ...]]:
        """Where a leaf unit's CPU counts in _compute's cgroup sums: (PID 1, under system.slice, directly under the
        user slice (no u_parent), the indexes of the u_parents it is under)."""
        cls = self._kcls.get(key)
        if cls is None:
            par = tuple(j for j, p in enumerate(self.u_parents) if key.startswith(p + "/"))
            cls = self._kcls[key] = (key == "/init.scope", key.startswith("s/"),
                                     key.startswith(("u/", "l/")) and not par, par)
        return cls

    def terms(self, boot8: str, i: int) -> _Terms:
        k = (boot8, i)
        if k not in self._terms:
            self._terms[k] = self._compute(boot8, i)
        return self._terms[k]

    def _compute(self, boot8: str, i: int) -> _Terms:
        steps = self.inp.steps[boot8]
        st = steps[i]
        fr = st.fr
        out = _Terms()
        if fr is None:
            return out
        c = self.c
        t_ms = fr.ton + fr.toff
        f = min(1.0, max(0.0, (fr.dton + fr.dtoff) / t_ms)) if t_ms > 0 else 0.0
        don, doff, T = fr.dton / 1000.0, fr.dtoff / 1000.0, t_ms / 1000.0
        on = st.dpms == 1
        out.off = st.dpms == 0
        out.e = float(fr.don + fr.doff)
        out.F = coeff(c, "F_on") * don + coeff(c, "F_off") * doff
        level = fr.bl / fr.ton if fr.ton > 0 else 0.0
        out.S = don * (coeff(c, "D_on") + backlight_mw(c.b_points, level))
        out.bl, out.ton = float(fr.bl), float(fr.ton)
        kappa = kappa_mw(c, st.cl)
        soft = out.soft
        cpu_targets: list[tuple[str, Optional[str], float]] = []   # for the wake fallback

        def add(item: str, part: Optional[str], e: float, fg: float = 0.0) -> None:
            if e <= 0:
                return
            v = soft.setdefault((item, part), [0.0, 0.0])
            v[0] += e
            v[1] += fg

        def cpu_term(item: str, part: Optional[str], us: float) -> float:
            if us <= 0:
                return 0.0
            _add(out.cpu, item, us / 1e6)
            cpu_targets.append((item, part, us))
            return f * kappa * us / 1e6

        fg_ov: list = []           # this step's fg_overlap, made on first use: the same for every app and Xwayland

        def step_fg() -> list[tuple[_Fg, float]]:
            if not fg_ov:
                fg_ov.append(self.fg_overlap(boot8, st.ma, st.mb))
            return fg_ov[0]

        cpu: dict[UKey, float] = {}
        for uk, us in st.cpu.items():
            _add(cpu, uk, float(us))
        for uk, us in self.fixes.get((boot8, i), {}).items():
            _add(cpu, uk, float(us))
        agg: dict[str, float] = {}
        leaves: dict[UKey, float] = {}
        for uk, us in cpu.items():
            if us <= 0:
                continue
            if uk[0] in self.parents:
                _add(agg, uk[0], us)
            else:
                _add(leaves, uk, us)
        gmap = st.gpu or {}

        # the leaves sorted into the cgroup sums below in one pass (in leaves order, and each list goes through
        # sum() as the per-sum generators did, so the floats come out the same)
        init_l: list[float] = []
        s_l: list[float] = []
        direct_l: list[float] = []
        par_l: list[list[float]] = [[] for _ in self.u_parents]
        for uk, us in leaves.items():
            is_init, is_s, is_direct, pars = self.leaf_class(uk[0])
            if is_init:
                init_l.append(us)
            if is_s:
                s_l.append(us)
            if is_direct:
                direct_l.append(us)
            for j in pars:
                par_l[j].append(us)

        # kernel = root minus the slices (and PID 1)
        init_us = sum(init_l)
        kern = agg.get("/", 0.0) - agg.get("/user.slice", 0.0) - agg.get("/system.slice", 0.0) - init_us
        add("sys", self.label(KERNEL), cpu_term("sys", self.label(KERNEL), kern))

        # cgroup leftovers: parents minus their known children (short-lived or unlisted units)
        if "/system.slice" in agg:
            p = self.label("s/~rest")
            add("sys", p, cpu_term("sys", p, agg["/system.slice"] - sum(s_l)))
        if "/user.slice" in agg:
            direct = sum(agg.get(p, 0.0) for p in self.u_parents)
            direct += sum(direct_l)
            p = self.label("u/~rest")
            add("sys", p, cpu_term("sys", p, agg["/user.slice"] - direct))
        for j, par in enumerate(self.u_parents):
            if par not in agg:
                continue
            rest = agg[par] - sum(par_l[j])
            if par == "u/app.slice":
                add(CLOSED_ID, None, cpu_term(CLOSED_ID, None, rest))
            else:
                p = self.label(par + "/~rest")
                add("sys", p, cpu_term("sys", p, rest))

        # units
        kwin_us = 0.0
        xw_gpu_mj = xw_gpu_s = 0.0
        for uk, (eng, cyc) in gmap.items():
            if uk[0] == KWIN_KEY:
                xw_gpu_mj += gpu_mj(c, eng, cyc)
                xw_gpu_s += eng / 1e9
        done_gpu: set = set()
        for uk, us in leaves.items():
            if uk[0] == KWIN_KEY:
                kwin_us += us
                continue
            item, part = self.item_of(uk, boot8)
            e = cpu_term(item, part, us)
            if uk in gmap:
                eng, cyc = gmap[uk]
                e += f * gpu_mj(c, eng, cyc)
                _add(out.gpu, item, eng / 1e9)
                done_gpu.add(uk)
            fg = e * self.fg_frac(boot8, st, uk, us, step_fg()) if on and item.startswith("app:") else 0.0
            add(item, part, e, fg)
        for uk, (eng, cyc) in gmap.items():
            if uk in done_gpu or uk[0] == KWIN_KEY or eng <= 0:
                continue
            item, part = self.item_of(uk, boot8)
            e = f * gpu_mj(c, eng, cyc)
            _add(out.gpu, item, eng / 1e9)
            fg = e * self.fg_frac(boot8, st, uk, 0.0, step_fg()) if on and item.startswith("app:") else 0.0
            add(item, part, e, fg)

        # KWin without Xwayland, plus its own composition GPU estimate
        xw_s = (st.x_ticks or 0) / 100.0
        kwin_net_us = max(0.0, kwin_us - xw_s * 1e6)
        kp = self.label(KWIN_KEY)
        e_kwin = cpu_term("ui", kp, kwin_net_us)
        gpu_busy = coeff(c, "r_kwin") * don
        e_kwin += gpu_busy * gpu_mw(c, coeff(c, "kwin_gpu_mhz"))
        if fr.ton > 0:
            # busy s over the whole on-time like the other counts (weighted with the plugged part in), not Don
            _add(out.gpu, "ui", coeff(c, "r_kwin") * fr.ton / 1000.0)
        add("ui", kp, e_kwin)

        # Xwayland: to the foreground X11 app, else 系统界面; unknown foreground on screen -> other
        xw_mj = f * (kappa * xw_s + xw_gpu_mj)
        if xw_mj > 0 or xw_s > 0:
            xp = self.label(XW_LABEL)
            span = st.mb - st.ma
            shares = step_fg() if on and span > 0 else []
            if not shares:
                shares = [(_Fg(st.ma, st.mb, "desktop"), max(span, 1.0))]
                span = max(span, 1.0)
            for fgs, ov in shares:
                sh = ov / span
                if fgs.what == "app" and fgs.uk is not None and self.apps.is_x11(fgs.cls):
                    item, part = self.item_of(fgs.uk, boot8)
                    add(item, part, xw_mj * sh, xw_mj * sh if item.startswith("app:") else 0.0)
                elif fgs.what == "unknown":
                    item, part = "other", FG_UNKNOWN_PART
                    add(item, part, xw_mj * sh)
                    continue
                else:
                    item, part = "ui", xp
                    add(item, part, xw_mj * sh)
                if xw_s > 0:
                    _add(out.cpu, item, xw_s * sh)
                    cpu_targets.append((item, part, xw_s * 1e6 * sh))
                if xw_gpu_s > 0:
                    _add(out.gpu, item, xw_gpu_s * sh)

        # Wi-Fi
        if st.pkt:
            add("wifi", None, f * min(coeff(c, "k_pkt") * st.pkt, coeff(c, "P_wifi_max") * T))

        # screen off: wakeups
        if out.off and doff > 0:
            rate = (st.ctx or 0) / coeff(c, "ctx_per_wake") / T if T > 0 else 0.0
            W = wake_mw(c, rate) * doff
            j = self.cover(boot8, i)
            wk = steps[j].wk if j is not None else None
            tot = sum(n for n in wk.values() if n > 0) if wk else 0
            if wk and tot > 0:
                since = steps[j].wk_since_m  # type: ignore[index]
                cov_span = steps[j].mb - (since if since is not None else steps[j].ma)  # type: ignore[index]
                ratio = (st.mb - st.ma) / cov_span if cov_span > 0 else 1.0
                for wkey, n in wk.items():
                    if n <= 0:
                        continue
                    item, part = self.item_of(wkey, boot8)  # type: ignore[arg-type]
                    add(item, part, W * n / tot)
                    _add(out.wake, item, n * min(1.0, ratio))
            else:
                out.wk_fallback = True
                tot_us = sum(t[2] for t in cpu_targets)
                if tot_us > 0:
                    for item, part, us in cpu_targets:
                        add(item, part, W * us / tot_us)
                else:
                    add("sys", self.label(KERNEL), W)
        return out


def _model(inp: Inputs) -> _Model:
    ctx = R.context(inp)
    if _MODEL and _MODEL[0] is inp and _MODEL[1].ctx is ctx:
        return _MODEL[1]
    m = _Model(inp)
    _MODEL[:] = [inp, m]
    return m


_MODEL: list = []
_DETAILS: list = []                    # [(RangeResult, [GroupDetail])], last few attributions


# ---------------------------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------------------------

def attribute(rng: Range, inp: Inputs) -> RangeResult:
    """Section 4 model and reconciliation for one range (energies in J)."""
    return attribute_detail(rng, inp)[0]


def attribute_detail(rng: Range, inp: Inputs) -> tuple[RangeResult, list[GroupDetail]]:
    """attribute() plus the reconciliation groups, for --text and diag."""
    M = _model(inp)
    ctx = M.ctx
    rules = inp.rules
    efull = e_full_j(inp)
    res = RangeResult(range=rng, e_full_j=efull)
    nb = len(rng.bucket_t)
    items: dict[str, _Item] = {}

    def item(iid: str) -> _Item:
        if iid not in items:
            items[iid] = _Item(buckets=[0.0] * nb)
        return items[iid]

    def spread(seg: Segment) -> list[tuple[int, float]]:
        return R.spread(seg.a, seg.b, rng.bucket_s, rng.bucket_t)

    def put(iid: str, sp: list[tuple[int, float]], e_j: float, fg_j: float = 0.0, off: bool = False,
            part: Optional[str] = None) -> None:
        """sp: spread(segment), made once per segment (it does not depend on the item)"""
        if e_j <= 0:
            return
        it = item(iid)
        it.e += e_j
        it.fg += fg_j
        if off:
            it.off += e_j - fg_j
        if part is not None:
            _add(it.parts, part, e_j)
        for bi, fr in sp:
            it.buckets[bi] += e_j * fr

    # seconds
    for s in rng.segments:
        d = s.b - s.a
        if s.kind in R.DISCHARGE:
            dp = R.seg_dpms(ctx, s)
            if dp == 1:
                res.on_s += d
            elif dp == 0:
                res.off_s += d
            if s.kind == "uncovered":
                res.uncovered_s += d
        elif s.kind == "charger":
            res.charger_s += d
        elif s.kind == "gap":
            res.gap_s += d

    # itemised segments -> weighted step terms
    accs: list[_SegAcc] = []
    for s in rng.segments:
        if s.kind not in ("on", "off") or s.boot8 is None:
            continue
        steps = inp.steps.get(s.boot8, [])
        t = _Terms(off=(s.kind == "off"))
        for i in s.steps:
            st = steps[i]
            if st.fr is None or not st.cov:
                continue
            w = R.step_weight(ctx, st, s.a, s.b)
            if w <= 0:
                continue
            tt = M.terms(s.boot8, i)
            t.e += w * tt.e
            t.F += w * tt.F
            t.S += w * tt.S
            t.bl += w * tt.bl
            t.ton += w * tt.ton
            t.wk_fallback = t.wk_fallback or tt.wk_fallback
            for k, (e, fg) in tt.soft.items():
                v = t.soft.setdefault(k, [0.0, 0.0])
                v[0] += w * e
                v[1] += w * fg
            wc = R.step_weight(ctx, st, s.a, s.b, counted=True)
            for src, dst in ((tt.cpu, t.cpu), (tt.gpu, t.gpu), (tt.wake, t.wake)):
                for k, v in src.items():
                    _add(dst, k, wc * v)
        accs.append(_SegAcc(s, t))

    # groups: a short screen-on segment is reconciled together with the nearest screen-on one
    parent = list(range(len(accs)))

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    ons = [k for k, a in enumerate(accs) if a.seg.kind == "on"]
    # pieces() cuts one timeline, so the screen-on segments come in time order, each longer than 0 and none
    # overlapping: the nearest one is then the previous or the next, and the previous wins a tie as the first one
    # found did. The scan over all of them was quadratic in weeks of short screen-ons. The order is checked here,
    # anything else still gets the full scan.
    on_segs = [accs[k].seg for k in ons]
    ordered = all(x.a < x.b for x in on_segs) and all(x.b <= y.a for x, y in zip(on_segs, on_segs[1:]))
    for p, k in enumerate(ons):
        s = accs[k].seg
        if s.b - s.a >= rules.short_on_merge_s:
            continue
        best, bd = None, None
        for j in ([ons[q] for q in (p - 1, p + 1) if 0 <= q < len(ons)] if ordered else ons):
            if j == k:
                continue
            o = accs[j].seg
            dist = max(0.0, o.a - s.b, s.a - o.b)
            if bd is None or dist < bd:
                best, bd = j, dist
        if best is not None:
            parent[find(k)] = find(best)
    groups: dict[int, list[int]] = {}
    for k in range(len(accs)):
        groups.setdefault(find(k), []).append(k)

    details: list[GroupDetail] = []
    e_items_j = other_unexpl_j = 0.0
    for members in sorted(groups.values(), key=lambda g: accs[g[0]].seg.a):
        E = sum(accs[k].t.e for k in members)
        fix = sum(accs[k].t.F + accs[k].t.S for k in members)
        soft = sum(v[0] for k in members for v in accs[k].t.soft.values())
        kf, ks, other, flagged = reconcile(E, fix, soft)
        if flagged:
            res.model_high_segments += len(members)
        details.append(GroupDetail(a=min(accs[k].seg.a for k in members),
                                   b=max(accs[k].seg.b for k in members), segments=len(members),
                                   e_j=E / 1000, fix_j=fix / 1000, soft_j=soft / 1000,
                                   other_j=other / 1000, scale_fix=kf, scale_soft=ks, flagged=flagged))
        e_items_j += E / 1000
        other_unexpl_j += other / 1000
        for k in members:
            a = accs[k]
            sp, t = spread(a.seg), a.t
            put("screen", sp, t.S * kf / 1000)
            put("floor", sp, t.F * kf / 1000)
            for (iid, part), (e, fg) in t.soft.items():
                put(iid, sp, e * ks / 1000, fg * ks / 1000, t.off, part)
            if E > 0:
                put("other", sp, other * t.e / E / 1000)
            for src, attr in ((t.cpu, "cpu"), (t.gpu, "gpu"), (t.wake, "wake")):
                for iid, v in src.items():
                    it = item(iid)
                    setattr(it, attr, (getattr(it, attr) or 0.0) + v)

    # uncovered -> unrecorded
    unrec_j = 0.0
    for s in rng.segments:
        if s.kind != "uncovered":
            continue
        e = s.d_pct * efull / 100 if s.d_pct > 0 else (s.b - s.a) * coeff(inp, "F_off") / 1000
        unrec_j += e
        if rng.state == "partial":
            put("unrecorded", spread(s), e)

    # D, or energy / E_full when D is too small to share out
    D = sum(s.d_pct for s in rng.segments if s.kind in R.DISCHARGE)
    if D >= rules.d_min_pct:
        res.used_pct_raw, res.used_pct_basis = D, "pct"
    else:
        res.used_pct_raw, res.used_pct_basis = (e_items_j + unrec_j) / efull * 100, "energy"

    # screen-on brightness, learned floor, unexplained share
    bl = sum(a.t.bl for a in accs if a.seg.kind == "on")
    ton = sum(a.t.ton for a in accs if a.seg.kind == "on")
    if ton > 0:
        res.brightness_hint_pct_h = brightness_hint(inp, bl / ton)
    # the measured screen-off power against what the model says for the same segments before reconciliation
    # (F_off + W + CPU / GPU / Wi-Fi): F_off alone is only the floor term, ~100 mW under any calm night
    offs = [a for a in accs if a.seg.kind == "off" and a.seg.b - a.seg.a >= FLOOR_LEARN_MIN_S]
    if len(offs) >= FLOOR_LEARN_MIN_N:
        res.learned_floor_off_mw = percentile([a.t.e / (a.seg.b - a.seg.a) for a in offs], 0.25)
        res.model_floor_off_mw = percentile([(a.t.F + a.t.S + sum(v[0] for v in a.t.soft.values()))
                                             / (a.seg.b - a.seg.a) for a in offs], 0.25)
    if e_items_j > 0:
        res.unexplained_frac = other_unexpl_j / e_items_j

    # foreground / background time and windows
    fg_s, win, alive_s, unknown_on, classes, alive_iv = _times(M, rng)
    res.fg_known = inp.src.fg_dir_exists and unknown_on < FG_UNKNOWN_MAX_S

    out: list[ItemEnergy] = []
    if rng.state in ("ok", "partial"):
        for iid, it in items.items():
            if it.e <= 0:
                continue
            kind, name, icon = M.meta.get(iid, ("app", iid, None))
            ie = ItemEnergy(id=iid, kind=kind, name=name, icon=icon, e_j=it.e,  # type: ignore[arg-type]
                            buckets_j=list(it.buckets))
            if kind == "app":
                ie.fg_j = min(it.e, it.fg)
                ie.bg_j = it.e - ie.fg_j
                ie.off_j = min(ie.bg_j, it.off)
                ie.fg_s = fg_s.get(iid, 0.0)
                ie.bg_s = max(0.0, alive_s.get(iid, 0.0) - ie.fg_s)
                res.alive_iv[iid] = alive_iv.get(iid, [])
                names = win.get(iid, {})
                if len(names) >= 2:
                    ie.windows = sorted(((n, v) for n, v in names.items() if v > 0),
                                        key=lambda x: (-x[1], x[0]))
                if any(fnmatch.fnmatchcase(c, "steam_app_*") for c in classes.get(iid, ())):
                    ie.note = STEAM_NOTE
                elif not res.fg_known and ie.bg_j > 0:
                    ie.note = FG_UNKNOWN_NOTE
            if kind in ("app", "ui", "sys"):
                ie.cpu_s = it.cpu
                ie.gpu_s = it.gpu
                ie.wake_off_n = it.wake
            if kind in ("ui", "sys", "other"):
                ie.parts = sorted(((p, v) for p, v in it.parts.items() if v > 0),
                                  key=lambda x: (-x[1], x[0]))
            out.append(ie)
        out.sort(key=lambda x: (-x.e_j, x.id))
    res.items = out
    _DETAILS[:] = ([(res, details)] + _DETAILS)[:6]
    return res, details


def _clip(ivs: list[tuple[float, float]], segs: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """(union of ivs) inside (union of disjoint segs), as disjoint pieces."""
    merged: list[list[float]] = []
    for a, b in sorted(ivs):
        if b <= a:
            continue
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return [(max(a, x), min(b, y)) for a, b in merged for x, y in segs if min(b, y) > max(a, x)]


def _times(M: _Model, rng: Range) -> tuple[dict, dict, dict, float, dict, dict]:
    """fg seconds, per-window seconds and window classes (fg stretches inside itemised screen-on
    segments), alive seconds inside itemised discharge segments and those stretches themselves
    ((boot8, mono a, mono b), for apps_rest's union), and screen-on seconds with unknown foreground."""
    fg_s: dict[str, float] = {}
    win: dict[str, dict[str, float]] = {}
    classes: dict[str, set[str]] = {}
    unknown = 0.0
    on_by_boot: dict[str, list[tuple[float, float]]] = {}
    dis_by_boot: dict[str, list[tuple[float, float]]] = {}
    for s in rng.segments:
        if s.kind not in ("on", "off") or s.boot8 is None:
            continue
        b = M.boots.get(s.boot8)
        if b is None or b.offset is None:
            continue
        iv = (s.a - b.offset, s.b - b.offset)
        dis_by_boot.setdefault(s.boot8, []).append(iv)
        if s.kind == "on":
            on_by_boot.setdefault(s.boot8, []).append(iv)
    for b8, ivs in on_by_boot.items():
        for a, b in ivs:
            for f, ov in M.fg_overlap(b8, a, b):
                if f.what == "unknown":
                    unknown += ov
                elif f.what == "app" and f.uk is not None:
                    iid = M.item_of(f.uk, b8)[0]
                    if not iid.startswith("app:"):
                        continue
                    _add(fg_s, iid, ov)
                    _add(win.setdefault(iid, {}), M.apps.window_name(f.cls, None), ov)
                    classes.setdefault(iid, set()).add(f.cls)
    alive: dict[str, float] = {}
    alive_iv: dict[str, list[tuple[str, float, float]]] = {}
    for b8, segs in dis_by_boot.items():
        per_item: dict[str, list[tuple[float, float]]] = {}
        end = M.mono_end(b8)
        for uk, lf in M.inp.lives.get(b8, {}).items():
            if uk[0] in M.parents:
                continue
            iid = M.item_of(uk, b8)[0]
            if not iid.startswith("app:"):
                continue
            z = M.exit_m.get((b8, uk))
            if z is None:
                z = lf.gone_m if lf.gone_m is not None else (end if end is not None else lf.last_m)
            per_item.setdefault(iid, []).append((lf.first_m, z))
        for iid, ivs in per_item.items():
            cut = _clip(ivs, segs)
            _add(alive, iid, sum(b - a for a, b in cut))
            alive_iv.setdefault(iid, []).extend((b8, a, b) for a, b in cut)
    return fg_s, win, alive, unknown, classes, alive_iv


def remain(inp: Inputs) -> Optional[Remain]:
    """Hours left at the mean drain of the last REMAIN_BASIS_H hours: the % drop over the discharge time in
    [now - 24 h, now] (screen on, off and unitemised; plugged and gap time left out), current % / (drop per
    hour). A whole day of the owner's use, not the last few hours, so one game or one night does not swing it.
    None when plugged, with less than 1 h of discharge in the window, or when the % did not fall."""
    bat = inp.src.battery
    if bat.plugged or bat.pct is None:
        return None
    ctx = R.context(inp)
    got_t = got_d = 0.0
    for p in R.pieces(ctx, ctx.now - REMAIN_BASIS_H * 3600, ctx.now, True):
        if p.kind in R.DISCHARGE:
            got_t += p.b - p.a
            got_d += ctx.drop(p.a, p.b)
    if got_t < REMAIN_MIN_S or got_d <= 0:
        return None
    return Remain(h=bat.pct / (got_d / got_t * 3600.0), basis_h=REMAIN_BASIS_H)


_ENERGY_T = re.compile(r"\bt=(\d+)")


def diag(inp: Inputs, results: dict[str, RangeResult]) -> Diag:
    """Numbers for y700-checklist (6b.a diag)."""
    now = inp.src.now
    r7 = results.get("7d")
    med = None
    if r7 is not None:
        det = next((d for r, d in _DETAILS if r is r7), None)
        if det is None:
            det = attribute_detail(r7.range, inp)[1]
        fracs = [g.other_j / g.e_j for g in det if g.e_j > 0]
        if fracs:
            med = percentile(fracs, 0.5)
    age = None
    if inp.coeffs.date:
        try:
            d = datetime.date.fromisoformat(inp.coeffs.date)
            today = datetime.datetime.fromtimestamp(now + inp.src.tz_offset_min * 60,
                                                    tz=datetime.timezone.utc).date()
            age = max(0, (today - d).days)
        except ValueError:
            age = None
    newest = None
    for b in inp.ledger.boots:
        for s in b.snaps:
            t = b.t(s.m) if b.offset is not None else s.w
            newest = t if newest is None else max(newest, t)
    energy_age = inp.src.energy_age_s
    if energy_age is None and inp.src.energy and inp.src.mono_now is not None:
        m = _ENERGY_T.search(inp.src.energy)
        if m:
            energy_age = max(0.0, inp.src.mono_now - int(m.group(1)) / 1000.0)
    return Diag(unexplained_median_7d=med,
                floor_off_learned_mw=r7.learned_floor_off_mw if r7 is not None else None,
                floor_off_model_mw=(r7.model_floor_off_mw if r7 is not None and r7.model_floor_off_mw is not None
                                    else coeff(inp, "F_off")),
                coeff_age_days=age,
                ledger_bytes=inp.ledger.bytes,
                ledger_newest_age_s=max(0.0, now - newest) if newest is not None else None,
                energy_age_s=energy_age,
                segments_flagged_7d=r7.model_high_segments if r7 is not None else 0)
