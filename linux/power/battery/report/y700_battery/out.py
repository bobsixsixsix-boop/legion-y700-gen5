"""Report output (DESIGN.md 6b.a, 6b.d): JSON v1 and the --text breakdown from a types.Report.

Everything that turns energy into battery points lives here (模块分界上的约定):
- one ratio per range, used_pct_raw / sum(e_j), so the items add up to D exactly;
- pct_raw is shared out in hundredths by largest remainder (so the rounded values still add up to the rounded
  used_pct_raw and no item is lost to rounding), pct in whole points by largest remainder again;
- apps under 0.5 points merge into apps_rest when there are at least two of them;
- coverage = 1 - unrecorded / sum(e_j);
- the curve is decimated to <= 400 points, keeping the points at gap edges (the page draws gaps between them);
- every Chinese sentence: title, sub, banners, empty, footnote, explain, hint, data_from_text, composition names.
Time formatting follows the page's Fmt.js rule for rule (dur / clock / day_clock / rel / mmdd), always by the
report's tz_offset_min, never the host time zone.
"""

from __future__ import annotations

import math
import re
import time
from typing import Any, Optional

from . import contract as C
from .types import ItemEnergy, RangeResult, Report, Segment

DAY = 86400
CLOSED_ID = C.CLOSED_ID
APP_ICON_FALLBACK = "application-x-executable"
APPS_MIN_H = int(round(C.APPS_MIN_PCT * 100))      # 0.5 points in hundredths

NAMES = {
    "screen": "屏幕",
    "floor": "基本耗电（开着机就有）",
    "ui": "系统界面",
    "sys": "系统后台",
    "wifi": "Wi‑Fi（粗估）",
    "other": "没算清的部分",
    "unrecorded": "没记到是谁用的",
}
EXPLAIN = {
    "screen": "背光和显示面板的耗电，按亮屏时长和当时的平均亮度估出来，是这几项里最准的。",
    "floor": "开着机就要花的电：内存、基带和各种芯片的待机电流，亮屏、熄屏各按一个固定功率算。",
    "ui": "桌面、状态栏、程序坞、控制中心和窗口合成（KWin）画界面用的电。",
    "sys": "系统服务和内核在后台用的电：网络、音频、传感器，还有我们自己的后台服务。",
    "wifi": "按收发的网络包数粗估的 Wi‑Fi 耗电，分不到具体应用。",
    "other": "实测的总耗电比各项估算加起来多出的部分。模型没覆盖到的东西（扬声器、刷新率等）都落在这里。",
    "unrecorded": "这段时间只知道电量掉了多少，不知道是谁用的：那会儿还没开始记录，或者飞行记录器没在记电流。",
    "apps_rest": "每个都不到 0.5% 的应用合在一起。",
}
COMP_NAMES = {"screen": "屏幕", "apps": "应用", "ui": "系统界面", "sys": "系统后台", "wifi": "Wi‑Fi",
              "floor": "基本耗电", "other": "没算清", "unrecorded": "没记到"}
HINT = "亮度每调低 10%，亮屏每小时约少用 {x:.1f}% 电量"
APPS_REST_NAME = "其他应用（{n} 个）"

EMPTY_JUST_FULL = ("刚充满", "拔掉充电器后开始统计这一轮。", "show_24h")
EMPTY_ALL_CHARGER = ("一直插着充电器", "这段时间一直插着充电器，电池没怎么用，所以不分应用。", None)
EMPTY_STARTED = ("刚开始记录", "从 {t} 起记各应用的用电，用一阵子再来看。", None)
EMPTY_DEGRADED = ("没有分项记录", "这段时间飞行记录器没在记电流，只能按电量百分比粗算总量，分不出应用。", None)
EMPTY_NO_LEDGER = ("还没有记录", "用电记录没在运行，只能画电量曲线。", None)

CHARGER_TEXT = {"charging": "正在充电", "full": "已充满 · 正在用充电器",
                "not_charging": "插着充电器 · 没在充电（停在上限）"}
CHARGER_OTHER = "插着充电器"          # plugged while sysfs says discharging / unknown (a charger too weak)

_THEME_ICON = re.compile(r"^[A-Za-z0-9_.+\-]+$")
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


# ---------------------------------------------------------------------------------------------
# Fmt.js twins
# ---------------------------------------------------------------------------------------------

def _lt(t: float, tz: int) -> time.struct_time:
    return time.gmtime(math.floor(t) + int(tz) * 60)


def dur(s: float) -> str:
    """< 60 s 「不到 1 分」; < 1 h 「M 分」; whole hours 「H 小时」; else 「H 小时 M 分」 (minutes floored)."""
    s = max(0, math.floor(s))
    if s < 60:
        return "不到 1 分"
    m = s // 60
    if m < 60:
        return f"{m} 分"
    h, m = divmod(m, 60)
    return f"{h} 小时" if m == 0 else f"{h} 小时 {m} 分"


def clock(t: float, tz: int) -> str:
    g = _lt(t, tz)
    return f"{g.tm_hour:02d}:{g.tm_min:02d}"


def day_clock(t: float, tz: int) -> str:
    return f"{_lt(t, tz).tm_mday}日 {clock(t, tz)}"


def mmdd(t: float, tz: int) -> str:
    g = _lt(t, tz)
    return f"{g.tm_mon:02d}-{g.tm_mday:02d}"


def _day_no(t: float, tz: int) -> int:
    return math.floor((t + int(tz) * 60) / DAY)


def rel(t: float, now: float, tz: int) -> str:
    """「今天 HH:MM」「昨天 HH:MM」, older 「D日 HH:MM」."""
    diff = _day_no(now, tz) - _day_no(t, tz)
    if diff == 0:
        return "今天 " + clock(t, tz)
    if diff == 1:
        return "昨天 " + clock(t, tz)
    return day_clock(t, tz)


# ---------------------------------------------------------------------------------------------
# Numbers
# ---------------------------------------------------------------------------------------------

def largest_remainder(raws: list[float], total: int) -> list[int]:
    """Integers proportional to raws that add up to total; ties go to the earlier index. All zero when the raws
    add up to nothing."""
    s = sum(r for r in raws if r > 0)
    if s <= 0 or total <= 0:
        return [0] * len(raws)
    q = [max(0.0, r) * total / s for r in raws]
    base = [math.floor(x) for x in q]
    rest = total - sum(base)
    order = sorted(range(len(q)), key=lambda i: (-(q[i] - base[i]), i))
    for i in order[:max(0, rest)]:
        base[i] += 1
    return base


def _half_up(x: float) -> int:
    return int(math.floor(x + 0.5 + 1e-9))


def _r(x: float, nd: int) -> float:
    """round() without -0.0."""
    return round(x, nd) + 0.0


def _int(x: Optional[float]) -> Optional[int]:
    if x is None or not math.isfinite(x):
        return None
    return max(0, _half_up(x))


def decimate(curve: list, n_max: int = C.MAX_CURVE, keep: Any = ()) -> list:
    """At most n_max points of a (t, pct) polyline, oldest first: Ramer-Douglas-Peucker on (t / span, pct / 100).

    Each interior point gets the deviation it had when RDP split there, capped by its parent's (so the set kept
    for any tolerance is "importance > tolerance"); the n_max most important survive, with a floor of 0.05 % of
    the axes so near-collinear points go even when there is room. Endpoints and points whose t is in keep (the gap
    edges) always stay. A curve that already fits is returned as is."""
    pts = list(curve)
    if len(pts) <= n_max:
        return pts
    n = len(pts)
    t0, t1 = pts[0][0], pts[-1][0]
    span = max(1.0, float(t1 - t0))
    xy = [((p[0] - t0) / span, p[1] / 100.0) for p in pts]
    keep_t = set(keep)
    fixed = [i == 0 or i == n - 1 or pts[i][0] in keep_t for i in range(n)]
    imp = [math.inf if f else 0.0 for f in fixed]
    anchors = [i for i in range(n) if fixed[i]]
    stack = [(a, b, math.inf) for a, b in zip(anchors, anchors[1:])]
    while stack:
        i, j, cap = stack.pop()
        if j <= i + 1:
            continue
        (x1, y1), (x2, y2) = xy[i], xy[j]
        dx, dy = x2 - x1, y2 - y1
        norm = math.hypot(dx, dy) or 1e-12
        best, bi = -1.0, i + 1
        c = x2 * y1 - y2 * x1
        for k in range(i + 1, j):
            x0, y0 = xy[k]
            d = abs(dy * x0 - dx * y0 + c) / norm
            if d > best:
                best, bi = d, k
        v = min(best, cap)
        imp[bi] = v
        stack.append((i, bi, v))
        stack.append((bi, j, v))
    room = n_max - sum(fixed)
    free = sorted((i for i in range(n) if not fixed[i] and imp[i] > 0.0005), key=lambda i: (-imp[i], i))
    chosen = set(i for i in range(n) if fixed[i])
    if room < 0:
        # more gap edges than room: keep the endpoints and spread the rest evenly
        inner = [i for i in sorted(chosen) if 0 < i < n - 1]
        step = len(inner) / max(1, n_max - 2)
        chosen = {0, n - 1} | {inner[int(k * step)] for k in range(max(0, n_max - 2))}
    else:
        chosen |= set(free[:room])
    return [pts[i] for i in sorted(chosen)]


# ---------------------------------------------------------------------------------------------
# JSON v1
# ---------------------------------------------------------------------------------------------

def _icon(icon: Optional[str]) -> Optional[str]:
    if not icon:
        return None
    if icon.startswith("file:///") or _THEME_ICON.match(icon):
        return icon
    if icon.startswith("/"):
        return "file://" + icon
    return None


def _bands(rng_bands: dict, start: int, end: int) -> dict[str, list[list[int]]]:
    out = {}
    for k in C.BAND_KINDS:
        merged: list[list[int]] = []
        for a, b in sorted(rng_bands.get(k, []) or []):
            x, y = max(start, int(round(a))), min(end, int(round(b)))
            if y <= x:
                continue
            if merged and x <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], y)
            else:
                merged.append([x, y])
        out[k] = merged
    return out


def _curve(curve: list, start: int, end: int, gaps: list[list[int]]) -> list[list]:
    pts = []
    for t, p in curve:
        if not (math.isfinite(t) and math.isfinite(p)):
            continue
        pt = (min(end, max(start, int(round(t)))), _r(min(100.0, max(0.0, p)), 1))
        if not pts or pts[-1] != pt:
            pts.append(pt)
    pts.sort(key=lambda x: x[0])
    keep = {t for g in gaps for t in g}
    return [[t, p] for t, p in decimate(pts, C.MAX_CURVE, keep)]


class _Row:
    """One list row while percentages are made: an ItemEnergy (or the merged apps) and its hundredths."""
    __slots__ = ("kind", "id", "h", "ie", "members")

    def __init__(self, kind: str, iid: str, h: int, ie: Optional[ItemEnergy], members: Optional[list] = None):
        self.kind, self.id, self.h, self.ie, self.members = kind, iid, h, ie, members or []


def _rows(res: RangeResult, used_raw: float, state: str) -> tuple[list[_Row], float, float]:
    """(rows, ratio points/J, sum e_j). Hundredths by largest remainder over every item, then apps_rest."""
    items = [it for it in res.items if it.e_j > 0 and math.isfinite(it.e_j)]
    tot = sum(it.e_j for it in items)
    if tot <= 0:
        return [], 0.0, 0.0
    k = used_raw / tot
    hs = largest_remainder([it.e_j * k for it in items], _half_up(used_raw * 100))
    rows: list[_Row] = []
    small: list[_Row] = []
    for it, h in zip(items, hs):
        kind = it.kind if it.kind in C.ITEM_KINDS else "app"
        r = _Row(kind, it.id, h, it)
        if h <= 0 and not (kind == "unrecorded" and state == "partial"):
            continue                            # 为零的项不列 (the partial range keeps its unrecorded row)
        if kind == "app" and h < APPS_MIN_H:
            small.append(r)
        else:
            rows.append(r)
    if len(small) >= 2:
        small.sort(key=lambda r: (-r.h, -r.ie.e_j, r.id))  # type: ignore[union-attr]
        rows.append(_Row("apps_rest", "apps_rest", sum(r.h for r in small), None, small))
    else:
        rows.extend(small)
    rows.sort(key=lambda r: (-r.h, -(r.ie.e_j if r.ie else 0.0), r.id))
    return rows, k, tot


def _scaled_buckets(bj: list[float], pct_raw: float, nb: int) -> list[float]:
    b = [max(0.0, x) if math.isfinite(x) else 0.0 for x in (list(bj) + [0.0] * nb)[:nb]]
    s = sum(b)
    if nb == 0:
        return []
    if s <= 0:
        b = [0.0] * nb
        b[-1] = pct_raw
        return [_r(x, 3) for x in b]
    f = pct_raw / s
    return [_r(x * f, 3) for x in b]


def _app_split(ie: ItemEnergy, p: float) -> tuple[float, float]:
    """(fg, off) points of an app with pct_raw p (fg + bg = p)."""
    if ie.e_j <= 0:
        return 0.0, 0.0
    fg = min(p, max(0.0, ie.fg_j / ie.e_j * p))
    off = min(p - fg, max(0.0, ie.off_j / ie.e_j * p))
    return fg, off


def _split_doc(fg_raw: float, off_raw: float, p: float, pct: int) -> tuple[dict, dict]:
    sr_fg = _r(min(p, fg_raw), 2)
    sr_bg = _r(max(0.0, p - sr_fg), 2)
    sr_off = _r(min(sr_bg, off_raw), 2)
    if p > 0 and pct > 0:
        fg = min(pct, max(0, _half_up(sr_fg * pct / p)))
        bg = pct - fg
        off = min(bg, max(0, _half_up(sr_off * pct / p)))
    else:
        fg = bg = off = 0
    return {"fg": fg, "bg": bg, "off": off}, {"fg": sr_fg, "bg": sr_bg, "off": sr_off}


def _alive_union_s(res: RangeResult, ids: list[str]) -> float:
    """Seconds at least one of the apps ids was open, from model.py's alive stretches (per boot, mono s)."""
    by_boot: dict[str, list[tuple[float, float]]] = {}
    for iid in ids:
        for b8, a, b in res.alive_iv.get(iid, ()):
            by_boot.setdefault(b8, []).append((a, b))
    tot = 0.0
    for ivs in by_boot.values():
        end = -math.inf
        for a, b in sorted(ivs):
            if b > end:
                tot += b - max(a, end)
                end = b
    return tot


def _item_docs(res: RangeResult, rows: list[_Row], k: float, used: int, nb: int) -> list[dict]:
    pcts = largest_remainder([r.h for r in rows], used)
    bh = res.brightness_hint_pct_h
    out = []
    for r, pct in zip(rows, pcts):
        p = r.h / 100.0
        kind = r.kind
        d: dict[str, Any] = {"id": r.id, "kind": kind, "name": None, "icon": None,
                             "role": C.ROLE_OF_KIND[kind], "pct": pct, "pct_raw": _r(p, 2),
                             "fg_s": None, "bg_s": None, "cpu_s": None, "gpu_s": None, "wake_off_n": None,
                             "split": None, "split_raw": None, "buckets": [], "windows": [], "parts": [],
                             "explain": None, "hint": None, "note": None}
        if kind == "apps_rest":
            ms = r.members
            d["name"] = APPS_REST_NAME.format(n=len(ms))
            d["icon"] = C.ICON_OF_KIND["apps_rest"]
            d["explain"] = EXPLAIN["apps_rest"]
            # the group as one app: in front while any member is (members' fg time never overlaps), open but
            # not in front for the rest of the union of their open time. A sum of the members' bg_s would count
            # the same seconds once per app and run past the range itself
            fg_raw = sum(m.ie.fg_s or 0.0 for m in ms)
            d["fg_s"] = _int(fg_raw) or 0
            d["bg_s"] = _int(max(0.0, _alive_union_s(res, [m.id for m in ms]) - fg_raw)) or 0
            for f in ("cpu_s", "gpu_s", "wake_off_n"):
                vals = [getattr(m.ie, f) for m in ms if getattr(m.ie, f) is not None]
                d[f] = _int(sum(vals)) if vals else None
            fg = off = 0.0
            bsum = [0.0] * nb
            for m in ms:
                mp = m.h / 100.0
                f1, o1 = _app_split(m.ie, mp)
                fg += f1
                off += o1
                mb = _scaled_buckets(m.ie.buckets_j, mp, nb)
                bsum = [a + b for a, b in zip(bsum, mb)]
            d["split"], d["split_raw"] = _split_doc(fg, off, p, pct)
            d["buckets"] = _scaled_buckets(bsum, p, nb)
            d["parts"] = [[m.ie.name or m.id[4:] or m.id, _r(m.h / 100.0, 2)] for m in ms]
            out.append(d)
            continue
        ie = r.ie
        assert ie is not None
        d["buckets"] = _scaled_buckets(ie.buckets_j, p, nb)
        d["note"] = ie.note or None
        if kind == "app":
            d["name"] = ie.name or r.id[4:] or r.id
            d["icon"] = _icon(ie.icon) or (APP_ICON_FALLBACK if r.id == CLOSED_ID else None)
            d["fg_s"] = _int(ie.fg_s) or 0
            d["bg_s"] = _int(ie.bg_s) or 0
            f1, o1 = _app_split(ie, p)
            d["split"], d["split_raw"] = _split_doc(f1, o1, p, pct)
            wins = [[str(n), _int(s) or 0] for n, s in ie.windows if n]
            wins = [w for w in wins if w[1] > 0]
            wins.sort(key=lambda w: (-w[1], w[0]))
            d["windows"] = wins
        else:
            d["name"] = NAMES[kind]
            d["icon"] = C.ICON_OF_KIND[kind]
            d["explain"] = EXPLAIN[kind]
        if kind in ("app", "ui", "sys"):
            d["cpu_s"] = _int(ie.cpu_s)
            d["gpu_s"] = _int(ie.gpu_s)
            d["wake_off_n"] = _int(ie.wake_off_n)
        if kind in ("ui", "sys", "other"):
            parts = [[str(n), _r(v * k, 2)] for n, v in ie.parts if n and v > 0]
            parts = [x for x in parts if x[1] > 0]
            parts.sort(key=lambda x: (-x[1], x[0]))
            d["parts"] = parts
        if kind == "screen" and bh is not None and math.isfinite(bh):
            d["hint"] = HINT.format(x=_r(max(0.0, bh), 1))
        out.append(d)
    return out


def _composition(rows: list[_Row], used: int) -> list[dict]:
    hs: dict[str, int] = {}
    for r in rows:
        ck = C.COMP_OF_ITEM[r.kind]
        hs[ck] = hs.get(ck, 0) + r.h
    kinds = [ck for ck in C.COMP_KINDS if hs.get(ck, 0) > 0]
    pcts = largest_remainder([hs[ck] for ck in kinds], used)
    return [{"kind": ck, "name": COMP_NAMES[ck], "pct": pc, "pct_raw": _r(hs[ck] / 100.0, 2),
             "role": C.ROLE_OF_COMP[ck]} for ck, pc in zip(kinds, pcts)]


def _seg_s(segs: list[Segment], kinds: tuple, degraded: Optional[bool] = None) -> float:
    return sum(s.b - s.a for s in segs if s.kind in kinds and (degraded is None or s.degraded == degraded))


def _coverage_from_segments(rep: Report, res: RangeResult) -> float:
    """No item list (just_full / all_charger / empty): itemised fr energy against itemised + uncovered, the
    uncovered part valued as model.py values the unrecorded item."""
    f_off = rep.coeffs.values.get("F_off", 147.0)
    cov = unc = 0.0
    for s in res.range.segments:
        if s.kind in ("on", "off") and s.e_j:
            cov += max(0.0, s.e_j)
        elif s.kind == "uncovered":
            unc += s.d_pct * res.e_full_j / 100 if s.d_pct > 0 else (s.b - s.a) * f_off / 1000
    return cov / (cov + unc) if cov + unc > 0 else 0.0


def _cur_boot8(rep: Report) -> Optional[str]:
    """The current boot as the segments tell it: the newest boot8 among segments that reach the report's now."""
    best = None
    for res in rep.ranges.values():
        for s in res.range.segments:
            if s.boot8 is not None and (best is None or s.b > best[0]):
                best = (s.b, s.boot8)
    return best[1] if best else None


def _empty_for(rep: Report, res: RangeResult, state: str, tz: int) -> Optional[dict]:
    def obj(tpl: tuple, **kw: Any) -> dict:
        return {"title": tpl[0], "text": tpl[1].format(**kw), "action": tpl[2]}
    if state == "just_full":
        return obj(EMPTY_JUST_FULL)
    if state == "all_charger":
        return obj(EMPTY_ALL_CHARGER)
    if state != "empty":
        return None
    segs = res.range.segments
    deg = _seg_s(segs, ("uncovered",), True)
    if deg > 0 and deg >= _seg_s(segs, ("uncovered",), False):
        return obj(EMPTY_DEGRADED)
    if rep.rec.since is None or not rep.rec.running:
        return obj(EMPTY_NO_LEDGER)
    t = res.range.data_from if res.range.data_from is not None else rep.rec.since
    return obj(EMPTY_STARTED, t=day_clock(t, tz))


def _banners(rep: Report, res: RangeResult, plugged: bool, cur8: Optional[str], secs: dict, tz: int) -> list[dict]:
    segs = res.range.segments
    out: list[tuple[str, str]] = []
    if not rep.rec.running:
        out.append(("recorder_off", "用电记录没在运行"))
    deg = _seg_s(segs, ("uncovered",), True)
    if deg > 0:
        whole = _seg_s(segs, ("on", "off")) <= 0 and _seg_s(segs, ("uncovered",), False) <= 0
        out.append(("degraded", "飞行记录器没在记电流：总耗电按电量百分比粗算，不分应用" if whole
                    else f"有 {dur(deg)}只按电量百分比粗算（飞行记录器没在记电流），这几段不分应用"))
    if secs["gap_s"] >= C.MIN_SPLIT_S:
        out.append(("gap", f"有 {dur(secs['gap_s'])}没记录（关机或重启）"))
    if res.range.unknown_time_boots > 0:
        out.append(("unknown_time", f"有 {res.range.unknown_time_boots} 次开机的时间不明，曲线上接在前一次后面"))
    if rep.rec.clock_unsynced and cur8 is not None and any(s.boot8 == cur8 for s in segs):
        out.append(("clock_unsynced", "时间未校准：这次开机后还没对上网络时间，时刻可能不准"))
    if not res.fg_known and _seg_s(segs, ("on", "off")) >= C.MIN_SPLIT_S:
        out.append(("fg_off", "前台记录没开（refresh-auto 没在运行），这段分不出前台后台"))
    if plugged:
        out.append(("charger_now", CHARGER_TEXT.get(rep.battery.status, CHARGER_OTHER)))
    return [{"kind": k, "level": C.BANNER_LEVEL[k], "text": t} for k, t in out]


def _title_sub(rep: Report, res: RangeResult, key: str, state: str, used: int, used_raw: float,
               charges: int, tz: int) -> tuple[str, str]:
    rng = res.range
    now = math.floor(rep.now)
    if key == "24h":
        if state == "all_charger":
            return "过去 24 小时", "过去 24 小时一直插着充电器"
        return "过去 24 小时", f"过去 24 小时用掉 {used}%" + (f"，充电 {charges} 次" if charges > 0 else "")
    if key == "7d":
        if state == "all_charger":
            return "过去 7 天", "过去 7 天一直插着充电器"
        return "过去 7 天", f"过去 7 天一共用掉 {used}%（约 {used_raw / 100:.1f} 次满电），充电 {charges} 次"
    if rng.anchor == "prev_round":
        a = rng.anchor_t if rng.anchor_t is not None else rng.start
        b = rng.plug_t if rng.plug_t is not None else rng.end
        return "上一轮", f"上一轮：{day_clock(a, tz)} 拔下 → {day_clock(b, tz)} 插上，用掉 {used}%"
    if rng.anchor == "no_full":
        md = mmdd(rng.start, tz)
        if state == "all_charger":
            return f"自 {md} 起（之前没有记录）", f"{md} 起没充满过，一直插着充电器"
        return f"自 {md} 起（之前没有记录）", f"{md} 起没充满过，用掉 {used}%"
    a = rng.anchor_t if rng.anchor_t is not None else rng.start
    if state == "just_full":
        return "自上次充满", f"刚充满：{clock(a, tz)} 拔下"
    sub = f"上次充满：{rel(a, now, tz)}，之后用掉 {used}%"
    if rng.mid_plugs > 0:
        sub += f"，中间插电 {rng.mid_plugs} 次"
    return "自上次充满", sub


def _footnote(rep: Report, high: int) -> str:
    c = rep.coeffs
    if not c.calibrated:
        s = "估算 · 未校准"
    elif c.date and _DATE.match(c.date):
        s = f"估算 · {c.date[5:]} 校准"
    else:
        s = "估算 · 已校准"
    if high > 0:
        s += f" · 有 {high} 段估算偏高，已按实测压低"
    return s


def _range_doc(rep: Report, key: str, res: RangeResult, plugged: bool, cur8: Optional[str]) -> dict:
    rng = res.range
    tz = int(rep.tz_offset_min)
    start, end = int(math.floor(rng.start)), int(math.floor(rng.end))
    if end <= start:
        end = start + 1
    used_raw = _r(max(0.0, res.used_pct_raw if math.isfinite(res.used_pct_raw) else 0.0), 2)
    used = _half_up(used_raw)
    state = rng.state if rng.state in C.STATES else "empty"
    nb = len(rng.bucket_t)
    secs = {k: _int(getattr(res, k)) or 0 for k in ("on_s", "off_s", "charger_s", "gap_s", "uncovered_s")}

    items: list[dict] = []
    comp: list[dict] = []
    if state in ("ok", "partial"):
        rows, k, tot = _rows(res, used_raw, state)
        if rows and any(r.h > 0 for r in rows):
            items = _item_docs(res, rows, k, used, nb)
            comp = _composition(rows, used)
            unrec = sum(it.e_j for it in res.items if it.kind == "unrecorded" and it.e_j > 0)
            coverage = 1.0 - unrec / tot if tot > 0 else 0.0
        else:
            state = "empty"         # nothing to list after all: show the empty text instead of a broken list
    if state not in ("ok", "partial"):
        coverage = _coverage_from_segments(rep, res)

    bands = _bands(rng.bands, start, end)
    df = rng.data_from
    data_from = None if df is None else int(min(end, max(start, math.floor(df))))
    bh = res.brightness_hint_pct_h
    title, sub = _title_sub(rep, res, key, state, used, used_raw, rng.charges, tz)
    return {
        "key": key, "state": state, "start": start, "end": end, "title": title, "sub": sub,
        "used_pct": used, "used_pct_raw": used_raw,
        **secs,
        "coverage": _r(min(1.0, max(0.0, coverage)), 3),
        "data_from": data_from,
        "data_from_text": None if data_from is None else f"从 {day_clock(data_from, tz)} 起才有按应用的记录",
        "brightness_hint_pct_h": None if bh is None or not math.isfinite(bh) else _r(max(0.0, bh), 1),
        "model_high_segments": max(0, int(res.model_high_segments)),
        "unknown_time_boots": max(0, int(rng.unknown_time_boots)),
        "curve": _curve(rng.curve, start, end, bands["gap"]),
        "bands": bands,
        "bucket_s": int(rng.bucket_s),
        "bucket_t": [int(t) for t in rng.bucket_t],
        "items": items,
        "composition": comp,
        "banners": _banners(rep, res, plugged, cur8, secs, tz),
        "empty": _empty_for(rep, res, state, tz),
        "footnote": _footnote(rep, int(res.model_high_segments)),
    }


def _plugged(rep: Report) -> bool:
    return bool(rep.battery.plugged) or rep.battery.status in ("charging", "full", "not_charging")


def to_json(rep: Report) -> dict:
    """The JSON v1 document (6b.a) of a report; contract.validate() is the caller's job."""
    bat = rep.battery
    plugged = _plugged(rep)
    rec = rep.rec
    c = rep.coeffs
    d = rep.diag
    pct = None if bat.pct is None else min(100, max(0, int(bat.pct)))
    remain = None
    if rep.remain is not None and not plugged and math.isfinite(rep.remain.h):
        remain = {"h": _r(max(0.0, rep.remain.h), 1), "basis_h": max(1, int(rep.remain.basis_h))}
    cur8 = _cur_boot8(rep)
    ranges = {k: _range_doc(rep, k, rep.ranges[k], plugged, cur8) for k in C.RANGE_KEYS}

    def opt_int(x: Optional[float]) -> Optional[int]:
        return None if x is None else _int(max(0.0, x))

    def opt_num(x: Optional[float], nd: int, hi: Optional[float] = None) -> Optional[float]:
        if x is None or not math.isfinite(x):
            return None
        x = max(0.0, x)
        return _r(min(hi, x) if hi is not None else x, nd)

    return {
        "v": C.V,
        "now": int(math.floor(rep.now)),
        "tz_offset_min": int(rep.tz_offset_min),
        "took_ms": max(0, int(rep.took_ms)),
        "rec": {"running": bool(rec.running), "degraded": bool(rec.degraded),
                "since": None if rec.since is None else int(math.floor(rec.since)),
                "last_write_age_s": opt_int(rec.last_write_age_s),
                "fg_log": bool(rec.fg_log), "clock_unsynced": bool(rec.clock_unsynced)},
        "battery": {"pct": pct, "status": bat.status if bat.status in C.BAT_STATUS else "unknown",
                    "plugged": plugged, "health_pct": rep.health_pct,
                    "cycles": None if bat.cycles is None or bat.cycles < 0 else int(bat.cycles)},
        "coeffs": {"version": int(c.version), "calibrated": bool(c.calibrated),
                   "date": c.date if c.date and _DATE.match(c.date) else None, "source": c.source},
        "remain": remain,
        "ranges": ranges,
        "diag": {"unexplained_median_7d": opt_num(d.unexplained_median_7d, 3, 1.0),
                 "floor_off_learned_mw": opt_num(d.floor_off_learned_mw, 1),
                 "floor_off_model_mw": opt_num(d.floor_off_model_mw, 1) or 0.0,
                 "coeff_age_days": None if d.coeff_age_days is None else max(0, int(d.coeff_age_days)),
                 "ledger_bytes": max(0, int(d.ledger_bytes)),
                 "ledger_newest_age_s": opt_int(d.ledger_newest_age_s),
                 "energy_age_s": opt_int(d.energy_age_s),
                 "segments_flagged_7d": max(0, int(d.segments_flagged_7d))},
    }


# ---------------------------------------------------------------------------------------------
# --text
# ---------------------------------------------------------------------------------------------

TITLE_OF = {"since_full": "自上次充满", "24h": "过去 24 小时", "7d": "过去 7 天"}


def _wh(j: float) -> str:
    return f"{j / 3600:.3f} Wh"


def _when(t: float, tz: int) -> str:
    return f"{mmdd(t, tz)} {clock(t, tz)}"


def _span(a: float, b: float, tz: int) -> str:
    return f"{_when(a, tz)}–{clock(b, tz) if _day_no(a, tz) == _day_no(b, tz) else _when(b, tz)}"


def to_text(rep: Report, details: Optional[dict] = None, doc: Optional[dict] = None,
            errors: Optional[list[str]] = None) -> str:
    """The agent-facing breakdown (6b.b --text; not a contract): per range the segments, the reconciliation
    groups (details: range key -> [model.GroupDetail]), every item in J / Wh / mean mW next to its points, flags
    and coverage, then the self-check result."""
    tz = int(rep.tz_offset_min)
    doc = doc if doc is not None else to_json(rep)
    L: list[str] = []
    add = L.append
    bat, rec, c, dg = rep.battery, rep.rec, rep.coeffs, rep.diag
    add(f"y700-battery-report --text · 现在 {_when(rep.now, tz)}（UTC{tz / 60:+g}）· now={int(rep.now)} · "
        f"用时 {rep.took_ms} ms")
    full_wh = ""
    if bat.charge_full_uah:
        e_full = next((r.e_full_j for r in rep.ranges.values() if r.e_full_j > 0), 0.0)
        full_wh = f" · charge_full {bat.charge_full_uah / 1e6:.3f} Ah ≈ {e_full / 3600:.2f} Wh"
    add(f"电池：{bat.pct}% · {bat.status} · {'插着电' if doc['battery']['plugged'] else '没插电'} · "
        f"健康 {rep.health_pct}% · 循环 {bat.cycles} 次{full_wh}")
    add(f"记录器：{'在跑' if rec.running else '没在跑'} · {'降级（cov 0）' if rec.degraded else '没降级'} · "
        f"最早 {('—' if rec.since is None else _when(rec.since, tz))} · 最新一行 "
        f"{('—' if rec.last_write_age_s is None else f'{rec.last_write_age_s:.0f} s 前')} · "
        f"前台日志 {'开' if rec.fg_log else '关'} · {'时间未校准' if rec.clock_unsynced else '时间已校准'}")
    add(f"系数：v{c.version} {c.source} {c.path} · {'已校准' if c.calibrated else '未校准'} {c.date or ''} · "
        f"F_on {c.values.get('F_on', '?')} mW · F_off {c.values.get('F_off', '?')} mW · D_on {c.values.get('D_on', '?')} mW")
    rem = doc["remain"]
    add("剩余：" + ("—" if rem is None else f"约 {rem['h']} 小时（按过去一天的放电）" if rem["basis_h"] == 24
                    else f"约 {rem['h']} 小时（按过去 {rem['basis_h']} 小时的放电）"))
    def opt(v: Optional[float], fmt: str) -> str:
        return "—" if v is None else format(v, fmt)
    add(f"体检：没算清中位数 {opt(dg.unexplained_median_7d, '.3f')} · 熄屏段功率 P25 实测 "
        f"{opt(dg.floor_off_learned_mw, '.1f')} mW / 同段模型 {dg.floor_off_model_mw:.1f} mW · 系数 "
        f"{opt(dg.coeff_age_days, 'd')} 天 · 账本 {dg.ledger_bytes} B · 最新一行 {opt(dg.ledger_newest_age_s, '.0f')} s · "
        f"energy {opt(dg.energy_age_s, '.0f')} s · 7 天模型偏高 {dg.segments_flagged_7d} 段")
    for key in C.RANGE_KEYS:
        res = rep.ranges[key]
        rng = res.range
        rd = doc["ranges"][key]
        add("")
        add(f"== {rd['title']} [{key}] state={rd['state']} anchor={rng.anchor} "
            f"{_when(rd['start'], tz)} → {_when(rd['end'], tz)}（{dur(rd['end'] - rd['start'])}）")
        add(f"   {rd['sub']}")
        e_items = sum(it.e_j for it in res.items)
        add(f"   用掉 {rd['used_pct_raw']:.2f}%（按 {res.used_pct_basis}）· E_full {_wh(res.e_full_j)} · "
            f"分项能量 {e_items:.1f} J = {_wh(e_items)} · coverage {rd['coverage']}")
        add(f"   时间：亮屏 {dur(rd['on_s'])} · 熄屏 {dur(rd['off_s'])} · 插电 {dur(rd['charger_s'])} · "
            f"缺口 {dur(rd['gap_s'])} · 不能分项 {dur(rd['uncovered_s'])}")
        add(f"   标记：模型偏高 {rd['model_high_segments']} 段 · 时间不明的开机 {rd['unknown_time_boots']} · "
            f"前台已知 {'是' if res.fg_known else '否'} · 亮度提示 "
            f"{'—' if rd['brightness_hint_pct_h'] is None else str(rd['brightness_hint_pct_h']) + ' %/h'} · "
            f"中间插电 {rng.mid_plugs} · 充电 {rng.charges} 次 · data_from {rd['data_from_text'] or '—'} · "
            f"曲线 {len(rng.curve)} → {len(rd['curve'])} 点 · 桶 {rd['bucket_s']} s × {len(rd['bucket_t'])}")
        if rd["banners"]:
            add("   横幅：" + "；".join(b["text"] for b in rd["banners"]))
        if rd["empty"]:
            add(f"   不分项：{rd['empty']['title']} / {rd['empty']['text']}")
        add(f"   页脚：{rd['footnote']}")
        add("   段：")
        gaps = 0.0
        for s in rng.segments:
            d = s.b - s.a
            if s.kind == "gap":
                gaps += d
                continue
            mw = f" 均 {s.e_j * 1000 / d:7.0f} mW" if s.e_j is not None and d > 0 else ""
            ej = f" E {s.e_j:9.1f} J = {_wh(s.e_j)}" if s.e_j is not None else ""
            flags = (" [降级]" if s.degraded else "") + (" [充电器带不动]" if s.weak_charger else "")
            add(f"     {_span(s.a, s.b, tz):<24} {s.kind:<9} {s.boot8 or '-':<8} {dur(d):<10} "
                f"掉 {s.d_pct:6.2f}%{ej}{mw}{flags}")
        if gaps:
            add(f"     （缺口共 {dur(gaps)}，不逐段列）")
        groups = (details or {}).get(key) or []
        if groups:
            add("   对账组（E 实测，Fix = 底噪 + 屏幕，Soft = 其余；λ 是缩放）：")
            for g in groups:
                d = g.b - g.a
                mw = f" 均 {g.e_j * 1000 / d:6.0f} mW" if d > 0 else ""
                branch = ("全部按比例压低" if g.scale_fix < 1 else "只压 Soft" if g.scale_soft < 1 else "多出的进没算清")
                add(f"     {_span(g.a, g.b, tz):<24} {g.segments} 段 E {g.e_j:8.1f} J Fix {g.fix_j:8.1f} J "
                    f"Soft {g.soft_j:8.1f} J 没算清 {g.other_j:7.1f} J λ_fix {g.scale_fix:.3f} "
                    f"λ_soft {g.scale_soft:.3f}{mw} · {branch}{' [模型偏高]' if g.flagged else ''}")
        if res.items:
            t_items = _seg_s(rng.segments, ("on", "off"))
            t_unc = _seg_s(rng.segments, ("uncovered",))
            by_id = {it["id"]: it for it in rd["items"]}
            rest = next((it for it in rd["items"] if it["kind"] == "apps_rest"), None)
            rest_ids = set()
            if rest is not None:
                rest_names = {n for n, _ in rest["parts"]}
                rest_ids = {ie.id for ie in res.items if ie.kind == "app" and ie.id not in by_id
                            and (ie.name or ie.id[4:]) in rest_names}
            add("   分项（J → 百分点；均 mW 按能分项的放电时长）：")
            for ie in res.items:
                it = by_id.get(ie.id)
                where = ("" if it is not None else " → 其他应用" if ie.id in rest_ids else " → 太小没列")
                pct = f"{it['pct']:>3}% {it['pct_raw']:7.2f}" if it is not None else "   —        "
                t = t_unc if ie.kind == "unrecorded" else t_items
                mw = f" 均 {ie.e_j * 1000 / t:7.1f} mW" if t > 0 else ""
                add(f"     {pct}  {ie.name:<24} {ie.e_j:9.1f} J {_wh(ie.e_j)}{mw}{where}")
                extra = []
                if ie.kind == "app":
                    extra.append(f"前台 {dur(ie.fg_s or 0)} 后台 {dur(ie.bg_s or 0)} · fg {ie.fg_j:.1f} J "
                                 f"bg {ie.bg_j:.1f} J（熄屏 {ie.off_j:.1f} J）")
                if ie.cpu_s is not None or ie.gpu_s is not None or ie.wake_off_n is not None:
                    extra.append(f"处理器 {ie.cpu_s or 0:.0f} s · 图形 {ie.gpu_s or 0:.0f} s · "
                                 f"熄屏唤醒 {ie.wake_off_n or 0:.0f} 次")
                if ie.parts:
                    extra.append("部分：" + "，".join(f"{n} {v:.1f} J" for n, v in ie.parts[:8]))
                if ie.windows:
                    extra.append("窗口：" + "，".join(f"{n} {dur(s)}" for n, s in ie.windows[:6]))
                if ie.note:
                    extra.append("注：" + ie.note)
                for x in extra:
                    add(f"            {x}")
            if rest is not None:
                add(f"     {rest['pct']:>3}% {rest['pct_raw']:7.2f}  {rest['name']}（上面标「→ 其他应用」的几项）")
        if rd["composition"]:
            add("   堆叠条：" + " · ".join(f"{e['name']} {e['pct']}%（{e['pct_raw']}）" for e in rd["composition"]))
    add("")
    if errors is None:
        errors = C.validate(doc)
    add("自检：通过" if not errors else f"自检没通过（{len(errors)} 条）：")
    for e in errors[:50]:
        add("   " + e)
    return "\n".join(L) + "\n"
