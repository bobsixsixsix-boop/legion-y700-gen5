"""Synthetic ledgers for the report tests: y700-batteryd's and refresh-auto's files without a tablet.

Rec emulates the recorder's writer closely enough that the report cannot tell the difference:
- ids as units.rs hands them out: "/" is 1, KWin 2, everyone else from 3 in discovery order, a new id when a key comes
  back with another inode, all renumbered when the process starts again (start_process());
- groups as main.rs fill/group/commit write them: H + the whole U table + an S with every usage after a head, else
  the not-yet-announced U lines + an S with only the changed cg / gpu, new / gone ids;
- the exact line text of snap.rs render_h / render_u / render_s / render_k (m and w with 2 decimals, edge 1, step 3);
- a write cut short (half()) leaves a fragment without "\\n"; the next write to that part starts with the "\\n" that
  closes it, as ledger.rs does.
Flight integrates a flightrec accumulator at a constant power between calls; fg logs are written as refresh-auto's
log_fg / fg_mark do (fg_esc'd cgroup, class last, START / STOP), numbered parts oldest first.

standard(dir) writes the multi-boot ledger most report tests start from and returns what is in it; build your own
with Rec + write() for anything else. Pure stdlib, no imports from the package under test.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Optional, Union

FR_FIELDS = ("t", "n", "ton", "toff", "don", "doff", "dton", "dtoff", "chg", "tchg",
             "tz", "tzero", "gap", "bl", "lb", "lbt")
KWIN_KEY = "u/session.slice/plasma-kwin_wayland.service"
USER_MGR = "/user.slice/user-1000.slice/user@1000.service"
T0 = 1793000000.0                    # 2026-10-26 09:33:20 UTC: a sane, synced wall clock for boot A
FG_BREAKS = "\n\r\v\f\x1c\x1d\x1e\x85  "

Unit = tuple[str, int]               # (ledger key, inode), the report's UKey


def cg_path(key: str) -> str:
    """The cgroup path of a ledger key (the inverse of units.rs cgroup_key for uid 1000)"""
    if key.startswith("u/"):
        return USER_MGR + "/" + key[2:]
    if key.startswith("s/"):
        return "/system.slice/" + key[2:]
    if key.startswith("l/"):
        return "/user.slice/user-1000.slice/" + key[2:]
    return key


def fg_esc(path: Optional[str]) -> str:
    """refresh-auto fg_esc(): whitespace and line breaks as \\xNN per UTF-8 byte, '-' if unknown"""
    if not path:
        return "-"
    return "".join("".join("\\x%02x" % b for b in c.encode()) if c.isspace() or c in FG_BREAKS else c
                   for c in path)


def _f(v: float, d: int = 2) -> str:
    return "%.*f" % (d, v)


class Flight:
    """flightrec's accumulator (DESIGN section 2 积分规则), advanced at a constant battery power between calls.
    mw > 0 discharges, < 0 charges, 0 is a true zero (tzero). level: backlight level while the screen is on.
    missing() opens a missing-reading run (tz > 0); the next run() closes it by acc.rs's rules (gap past 30 min since
    the last valid reading, backfilled at mw when discharging, else tzero). Without missing() the output is unchanged."""

    def __init__(self, m0: float):
        self.v = dict.fromkeys(FR_FIELDS, 0)
        self.v["t"] = self.v["lbt"] = round(m0 * 1000)
        self.pend = [0, 0]                   # the open missing run, [off, on] ms (acc.rs pend; the line has tz)

    def missing(self, m: float, dpms: bool, level: int = 0) -> "Flight":
        """battmgr gave no reading (a failed read, or 0 while discharging) until m: the time waits in tz"""
        t = round(m * 1000)
        dt = t - self.v["t"]
        if dt <= 0:
            return self
        v = self.v
        v["ton" if dpms else "toff"] += dt
        self.pend[1 if dpms else 0] += dt
        v["tz"] += dt
        if dpms:
            v["bl"] += level * dt
        v["n"] += max(1, dt // 10000)
        v["t"] = t
        return self

    def _close(self, t: int, mw: float) -> None:
        """the next valid reading ends the open run: more than 30 min since the last valid one -> gap; discharging ->
        backfilled per dpms bucket at mw; anything else -> tzero"""
        v = self.v
        pend = self.pend[0] + self.pend[1]
        if t - v["lbt"] > 1_800_000:
            v["gap"] += pend
        elif mw > 0:
            for on in (0, 1):
                v["don" if on else "doff"] += round(mw * self.pend[on] / 1000)
                v["dton" if on else "dtoff"] += self.pend[on]
        else:
            v["tzero"] += pend
        v["tz"] -= pend
        self.pend = [0, 0]

    def run(self, m: float, dpms: bool, mw: float, level: int = 0) -> "Flight":
        t = round(m * 1000)
        dt = t - self.v["t"]
        if dt <= 0:
            return self
        v = self.v
        if self.pend != [0, 0]:
            self._close(t, mw)
        e = round(abs(mw) * dt / 1000)
        v["ton" if dpms else "toff"] += dt
        if mw > 0:
            v["don" if dpms else "doff"] += e
            v["dton" if dpms else "dtoff"] += dt
        elif mw < 0:
            v["chg"] += e
            v["tchg"] += dt
        else:
            v["tzero"] += dt
        if dpms:
            v["bl"] += level * dt
        v["n"] += max(1, dt // 10000)
        v["t"] = v["lbt"] = t
        v["lb"] = int(mw)
        return self

    def dead(self, m_back: float) -> "Flight":
        """flightrec was not running until m_back: on its restart in the same boot it continues the file's counters,
        the time it missed is a gap"""
        t = round(m_back * 1000)
        self.v["gap"] += t - self.v["t"]
        self.v["t"] = t
        return self

    def fr(self) -> dict[str, int]:
        return dict(self.v)


@dataclass
class _U:
    id: int
    ino: int
    announced: bool = False


class Rec:
    """One boot's recorder output. wall_off: raw CLOCK_REALTIME - CLOCK_MONOTONIC (w = m + wall_off); sync: the
    sync flag lines carry. boot: the dashed full id (made up from boot8 if not given)."""

    def __init__(self, boot8: str, wall_off: float, sync: bool = True, boot: Optional[str] = None):
        self.boot8 = boot8
        self.boot = boot or "%s-0000-4000-8000-%s0000" % (boot8, boot8)
        self.wall_off = wall_off
        self.sync = sync
        self.parts: list[str] = [""]          # b- parts by number
        self.fg_parts: list[str] = [""]       # fg parts: .1, .2, ... then the live (unnumbered) one last
        self.log: list[dict] = []             # every written snapshot: {"m", "why", "units", "gpu", "head"}
        self._cut = False
        self.start_process()

    # -- the recorder process

    def start_process(self) -> None:
        """A new y700-batteryd process: ids renumbered, the next group is headed by H why=start"""
        self.live: dict[str, _U] = {}
        self.next_id = 3
        self.reserved: set[int] = set()
        self.gone_ids: list[int] = []
        self.written_cg: dict[int, int] = {}
        self.written_gpu: dict[int, tuple[int, int]] = {}
        self.head: Optional[str] = "start"

    def rotate(self) -> None:
        """The part reached 4 MiB: the next group goes to a new part, headed by H why=part (or start if pending)"""
        self.parts.append("")
        self._cut = False
        if self.head is None:
            self.head = "part"

    def _take_id(self, key: str) -> int:
        r = 1 if key == "/" else 2 if key == KWIN_KEY else None
        if r is not None and r not in self.reserved:
            self.reserved.add(r)
            return r
        i = self.next_id
        self.next_id += 1
        return i

    def _retire(self, key: str) -> None:
        u = self.live.pop(key)
        if u.announced:
            self.gone_ids.append(u.id)

    def _apply(self, units: dict[Unit, Optional[int]]) -> None:
        seen: set[str] = set()
        for key, ino in units:
            if key in seen:
                continue
            seen.add(key)
            u = self.live.get(key)
            if u is not None and u.ino == ino:
                continue
            if u is not None:
                self._retire(key)
            self.live[key] = _U(self._take_id(key), ino)
        for key in [k for k in self.live if k not in seen]:
            self._retire(key)

    def _append(self, text: str) -> None:
        if self._cut:
            text = "\n" + text
            self._cut = False
        self.parts[-1] += text

    def id_of(self, unit: Unit) -> int:
        return self.live[unit[0]].id

    def snap(self, m: float, why: str, units: dict[Unit, Optional[int]], *, dpms: Optional[int] = None,
             pw: Optional[str] = None, cov: bool = True, edge: Optional[float] = None,
             fr: Optional[dict[str, int]] = None, gpu: Optional[dict[Unit, tuple[int, int]]] = None,
             wk: Optional[dict[Union[Unit, str], int]] = None, cl: Optional[list[list[int]]] = None,
             ctx: Optional[int] = None, pkt: Optional[tuple[int, int]] = None, x: Optional[tuple[int, int]] = None,
             st: Optional[str] = None, cap: Optional[int] = None, write: bool = True) -> str:
        """One snapshot group. units: every unit alive now -> usage_usec (None = cpu.stat unreadable), dict order is
        discovery order for new ids. gpu: this process's accumulated (engine_ns, cycles) per unit. wk: per unit or
        "-k". Returns the group's text; write=False leaves the recorder state as a failed write would."""
        self._apply(units)
        usage = {k: units[(k, u.ino)] for k, u in self.live.items()}
        full = self.head is not None
        rows = sorted(self.live.items(), key=lambda kv: kv[1].id)
        cg = [(u.id, usage[k]) for k, u in rows
              if usage[k] is not None and (full or self.written_cg.get(u.id) != usage[k])]
        new = [] if full else [u.id for _, u in rows if not u.announced]
        gone = [] if full else sorted(self.gone_ids)
        acc = {self.live[k].id: v for (k, _ino), v in (gpu or {}).items() if k in self.live}
        g = sorted((i, v) for i, v in acc.items() if (v != (0, 0) if full else self.written_gpu.get(i) != v))
        w = m + self.wall_off
        s = '{"k":"S","why":%s,"m":%s,"w":%s,"sync":%d' % (json.dumps(why), _f(m), _f(w), self.sync)
        if dpms is not None:
            s += ',"dpms":%d' % dpms
        if pw is not None:
            s += ',"pw":%s' % json.dumps(pw)
        s += ',"cov":%d' % cov
        if edge is not None:
            s += ',"edge":%s' % _f(edge, 1)
        if fr is not None:
            s += ',"fr":{%s}' % ",".join('"%s":%d' % (k, fr[k]) for k in FR_FIELDS if k in fr)
        s += ',"cg":{%s}' % ",".join('"%d":%d' % c for c in cg)
        if new:
            s += ',"new":[%s]' % ",".join(map(str, new))
        if gone:
            s += ',"gone":[%s]' % ",".join(map(str, gone))
        s += ',"cl":[%s]' % ",".join("[%d,%d,%d]" % tuple(c) for c in (cl or []))
        if ctx is not None:
            s += ',"ctx":%d' % ctx
        if pkt is not None:
            s += ',"pkt":[%d,%d]' % pkt
        if x is not None:
            s += ',"x":[%d,%d]' % x
        if g:
            s += ',"gpu":{%s}' % ",".join('"%d":[%d,%d]' % (i, e, c) for i, (e, c) in g)
        if wk is not None:
            items = [("-k" if k == "-k" else str(self.live[k[0]].id), n) for k, n in wk.items()]
            s += ',"wk":{%s}' % ",".join("%s:%d" % (json.dumps(k), n) for k, n in items)
        if st is not None:
            s += ',"st":%s' % json.dumps(st)
        if cap is not None:
            s += ',"cap":%d' % cap
        s += "}\n"
        text = ""
        if full:
            text += '{"k":"H","v":1,"boot":%s,"part":%d,"m":%s,"w":%s,"sync":%d,"why":%s}\n' % (
                json.dumps(self.boot), len(self.parts) - 1, _f(m), _f(w), self.sync, json.dumps(self.head))
        for k, u in rows:
            if full or not u.announced:
                text += '{"k":"U","id":%d,"p":%s,"ino":%d}\n' % (u.id, json.dumps(k), u.ino)
        text += s
        if write:
            self.log.append({"m": m, "why": why, "units": dict(units), "gpu": dict(gpu or {}), "head": self.head})
            self._append(text)
            for u in self.live.values():
                u.announced = True
            self.gone_ids = []
            if full:
                self.written_cg, self.written_gpu = {}, {}
            self.written_cg.update(cg)
            self.written_gpu.update(g)
            self.head = None
        return text

    def half(self, m: float, why: str, units: dict[Unit, Optional[int]], cut: int = 60, **kw) -> None:
        """A group whose write() was cut after `cut` bytes (SIGKILL at MemoryMax, ENOSPC): the fragment stays without
        its "\\n" and nothing counts as written"""
        text = self.snap(m, why, units, write=False, **kw)
        self._append(text[:cut])
        self._cut = True

    def step_clock(self, m: float, step: float, sync: Optional[bool] = None, src: str = "chrony") -> None:
        """chrony stepped the wall clock by step s at mono m: a K line (w after the step); sync as asked right after"""
        self.wall_off += step
        if sync is not None:
            self.sync = sync
        self._append('{"k":"K","m":%s,"w":%s,"sync":%d,"src":%s,"step":%s}\n' % (
            _f(m), _f(m + self.wall_off), self.sync, json.dumps(src), _f(step, 3)))

    # -- refresh-auto's foreground log

    def fg_mark(self, m: float, what: str) -> None:
        self.fg_parts[-1] += "%.2f %s\n" % (m, what)

    def fg(self, m: float, pid: int, covers: int, new: Optional[int], prev: Optional[int], cgroup: Optional[str],
           cls: str) -> None:
        """One window report. cgroup: a ledger key (made into its path) or a full cgroup path, None = '-'"""
        path = None if cgroup is None else cgroup if cgroup.startswith("/") else cg_path(cgroup)
        cls = "".join(" " if c in FG_BREAKS else c for c in cls)
        self.fg_parts[-1] += "%.2f %d %d %s %s %s %s\n" % (m, pid, covers, "-" if new is None else new,
                                                           "-" if prev is None else prev, fg_esc(path), cls)

    def fg_raw(self, text: str) -> None:
        self.fg_parts[-1] += text

    def fg_rotate(self) -> None:
        """The live fg log was renamed to the next numbered part; a new live one starts"""
        self.fg_parts.append("")


def _put(path: str, text: str) -> None:
    with open(path, "wb") as f:
        f.write(text.encode("utf-8"))


def write(d: str, recs: list[Rec], order: Optional[list[str]] = None) -> None:
    """The ledger directory: boots.txt (recs' order unless given) and each boot's b- / fg- parts"""
    os.makedirs(d, exist_ok=True)
    _put(os.path.join(d, "boots.txt"), "".join(b + "\n" for b in (order if order is not None
                                                                     else [r.boot8 for r in recs])))
    for r in recs:
        for n, text in enumerate(r.parts):
            if text:
                _put(os.path.join(d, "b-%s.jsonl" % r.boot8 if n == 0 else "b-%s.%d.jsonl" % (r.boot8, n)), text)
        for n, text in enumerate(r.fg_parts[:-1], 1):
            _put(os.path.join(d, "fg-%s.%d.log" % (r.boot8, n)), text)
        if r.fg_parts[-1] or len(r.fg_parts) > 1:
            _put(os.path.join(d, "fg-%s.log" % r.boot8), r.fg_parts[-1])


# ---------------------------------------------------------------------------------------------
# The standard scenario
# ---------------------------------------------------------------------------------------------

ROOT: Unit = ("/", 1)
KWIN: Unit = (KWIN_KEY, 4869)
SYS: Unit = ("/system.slice", 63)
USR: Unit = ("/user.slice", 64)
INIT: Unit = ("/init.scope", 65)
NM: Unit = ("s/NetworkManager.service", 2000)
APPS: Unit = ("u/app.slice", 3000)
SESS: Unit = ("u/session.slice", 3001)
SHELL: Unit = ("u/session.slice/plasma-plasmashell.service", 5464)
FGD: Unit = ("u/app.slice/y700-refresh-auto.service", 6449)
CLAUDE: Unit = ("u/app.slice/app-com.anthropic.Claude-16803.scope", 11937)
TG_DOCK: Unit = ("u/app.slice/app-y700-org.telegram.desktop-3315-12.scope", 12001)
TG_FLAT: Unit = ("u/app.slice/app-flatpak-org.telegram.desktop-4120.scope", 12002)
STEAM: Unit = ("u/app.slice/app-steam-arm64-tri-restore-1700000000.service", 98977)

A, B, C, D = "aaaa0001", "bbbb0002", "cccc0003", "dddd0004"
B_FAKE = T0 + 5800.0                 # fake-hwclock restored a time a bit before A's end
C_FAKE = T0 + 7000.0                 # C boots on a stale clock ...
C_STEP_M, C_STEP = 45.0, 3600.0      # ... chrony steps it at mono 45
C_REAL = C_FAKE + C_STEP
D_FAKE = T0 + 50000.0                # the current boot, never synced (no network since boot)


def _base(u: dict[Unit, int], k: float) -> dict[Unit, int]:
    """every unit's usage grown by k (the cg counters are absolute and only go up)"""
    return {unit: v + int(k * (i + 1) * 1000) for i, (unit, v) in enumerate(u.items())}


def standard(d: str, d_fake: float = D_FAKE) -> dict:
    """Four boots, oldest first:

    A aaaa0001  synced. Two b- parts (H why=part at m 3000); a recorder restart (H why=start at m 5300, ids
                renumbered, gpu from zero, Xwayland's pid changes after it); screen on/off edges with wk; a plug
                session (pw chg edge at 2600 with st=Charging cap 85, pw dis edge at 4000 cap 95); flightrec degraded
                (cov 0, stale fr) at 4600 and 4900, back at 5200 with the missed time as gap; a dock Telegram scope gone
                by 700; the flatpak Telegram scope new at 2500 and gone at the part head (implicit); Steam's restore
                helper new at the part head (implicit); pkt counters reset before the last step. fg log in two parts
                (.1 then the live one) with START / STOP, pid 0 + empty class, a nested cgroup with a space, a class
                with spaces, one garbage line and an unterminated last line.
    B bbbb0002  never synced (fake-hwclock), past: chained after A. A half line, then a recorder restart.
    C cccc0003  boots unsynced, K line at m 45 steps the clock by +3600 s; synced after. Ends in a half line.
    D dddd0004  the current boot, never synced: anchored at now. fg log with only START. Its fake clock is d_fake
                (a d_fake before A: the clock is behind, ledger.assign_clocks starts D after C).

    Returns {"dir", "recs" {boot8: Rec}, "ids" {boot8: [id map per process]}, plus the constants above}."""
    recs: dict[str, Rec] = {}
    # ---- A
    a = recs[A] = Rec(A, T0, sync=True)
    fl = Flight(99.0)
    u1 = {ROOT: 1_000_000, KWIN: 500_000, SYS: 300_000, USR: 600_000, INIT: 10_000, NM: 50_000, APPS: 200_000,
          SESS: 400_000, SHELL: 300_000, FGD: 20_000, TG_DOCK: 1000}
    cl = [[1000, 1_000_000, 5000], [100, 200_000, 5000]]
    a.snap(100.0, "start", u1, dpms=1, pw="dis", fr=fl.run(100.0, True, 1500, 1000).fr(),
           gpu={KWIN: (1_000_000_000, 300_000_000)}, cl=cl, ctx=1_000_000, pkt=(100, 50), x=(2941, 1000),
           st="Discharging", cap=90)
    ids_a1 = {u: a.id_of(u) for u in u1}
    u2 = {**_base(u1, 300), CLAUDE: 900_000}
    u2[TG_DOCK] = 1000                                   # unchanged: not in cg
    a.snap(400.0, "ck", u2, dpms=1, pw="dis", fr=fl.run(400.0, True, 1500, 1000).fr(),
           gpu={KWIN: (1_300_000_000, 390_000_000), CLAUDE: (200_000_000, 60_000_000)},
           cl=[[1600, 1_900_000, 8000], [150, 300_000, 8000]], ctx=1_100_000, pkt=(300, 120), x=(2941, 1050))
    ids_a1[CLAUDE] = a.id_of(CLAUDE)
    u3 = _base({k: v for k, v in u2.items() if k != TG_DOCK}, 300)
    a.snap(700.0, "off", u3, dpms=0, pw="dis", edge=699.5, fr=fl.run(700.0, True, 1500, 1000).fr(),
           gpu={KWIN: (1_400_000_000, 420_000_000), CLAUDE: (260_000_000, 80_000_000)},
           wk={KWIN: 500, CLAUDE: 300, "-k": 1000}, cl=[[2000, 2_500_000, 11000], [200, 400_000, 11000]],
           ctx=1_200_000, pkt=(400, 160), x=(2941, 1100))
    u4 = {**_base(u3, 1800), TG_FLAT: 5000}
    a.snap(2500.0, "ck", u4, dpms=0, pw="dis", fr=fl.run(2500.0, False, 400).fr(),
           gpu={KWIN: (1_400_000_000, 420_000_000), CLAUDE: (260_000_000, 80_000_000)},
           wk={KWIN: 100, FGD: 50, "-k": 2000}, cl=[[2500, 3_000_000, 29000], [220, 440_000, 29000]],
           ctx=1_300_000, pkt=(500, 200), x=(2941, 1100))
    ids_a1[TG_FLAT] = a.id_of(TG_FLAT)
    u5 = _base(u4, 100)
    a.snap(2600.0, "pw", u5, dpms=0, pw="chg", edge=2598.0, fr=fl.run(2600.0, False, 400).fr(),
           cl=[[2510, 3_010_000, 30000], [221, 441_000, 30000]], ctx=1_310_000, pkt=(510, 205), x=(2941, 1100),
           st="Charging", cap=85)
    a.rotate()
    u6 = {**_base({k: v for k, v in u5.items() if k != TG_FLAT}, 400), STEAM: 70_000}
    a.snap(3000.0, "ck", u6, dpms=0, pw="chg", fr=fl.run(3000.0, False, -5000).fr(),
           gpu={KWIN: (1_400_000_000, 420_000_000), CLAUDE: (260_000_000, 80_000_000)},
           wk={"-k": 300}, cl=[[2600, 3_100_000, 34000], [230, 450_000, 34000]], ctx=1_350_000, pkt=(520, 210),
           x=(2941, 1100))
    ids_a1[STEAM] = a.id_of(STEAM)
    u7 = _base(u6, 1000)
    a.snap(4000.0, "pw", u7, dpms=0, pw="dis", edge=3999.0, fr=fl.run(4000.0, False, -5000).fr(),
           gpu={KWIN: (1_400_000_000, 420_000_000), CLAUDE: (260_000_000, 80_000_000)},
           cl=[[2700, 3_200_000, 44000], [240, 460_000, 44000]], ctx=1_400_000, pkt=(530, 215), x=(2941, 1100),
           st="Discharging", cap=95)
    u8 = _base(u7, 300)
    a.snap(4300.0, "on", u8, dpms=1, pw="dis", edge=4299.0, fr=fl.run(4300.0, False, 400).fr(),
           gpu={KWIN: (1_500_000_000, 450_000_000), CLAUDE: (300_000_000, 90_000_000)},
           wk={KWIN: 40, "-k": 600}, cl=[[2800, 3_300_000, 47000], [245, 465_000, 47000]], ctx=1_450_000,
           pkt=(560, 230), x=(2941, 1150))
    stale = fl.run(4450.0, True, 1500, 1000).fr()        # flightrec dies at 4450
    u9 = _base(u8, 300)
    a.snap(4600.0, "ck", u9, dpms=1, pw="dis", cov=False, fr=stale,
           gpu={KWIN: (1_600_000_000, 480_000_000), CLAUDE: (350_000_000, 100_000_000)},
           cl=[[3000, 3_600_000, 50000], [250, 470_000, 50000]], ctx=1_500_000, pkt=(600, 250), x=(2941, 1200))
    u10 = _base(u9, 300)
    a.snap(4900.0, "ck", u10, dpms=1, pw="dis", cov=False, fr=stale,
           gpu={KWIN: (1_700_000_000, 510_000_000), CLAUDE: (400_000_000, 110_000_000)},
           cl=[[3200, 3_900_000, 53000], [255, 475_000, 53000]], ctx=1_550_000, pkt=(640, 270), x=(2941, 1250))
    u11 = _base(u10, 300)
    a.snap(5200.0, "ck", u11, dpms=1, pw="dis", fr=fl.dead(5100.0).run(5200.0, True, 1500, 1000).fr(),
           gpu={KWIN: (1_800_000_000, 540_000_000), CLAUDE: (450_000_000, 120_000_000)},
           cl=[[3400, 4_200_000, 56000], [260, 480_000, 56000]], ctx=1_600_000, pkt=(680, 290), x=(2941, 1300))
    # recorder restart: discovery order changed, so the ids do too
    a.start_process()
    u12 = _base(u11, 100)
    u12 = {CLAUDE: u12[CLAUDE], **{k: v for k, v in u12.items() if k != CLAUDE}}
    a.snap(5300.0, "start", u12, dpms=1, pw="dis", fr=fl.run(5300.0, True, 1500, 1000).fr(),
           gpu={KWIN: (5_000_000, 1_000_000), CLAUDE: (7_000_000, 2_000_000)},
           cl=[[3500, 4_300_000, 57000], [262, 482_000, 57000]], ctx=1_620_000, pkt=(700, 300), x=(2941, 1320),
           st="Discharging", cap=93)
    ids_a2 = {u: a.id_of(u) for u in u12}
    u13 = _base(u12, 300)
    a.snap(5600.0, "ck", u13, dpms=1, pw="dis", fr=fl.run(5600.0, True, 1500, 1000).fr(),
           gpu={KWIN: (6_000_000, 1_200_000), CLAUDE: (9_000_000, 2_500_000)},
           cl=[[3700, 4_600_000, 60000], [264, 484_000, 60000]], ctx=1_700_000, pkt=(740, 320), x=(3999, 10))
    u14 = _base(u13, 300)
    a.snap(5900.0, "term", u14, dpms=1, pw="dis", fr=fl.run(5900.0, True, 1500, 1000).fr(),
           gpu={KWIN: (7_000_000, 1_400_000), CLAUDE: (11_000_000, 3_000_000)},
           cl=[[3900, 4_900_000, 63000], [266, 486_000, 63000]], ctx=1_800_000, pkt=(5, 3), x=(3999, 40))
    a.fg_mark(99.0, "START")
    a.fg(101.0, 3315, 1, 300_000, None, SHELL[0], "plasmashell")
    a.fg(450.0, 16803, 1, 900_000, 330_000, CLAUDE[0], "com.anthropic.Claude")
    a.fg_rotate()
    a.fg(600.0, 0, 0, None, None, None, "")
    a.fg(2650.0, 4120, 1, 500, None, cg_path(TG_FLAT[0]) + "/tray x.scope", "Telegram Desktop")
    a.fg_raw("garbage line\n")
    a.fg(4400.0, 5000, 1, 100, 200, STEAM[0], "steam_app_4242421")
    a.fg_mark(5900.0, "STOP")
    a.fg_raw("5950.00 3315 1 1 1 /user.slice")          # unterminated: dropped
    # ---- B
    b = recs[B] = Rec(B, B_FAKE, sync=False)
    flb = Flight(29.0)
    ub = {ROOT: 100_000, KWIN: 50_000, SYS: 30_000, USR: 60_000, INIT: 1000, NM: 5000, APPS: 20_000,
          SESS: 40_000, SHELL: 30_000, FGD: 2000}
    b.snap(30.0, "start", ub, dpms=1, pw="dis", fr=flb.run(30.0, True, 1200, 800).fr(), cl=cl, ctx=10, pkt=(1, 1),
           x=(2000, 5), st="Discharging", cap=80)
    b.snap(330.0, "ck", _base(ub, 300), dpms=1, pw="dis", fr=flb.run(330.0, True, 1200, 800).fr(), cl=cl, ctx=20,
           pkt=(2, 2), x=(2000, 9))
    b.half(630.0, "ck", _base(ub, 600), dpms=1, pw="dis", fr=flb.run(630.0, True, 1200, 800).fr(), cl=cl)
    b.start_process()
    b.snap(700.0, "start", _base(ub, 670), dpms=1, pw="dis", fr=flb.run(700.0, True, 1200, 800).fr(), cl=cl,
           ctx=40, pkt=(4, 4), x=(2000, 20), st="Discharging", cap=76)
    b.snap(1000.0, "term", _base(ub, 970), dpms=1, pw="dis", fr=flb.run(1000.0, True, 1200, 800).fr(), cl=cl,
           ctx=50, pkt=(5, 5), x=(2000, 25))
    # ---- C
    c = recs[C] = Rec(C, C_FAKE, sync=False)
    flc = Flight(19.0)
    uc = dict(ub)
    c.snap(20.0, "start", uc, dpms=1, pw="dis", fr=flc.run(20.0, True, 1500, 900).fr(), cl=cl, st="Discharging",
           cap=70)
    c.step_clock(C_STEP_M, C_STEP, sync=True)
    c.snap(320.0, "ck", _base(uc, 300), dpms=1, pw="dis", fr=flc.run(320.0, True, 1500, 900).fr(), cl=cl)
    c.snap(620.0, "off", _base(uc, 600), dpms=0, pw="dis", edge=619.0, fr=flc.run(620.0, True, 1500, 900).fr(),
           wk={"-k": 900}, cl=cl)
    c.snap(2420.0, "ck", _base(uc, 2400), dpms=0, pw="dis", fr=flc.run(2420.0, False, 350).fr(),
           wk={"-k": 1800}, cl=cl)
    c.half(2720.0, "ck", _base(uc, 2700), dpms=0, pw="dis", fr=flc.run(2720.0, False, 350).fr(), cl=cl)
    # ---- D
    dd = recs[D] = Rec(D, d_fake, sync=False)
    fld = Flight(14.0)
    dd.snap(15.0, "start", ub, dpms=1, pw="dis", fr=fld.run(15.0, True, 1500, 900).fr(), cl=cl,
            st="Discharging", cap=60)
    dd.snap(315.0, "ck", _base(ub, 300), dpms=1, pw="dis", fr=fld.run(315.0, True, 1500, 900).fr(), cl=cl)
    dd.fg_mark(14.5, "START")
    write(d, [a, b, c, dd])
    return {"dir": d, "recs": recs, "ids": {A: [ids_a1, ids_a2]}, "T0": T0, "B_FAKE": B_FAKE, "C_FAKE": C_FAKE,
            "C_STEP_M": C_STEP_M, "C_STEP": C_STEP, "C_REAL": C_REAL, "D_FAKE": d_fake}
