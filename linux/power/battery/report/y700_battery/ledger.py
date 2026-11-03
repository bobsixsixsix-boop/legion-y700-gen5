"""The batteryd ledger and refresh-auto's foreground log (DESIGN.md sections 2, 3 and 6b.d).

Reads ~/.local/state/y700-battery/ as y700-batteryd (recorder/src/{ledger,snap,main,units}.rs) and refresh-auto's
log_fg() write it, and turns it into types.Boot / Step / UnitLife. Everything here follows the writers' rules, so a
change on their side lands here too:

- boots.txt orders the boots (the RTC starts at 1970: file times cannot); b-<boot8>.jsonl is part 0, then
  b-<boot8>.<n>.jsonl, n ascending = newer. fg parts run the other way round: fg-<boot8>.<n>.log oldest first, then the
  unnumbered fg-<boot8>.log, which is always the newest.
- U ids are only valid until the next H and are renumbered from 1 when the recorder restarts, so every map leaving this
  module is keyed by UKey = (path, inode); units are paired across H lines by that pair alone.
- cg / gpu after an H hold every unit; otherwise only what changed since the previous S. new / gone are empty after an
  H: the H's full U table says what came and went.
- A half line (SIGKILL at MemoryMax, ENOSPC) is closed with "\\n" by the next writer: it shows up as one line that does
  not parse and is counted in Boot.bad_lines.

read_dir() is the only function that touches the file system (the interface hands it a path); the rest works on
parsed objects and strings.
"""

from __future__ import annotations

import dataclasses
import json
import math
import os
import stat
from statistics import median
from typing import Iterator, Optional

from .apps import unescape_unit
from .types import (FR_FIELDS, KERNEL, Boot, FgEvent, Fr, FrDelta, Head, KStep, Ledger, Snap, Step, UKey,
                    UnitLife)

SCAN_WHYS = frozenset({"start", "on", "off", "once"})
"""Snapshot reasons that run a thread scan (main.rs snapshot(): plus ck while the screen is off)."""

USER_SLICES = ("app.slice", "session.slice", "background.slice")
_FRD_FIELDS = tuple(f.name for f in dataclasses.fields(FrDelta))
_FR_SET = frozenset(FR_FIELDS)


# ---------------------------------------------------------------------------------------------
# cgroup path -> ledger key (units.rs cgroup_key)
# ---------------------------------------------------------------------------------------------

def _is_unit(name: str) -> bool:
    return name.endswith(".service") or name.endswith(".scope")


def _outer(rest: list[str]) -> Optional[str]:
    """'a/b.service/c' -> 'a/b.service': up to the FIRST .service/.scope component (the outermost unit; refresh-auto's
    fg log names the innermost one, the ledger counts nested cgroups for the unit above them)"""
    for i, c in enumerate(rest):
        if _is_unit(c):
            return "/".join(rest[:i + 1])
    return None


def cgroup_key(path: str, uid: Optional[int] = None) -> str:
    """The ledger key of the unit a cgroup path belongs to, as recorder units.rs cgroup_key() makes it.

    uid: the recorder's own uid (1000 on the tablet). None takes it from the path itself (user-<N>.slice followed by
    user@<N>.service with the same N): the fg log only ever names the session user's windows, and the report may run
    on a machine where that uid means nothing."""
    c = [s for s in path.split("/") if s]
    if not c:
        return "/"
    top = c[0]
    if top == "system.slice":
        u = _outer(c[1:])
        return "s/" + u if u is not None else "/system.slice"
    if top == "init.scope":
        return "/init.scope"
    if top != "user.slice":
        return "/"
    us = c[1] if len(c) > 1 else ""
    if not (us.startswith("user-") and us.endswith(".slice")):
        return "/user.slice"
    n = us[len("user-"):-len(".slice")]
    if uid is not None and n != str(uid):
        return "/user.slice"          # another user's sessions: only in the slice total
    third = c[2] if len(c) > 2 else ""
    if third == "user@%s.service" % n:
        rest = c[3:]
        u = _outer(rest)
        if u is not None:
            return "u/" + u
        if rest and rest[0] in USER_SLICES:
            return "u/" + rest[0]
        return "/user.slice"
    if third.startswith("session-") and third.endswith(".scope"):
        return "l/" + third
    return "/user.slice"


# ---------------------------------------------------------------------------------------------
# refresh-auto's foreground log
# ---------------------------------------------------------------------------------------------

def _fnum(s: str) -> float:
    v = float(s)
    if not math.isfinite(v):
        raise ValueError(s)
    return v


def _opt_int(s: str) -> Optional[int]:
    if s == "-":
        return None
    v = int(s)
    if v < 0:
        raise ValueError(s)
    return v


def _parse_fg(text: str) -> tuple[list[FgEvent], int]:
    """(events, lines dropped). The last piece without its "\\n" is a write in flight or a part cut at rotation:
    dropped, as refresh-auto's own comment asks of readers."""
    out: list[FgEvent] = []
    bad = 0
    pieces = text.split("\n")
    if pieces[-1]:
        bad += 1
    for line in pieces[:-1]:
        if not line:
            continue
        f = line.split(" ", 6)
        try:
            m = _fnum(f[0])
            if len(f) == 2 and f[1] in ("START", "STOP"):
                out.append(FgEvent(m=m, kind="start" if f[1] == "START" else "stop"))
                continue
            if len(f) != 7:
                raise ValueError(line)
            pid = int(f[1])
            covers = int(f[2])
            if pid < 0 or covers not in (0, 1):
                raise ValueError(line)
            raw = f[5]
            # key from the raw field: systemd's own escapes (\x2d) are part of the cgroup's real name and of the
            # ledger key; only the human-facing cgroup gets every \xNN undone
            cg = None if raw == "-" else raw
            out.append(FgEvent(m=m, kind="fg", pid=pid, covers=covers, new_usage=_opt_int(f[3]),
                               prev_usage=_opt_int(f[4]), cgroup=None if cg is None else unescape_unit(cg),
                               key=None if cg is None else cgroup_key(cg), cls=f[6]))
        except (ValueError, IndexError):
            bad += 1
    return out, bad


def read_fg(text: str) -> list[FgEvent]:
    """Events of one fg log part (or of several parts joined in order), oldest first; bad lines are skipped."""
    return _parse_fg(text)[0]


# ---------------------------------------------------------------------------------------------
# The ledger directory
# ---------------------------------------------------------------------------------------------

def _part_name(name: str) -> Optional[tuple[str, int, bool]]:
    """(boot8, part, is an fg log) of a ledger file name, None for anything else (ledger.rs parse_name)"""
    if name.startswith("b-") and name.endswith(".jsonl"):
        fg, rest = False, name[2:-6]
    elif name.startswith("fg-") and name.endswith(".log"):
        fg, rest = True, name[3:-4]
    else:
        return None
    boot, dot, n = rest.partition(".")
    if dot:
        if not (n.isascii() and n.isdigit()):
            return None
        part = int(n)
    else:
        part = 0
    if not boot or not (boot.isascii() and boot.isalnum()):
        return None
    return boot, part, fg


def _read_boots_txt(path: str) -> list[str]:
    try:
        with open(os.path.join(path, "boots.txt"), encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return []
    out: list[str] = []
    for line in text.splitlines():
        b = line.strip()
        if b and b.isascii() and b.isalnum() and b not in out:
            out.append(b)
    return out


def _num(v) -> float:
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        raise ValueError(v)
    return float(v)


def _int(v) -> int:
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        raise ValueError(v)
    return int(v)


def _ids(raw, units: dict[int, UKey]) -> Iterator[tuple[UKey, object]]:
    """(UKey, value) for the ids of an S map that this H declared; other ids are skipped"""
    for i, v in raw.items():
        try:
            u = units.get(int(i))
        except (TypeError, ValueError):
            continue
        if u is not None:
            yield u, v


def _snap(d: dict, head_idx: int, units: dict[int, UKey]) -> Snap:
    def uk(i) -> Optional[UKey]:
        try:
            return units.get(int(i))
        except (TypeError, ValueError):
            return None

    # cg is most of a 40-day ledger's parse time: plain ints skip _int()'s checks (bool is not int here)
    cg: dict[UKey, int] = {u: v if type(v) is int else _int(v) for u, v in _ids(d.get("cg") or {}, units)}
    gpu: dict[UKey, tuple[int, int]] = {u: (_int(v[0]), _int(v[1])) for u, v in _ids(d.get("gpu") or {}, units)}
    wk = None
    if "wk" in d:
        wk = {}
        for i, n in (d["wk"] or {}).items():
            u = KERNEL if i == KERNEL else uk(i)
            if u is not None:
                wk[u] = _int(n)
    fr = None
    if isinstance(d.get("fr"), dict):
        fr = Fr(**{k: v if type(v) is int else _int(v) for k, v in d["fr"].items() if k in _FR_SET})
    cl = [(c[0], c[1], c[2]) if type(c[0]) is type(c[1]) is type(c[2]) is int else (_int(c[0]), _int(c[1]), _int(c[2]))
          for c in (d.get("cl") or [])]
    pkt = d.get("pkt")
    x = d.get("x")
    dpms = d.get("dpms")
    pw = d.get("pw")
    return Snap(why=str(d["why"]), m=_num(d["m"]), w=_num(d["w"]), sync=bool(d.get("sync")), head=head_idx,
                cov=bool(d.get("cov")), dpms=None if dpms is None else _int(dpms),
                pw=pw if pw in ("dis", "chg") else None,
                edge=None if d.get("edge") is None else _num(d["edge"]), fr=fr, cg=cg,
                new=[u for u in (uk(i) for i in d.get("new") or []) if u is not None],
                gone=[u for u in (uk(i) for i in d.get("gone") or []) if u is not None],
                cl=cl, ctx=None if d.get("ctx") is None else _int(d["ctx"]),
                pkt=None if pkt is None else (_int(pkt[0]), _int(pkt[1])),
                x=None if x is None else (_int(x[0]), _int(x[1])), gpu=gpu, wk=wk,
                st=None if d.get("st") is None else str(d["st"]),
                cap=None if d.get("cap") is None else _int(d["cap"]))


def _parse_ledger_text(boot: Boot, text: str) -> None:
    """Append one part file's lines to boot. A U or S line before the file's first H cannot be decoded (its ids belong
    to an H we do not have): counted bad. Every part starts with its own H, so nothing carries over between files."""
    pieces = text.split("\n")
    if not pieces[-1]:
        pieces.pop()
    # else: the last line has no "\n" yet. A whole JSON object cannot be cut and still parse, so it is taken when it
    # parses and counted bad otherwise.
    head: Optional[int] = None
    for line in pieces:
        if not line:
            continue
        try:
            d = json.loads(line)
            if not isinstance(d, dict):
                raise ValueError("not an object")
            k = d.get("k")
            if k == "H":
                h = Head(boot=str(d["boot"]), part=_int(d["part"]), m=_num(d["m"]), w=_num(d["w"]),
                         sync=bool(d.get("sync")), why="part" if d.get("why") == "part" else "start")
                boot.heads.append(h)
                head = len(boot.heads) - 1
                if boot.boot is None:
                    boot.boot = h.boot
            elif k == "U":
                if head is None:
                    raise ValueError("U before H")
                boot.heads[head].units[_int(d["id"])] = (str(d["p"]), _int(d["ino"]))
            elif k == "S":
                if head is None:
                    raise ValueError("S before H")
                boot.snaps.append(_snap(d, head, boot.heads[head].units))
            elif k == "K":
                boot.ksteps.append(KStep(m=_num(d["m"]), w=_num(d["w"]), sync=bool(d.get("sync")),
                                         src=str(d.get("src", "")), step=_num(d.get("step", 0.0))))
            # any other k: a newer recorder's line kind, skipped without counting it bad
        except (ValueError, KeyError, TypeError, IndexError):
            boot.bad_lines += 1


def _read(path: str) -> Optional[bytes]:
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


def read_dir(path: str) -> Ledger:
    """Parse the ledger directory. Boots are ordered by boots.txt; boots with files but missing from boots.txt (it is
    rewritten with the newest half beyond 512 entries) come first, by file mtime - the recorder's own pruning order.
    A missing directory is an empty ledger."""
    led = Ledger(dir=path)
    try:
        names = os.listdir(path)
    except OSError:
        return led
    files: dict[str, dict[str, list[tuple[int, str]]]] = {}
    mtime: dict[str, float] = {}
    for name in names:
        p = _part_name(name)
        if p is None:
            continue
        full = os.path.join(path, name)
        try:
            st = os.stat(full)
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode):
            continue
        b8, part, fg = p
        files.setdefault(b8, {"b": [], "fg": []})["fg" if fg else "b"].append((part, full))
        mtime[b8] = min(mtime.get(b8, st.st_mtime), st.st_mtime)
    listed = [b for b in _read_boots_txt(path) if b in files]
    unlisted = sorted((b for b in files if b not in listed), key=lambda b: (mtime[b], b))
    for b8 in unlisted + listed:
        boot = Boot(boot8=b8)
        for _, full in sorted(files[b8]["b"]):
            data = _read(full)
            if data is None:
                continue
            boot.bytes += len(data)
            _parse_ledger_text(boot, data.decode("utf-8", "replace"))
        # fg: numbered parts oldest first, the unnumbered one (part 0) is the newest
        for _, full in sorted(files[b8]["fg"], key=lambda pf: (pf[0] == 0, pf[0])):
            data = _read(full)
            if data is None:
                continue
            boot.bytes += len(data)
            ev, bad = _parse_fg(data.decode("utf-8", "replace"))
            boot.fg.extend(ev)
            boot.bad_lines += bad
        led.bytes += boot.bytes
        led.boots.append(boot)
    return led


# ---------------------------------------------------------------------------------------------
# Clocks (section 2 时钟)
# ---------------------------------------------------------------------------------------------

def _lines(boot: Boot) -> Iterator[tuple[float, float, bool]]:
    for h in boot.heads:
        yield h.m, h.w, h.sync
    for s in boot.snaps:
        yield s.m, s.w, s.sync
    for k in boot.ksteps:
        yield k.m, k.w, k.sync


def _sync_offset(boot: Boot) -> Optional[float]:
    d = [w - m for m, w, sync in _lines(boot) if sync]
    return median(d) if d else None


def _raw_offset(boot: Boot) -> Optional[float]:
    d = [w - m for m, w, _ in _lines(boot)]
    return median(d) if d else None


def last_m(boot: Boot) -> Optional[float]:
    """mono s of the boot's newest ledger line, None without lines"""
    return max((m for m, _, _ in _lines(boot)), default=None)


def first_m(boot: Boot) -> Optional[float]:
    return min((m for m, _, _ in _lines(boot)), default=None)


def assign_clocks(led: Ledger, cur_boot8: Optional[str], now: float, mono_now: Optional[float]) -> float:
    """Fill Boot.clock / Boot.offset (types.Boot) and return the report's now:

    - sync:    median(w - m) over the boot's sync=1 lines;
    - now:     the current boot never synced: mono_now maps to now. Without mono_now (--from with no mono.txt) its
               newest ledger line is taken as written at now. A clock that is behind (no network since boot, the
               early clock from before any time sync) would start it before the newest line of a placed boot: every past boot then
               lies in the "future" and the report shows this boot alone. It starts at that line instead, like a
               chained boot, still clock "now" (banner 时间未校准), and the returned now moves with it;
    - chained: a past boot that never synced starts (mono 0) where the previous placed boot's newest line is. Leading
               ones with nothing placed before them end where the next placed boot starts; with nothing placed at all,
               the raw w - m is all there is;
    - none:    a boot without ledger lines (only an fg log): nothing to place it by.
    """
    boots = led.boots
    for b in boots:
        b.clock, b.offset = "none", None
        if last_m(b) is None:
            continue
        off = _sync_offset(b)
        if off is not None:
            b.clock, b.offset = "sync", off
        elif cur_boot8 is not None and b.boot8 == cur_boot8:
            anchor = mono_now if mono_now is not None else last_m(b)
            b.clock, b.offset = "now", now - anchor
    prev: Optional[Boot] = None
    for b in boots:
        if b.offset is not None:
            prev = b
        elif last_m(b) is not None and prev is not None:
            b.clock, b.offset = "chained", prev.t(last_m(prev))
            prev = b
    nxt: Optional[Boot] = None
    for b in reversed(boots):
        if b.offset is not None:
            nxt = b
        elif last_m(b) is not None and nxt is not None:
            b.clock, b.offset = "chained", nxt.offset - last_m(b)
            nxt = b
    for b in boots:
        if b.offset is None and last_m(b) is not None:
            b.clock, b.offset = "chained", _raw_offset(b)
    cur = next((b for b in boots if b.clock == "now"), None)
    end = max((b.t(last_m(b)) for b in boots if b is not cur and b.offset is not None), default=None)
    if cur is None or end is None or cur.offset >= end:
        return now
    cur.offset = end
    return cur.t(mono_now if mono_now is not None else last_m(cur))


def newest_wall(led: Ledger) -> Optional[float]:
    """Epoch s of the newest ledger line: Boot.t() once clocks are assigned, else that boot's sync median (raw w for a
    boot that never synced). None for an empty ledger."""
    best: Optional[float] = None
    for b in led.boots:
        lm = last_m(b)
        if lm is None:
            continue
        if b.offset is not None:
            t = b.t(lm)
        else:
            off = _sync_offset(b)
            if off is None:
                off = _raw_offset(b)
            t = lm + off
        best = t if best is None else max(best, t)
    return best


# ---------------------------------------------------------------------------------------------
# Steps and unit lifetimes
# ---------------------------------------------------------------------------------------------

def _is_scan(s: Snap) -> bool:
    return s.why in SCAN_WHYS or (s.why == "ck" and s.dpms == 0) or s.wk is not None


def _walk(boot: Boot) -> Iterator[tuple[Snap, set[UKey], list[UKey], list[UKey], bool]]:
    """Per S line: (snap, units alive after it, came since the previous S, went since the previous S, an H why=start
    lies between the previous S and this one).

    At the first S under an H the alive set is the H's U table (new / gone are left empty by the recorder there),
    minus the units declared after that S: those U lines belong to later groups and show up in their S's new."""
    later: dict[int, set[UKey]] = {}
    seen: set[int] = set()
    for s in boot.snaps:
        if s.head in seen:
            later.setdefault(s.head, set()).update(s.new)
        else:
            seen.add(s.head)
    alive: set[UKey] = set()
    prev_head: Optional[int] = None
    for s in boot.snaps:
        restart = False
        if s.head != prev_head:
            lo = 0 if prev_head is None else prev_head + 1
            restart = prev_head is not None and any(boot.heads[j].why == "start" for j in range(lo, s.head + 1))
            table = set(boot.heads[s.head].units.values()) - later.get(s.head, set())
            after = (table | set(s.new)) - set(s.gone)
        else:
            after = (alive | set(s.new)) - set(s.gone)
        new = sorted(after - alive)
        gone = sorted(alive - after)
        alive = after
        prev_head = s.head
        yield s, alive, new, gone, restart


def _fr_delta(a, b) -> Optional[FrDelta]:
    """None when either end has no accumulator or any counter went back (flightrec's file was reset in this boot).

    tz is not a counter but the length of the missing run still open at that line (acc.rs pend): when the run ends it
    goes back to 0 and its time moves into dton/dtoff, tzero or gap. So its delta is signed and never voids the step;
    dton + dtoff + tchg + tzero + tz + gap still adds up to b.t - a.t (acc.rs time partition)."""
    if a is None or b is None or b.t < a.t or b.n < a.n:
        return None
    vals = {}
    for f in _FRD_FIELDS:
        d = getattr(b, f) - getattr(a, f)
        if d < 0 and f != "tz":
            return None
        vals[f] = d
    return FrDelta(**vals)


def steps(boot: Boot) -> list[Step]:
    """The intervals between consecutive S lines of one boot (types.Step).

    cov is True only when BOTH ends had a live accumulator: flightrec dying is not an edge, so no snapshot marks it, and
    an interval that ends degraded was not fully integrated even when it started covered."""
    out: list[Step] = []
    off = boot.offset if boot.offset is not None else (_raw_offset(boot) or 0.0)
    cpu_last: dict[UKey, int] = {}
    gpu_last: dict[UKey, tuple[int, int]] = {}
    scan_m: Optional[float] = None
    prev: Optional[Snap] = None
    for s, _alive, new, gone, restart in _walk(boot):
        cpu: dict[UKey, int] = {}
        for u, v in s.cg.items():
            base = cpu_last.get(u)
            # first seen after the boot's first S: its whole usage is this step's. A counter going back means a
            # new cgroup under a reused inode: counted from zero too.
            d = v - base if base is not None and v >= base else v
            if d > 0:
                cpu[u] = d
            cpu_last[u] = v
        gpu: Optional[dict[UKey, tuple[int, int]]] = None
        if restart or prev is None:
            gpu_last = dict(s.gpu)              # a new recorder process: its accumulator starts over
        else:
            gpu = {}
            for u, (e, c) in s.gpu.items():
                be, bc = gpu_last.get(u, (0, 0))
                de, dc = e - be, c - bc
                if de < 0 or dc < 0:
                    de, dc = e, c
                if de or dc:
                    gpu[u] = (de, dc)
                gpu_last[u] = (e, c)
        wk = since = None
        if _is_scan(s):
            if s.wk is not None and not restart:
                wk, since = s.wk, scan_m
            scan_m = s.m
        if prev is not None:
            a, b = prev, s
            cl: list[tuple[int, int, int]] = []
            if a.cl and len(a.cl) == len(b.cl):
                cl = [(cb[0] - ca[0], cb[1] - ca[1], cb[2] - ca[2]) for ca, cb in zip(a.cl, b.cl)]
                if any(v < 0 for c in cl for v in c):
                    cl = []
            ctx = b.ctx - a.ctx if a.ctx is not None and b.ctx is not None and b.ctx >= a.ctx else None
            pkt = None
            if a.pkt is not None and b.pkt is not None:
                drx, dtx = b.pkt[0] - a.pkt[0], b.pkt[1] - a.pkt[1]
                pkt = drx + dtx if drx >= 0 and dtx >= 0 else None   # an interface went down and up: unknown
            xt = None
            if a.x is not None and b.x is not None and a.x[0] == b.x[0] and b.x[1] >= a.x[1]:
                xt = b.x[1] - a.x[1]
            out.append(Step(boot8=boot.boot8, ma=a.m, mb=b.m, ta=a.m + off, tb=b.m + off, dpms=a.dpms, pw=a.pw,
                            cov=a.cov and b.cov, restart=restart, fr=_fr_delta(a.fr, b.fr), cpu=cpu, gpu=gpu,
                            wk=wk, wk_since_m=since, cl=cl, ctx=ctx, pkt=pkt, x_ticks=xt, new=new, gone=gone))
        prev = s
    return out


def lives(boot: Boot) -> dict[UKey, UnitLife]:
    """Per UKey: first / last snapshot that had it alive, the snapshot that found it gone, first / last usage seen."""
    out: dict[UKey, UnitLife] = {}
    used: set[UKey] = set()
    prev_m: Optional[float] = None
    last_s: Optional[float] = None
    alive: set[UKey] = set()
    for s, alive, new, gone, _restart in _walk(boot):
        for u in new:
            life = out.get(u)
            if life is None:
                out[u] = UnitLife(ukey=u, boot8=boot.boot8, first_m=s.m, last_m=s.m)
            else:
                life.gone_m = None            # back after a gap (a head that missed it)
        for u in gone:
            life = out[u]
            life.last_m = prev_m if prev_m is not None else life.first_m
            life.gone_m = s.m
        for u, v in s.cg.items():
            life = out.get(u)
            if life is None:                  # usage for a unit not in the table: kept, not invented as alive
                life = out[u] = UnitLife(ukey=u, boot8=boot.boot8, first_m=s.m, last_m=s.m)
            if u not in used:
                life.first_usage = v
                used.add(u)
            life.last_usage = v
        prev_m = last_s = s.m
    if last_s is not None:
        for u in alive:
            out[u].last_m = last_s
    return out
