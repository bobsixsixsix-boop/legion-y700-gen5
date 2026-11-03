"""--fit: suggest coefficients from the ledger (DESIGN.md section 4, 6b.b). Never writes a file.

Rows are model.py's reconciliation groups over all the ledger holds (a range from the first data to now): the
measured flightrec energy E of each group against the model terms that are linear in one coefficient each:
F_on, F_off (floor), D_on, B (screen), Pmax_little, Pmax_big (the CPU price kappa), Pg (app GPU, Xwayland and the
KWin composition estimate), k_pkt (Wi-Fi, below its P_wifi_max cap) and A (screen-off wakeups). Column k is the
model's Fix + Soft with every other fitted coefficient set to zero, so E ~ sum_k scale_k * column_k. Rows are
divided by the group's span (mean mW), so a long group does not outweigh many short ones.

Non-negative least squares (Lawson-Hanson). Columns the data cannot tell apart (F_on and D_on are both "screen-on
seconds" times a constant) are tied to one shared scale. A scale outside x0.5..x2 is not suggested: that
coefficient stays at x1 and the rest are fitted again (worst offender first), so the suggestion never relies on a
value it would refuse. The suggested coeffs-v<N+1>.json is the current file with only the accepted entries
changed; whether to install it is a human decision (DESIGN: 采不采用由人手动决定).

numpy is imported inside fit() only (6b.d): the report itself stays pure stdlib.
"""

from __future__ import annotations

import copy
import dataclasses
import datetime
import json
import math
from typing import Any, Callable, Optional

from . import config, model
from . import ranges as R
from .types import Coeffs, Inputs

FIT_COEFFS = ("F_on", "F_off", "D_on", "B", "Pmax_little", "Pmax_big", "Pg", "k_pkt", "A")
LO, HI = 0.5, 2.0
MIN_ROWS = 8
MIN_SPAN_S = 60.0
TIE_COS = 0.9999            # columns this parallel cannot be told apart by any fit
LOOKBACK_S = 40 * 86400

Lstsq = Callable[[list[list[float]], list[float]], list[float]]


class FitError(Exception):
    """Not enough data to fit: str(e) is the Chinese reason."""


class NeedNumpy(Exception):
    """numpy is not installed (cli prints 「--fit 要 numpy」, exit 2)."""


# ---------------------------------------------------------------------------------------------
# Design matrix (pure Python)
# ---------------------------------------------------------------------------------------------

def _only(c: Coeffs, keep: Optional[str]) -> Coeffs:
    """c with every fitted coefficient zero except keep (at its current value)."""
    vals = dict(c.values)
    for k in FIT_COEFFS:
        if k != "B":
            vals[k] = model.coeff(c, k) if k == keep else 0.0
    pts = list(c.b_points or model.B_DEFAULT) if keep == "B" else [(0.0, 0.0), (4095.0, 0.0)]
    return dataclasses.replace(c, values=vals, b_points=pts)


def all_data_range(inp: Inputs) -> Any:
    """One since_full-style range over everything the inputs hold (chained boots included)."""
    ctx = R.context(inp, refresh=True)
    first = ctx.first_data if ctx.first_data is not None else ctx.now - LOOKBACK_S
    start = int(math.floor(max(first, ctx.now - LOOKBACK_S)))
    return R.make_range(ctx, "since_full", min(start, ctx.now - 1), ctx.now, anchor="no_full")


def design(inp: Inputs) -> dict:
    """{"rows": [(a, b, span_s, E_J)], "cols": {coeff: [J per row]}, "base": [J per row]}.

    base is the model with every fitted coefficient zero (terms that no fitted coefficient scales); it is taken
    off E before fitting."""
    rng = all_data_range(inp)
    det0 = model.attribute_detail(rng, inp)[1]
    rows = [(g.a, g.b, max(MIN_SPAN_S, g.b - g.a), g.e_j) for g in det0]
    cols: dict[str, list[float]] = {}
    for k in (None,) + FIT_COEFFS:
        ik = dataclasses.replace(inp, coeffs=_only(inp.coeffs, k))
        det = model.attribute_detail(rng, ik)[1]
        if len(det) != len(rows):
            raise FitError("拟合时分组对不上（模型分组随系数变了）")
        cols["" if k is None else k] = [g.fix_j + g.soft_j for g in det]
    base = cols.pop("")
    return {"rows": rows, "cols": cols, "base": base}


# ---------------------------------------------------------------------------------------------
# NNLS
# ---------------------------------------------------------------------------------------------

def _dot(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b))


def nnls(cols: list[list[float]], y: list[float], lstsq: Lstsq, max_iter: int = 200) -> list[float]:
    """Lawson-Hanson: min |A x - y| with x >= 0, A given column-wise; lstsq solves the unconstrained
    sub-problems on the passive columns."""
    n = len(cols)
    x = [0.0] * n
    passive: list[int] = []
    scale = max((abs(v) for c in cols for v in c), default=1.0) or 1.0
    tol = 1e-10 * scale * max(1, len(y))

    def resid(v: list[float]) -> list[float]:
        return [yi - sum(v[j] * cols[j][i] for j in range(n)) for i, yi in enumerate(y)]

    it = 0
    while it < max_iter:
        r = resid(x)
        w = [_dot(c, r) for c in cols]
        cand = [j for j in range(n) if j not in passive and w[j] > tol]
        if not cand:
            break
        passive.append(max(cand, key=lambda j: w[j]))
        while True:
            it += 1
            sub = lstsq([cols[j] for j in passive], y)
            z = [0.0] * n
            for j, v in zip(passive, sub):
                z[j] = v
            if all(z[j] > 0 for j in passive) or it >= max_iter:
                x = [max(0.0, v) for v in z]
                break
            alpha = min(x[j] / (x[j] - z[j]) for j in passive if z[j] <= 0 and x[j] - z[j] > 0) \
                if any(z[j] <= 0 and x[j] - z[j] > 0 for j in passive) else 0.0
            x = [x[j] + alpha * (z[j] - x[j]) for j in range(n)]
            passive = [j for j in passive if x[j] > 1e-12]
            if not passive:
                break
    return x


def _numpy_lstsq() -> Lstsq:
    try:
        import numpy as np   # noqa: PLC0415 - only --fit may need numpy (6b.d)
    except ImportError as e:
        raise NeedNumpy() from e

    def solve(cols: list[list[float]], y: list[float]) -> list[float]:
        a = np.array(cols, dtype=float).T
        return [float(v) for v in np.linalg.lstsq(a, np.array(y, dtype=float), rcond=None)[0]]
    return solve


def _cos(a: list[float], b: list[float]) -> float:
    na, nb = math.sqrt(_dot(a, a)), math.sqrt(_dot(b, b))
    return _dot(a, b) / (na * nb) if na > 0 and nb > 0 else 0.0


def _rmse(y: list[float], cols: dict[str, list[float]], scales: dict[str, float]) -> float:
    if not y:
        return 0.0
    s = 0.0
    for i, yi in enumerate(y):
        e = yi - sum(scales.get(k, 1.0) * c[i] for k, c in cols.items())
        s += e * e
    return math.sqrt(s / len(y))


# ---------------------------------------------------------------------------------------------
# Public
# ---------------------------------------------------------------------------------------------

def solve(dm: dict, lstsq: Lstsq) -> dict:
    """Scales from a design matrix: {"scales": {coeff: scale}, "reasons": {coeff: str}, "accepted": {coeff: bool},
    "ties": {coeff: [coeffs]}, "rows", "rmse_before_mw", "rmse_after_mw"}."""
    rows = dm["rows"]
    span = [r[2] for r in rows]
    y = [(r[3] - b) * 1000.0 / s for r, b, s in zip(rows, dm["base"], span)]          # mW
    cols = {k: [v * 1000.0 / s for v, s in zip(c, span)] for k, c in dm["cols"].items()}
    reasons: dict[str, str] = {}
    scales: dict[str, float] = {k: 1.0 for k in cols}
    accepted: dict[str, bool] = {k: False for k in cols}
    live = [k for k in FIT_COEFFS if k in cols and any(abs(v) > 1e-9 for v in cols[k])]
    for k in cols:
        if k not in live:
            reasons[k] = "账本里没有它的数据，不改"
    # tie columns the data cannot separate
    groups: list[list[str]] = []
    for k in live:
        for g in groups:
            if _cos(cols[g[0]], cols[k]) >= TIE_COS:
                g.append(k)
                break
        else:
            groups.append([k])
    gcol = {g[0]: [sum(cols[k][i] for k in g) for i in range(len(y))] for g in groups}
    ties = {k: g for g in groups for k in g if len(g) > 1}
    free = [g[0] for g in groups]
    fixed: dict[str, float] = {}
    while free:
        yy = [yi - sum(gcol[f][i] for f in fixed) for i, yi in enumerate(y)]
        x = nnls([gcol[f] for f in free], yy, lstsq)
        bad = [(abs(math.log(max(v, 1e-6))), f, v) for f, v in zip(free, x) if not LO <= v <= HI]
        if not bad:
            for f, v in zip(free, x):
                for k in next(g for g in groups if g[0] == f):
                    scales[k], accepted[k] = v, True
                    reasons[k] = f"拟合出 ×{v:.3f}"
            break
        _, f, v = max(bad)
        fixed[f] = 1.0
        free.remove(f)
        for k in next(g for g in groups if g[0] == f):
            scales[k] = 1.0
            reasons[k] = f"拟合出 ×{v:.3f}，超出 ×{LO:g}–×{HI:g}，不改"
    for k, g in ties.items():
        reasons[k] += "（和 " + "、".join(x for x in g if x != k) + " 分不开，按同一比例）"
    return {"scales": scales, "accepted": accepted, "reasons": reasons, "ties": ties, "rows": len(rows),
            "rmse_before_mw": _rmse(y, cols, {}), "rmse_after_mw": _rmse(y, cols, scales)}


def _today(inp: Inputs) -> str:
    d = datetime.datetime.fromtimestamp(math.floor(inp.src.now) + inp.src.tz_offset_min * 60,
                                        tz=datetime.timezone.utc)
    return d.date().isoformat()


def _plain_doc(c: Coeffs) -> dict:
    co: dict[str, Any] = {k: {"value": v} for k, v in sorted(c.values.items())}
    if c.b_points:
        co["B"] = {"value": [[x, y] for x, y in c.b_points]}
    return {"version": c.version, "calibrated": c.calibrated, "date": c.date, "coeffs": co}


def _num(v: float) -> Any:
    """4 significant digits: one decimal would turn k_pkt 0.2 x 0.7 into 0.1, and anything under 0.05 into a 0
    that model.coeff() then takes as a real value."""
    r = float(f"{v:.4g}")
    return int(r) if r == int(r) and abs(r) >= 1 else r


def fit(inp: Inputs, base_doc: Optional[dict] = None, lstsq: Optional[Lstsq] = None) -> dict:
    """Fit the ledger in inp. base_doc: the JSON of the current coeffs file (read via config when None); lstsq: the
    least-squares solver (numpy's when None; NeedNumpy without numpy).

    Returns {"rows", "rmse_before_mw", "rmse_after_mw", "coeffs": {name: {"current", "scale", "suggest",
    "accepted", "reason"}}, "doc": suggested coeffs-v<N+1>.json as a dict}."""
    if lstsq is None:
        lstsq = _numpy_lstsq()
    dm = design(inp)
    if len(dm["rows"]) < MIN_ROWS:
        raise FitError(f"账本里能拟合的段太少：{len(dm['rows'])} 组，至少要 {MIN_ROWS} 组")
    sol = solve(dm, lstsq)
    c = inp.coeffs
    date = _today(inp)
    doc = copy.deepcopy(base_doc if base_doc is not None else (config.coeffs_doc(c) or _plain_doc(c)))
    doc["version"] = int(c.version) + 1
    doc["date"] = date
    co = doc.setdefault("coeffs", {})
    per: dict[str, dict] = {}
    for k in FIT_COEFFS:
        s = sol["scales"].get(k, 1.0)
        ok = bool(sol["accepted"].get(k, False))
        if k == "B":
            cur: Any = [[x, y] for x, y in (c.b_points or model.B_DEFAULT)]
            sug: Any = [[x, _num(y * s)] for x, y in cur]
        else:
            cur = model.coeff(c, k)
            sug = _num(cur * s)
        per[k] = {"current": cur, "scale": round(s, 4), "suggest": sug if ok else cur, "accepted": ok,
                  "reason": sol["reasons"].get(k, "")}
        if ok and abs(s - 1.0) > 1e-4:
            e = co.get(k)
            e = dict(e) if isinstance(e, dict) else {"value": e}
            e["value"] = sug
            e["src"] = (f"y700-battery-report --fit {date}：账本 {sol['rows']} 组非负最小二乘，"
                        f"原值 ×{s:.3f}（只给建议，人工确认后才放进 ~/.config/y700-battery/）")
            e["date"] = date
            e["ci95"] = None
            co[k] = e
    doc["calibrated"] = bool(doc.get("calibrated")) or any(p["accepted"] for p in per.values())
    doc["_fit"] = {"rows": sol["rows"], "rmse_before_mw": round(sol["rmse_before_mw"], 1),
                   "rmse_after_mw": round(sol["rmse_after_mw"], 1),
                   "scales": {k: per[k]["scale"] for k in FIT_COEFFS},
                   "accepted": [k for k in FIT_COEFFS if per[k]["accepted"]]}
    return {"rows": sol["rows"], "rmse_before_mw": sol["rmse_before_mw"], "rmse_after_mw": sol["rmse_after_mw"],
            "coeffs": per, "doc": doc}


def format_fit(res: dict) -> str:
    """The suggested coeffs-v<N+1>.json text (what --fit prints on stdout)."""
    return json.dumps(res["doc"], ensure_ascii=False, indent=1) + "\n"


def summary(res: dict) -> str:
    """Human summary for stderr."""
    lines = [f"--fit：{res['rows']} 组，误差（均方根）{res['rmse_before_mw']:.1f} mW → {res['rmse_after_mw']:.1f} mW"]
    for k, p in res["coeffs"].items():
        mark = "采用" if p["accepted"] else "不改"
        lines.append(f"  {k:<12} ×{p['scale']:<7} {mark}  {p['reason']}")
    lines.append("建议的系数文件打印在 stdout；确认后另存为 ~/.config/y700-battery/coeffs-v"
                 f"{res['doc'].get('version')}.json 才生效。")
    return "\n".join(lines)
