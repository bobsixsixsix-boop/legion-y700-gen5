"""UPower charge / rate history (DESIGN.md sections 2 "UPower 历史的时间", 4 "是否插电", 6b.b).

Two sources, merged: GetHistory over D-Bus (upowerd's memory, which only goes back to upowerd's start: the 10-30
capture begins at the boot) and the battery's /var/lib/upower/history-{charge,rate}-<id>.dat files (written every
10 min, 7 days each). <id> is up-device.c's model[-<energy_full_design as int>][-serial] with g_strdelimit's
characters made '_'; the design energy wobbles with the voltage, so one battery leaves several files (-33 ... -40 on the
tablet), and Bluetooth devices leave files named after their native path - never read those.

Times are raw CLOCK_REALTIME stamps, and right after boot that clock is fake-hwclock's (or a drifted RTC's) until
chrony steps it. clean() fixes what the ledger can prove (section 2):
  - each boot's ledger lines give its raw clock eras (split at K lines), so a point whose raw time falls in a
    pre-step era is moved by that era's error (boot offset - era offset);
  - a point between two boots (after the previous boot's newest ledger line, before the next boot's mono 0) is
    dropped; so is one no era claims after the ledger began;
  - after that, a point earlier than the last kept one is dropped.
Points before the first ledger boot are kept as recorded: nothing is known about their clock.
"""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from statistics import median
from typing import Iterable, Optional

from .types import UP_STATES, History, Ledger, UpPoint

SANE_WALL = 1.7e9
"""Below this a stamp is the RTC's 1970 or close to it; fake-hwclock stamps are above it and need the eras."""

BOOT_SLACK_S = 120.0
"""How far before a boot's mono 0 a point still belongs to that boot when its first ledger line was already synced:
upowerd's first points come before chrony's step, which no K line recorded. Kept points are off by at most the
(unknown) step, which is small when the RTC kept time."""

_DELIM = set("\\\t\"?' /,.")
_STATE_CODE = {v: k for k, v in UP_STATES.items()}


# ---------------------------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------------------------

def _point(t, v, s) -> Optional[UpPoint]:
    try:
        if isinstance(t, bool) or isinstance(v, bool):
            return None
        t, v = float(t), float(v)
        if isinstance(s, str):
            s = _STATE_CODE[s] if s in _STATE_CODE else int(s)
        s = int(s)
    except (TypeError, ValueError, KeyError):
        return None
    if not (math.isfinite(t) and math.isfinite(v)) or s not in UP_STATES:
        return None
    return UpPoint(t=t, value=v, state=s)


def parse_gethistory(text: str) -> list[UpPoint]:
    """busctl --json=short output of GetHistory ({"type":"a(udu)","data":[[[time, value, state], ...]]}, newest
    first) -> points in recording order, oldest first. Anything unparsable gives []."""
    d = None
    for cand in (text.strip(), *text.strip().splitlines()[:1]):
        try:
            d = json.loads(cand)
            break
        except ValueError:
            continue
    if not isinstance(d, dict) or not isinstance(d.get("data"), list) or not d["data"]:
        return []
    arr = d["data"][0]
    if not isinstance(arr, list):
        return []
    out = []
    for item in reversed(arr):
        if isinstance(item, list) and len(item) == 3:
            p = _point(*item)
            if p is not None:
                out.append(p)
    return out


def parse_dat(text: str) -> list[UpPoint]:
    """A history-*.dat file: "time\\tvalue\\tstate" lines (up-history.c, state as a word such as fully-charged; a
    number is accepted too), in file order (oldest first)."""
    out = []
    for line in text.splitlines():
        f = line.split()
        if len(f) != 3:
            continue
        p = _point(f[0], f[1], f[2])
        if p is not None:
            out.append(p)
    return out


def _delimit(s: str) -> str:
    return "".join("_" if c in _DELIM else c for c in s)


def dat_kind(name: str) -> Optional[tuple[str, str]]:
    """("charge" | "rate", device id) of a history file name, None for other files and kinds"""
    for kind in ("charge", "rate"):
        pre = "history-%s-" % kind
        if name.startswith(pre) and name.endswith(".dat") and len(name) > len(pre) + 4:
            return kind, name[len(pre):-4]
    return None


def battery_dat_names(names: Iterable[str], model: Optional[str]) -> list[str]:
    """The charge / rate .dat names that belong to the battery, sorted.

    With the battery's model_name: ids equal to its delimited form or starting with it plus '-' (the design-energy
    and serial suffixes). upowerd ignores a model of 2 chars or less, and so does this.
    Without one (bp-capture's battery.txt has no model_name): ids of the shape <base>-<integer> and their <base>, for a
    base that is not generic_id and not a native path (Bluetooth devices: "/org/bluez/..." delimited, so starting
    with '_'). The design-energy suffix is what marks a battery; no other device kind gets one."""
    parsed = [(n, k[1]) for n in names for k in [dat_kind(n)] if k is not None]
    if model is not None and len(model.strip()) > 2:
        dm = _delimit(model.strip())
        return sorted(n for n, i in parsed if i == dm or i.startswith(dm + "-"))
    bases = set()
    for _, i in parsed:
        m = re.fullmatch(r"(.+)-\d+", i)
        if m:
            bases.add(m.group(1))
    bases = {b for b in bases if b != "generic_id" and not b.startswith("_")}
    out = []
    for n, i in parsed:
        m = re.fullmatch(r"(.+)-\d+", i)
        if i in bases or (m is not None and m.group(1) in bases):
            out.append(n)
    return sorted(out)


# ---------------------------------------------------------------------------------------------
# Clock correction (section 2)
# ---------------------------------------------------------------------------------------------

@dataclass(slots=True)
class _Era:
    lo: float       # raw epoch s range this era's stamps fall in
    hi: float
    shift: float    # add to a raw stamp to get the corrected time


def _eras(led: Ledger) -> list[_Era]:
    """Raw clock eras of every placed boot, oldest first. A boot's eras are split at its K lines (the K line's own w is
    already after the step); each era's raw offset is the median w - m of its lines. The first era reaches back to
    mono 0 (minus BOOT_SLACK_S when it was already synced), the last one to the boot's newest line - or open-ended
    for the newest boot in the ledger, which may be the current one."""
    out: list[_Era] = []
    placed = [b for b in led.boots if b.offset is not None and (b.heads or b.snaps or b.ksteps)]
    for bi, b in enumerate(placed):
        lines = [(h.m, h.w, h.sync) for h in b.heads] + [(s.m, s.w, s.sync) for s in b.snaps] + \
                [(k.m, k.w, k.sync) for k in b.ksteps]
        last = max(m for m, _, _ in lines)
        cuts = sorted(k.m for k in b.ksteps)
        bounds = [0.0] + cuts + [math.inf]
        n = len(bounds) - 1
        for j in range(n):
            mine = [(w - m, sync) for m, w, sync in lines if bounds[j] <= m < bounds[j + 1]]
            if not mine:
                continue
            r = median(d for d, _ in mine)
            m_lo = bounds[j]
            m_hi = bounds[j + 1] if j < n - 1 else (math.inf if bi == len(placed) - 1 else last)
            lo = r + m_lo
            if j == 0 and any(sync for _, sync in mine):
                lo -= BOOT_SLACK_S
            out.append(_Era(lo=lo, hi=r + m_hi, shift=b.offset - r))
    return out


def clean(points: list[UpPoint], led: Ledger) -> tuple[list[UpPoint], int]:
    """One source's points in recording order -> (kept points with corrected times, number dropped). Also dropped:
    stamps below SANE_WALL and upowerd's start marker (value 0 with state unknown). Needs ledger.assign_clocks()."""
    eras = _eras(led)
    out: list[UpPoint] = []
    dropped = 0
    cur = 0
    entered = False                 # a point has been placed in a ledger era: the "before the ledger" case is over
    last_raw: Optional[float] = None
    last_t: Optional[float] = None
    for p in points:
        if not p.t >= SANE_WALL or (p.value == 0 and p.state == 0):
            dropped += 1
            continue
        t: Optional[float]
        if not eras:
            t = p.t
        else:
            # raw time going back means a new era (a backward step, the next boot's fake clock): look past the current
            start = cur + 1 if entered and last_raw is not None and p.t < last_raw else cur
            j = next((j for j in range(start, len(eras)) if eras[j].lo <= p.t <= eras[j].hi), None)
            if j is not None:
                cur, entered = j, True
                t = p.t + eras[j].shift
            elif not entered and p.t < eras[0].lo:
                t = p.t
            else:
                t = None            # between boots, or before a step no K line recorded
        last_raw = p.t
        if t is None or (last_t is not None and t < last_t):
            dropped += 1
            continue
        out.append(UpPoint(t=t, value=p.value, state=p.state))
        last_t = t
    return out, dropped


def _merge(lists: list[list[UpPoint]]) -> list[UpPoint]:
    """Sorted by time; the same point from D-Bus and a .dat (same second, state and value) kept once"""
    allp = sorted((p for ps in lists for p in ps), key=lambda p: (p.t, p.state, p.value))
    out: list[UpPoint] = []
    for p in allp:
        q = out[-1] if out else None
        if q is not None and int(q.t) == int(p.t) and q.state == p.state and abs(q.value - p.value) <= 1e-3:
            continue
        out.append(p)
    return out


def load(src, led: Ledger) -> History:
    """types.History from a types.Sources: D-Bus JSON and .dat texts, each cleaned on its own (each is one recording
    order), then merged. src.upower_dat holds only the battery's files (sources.py picks them)."""
    srcs: dict[str, list[list[UpPoint]]] = {"charge": [], "rate": []}
    got_dbus = got_dat = False
    for kind, text in (("charge", src.upower_charge_json), ("rate", src.upower_rate_json)):
        if text:
            ps = parse_gethistory(text)
            if ps:
                got_dbus = True
                srcs[kind].append(ps)
    for name in sorted(src.upower_dat or {}):
        k = dat_kind(name)
        if k is None:
            continue
        ps = parse_dat(src.upower_dat[name])
        if ps:
            got_dat = True
            srcs[k[0]].append(ps)
    hist = History(source="dbus+dat" if got_dbus and got_dat else "dbus" if got_dbus else "dat" if got_dat else "none")
    for kind in ("charge", "rate"):
        kept = []
        for ps in srcs[kind]:
            c, n = clean(ps, led)
            kept.append(c)
            hist.dropped += n
        setattr(hist, kind, _merge(kept))
    return hist
