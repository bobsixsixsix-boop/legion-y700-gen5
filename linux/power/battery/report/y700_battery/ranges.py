"""Plug timeline, the three page ranges, their segments and bucket grids (DESIGN.md sections 4, 5, 6b.a, 6b.d).

Everything here is wall clock (epoch s, after ledger.assign_clocks / upower.clean). Range start / end,
bands, curve times and bucket_t are whole seconds because JSON v1 wants ints; the segments inside keep
the ledger's fractional seconds and are clipped to the range.

Plug state (DESIGN 4 是否插电) comes from, in priority order: sysfs now, UPower GetHistory states (rate
and charge points), the raw battery status (st) of the ledger's pw-edge snapshots. The charge-control
threshold is never read: bypass lowers it to the current %, so it would make every bypass look full.
The flightrec "pw" vote is not a plug signal either (it only says when to snapshot).

Interpretation choices (each one is listed in the core agent's report):
- A state change seen only by sysfs (the history still says the old state) is placed at the last
  reading of the old state: the uncertain stretch goes to the new state. With a ledger pw-edge st the
  change sits at that snapshot, which is what makes ".dat still charging, sysfs Discharging 5 min" work.
- A ledger st reading loses when the UPower readings on both sides within 10 min agree with each other
  and not with it (UPower is the primary source, the ledger the second one).
- A weak-charger session (mean bat > +50 mW and the % fell) is discharge: never full, never a mid plug.
- Outside the ledger, UPower silence longer than 3 h is a gap (upowerd was not running: powered off).
"""

from __future__ import annotations

import bisect
import math
from dataclasses import dataclass
from typing import Optional

from .types import UP_PLUGGED, Inputs, PlugSession, Range, Segment, Step

DAY = 86400
WINDOWS = {"24h": DAY, "7d": 7 * DAY}
SINCE_BUCKET_SIZES = (900, 1800, 3600, 7200, 10800, 21600, 43200, 86400)
MAX_SINCE_BUCKETS = 48
NO_FULL_LOOKBACK_S = 40 * DAY     # DESIGN 5 case 7: "40 天内一次都没充满"
UP_SHADOW_S = 600.0               # UPower writes merge to 10 min; closer readings outrank a ledger st
UP_SILENCE_S = 3 * 3600.0         # rate points come every poll while upowerd runs
FULL_AFTER_S = 60.0               # a % reading right after the unplug still tells how full it got
UP_UNPLUGGED = frozenset({2, 3, 6})
DISCHARGE = ("on", "off", "uncovered")
_PRIO = {"sysfs": 0, "upower": 1, "ledger": 2}


def st_plugged(st: str) -> Optional[bool]:
    """Raw sysfs battery status -> plugged (True), on battery (False) or unknown (None)."""
    s = st.strip().lower()
    if s in ("charging", "full", "not charging", "not_charging"):
        return True
    if s == "discharging":
        return False
    return None


def overlap(a: float, b: float, c: float, d: float) -> float:
    return max(0.0, min(b, d) - max(a, c))


def overlap_list(a: float, b: float, ivs: list[tuple[float, float]]) -> float:
    """Length of [a, b] covered by ivs (sorted, disjoint)."""
    return sum(overlap(a, b, x, y) for x, y in ivs if y > a and x < b)


def _inside(ivs: list[tuple[float, float]], t: float) -> bool:
    return any(x <= t < y for x, y in ivs)


@dataclass(slots=True)
class _Obs:
    t: float
    plugged: bool
    src: str
    full: bool = False


@dataclass(slots=True)
class BootSpan:
    """A ledger boot on the wall clock: [a, b] = first / last snapshot."""
    boot8: str
    clock: str
    a: float
    b: float
    current: bool
    last_dpms: Optional[int]
    steps: list[Step]
    step_ta: list[float]

    def step_at(self, t: float) -> Optional[int]:
        i = bisect.bisect_right(self.step_ta, t) - 1
        if 0 <= i < len(self.steps) and self.steps[i].ta <= t <= self.steps[i].tb:
            return i
        return None


@dataclass(slots=True)
class Piece:
    """An elementary stretch with one classification (several make a Segment)."""
    a: float
    b: float
    kind: str
    boot8: Optional[str] = None
    dpms: Optional[int] = None
    degraded: bool = False
    weak: bool = False


@dataclass(slots=True)
class Ctx:
    """Everything the range builder and the model share, built once per Inputs."""
    inp: Inputs
    now: int
    sessions: list[PlugSession]
    charger: list[tuple[float, float]]
    weak: list[tuple[float, float]]
    pct: list[tuple[float, float]]
    pct_t: list[float]
    first_data: Optional[float]
    boots: list[BootSpan]
    silences: list[tuple[float, float]]

    def pct_at(self, t: float) -> Optional[float]:
        """Battery % at t, linear between readings, flat outside them."""
        if not self.pct:
            return None
        i = bisect.bisect_right(self.pct_t, t)
        if i == 0:
            return self.pct[0][1]
        if i == len(self.pct):
            return self.pct[-1][1]
        (t0, p0), (t1, p1) = self.pct[i - 1], self.pct[i]
        if t1 <= t0:
            return p1
        return p0 + (p1 - p0) * (t - t0) / (t1 - t0)

    def drop(self, a: float, b: float) -> float:
        pa, pb = self.pct_at(a), self.pct_at(b)
        if pa is None or pb is None:
            return 0.0
        return max(0.0, pa - pb)

    def boot_at(self, t: float) -> Optional[BootSpan]:
        hit = None
        for bs in self.boots:          # later boot wins where clocks overlap
            if bs.a <= t <= bs.b:
                hit = bs
        return hit

    def between_boots(self, t: float) -> bool:
        return any(bs.b < t for bs in self.boots) and any(bs.a > t for bs in self.boots)


# ---------------------------------------------------------------------------------------------
# Plug timeline
# ---------------------------------------------------------------------------------------------

def _pct_series(inp: Inputs, now: float) -> list[tuple[float, float]]:
    pts = [(p.t, float(p.value)) for p in inp.history.charge if p.value > 0 and p.t <= now]
    for b in inp.ledger.boots:
        if b.offset is None:
            continue
        for s in b.snaps:
            if s.cap is not None and s.cap > 0:
                t = b.t(s.m)
                if t <= now:
                    pts.append((t, float(s.cap)))
    if inp.src.battery.pct is not None:
        pts.append((float(now), float(inp.src.battery.pct)))
    pts.sort()
    return pts


def _observations(inp: Inputs, now: float) -> list[_Obs]:
    up: list[_Obs] = []
    for p in list(inp.history.rate) + list(inp.history.charge):
        if p.t > now:
            continue
        if p.state in UP_PLUGGED:
            up.append(_Obs(p.t, True, "upower", p.state == 4))
        elif p.state in UP_UNPLUGGED:
            up.append(_Obs(p.t, False, "upower"))
        # state 0 (unknown) says nothing: upowerd writes one at every start
    up.sort(key=lambda o: o.t)
    up_t = [o.t for o in up]
    obs = list(up)
    for b in inp.ledger.boots:
        if b.offset is None:
            continue
        for s in b.snaps:
            if s.st is None:
                continue
            pl = st_plugged(s.st)
            t = b.t(s.m)
            if pl is None or t > now:
                continue
            i = bisect.bisect_left(up_t, t)
            prev = up[i - 1] if i > 0 else None
            nxt = up[i] if i < len(up) else None
            if (prev is not None and nxt is not None and t - prev.t <= UP_SHADOW_S
                    and nxt.t - t <= UP_SHADOW_S and prev.plugged == nxt.plugged != pl):
                continue
            obs.append(_Obs(t, pl, "ledger", s.st.strip().lower() == "full"))
    bat = inp.src.battery
    obs.append(_Obs(float(now), bool(bat.plugged), "sysfs", bat.status == "full"))
    obs.sort(key=lambda o: (o.t, _PRIO[o.src]))
    return obs


def _step_ends(inp: Inputs) -> dict[str, list[float]]:
    """Each boot's step end times, for the boots whose steps run forward in time (all of them, as the recorder
    writes them): _fr_mean_mw bisects these instead of scanning every step once per plug session."""
    out = {}
    for b8, steps in inp.steps.items():
        if all(p.ta <= q.ta and p.tb <= q.tb for p, q in zip(steps, steps[1:])):
            out[b8] = [st.tb for st in steps]
    return out


def _fr_mean_mw(inp: Inputs, a: float, b: float,
                ends: Optional[dict[str, list[float]]] = None) -> Optional[float]:
    """Mean battery power (signed, + = discharging) over [a, b] from the flightrec accumulator. ends: _step_ends(),
    so only the steps that can overlap [a, b] are looked at (same sums, same order)."""
    num = den = 0.0
    for b8, steps in inp.steps.items():
        tb = ends.get(b8) if ends is not None else None
        # sorted: the steps ending by a do not overlap, nor does anything from the first one starting at b on
        for k in range(bisect.bisect_right(tb, a) if tb is not None else 0, len(steps)):
            st = steps[k]
            if tb is not None and st.ta >= b:
                break
            if st.fr is None or not st.cov or st.tb <= st.ta:
                continue
            ov = overlap(st.ta, st.tb, a, b)
            if ov <= 0:
                continue
            w = ov / (st.tb - st.ta)
            num += w * (st.fr.don + st.fr.doff - st.fr.chg)
            den += w * (st.fr.ton + st.fr.toff)
    if den <= 0:
        return None
    return 1000.0 * num / den          # mJ / ms = W


def _make_sessions(inp: Inputs, now: float, ctx: Ctx) -> list[PlugSession]:
    obs = _observations(inp, now)
    runs: list[list] = []              # [plugged, first obs, last obs, srcs, full]
    for o in obs:
        if runs and runs[-1][0] == o.plugged:
            r = runs[-1]
            r[2] = o
            r[3].add(o.src)
            r[4] = r[4] or o.full
        else:
            runs.append([o.plugged, o, o, {o.src}, o.full])

    def edge(prev: list, nxt: list) -> float:
        first = nxt[1]
        return first.t if first.src != "sysfs" else prev[2].t

    ses: list[PlugSession] = []
    for i, r in enumerate(runs):
        if not r[0]:
            continue
        a = r[1].t if i == 0 else edge(runs[i - 1], r)
        b = None if i == len(runs) - 1 else edge(r, runs[i + 1])
        ses.append(PlugSession(a=a, b=b, full=r[4], src="+".join(sorted(r[3], key=_PRIO.get))))

    merged: list[PlugSession] = []
    for s in ses:
        p = merged[-1] if merged else None
        if p is not None and p.b is not None and s.a - p.b < inp.rules.loose_plug_merge_s:
            p.b = s.b
            p.full = p.full or s.full
            p.src = "+".join(sorted(set(p.src.split("+")) | set(s.src.split("+")), key=_PRIO.get))
        else:
            merged.append(s)

    ends = _step_ends(inp)
    for s in merged:
        end = now if s.b is None else s.b
        lo = bisect.bisect_left(ctx.pct_t, s.a)
        vals = [p for _, p in ctx.pct[lo:bisect.bisect_right(ctx.pct_t, end + FULL_AFTER_S, lo)]]
        s.max_pct = max(vals) if vals else None
        if s.max_pct is not None and s.max_pct >= inp.rules.full_pct:
            s.full = True
        mw = _fr_mean_mw(inp, s.a, end, ends)
        pa, pb = ctx.pct_at(s.a), ctx.pct_at(end)
        if (mw is not None and mw > inp.rules.weak_charger_mw and pa is not None and pb is not None
                and pa - pb >= inp.rules.weak_charger_drop_pct):
            s.weak = True
            s.full = False             # the % fell: this was discharge, not a charge
    return merged


def _boot_spans(inp: Inputs) -> list[BootSpan]:
    cur8 = inp.src.boot_id.replace("-", "")[:8] if inp.src.boot_id else None
    out = []
    for b in inp.ledger.boots:
        if b.offset is None or not b.snaps:
            continue
        steps = list(inp.steps.get(b.boot8, []))
        out.append(BootSpan(boot8=b.boot8, clock=b.clock, a=b.t(b.snaps[0].m), b=b.t(b.snaps[-1].m),
                            current=(b.boot8 == cur8), last_dpms=b.snaps[-1].dpms, steps=steps,
                            step_ta=[s.ta for s in steps]))
    out.sort(key=lambda x: x.a)
    return out


def _make_ctx(inp: Inputs) -> Ctx:
    now = int(math.floor(inp.src.now))
    pct = _pct_series(inp, now)
    ctx = Ctx(inp=inp, now=now, sessions=[], charger=[], weak=[], pct=pct, pct_t=[p[0] for p in pct],
              first_data=None, boots=_boot_spans(inp), silences=[])
    ups = sorted(p.t for p in list(inp.history.rate) + list(inp.history.charge) if p.t <= now)
    ctx.silences = [(x, y) for x, y in zip(ups, ups[1:]) if y - x > UP_SILENCE_S]
    firsts = [t for t in (ups[0] if ups else None,
                          min((bs.a for bs in ctx.boots), default=None)) if t is not None]
    ctx.first_data = min(firsts) if firsts else None
    ctx.sessions = _make_sessions(inp, now, ctx)
    ctx.charger = [(s.a, now if s.b is None else s.b) for s in ctx.sessions if not s.weak]
    ctx.weak = [(s.a, now if s.b is None else s.b) for s in ctx.sessions if s.weak]
    inp.sessions = ctx.sessions
    return ctx


_CACHE: list = []                       # [(inp, ctx)]: one entry, identity-checked


def context(inp: Inputs, refresh: bool = False) -> Ctx:
    """The shared context for inp (built on first use; build() always rebuilds it)."""
    if not refresh and _CACHE and _CACHE[0][0] is inp:
        return _CACHE[0][1]
    ctx = _make_ctx(inp)
    _CACHE[:] = [(inp, ctx)]
    return ctx


def plug_timeline(inp: Inputs) -> list[PlugSession]:
    """Merged plug sessions, oldest first; also stored in inp.sessions."""
    return context(inp, refresh=True).sessions


# ---------------------------------------------------------------------------------------------
# Pieces and segments
# ---------------------------------------------------------------------------------------------

def classify(ctx: Ctx, t: float, window: bool) -> Piece:
    """What the moment t is. window=True for 24h / 7d, which leave unknown-time boots out."""
    bs = ctx.boot_at(t)
    if bs is not None:
        if window and bs.clock == "chained":
            return Piece(t, t, "gap")
        i = bs.step_at(t)
        st = bs.steps[i] if i is not None else None
        dpms = st.dpms if st is not None else None
        if _inside(ctx.charger, t):
            return Piece(t, t, "charger", bs.boot8, dpms)
        weak = _inside(ctx.weak, t)
        if st is not None and st.cov and st.fr is not None and dpms in (0, 1):
            return Piece(t, t, "on" if dpms == 1 else "off", bs.boot8, dpms, False, weak)
        return Piece(t, t, "uncovered", bs.boot8, dpms, True, weak)
    if ctx.between_boots(t):
        return Piece(t, t, "gap")
    if _inside(ctx.charger, t):
        return Piece(t, t, "charger")
    weak = _inside(ctx.weak, t)
    last = ctx.boots[-1] if ctx.boots else None
    if last is not None and last.current and t > last.b:
        # after the newest snapshot of this boot: the state is the last one written (edges snapshot)
        return Piece(t, t, "uncovered", last.boot8, last.last_dpms, False, weak)
    if ctx.first_data is None or t < ctx.first_data or _inside(ctx.silences, t):
        return Piece(t, t, "gap")
    return Piece(t, t, "uncovered", None, None, False, weak)


def pieces(ctx: Ctx, start: float, end: float, window: bool) -> list[Piece]:
    cuts = {float(start), float(end)}

    def add(t: float) -> None:
        if start < t < end:
            cuts.add(t)

    for bs in ctx.boots:
        add(bs.a)
        add(bs.b)
        lo = max(0, bisect.bisect_left(bs.step_ta, start) - 1)
        for st in bs.steps[lo:]:
            if st.ta >= end:
                break
            add(st.ta)
            add(st.tb)
    for x, y in ctx.charger + ctx.weak + ctx.silences:
        add(x)
        add(y)
    if ctx.first_data is not None:
        add(ctx.first_data)
    xs = sorted(cuts)
    out: list[Piece] = []
    for x, y in zip(xs, xs[1:]):
        if y <= x:
            continue
        p = classify(ctx, (x + y) / 2, window)
        p.a, p.b = x, y
        if out and _sig(out[-1]) == _sig(p) and out[-1].b == x:
            out[-1].b = y
        else:
            out.append(p)
    return out


def _sig(p: Piece) -> tuple:
    if p.kind == "gap":
        return ("gap",)
    if p.kind == "charger":
        return ("charger", p.boot8)
    return (p.kind, p.boot8, p.dpms, p.degraded, p.weak)


def step_weight(ctx: Ctx, st: Step, a: float, b: float, counted: bool = False) -> float:
    """Share of a step's accumulator deltas that falls into [a, b]: by time, leaving the step's
    plugged (not weak) part out of both sides, since the deltas were accumulated while discharging.
    counted=True is for what the step counted the whole time (CPU and GPU s, wakeups): the plugged part
    stays in the denominator, so a step that sat on the charger most of the time gives only its unplugged
    share (10-31: weight 1 there made Steam's CPU s and wakeups since full count 25 plugged min)."""
    span = st.tb - st.ta
    if span <= 0:
        return 0.0
    den = span if counted else span - overlap_list(st.ta, st.tb, ctx.charger)
    lo, hi = max(a, st.ta), min(b, st.tb)
    if den <= 0 or hi <= lo:
        return 0.0
    num = (hi - lo) - overlap_list(lo, hi, ctx.charger)
    return max(0.0, min(1.0, num / den))


def segments(ctx: Ctx, ps: list[Piece], seg_max: int) -> list[Segment]:
    out: list[Segment] = []
    for p in ps:
        n = max(1, math.ceil((p.b - p.a) / seg_max - 1e-9))
        for k in range(n):
            a = p.a + (p.b - p.a) * k / n
            b = p.b if k == n - 1 else p.a + (p.b - p.a) * (k + 1) / n
            seg = Segment(boot8=p.boot8, a=a, b=b, kind=p.kind, degraded=p.degraded,  # type: ignore[arg-type]
                          weak_charger=p.weak)
            seg.d_pct = ctx.drop(a, b)
            bs = next((x for x in ctx.boots if x.boot8 == p.boot8), None) if p.boot8 else None
            if bs is not None:
                lo = max(0, bisect.bisect_left(bs.step_ta, a) - 1)
                for i in range(lo, len(bs.steps)):
                    st = bs.steps[i]
                    if st.ta >= b:
                        break
                    if overlap(st.ta, st.tb, a, b) > 0:
                        seg.steps.append(i)
                if seg.kind in ("on", "off"):
                    seg.e_j = sum(step_weight(ctx, bs.steps[i], a, b)
                                  * (bs.steps[i].fr.don + bs.steps[i].fr.doff)  # type: ignore[union-attr]
                                  for i in seg.steps if bs.steps[i].fr is not None) / 1000.0
            out.append(seg)
    return out


def seg_dpms(ctx: Ctx, seg: Segment) -> Optional[int]:
    """Screen state of a segment: on/off by kind, uncovered by what its middle was classified as."""
    if seg.kind == "on":
        return 1
    if seg.kind == "off":
        return 0
    if seg.kind == "uncovered":
        return classify(ctx, (seg.a + seg.b) / 2, False).dpms
    return None


def boot_steps(ctx: Ctx, boot8: Optional[str]) -> list[Step]:
    if boot8 is None:
        return []
    return ctx.inp.steps.get(boot8, [])


# ---------------------------------------------------------------------------------------------
# Bands, curve, buckets
# ---------------------------------------------------------------------------------------------

def int_bands(ivs: list[tuple[float, float]]) -> list[tuple[int, int]]:
    """Whole-second bands, sorted, empty ones dropped, overlapping or touching ones merged."""
    out: list[list[int]] = []
    for a, b in sorted(ivs):
        x, y = int(round(a)), int(round(b))
        if y <= x:
            continue
        if out and x <= out[-1][1]:
            out[-1][1] = max(out[-1][1], y)
        else:
            out.append([x, y])
    return [(x, y) for x, y in out]


def _curve(ctx: Ctx, start: int, end: int, gaps: list[tuple[int, int]]) -> list[tuple[float, float]]:
    if not ctx.pct:
        return []
    t0 = max(float(start), ctx.pct_t[0])
    if t0 > end:
        return []
    pts = [(t, p) for t, p in ctx.pct if start <= t <= end]
    extra = [t0, float(end)]
    for a, b in gaps:
        extra += [t for t in (a, b) if t0 <= t <= end]
    pts += [(t, ctx.pct_at(t)) for t in extra]  # type: ignore[misc]
    out: list[tuple[float, float]] = []
    for t, p in sorted(pts):
        pt = (float(min(end, max(start, int(round(t))))), round(min(100.0, max(0.0, p)), 1))
        if not out or out[-1] != pt:
            out.append(pt)
    out.sort(key=lambda x: x[0])
    return out


def bucket_grid(key: str, start: float, end: float, tz_offset_min: int) -> tuple[int, list[int]]:
    """The bucket grid of DESIGN 6b.a, aligned to local time (t + tz*60) % bucket_s == 0.

    24h / 7d: 24 hourly / 7 daily buckets, the last one is the local hour / day that contains end.
    since_full: the smallest size of SINCE_BUCKET_SIZES that needs <= 48 buckets from the bucket
    containing start to the last bucket with bucket_t[-1] < end <= bucket_t[-1] + bucket_s.
    """
    off = int(tz_offset_min) * 60
    start, end = int(start), int(end)
    if key in WINDOWS:
        bs, n = (3600, 24) if key == "24h" else (DAY, 7)
        last = (end + off) // bs * bs - off
        return bs, [last - (n - 1 - i) * bs for i in range(n)]
    bs = SINCE_BUCKET_SIZES[-1]
    for size in SINCE_BUCKET_SIZES:
        if (end - 1 + off) // size - (start + off) // size + 1 <= MAX_SINCE_BUCKETS:
            bs = size
            break
    first = (start + off) // bs * bs - off
    last = (end - 1 + off) // bs * bs - off
    return bs, list(range(first, last + 1, bs))


def spread(a: float, b: float, bucket_s: int, bucket_t: list[int]) -> list[tuple[int, float]]:
    """Fractions of [a, b] per bucket index; time before the first bucket goes to the first one,
    time after the last bucket to the last one (the 24h / 7d grids start before or after start)."""
    n = len(bucket_t)
    if n == 0 or b <= a:
        return [(0, 1.0)] if n else []
    lo, hi = bucket_t[0], bucket_t[-1] + bucket_s
    out: dict[int, float] = {}
    if a < lo:
        out[0] = out.get(0, 0.0) + (min(b, lo) - a)
    if b > hi:
        out[n - 1] = out.get(n - 1, 0.0) + (b - max(a, hi))
    x, y = max(a, lo), min(b, hi)
    if y > x:
        i = min(n - 1, int((x - lo) // bucket_s))
        while i < n and bucket_t[i] < y:
            ov = overlap(x, y, bucket_t[i], bucket_t[i] + bucket_s)
            if ov > 0:
                out[i] = out.get(i, 0.0) + ov
            i += 1
    tot = b - a
    return [(i, v / tot) for i, v in sorted(out.items())]


# ---------------------------------------------------------------------------------------------
# Ranges
# ---------------------------------------------------------------------------------------------

def _state(segs: list[Segment], min_split: int) -> str:
    def total(kinds: tuple) -> float:
        return sum(s.b - s.a for s in segs if s.kind in kinds)
    if total(DISCHARGE) < min_split and total(("charger",)) > 0:
        return "all_charger"
    if total(("on", "off")) < min_split:
        return "empty"
    # on the whole seconds out.py writes as uncovered_s (half up), so the state and the number always agree
    if math.floor(total(("uncovered",)) + 0.5 + 1e-9) >= min_split:
        return "partial"
    return "ok"


def _charges(ctx: Ctx, ps: list[Piece]) -> int:
    """Plug-ins shown in [ps]: non-weak sessions with charger time there; two of them with nothing but gap
    between them count once (a reboot or power-off while plugged splits the drawn band, not the plug-in)."""
    chg = [(p.a, p.b) for p in ps if p.kind == "charger"]
    known = [(p.a, p.b) for p in ps if p.kind != "gap"]
    chg_b, known_b = [y for _, y in chg], [y for _, y in known]

    def hits(ivs: list[tuple[float, float]], ends: list[float], a: float, b: float) -> bool:
        i = bisect.bisect_right(ends, a)       # the first stretch ending after a starts before b?
        return i < len(ivs) and ivs[i][0] < b

    n = 0
    prev_b: Optional[float] = None
    for s in ctx.sessions:
        b = ctx.now if s.b is None else s.b
        if s.weak or not hits(chg, chg_b, s.a, b):
            continue
        if prev_b is None or hits(known, known_b, prev_b, s.a):
            n += 1
        prev_b = b
    return n


def make_range(ctx: Ctx, key: str, start: int, end: int, **kw) -> Range:
    """Range with its segments, bands, curve and grid; state is the data state (just_full is set
    by the caller)."""
    inp = ctx.inp
    window = key in WINDOWS
    ps = pieces(ctx, start, end, window)
    segs = segments(ctx, ps, inp.rules.segment_max_s)
    rng = Range(key=key, start=start, end=end, state=_state(segs, inp.rules.min_split_s),  # type: ignore[arg-type]
                **kw)
    rng.segments = segs
    bands = {
        "on": int_bands([(p.a, p.b) for p in ps if p.dpms == 1 and p.kind != "gap"]),
        "charger": int_bands([(s.a, s.b) for s in segs if s.kind == "charger"]),
        "gap": int_bands([(s.a, s.b) for s in segs if s.kind == "gap"]),
        "uncovered": int_bands([(s.a, s.b) for s in segs if s.kind == "uncovered"]),
    }
    rng.bands = bands  # type: ignore[assignment]
    rng.curve = _curve(ctx, start, end, bands["gap"])
    rng.bucket_s, rng.bucket_t = bucket_grid(key, start, end, inp.src.tz_offset_min)
    first_item = next((s.a for s in segs if s.kind in ("on", "off")), None)
    if first_item is None:
        # nothing itemised: mark where the screen state becomes known instead (before the ledger's first
        # snapshot nobody recorded it, and the page must not draw that as 熄屏), or the end if it never does
        first_item = next((p.a for p in ps if p.kind != "gap" and p.dpms is not None), float(end))
    if first_item > start and any(s.kind == "uncovered" and s.b <= first_item for s in segs):
        rng.data_from = float(min(end, int(round(first_item))))
    cur = ctx.sessions[-1] if ctx.sessions and ctx.sessions[-1].b is None else None
    rng.plugged_now = bool(inp.src.battery.plugged)
    rng.full_now = bool(cur is not None and cur.full)
    rng.mid_plugs = sum(1 for s in ctx.sessions if not s.weak and s.b is not None
                        and s.a >= start and s.b <= end)
    rng.charges = _charges(ctx, ps)
    if not window:
        rng.unknown_time_boots = sum(1 for bs in ctx.boots if bs.clock == "chained"
                                     and overlap(bs.a, bs.b, start, end) > 0)
    return rng


def _since_full(ctx: Ctx) -> Range:
    inp, now = ctx.inp, ctx.now
    ses = ctx.sessions
    cur = ses[-1] if ses and ses[-1].b is None else None

    def last_full(before: float) -> Optional[PlugSession]:
        # the same 40 days as case 7: an older full charge still in the ledger's oldest part is no anchor
        # (it would also need more than 48 daily buckets)
        lo = now - NO_FULL_LOOKBACK_S
        fulls = [s for s in ses if s.b is not None and s.full and not s.weak and lo <= s.b <= before]
        return fulls[-1] if fulls else None

    if ctx.first_data is not None and ctx.first_data < now:
        earliest = max(ctx.first_data, now - NO_FULL_LOOKBACK_S)
    else:
        earliest = float(now - DAY)
    plug_t = cur.a if cur is not None else None
    just = False
    if cur is not None and cur.full:
        # case 4: plugged and full -> the previous round, up to this plug-in
        end = cur.a
        prev = last_full(cur.a)
        anchor, start = ("prev_round", prev.b) if prev else ("no_full", earliest)
    else:
        end = float(now)
        prev = last_full(now)
        anchor, start = ("full", prev.b) if prev else ("no_full", earliest)
        just = prev is not None and cur is None and now - prev.b < inp.rules.just_full_s
    s_i, e_i = int(round(start)), min(now, int(round(end)))
    if e_i <= s_i and anchor != "full":
        e_i = now                      # nothing before this plug-in: show up to now
    s_i = min(s_i, e_i - 1)
    rng = make_range(ctx, "since_full", s_i, e_i, anchor=anchor,
                     anchor_t=prev.b if prev is not None else None, plug_t=plug_t)
    if just:
        rng.state = "just_full"
    return rng


def build(inp: Inputs) -> dict[str, Range]:
    """The three page ranges (DESIGN 5 for since_full, exact windows for 24h / 7d)."""
    ctx = context(inp, refresh=True)
    out = {"since_full": _since_full(ctx)}
    cur = ctx.sessions[-1] if ctx.sessions and ctx.sessions[-1].b is None else None
    for key, span in WINDOWS.items():
        out[key] = make_range(ctx, key, ctx.now - span, ctx.now, anchor="window",
                              plug_t=cur.a if cur is not None else None)
    return out
