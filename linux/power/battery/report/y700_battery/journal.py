"""CPU a user unit used after the ledger last saw it (DESIGN.md section 4 "已退出的单元").

systemd logs one "Consumed" message per unit stop (MESSAGE_ID ae8f7b866b0347b9af31fe1c80b127c0) with the unit's
lifetime CPU_USAGE_NSEC. The ledger only sees a unit at snapshots, so whatever it used between its last snapshot and
its exit - or all of it, for a unit that came and went between two snapshots - is that total minus the ledger's last
value, added to the step the exit falls in.
"""

from __future__ import annotations

import json
from typing import Iterable, Optional

from .types import Consumed, ExitFix, Ledger, UKey, UnitLife

CONSUMED_ID = "ae8f7b866b0347b9af31fe1c80b127c0"

MATCH_TOL_S = 2.0
"""Slack between a snapshot's m and the exit's m: the recorder takes m after reading the counters, journald stamps the
message after the unit stopped."""


def _s(v) -> Optional[str]:
    """A journal JSON field as text: journalctl writes non-UTF-8 values as byte arrays and repeated fields as lists"""
    if v is None:
        return None
    if isinstance(v, str):
        return v
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return str(v)
    if isinstance(v, list) and v:
        if all(isinstance(b, int) and 0 <= b < 256 for b in v):
            return bytes(v).decode("utf-8", "replace")
        return _s(v[0])
    return None


def parse(lines: Iterable[str]) -> list[Consumed]:
    """journalctl -o json lines -> Consumed; lines that are not such a message (or lack a field) are skipped."""
    out: list[Consumed] = []
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if not isinstance(d, dict):
            continue
        mid = _s(d.get("MESSAGE_ID"))
        if mid is not None and mid != CONSUMED_ID:
            continue
        unit, boot = _s(d.get("USER_UNIT")), _s(d.get("_BOOT_ID"))
        nsec, mono, real = _s(d.get("CPU_USAGE_NSEC")), _s(d.get("__MONOTONIC_TIMESTAMP")), \
            _s(d.get("__REALTIME_TIMESTAMP"))
        if not unit or not boot or nsec is None or mono is None:
            continue
        boot8 = boot.replace("-", "").lower()[:8]
        try:
            cpu = int(nsec) // 1000
            m = int(mono) / 1e6
            w = int(real) / 1e6 if real is not None else 0.0
        except ValueError:
            continue
        if len(boot8) != 8 or cpu < 0:
            continue
        out.append(Consumed(unit=unit, cpu_usec=cpu, boot8=boot8, m=m, w=w))
    return out


def _unit_name(key: str) -> str:
    return key.rsplit("/", 1)[-1]


def attach(consumed: Iterable[Consumed], led: Ledger, lives: dict[str, dict[UKey, UnitLife]]) -> list[ExitFix]:
    """Pair each exit with the ledger unit it ended (types.ExitFix).

    - Boots the ledger does not have, and exits before the boot's first snapshot, have no step to go to: dropped.
    - Candidates are the boot's units with the same unit name. The one that ended is alive at or before the exit
      (first_m <= m), was last seen no later than the exit and was not already gone well before it; the latest such
      wins. extra = lifetime total - its last ledger usage; negative (a counter from another cgroup) is dropped.
    - An instance of that name alive across the exit is a different one (the same unit restarted): this exit cannot be
      told apart from it, so it is dropped rather than counted twice.
    - No instance near the exit: the unit came and went between snapshots; all of its CPU is extra, keyed by the same
      name's key from any boot, else systemd's default slice for user units, "u/app.slice/<unit>".
    """
    boots = {b.boot8: b for b in led.boots}
    by_name: dict[tuple[str, str], list[UnitLife]] = {}
    any_key: dict[str, str] = {}
    for b8, ls in lives.items():
        for u, life in ls.items():
            n = _unit_name(u[0])
            by_name.setdefault((b8, n), []).append(life)
            any_key.setdefault(n, u[0])
    out: list[ExitFix] = []
    for c in consumed:
        b = boots.get(c.boot8)
        if b is None or not b.snaps or c.m < b.snaps[0].m:
            continue
        cands = by_name.get((c.boot8, c.unit), [])
        near = [l for l in cands
                if l.first_m <= c.m + MATCH_TOL_S and (l.gone_m is None or l.gone_m >= c.m - MATCH_TOL_S)]
        ended = [l for l in near if l.last_m <= c.m + MATCH_TOL_S]
        if ended:
            life = max(ended, key=lambda l: l.last_m)
            extra = c.cpu_usec - life.last_usage
            if extra >= 0:
                out.append(ExitFix(consumed=c, ukey=life.ukey, key=life.ukey[0], boot8=c.boot8, m_exit=c.m,
                                   extra_usec=extra))
            continue
        if near:
            continue
        key = any_key.get(c.unit, "u/app.slice/" + c.unit)
        out.append(ExitFix(consumed=c, ukey=None, key=key, boot8=c.boot8, m_exit=c.m, extra_usec=c.cpu_usec))
    return out
