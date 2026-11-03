"""Validator for the report's JSON v1 (DESIGN.md section 6b.a).

validate(doc) returns a list of human-readable violations; an empty list means valid.
It is strict on purpose: unknown keys, wrong types (bool is not an int, int is accepted where
a number is expected), enum values and the cross-field invariants are all errors, so the
report, the page and the canned test JSONs cannot drift apart silently.

cli.py runs it on every document before printing; tests run it on every canned JSON.
Pure stdlib, no I/O.
"""

from __future__ import annotations

import math
import re
from typing import Any

V = 1

RANGE_KEYS = ("since_full", "24h", "7d")
STATES = ("ok", "just_full", "all_charger", "empty", "partial")
NO_SPLIT_STATES = ("just_full", "all_charger", "empty")
BAT_STATUS = ("charging", "discharging", "full", "not_charging", "unknown")
COEFF_SOURCES = ("package", "user", "dev")

ITEM_KINDS = ("screen", "floor", "app", "apps_rest", "ui", "sys", "wifi", "other", "unrecorded")
COMPONENT_KINDS = ("screen", "floor", "ui", "sys", "wifi", "other", "unrecorded")
APPISH = ("app", "apps_rest")
ROLE_OF_KIND = {
    "screen": "screen", "app": "accent", "apps_rest": "accent", "ui": "accent2",
    "sys": "neutral1", "wifi": "neutral2", "floor": "neutral3", "other": "neutral4",
    "unrecorded": "neutral4",
}
ICON_OF_KIND = {
    "screen": "video-display", "floor": "battery", "ui": "preferences-desktop",
    "sys": "preferences-system", "wifi": "network-wireless", "other": "help-about",
    "unrecorded": "dialog-information", "apps_rest": "application-x-executable",
}
CLOSED_ID = "app:#closed"

COMP_KINDS = ("screen", "apps", "ui", "sys", "wifi", "floor", "other", "unrecorded")
COMP_OF_ITEM = {"screen": "screen", "app": "apps", "apps_rest": "apps", "ui": "ui", "sys": "sys",
                "wifi": "wifi", "floor": "floor", "other": "other", "unrecorded": "unrecorded"}
ROLE_OF_COMP = {"screen": "screen", "apps": "accent", "ui": "accent2", "sys": "neutral1",
                "wifi": "neutral2", "floor": "neutral3", "other": "neutral4",
                "unrecorded": "neutral4"}

BANNER_ORDER = ("recorder_off", "degraded", "gap", "unknown_time", "clock_unsynced", "fg_off",
                "charger_now")
BANNER_LEVEL = {k: "warn" for k in BANNER_ORDER}
BANNER_LEVEL["charger_now"] = "charge"

EMPTY_ACTIONS = (None, "show_24h")

MAX_CURVE = 400
MAX_SINCE_BUCKETS = 48
SINCE_BUCKET_SIZES = (900, 1800, 3600, 7200, 10800, 21600, 43200, 86400)
MIN_SPLIT_S = 300          # uncovered discharge >= this makes a range "partial"
APPS_MIN_PCT = 0.5         # apps below this merge into apps_rest (when there are >= 2 of them)
DAY = 86400

TOP_KEYS = ("v", "now", "tz_offset_min", "took_ms", "rec", "battery", "coeffs", "remain",
            "ranges", "diag")
REC_KEYS = ("running", "degraded", "since", "last_write_age_s", "fg_log", "clock_unsynced")
BAT_KEYS = ("pct", "status", "plugged", "health_pct", "cycles")
COEFF_KEYS = ("version", "calibrated", "date", "source")
REMAIN_KEYS = ("h", "basis_h")
DIAG_KEYS = ("unexplained_median_7d", "floor_off_learned_mw", "floor_off_model_mw",
             "coeff_age_days", "ledger_bytes", "ledger_newest_age_s", "energy_age_s",
             "segments_flagged_7d")
RANGE_FIELDS = ("key", "state", "start", "end", "title", "sub", "used_pct", "used_pct_raw",
                "on_s", "off_s", "charger_s", "gap_s", "uncovered_s", "coverage", "data_from",
                "data_from_text", "brightness_hint_pct_h", "model_high_segments",
                "unknown_time_boots", "curve", "bands", "bucket_s", "bucket_t", "items",
                "composition", "banners", "empty", "footnote")
BAND_KINDS = ("on", "charger", "gap", "uncovered")
ITEM_FIELDS = ("id", "kind", "name", "icon", "role", "pct", "pct_raw", "fg_s", "bg_s", "cpu_s",
               "gpu_s", "wake_off_n", "split", "split_raw", "buckets", "windows", "parts",
               "explain", "hint", "note")
SPLIT_KEYS = ("fg", "bg", "off")
COMP_FIELDS = ("kind", "name", "pct", "pct_raw", "role")
BANNER_FIELDS = ("kind", "level", "text")
EMPTY_FIELDS = ("title", "text", "action")

_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_THEME_ICON = re.compile(r"^[A-Za-z0-9_.+\-]+$")
_EPS = 1e-6


def is_error(doc: Any) -> bool:
    """True for the error document shape {"v":1,"error":"..."}."""
    return isinstance(doc, dict) and "error" in doc


def _is_int(x: Any) -> bool:
    return type(x) is int


def _is_num(x: Any) -> bool:
    return type(x) in (int, float) and math.isfinite(x)


def _is_str(x: Any) -> bool:
    return type(x) is str and x != ""


class _Checker:
    def __init__(self) -> None:
        self.errs: list[str] = []

    def err(self, path: str, msg: str) -> None:
        self.errs.append(f"{path}: {msg}")

    def keys(self, obj: Any, path: str, want: tuple[str, ...]) -> bool:
        """Exact key set. Returns False (and stops the caller) when obj is not a dict."""
        if not isinstance(obj, dict):
            self.err(path, f"expected object, got {type(obj).__name__}")
            return False
        missing = [k for k in want if k not in obj]
        extra = [k for k in obj if k not in want]
        if missing:
            self.err(path, "missing keys " + ", ".join(missing))
        if extra:
            self.err(path, "unknown keys " + ", ".join(sorted(extra)))
        return not missing

    def int_(self, x: Any, path: str, lo: int | None = None, hi: int | None = None,
             null: bool = False) -> bool:
        if x is None and null:
            return True
        if not _is_int(x):
            self.err(path, f"expected int{' or null' if null else ''}, got {x!r}")
            return False
        if lo is not None and x < lo or hi is not None and x > hi:
            self.err(path, f"{x} out of range [{lo}, {hi}]")
            return False
        return True

    def num(self, x: Any, path: str, lo: float | None = None, hi: float | None = None,
            null: bool = False) -> bool:
        if x is None and null:
            return True
        if not _is_num(x):
            self.err(path, f"expected number{' or null' if null else ''}, got {x!r}")
            return False
        if lo is not None and x < lo - _EPS or hi is not None and x > hi + _EPS:
            self.err(path, f"{x} out of range [{lo}, {hi}]")
            return False
        return True

    def bool_(self, x: Any, path: str) -> bool:
        if type(x) is not bool:
            self.err(path, f"expected bool, got {x!r}")
            return False
        return True

    def str_(self, x: Any, path: str, null: bool = False) -> bool:
        if x is None and null:
            return True
        if not _is_str(x):
            self.err(path, f"expected non-empty string{' or null' if null else ''}, got {x!r}")
            return False
        return True

    def enum(self, x: Any, path: str, allowed: tuple) -> bool:
        if x not in allowed or type(x) not in (str, type(None)):
            self.err(path, f"{x!r} not one of {', '.join(map(str, allowed))}")
            return False
        return True


def _check_lr(c: _Checker, path: str, pcts: list[int], raws: list[float], total: int) -> None:
    """pcts must be the largest-remainder rounding of raws scaled to sum exactly to total."""
    if sum(pcts) != total:
        c.err(path, f"pct sum {sum(pcts)} != {total}")
        return
    s = sum(raws)
    if s <= 0:
        if any(pcts):
            c.err(path, "non-zero pct with zero pct_raw total")
        return
    tol = 0.02
    quotas = [r * total / s for r in raws]
    ups, downs = [], []
    for i, (p, q) in enumerate(zip(pcts, quotas)):
        if not (math.floor(q - tol) <= p <= math.ceil(q + tol)):
            c.err(f"{path}[{i}]", f"pct {p} is not a rounding of quota {q:.3f}")
            return
        if p > q + tol:
            ups.append(q - math.floor(q))
        elif p < q - tol:
            downs.append(q - math.floor(q))
    if ups and downs and min(ups) < max(downs) - tol:
        c.err(path, "not largest-remainder: a smaller remainder was rounded up over a larger one")


def _bands(c: _Checker, b: Any, path: str, start: int, end: int) -> dict[str, list]:
    out: dict[str, list] = {k: [] for k in BAND_KINDS}
    if not c.keys(b, path, BAND_KINDS):
        return out
    for k in BAND_KINDS:
        lst = b[k]
        p = f"{path}.{k}"
        if not isinstance(lst, list):
            c.err(p, "expected list")
            continue
        prev_end = None
        good = []
        for i, iv in enumerate(lst):
            pi = f"{p}[{i}]"
            if not (isinstance(iv, list) and len(iv) == 2 and _is_int(iv[0]) and _is_int(iv[1])):
                c.err(pi, f"expected [int, int], got {iv!r}")
                continue
            a, z = iv
            if not a < z:
                c.err(pi, f"empty or reversed band {iv}")
            if a < start or z > end:
                c.err(pi, f"band {iv} outside range [{start}, {end}]")
            if prev_end is not None and a <= prev_end:
                c.err(pi, "bands must be sorted, non-overlapping and not touching (merge them)")
            prev_end = z
            good.append((a, z))
        out[k] = good
    return out


def _overlap(xs: list, ys: list) -> int:
    tot = 0
    for a, b in xs:
        for c_, d in ys:
            tot += max(0, min(b, d) - max(a, c_))
    return tot


def _length(xs: list) -> int:
    return sum(b - a for a, b in xs)


def _buckets(c: _Checker, r: dict, key: str, path: str, tz: int) -> int:
    """Checks bucket_s / bucket_t; returns the number of buckets (or -1 when unusable)."""
    bs, bt = r.get("bucket_s"), r.get("bucket_t")
    start, end = r.get("start"), r.get("end")
    if not c.int_(bs, path + ".bucket_s", lo=1):
        return -1
    if not isinstance(bt, list) or not all(_is_int(t) for t in bt) or not bt:
        c.err(path + ".bucket_t", "expected non-empty list of int")
        return -1
    for i in range(1, len(bt)):
        if bt[i] - bt[i - 1] != bs:
            c.err(path + ".bucket_t", f"step at {i} is {bt[i] - bt[i - 1]}, expected {bs}")
            return -1
    if not (_is_int(start) and _is_int(end)):
        return len(bt)
    off = tz * 60
    if key == "24h":
        if bs != 3600 or len(bt) != 24:
            c.err(path, "24h needs 24 buckets of 3600 s")
        if (bt[0] + off) % 3600:
            c.err(path + ".bucket_t", "24h buckets must start on local hours")
        if not (bt[-1] <= end < bt[-1] + bs):
            c.err(path + ".bucket_t", "last 24h bucket must contain end")
    elif key == "7d":
        if bs != DAY or len(bt) != 7:
            c.err(path, "7d needs 7 buckets of 86400 s")
        if (bt[0] + off) % DAY:
            c.err(path + ".bucket_t", "7d buckets must start on local midnight")
        if not (bt[-1] <= end < bt[-1] + bs):
            c.err(path + ".bucket_t", "last 7d bucket must contain end")
    else:
        if bs not in SINCE_BUCKET_SIZES:
            c.err(path + ".bucket_s", f"{bs} not one of {SINCE_BUCKET_SIZES}")
        if len(bt) > MAX_SINCE_BUCKETS:
            c.err(path + ".bucket_t", f"{len(bt)} buckets > {MAX_SINCE_BUCKETS}")
        if (bt[0] + off) % bs:
            c.err(path + ".bucket_t", "since_full buckets must be aligned to the local grid")
        if not (bt[0] <= start < bt[0] + bs):
            c.err(path + ".bucket_t", "first bucket must contain start")
        if not (bt[-1] < end <= bt[-1] + bs):
            c.err(path + ".bucket_t", "last bucket must contain end")
        smaller = [s for s in SINCE_BUCKET_SIZES if s < bs]
        if smaller:
            s2 = smaller[-1]
            n2 = (end - 1 + off) // s2 - (start + off) // s2 + 1
            if n2 <= MAX_SINCE_BUCKETS:
                c.err(path + ".bucket_s", f"{s2} s would fit in {n2} buckets; use the smallest size")
    return len(bt)


def _split(c: _Checker, it: dict, path: str) -> None:
    sp, sr = it["split"], it["split_raw"]
    pct, raw = it["pct"], it["pct_raw"]
    ok = c.keys(sp, path + ".split", SPLIT_KEYS) and c.keys(sr, path + ".split_raw", SPLIT_KEYS)
    if not ok:
        return
    if not all(c.int_(sp[k], f"{path}.split.{k}", lo=0) for k in SPLIT_KEYS):
        return
    if not all(c.num(sr[k], f"{path}.split_raw.{k}", lo=0) for k in SPLIT_KEYS):
        return
    if _is_int(pct) and sp["fg"] + sp["bg"] != pct:
        c.err(path + ".split", f"fg+bg = {sp['fg'] + sp['bg']} != pct {pct}")
    if sp["off"] > sp["bg"]:
        c.err(path + ".split", "off > bg")
    if _is_num(raw):
        if abs(sr["fg"] + sr["bg"] - raw) > 0.02:
            c.err(path + ".split_raw", f"fg+bg = {sr['fg'] + sr['bg']:.3f} != pct_raw {raw}")
        if sr["off"] > sr["bg"] + 0.01:
            c.err(path + ".split_raw", "off > bg")
        if _is_int(pct) and raw > 0:
            q = sr["fg"] * pct / raw
            if not (math.floor(q - 0.02) <= sp["fg"] <= math.ceil(q + 0.02)):
                c.err(path + ".split.fg", f"{sp['fg']} is not a rounding of {q:.3f}")
            qo = sr["off"] * pct / raw
            if abs(sp["off"] - qo) > 1.0 + _EPS:
                c.err(path + ".split.off", f"{sp['off']} too far from {qo:.3f}")


def _item(c: _Checker, it: Any, path: str, nb: int, dis_s: int | None = None) -> bool:
    """One item; dis_s = the range's on_s + off_s when both are valid (bounds an app's fg_s + bg_s)."""
    if not c.keys(it, path, ITEM_FIELDS):
        return False
    kind = it["kind"]
    if not c.enum(kind, path + ".kind", ITEM_KINDS):
        return False
    iid = it["id"]
    if c.str_(iid, path + ".id"):
        if kind == "app":
            if not (iid.startswith("app:") and len(iid) > 4):
                c.err(path + ".id", f"app ids are app:<id>, got {iid!r}")
        elif iid != kind:
            c.err(path + ".id", f"{kind} item must have id {kind!r}, got {iid!r}")
    c.str_(it["name"], path + ".name")
    icon = it["icon"]
    if c.str_(icon, path + ".icon", null=True) and icon is not None:
        if not (icon.startswith("file:///") or _THEME_ICON.match(icon)):
            c.err(path + ".icon", f"not a theme name or file:/// url: {icon!r}")
    if kind in ICON_OF_KIND and icon != ICON_OF_KIND[kind]:
        c.err(path + ".icon", f"{kind} uses icon {ICON_OF_KIND[kind]!r}")
    if it["role"] != ROLE_OF_KIND[kind]:
        c.err(path + ".role", f"{kind} has role {ROLE_OF_KIND[kind]!r}, got {it['role']!r}")
    c.int_(it["pct"], path + ".pct", lo=0)
    c.num(it["pct_raw"], path + ".pct_raw", lo=0)

    appish = kind in APPISH
    for k in ("fg_s", "bg_s"):
        if appish:
            c.int_(it[k], f"{path}.{k}", lo=0)
        elif it[k] is not None:
            c.err(f"{path}.{k}", f"must be null for {kind}")
    if (appish and dis_s is not None and _is_int(it["fg_s"]) and _is_int(it["bg_s"])
            and it["fg_s"] + it["bg_s"] > dis_s + 1):
        # both are seconds of the range's discharge time (apps_rest: the union of its members, not a sum)
        c.err(path + ".bg_s", f"fg_s + bg_s = {it['fg_s'] + it['bg_s']} > on_s + off_s = {dis_s}")
    for k in ("cpu_s", "gpu_s", "wake_off_n"):
        if kind in ("app", "apps_rest", "ui", "sys"):
            c.int_(it[k], f"{path}.{k}", lo=0, null=True)
        elif it[k] is not None:
            c.err(f"{path}.{k}", f"must be null for {kind}")
    if appish:
        _split(c, it, path)
    else:
        for k in ("split", "split_raw"):
            if it[k] is not None:
                c.err(f"{path}.{k}", f"must be null for {kind}")

    b = it["buckets"]
    if not isinstance(b, list) or not all(_is_num(x) and x >= 0 for x in b):
        c.err(path + ".buckets", "expected list of numbers >= 0")
    else:
        if nb >= 0 and len(b) != nb:
            c.err(path + ".buckets", f"len {len(b)} != len(bucket_t) {nb}")
        if _is_num(it["pct_raw"]) and abs(sum(b) - it["pct_raw"]) > 0.002 * len(b) + 0.02:
            c.err(path + ".buckets", f"sum {sum(b):.3f} != pct_raw {it['pct_raw']}")

    w = it["windows"]
    if not isinstance(w, list):
        c.err(path + ".windows", "expected list")
    else:
        for i, pair in enumerate(w):
            if not (isinstance(pair, list) and len(pair) == 2 and _is_str(pair[0])
                    and _is_int(pair[1]) and pair[1] >= 0):
                c.err(f"{path}.windows[{i}]", f"expected [name, int s], got {pair!r}")
        if w and kind != "app":
            c.err(path + ".windows", f"only app items have windows, not {kind}")
        elif w and _is_int(it["fg_s"]):
            tot = sum(p[1] for p in w if isinstance(p, list) and len(p) == 2 and _is_int(p[1]))
            if tot > it["fg_s"] + len(w):
                c.err(path + ".windows", f"window seconds {tot} > fg_s {it['fg_s']}")

    parts = it["parts"]
    if not isinstance(parts, list):
        c.err(path + ".parts", "expected list")
    else:
        for i, pair in enumerate(parts):
            if not (isinstance(pair, list) and len(pair) == 2 and _is_str(pair[0])
                    and _is_num(pair[1]) and pair[1] >= 0):
                c.err(f"{path}.parts[{i}]", f"expected [name, number], got {pair!r}")
        if parts and kind not in ("ui", "sys", "apps_rest", "other"):
            c.err(path + ".parts", f"{kind} items have no parts")
        good = [p[1] for p in parts if isinstance(p, list) and len(p) == 2 and _is_num(p[1])]
        if _is_num(it["pct_raw"]):
            tol = 0.01 * len(good) + 0.02
            if sum(good) > it["pct_raw"] + tol:
                c.err(path + ".parts", f"parts sum {sum(good):.3f} > pct_raw {it['pct_raw']}")
            if kind == "apps_rest":
                if len(parts) < 2:
                    c.err(path + ".parts", "apps_rest needs the >= 2 merged apps as parts")
                elif abs(sum(good) - it["pct_raw"]) > tol:
                    c.err(path + ".parts", "apps_rest parts must sum to pct_raw")
                elif any(v >= APPS_MIN_PCT for v in good):
                    c.err(path + ".parts", f"apps_rest only takes apps below {APPS_MIN_PCT}")

    if kind == "app":
        if it["explain"] is not None:
            c.err(path + ".explain", "must be null for app")
    elif kind == "apps_rest":
        c.str_(it["explain"], path + ".explain", null=True)
    else:
        c.str_(it["explain"], path + ".explain")
    if kind == "screen":
        c.str_(it["hint"], path + ".hint", null=True)
    elif it["hint"] is not None:
        c.err(path + ".hint", "only the screen item has a hint")
    c.str_(it["note"], path + ".note", null=True)
    return True


def _range(c: _Checker, r: Any, key: str, doc: dict) -> None:
    path = f"ranges.{key}"
    if not c.keys(r, path, RANGE_FIELDS):
        return
    now = doc.get("now") if _is_int(doc.get("now")) else None
    tz = doc.get("tz_offset_min") if _is_int(doc.get("tz_offset_min")) else 0
    if r["key"] != key:
        c.err(path + ".key", f"{r['key']!r} != {key!r}")
    state = r["state"]
    c.enum(state, path + ".state", STATES)
    if state == "just_full" and key != "since_full":
        c.err(path + ".state", "just_full only exists in since_full")

    start, end = r["start"], r["end"]
    span = None
    if c.int_(start, path + ".start", lo=0) and c.int_(end, path + ".end", lo=0):
        if not start < end:
            c.err(path, f"start {start} must be < end {end}")
        if now is not None and end > now:
            c.err(path + ".end", f"{end} after now {now}")
        if key == "24h" and now is not None and (end != now or start != now - DAY):
            c.err(path, "24h is exactly [now - 86400, now]")
        if key == "7d" and now is not None and (end != now or start != now - 7 * DAY):
            c.err(path, "7d is exactly [now - 7*86400, now]")
        span = end - start
    c.str_(r["title"], path + ".title")
    c.str_(r["sub"], path + ".sub")
    c.str_(r["footnote"], path + ".footnote")

    if c.int_(r["used_pct"], path + ".used_pct", lo=0) and \
            c.num(r["used_pct_raw"], path + ".used_pct_raw", lo=0):
        if r["used_pct"] != math.floor(r["used_pct_raw"] + 0.5 + _EPS):
            c.err(path + ".used_pct", f"{r['used_pct']} is not round-half-up of {r['used_pct_raw']}")
    secs = {}
    for k in ("on_s", "off_s", "charger_s", "gap_s", "uncovered_s"):
        if c.int_(r[k], f"{path}.{k}", lo=0):
            secs[k] = r[k]
    if span is not None and len(secs) == 5:
        tol = max(120, span // 100)
        known = secs["on_s"] + secs["off_s"] + secs["charger_s"] + secs["gap_s"]
        if known > span + tol:
            c.err(path, f"on+off+charger+gap = {known} > span {span}")
        if known + secs["uncovered_s"] < span - tol:
            c.err(path, f"on+off+charger+gap+uncovered = {known + secs['uncovered_s']} < span {span}")
    c.num(r["coverage"], path + ".coverage", lo=0, hi=1)
    df, dft = r["data_from"], r["data_from_text"]
    if (df is None) != (dft is None):
        c.err(path + ".data_from", "data_from and data_from_text are both null or both set")
    if c.int_(df, path + ".data_from", null=True) and df is not None and span is not None:
        if not start <= df <= end:
            c.err(path + ".data_from", "outside the range")
    c.str_(dft, path + ".data_from_text", null=True)
    c.num(r["brightness_hint_pct_h"], path + ".brightness_hint_pct_h", lo=0, null=True)
    c.int_(r["model_high_segments"], path + ".model_high_segments", lo=0)
    c.int_(r["unknown_time_boots"], path + ".unknown_time_boots", lo=0)

    curve = r["curve"]
    if not isinstance(curve, list):
        c.err(path + ".curve", "expected list")
    else:
        if len(curve) > MAX_CURVE:
            c.err(path + ".curve", f"{len(curve)} points > {MAX_CURVE}")
        prev = None
        for i, pt in enumerate(curve):
            pi = f"{path}.curve[{i}]"
            if not (isinstance(pt, list) and len(pt) == 2 and _is_int(pt[0]) and _is_num(pt[1])):
                c.err(pi, f"expected [int t, pct], got {pt!r}")
                break
            t, pct = pt
            if not 0 <= pct <= 100:
                c.err(pi, f"pct {pct} outside 0..100")
            if abs(pct * 10 - round(pct * 10)) > 1e-6:
                c.err(pi, f"pct {pct} has more than one decimal")
            if span is not None and not start <= t <= end:
                c.err(pi, f"t {t} outside the range")
            if prev is not None and t < prev:
                c.err(pi, "curve t must be non-decreasing")
            prev = t

    bands = _bands(c, r["bands"], path + ".bands", start if _is_int(start) else 0,
                   end if _is_int(end) else 2**62)
    if _overlap(bands["gap"], bands["charger"] + bands["uncovered"] + bands["on"]):
        c.err(path + ".bands", "gap overlaps charger / uncovered / on")
    if _overlap(bands["charger"], bands["uncovered"]):
        c.err(path + ".bands", "charger overlaps uncovered")
    for bk, sk in (("charger", "charger_s"), ("gap", "gap_s"), ("uncovered", "uncovered_s")):
        if sk in secs and abs(_length(bands[bk]) - secs[sk]) > 2 * len(bands[bk]) + 2:
            c.err(path + ".bands." + bk, f"total {_length(bands[bk])} s != {sk} {secs[sk]}")
    if "on_s" in secs and _length(bands["on"]) < secs["on_s"] - 2 * len(bands["on"]) - 2:
        c.err(path + ".bands.on", f"total {_length(bands['on'])} s < on_s {secs['on_s']}")

    nb = _buckets(c, r, key, path, tz)

    items = r["items"]
    comp = r["composition"]
    good_items: list[dict] = []
    if not isinstance(items, list):
        c.err(path + ".items", "expected list")
        items = []
    dis_s = secs["on_s"] + secs["off_s"] if "on_s" in secs and "off_s" in secs else None
    for i, it in enumerate(items):
        if _item(c, it, f"{path}.items[{i}]", nb, dis_s):
            good_items.append(it)
    if not isinstance(comp, list):
        c.err(path + ".composition", "expected list")
        comp = []
    good_comp = []
    for i, e in enumerate(comp):
        p = f"{path}.composition[{i}]"
        if not c.keys(e, p, COMP_FIELDS):
            continue
        if c.enum(e["kind"], p + ".kind", COMP_KINDS):
            if e["role"] != ROLE_OF_COMP[e["kind"]]:
                c.err(p + ".role", f"{e['kind']} has role {ROLE_OF_COMP[e['kind']]!r}")
            c.str_(e["name"], p + ".name")
            if c.int_(e["pct"], p + ".pct", lo=0) and c.num(e["pct_raw"], p + ".pct_raw", lo=0):
                if e["pct_raw"] <= 0:
                    c.err(p + ".pct_raw", "zero entries are left out")
                good_comp.append(e)

    empty = r["empty"]
    if state in NO_SPLIT_STATES:
        if items:
            c.err(path + ".items", f"must be empty in state {state}")
        if comp:
            c.err(path + ".composition", f"must be empty in state {state}")
        if c.keys(empty, path + ".empty", EMPTY_FIELDS):
            c.str_(empty["title"], path + ".empty.title")
            c.str_(empty["text"], path + ".empty.text")
            if c.enum(empty["action"], path + ".empty.action", EMPTY_ACTIONS):
                if (empty["action"] == "show_24h") != (state == "just_full"):
                    c.err(path + ".empty.action", "show_24h exactly when state is just_full")
    elif state in ("ok", "partial"):
        if empty is not None:
            c.err(path + ".empty", f"must be null in state {state}")
        if not items:
            c.err(path + ".items", f"must not be empty in state {state}")
        if not comp:
            c.err(path + ".composition", f"must not be empty in state {state}")
        _sums(c, path, r, good_items, good_comp, state, secs)

    _banners(c, r["banners"], path + ".banners", doc)


def _sums(c: _Checker, path: str, r: dict, items: list[dict], comp: list[dict], state: str,
          secs: dict) -> None:
    if not (_is_int(r["used_pct"]) and _is_num(r["used_pct_raw"])):
        return
    used, used_raw = r["used_pct"], r["used_pct_raw"]
    if not all(_is_int(it["pct"]) and _is_num(it["pct_raw"]) for it in items):
        return
    ids = [it["id"] for it in items if type(it["id"]) is str]
    if len(set(ids)) != len(ids):
        c.err(path + ".items", "duplicate ids")
    for k in COMPONENT_KINDS + ("apps_rest",):
        if sum(1 for it in items if it["kind"] == k) > 1:
            c.err(path + ".items", f"more than one {k} item")
    raws = [it["pct_raw"] for it in items]
    for i in range(1, len(raws)):
        if raws[i] > raws[i - 1] + _EPS:
            c.err(path + ".items", f"not sorted by pct_raw (index {i})")
            break
    if abs(sum(raws) - used_raw) > 0.01 * len(raws) + 0.01:
        c.err(path + ".items", f"pct_raw sum {sum(raws):.3f} != used_pct_raw {used_raw}")
    _check_lr(c, path + ".items", [it["pct"] for it in items], raws, used)

    small = [it for it in items if it["kind"] == "app" and it["pct_raw"] < APPS_MIN_PCT]
    has_rest = any(it["kind"] == "apps_rest" for it in items)
    if len(small) > 1 or (small and has_rest):
        c.err(path + ".items", f"apps below {APPS_MIN_PCT} must be merged into apps_rest")
    for it in items:
        if it["kind"] == "apps_rest" and _is_str(it["name"]) and isinstance(it["parts"], list):
            if f"（{len(it['parts'])} 个）" not in it["name"]:
                c.err(path + ".items", "apps_rest name must carry its count, e.g. 其他应用（3 个）")

    unrec = [it for it in items if it["kind"] == "unrecorded"]
    if state == "partial":
        if not unrec:
            c.err(path + ".items", "partial needs the unrecorded item")
        if secs.get("uncovered_s", MIN_SPLIT_S) < MIN_SPLIT_S:
            c.err(path + ".uncovered_s", f"partial needs >= {MIN_SPLIT_S} s uncovered")
        if unrec and _is_num(r["coverage"]) and used_raw > 0:
            want = (1 - r["coverage"]) * used_raw
            if abs(unrec[0]["pct_raw"] - want) > 0.02 * used_raw + 0.1:
                c.err(path + ".coverage", f"unrecorded pct_raw {unrec[0]['pct_raw']} != "
                                          f"(1 - coverage) * used_pct_raw = {want:.2f}")
    elif state == "ok":
        if unrec:
            c.err(path + ".items", "ok has no unrecorded item (that is partial)")
        if secs.get("uncovered_s", 0) >= MIN_SPLIT_S:
            c.err(path + ".uncovered_s", f">= {MIN_SPLIT_S} s uncovered makes the range partial")

    kinds = [e["kind"] for e in comp]
    if len(set(kinds)) != len(kinds):
        c.err(path + ".composition", "duplicate kinds")
    order = [COMP_KINDS.index(k) for k in kinds]
    if order != sorted(order):
        c.err(path + ".composition", "kinds must follow " + ", ".join(COMP_KINDS))
    _check_lr(c, path + ".composition", [e["pct"] for e in comp], [e["pct_raw"] for e in comp],
              used)
    want_comp: dict[str, float] = {}
    count: dict[str, int] = {}
    for it in items:
        ck = COMP_OF_ITEM[it["kind"]]
        want_comp[ck] = want_comp.get(ck, 0.0) + it["pct_raw"]
        count[ck] = count.get(ck, 0) + 1
    have = {e["kind"]: e["pct_raw"] for e in comp}
    for ck, v in want_comp.items():
        if v <= 0:
            continue
        if ck not in have:
            c.err(path + ".composition", f"missing {ck} (items sum {v:.2f})")
        elif abs(have[ck] - v) > 0.01 * count[ck] + 0.02:
            c.err(path + ".composition", f"{ck} pct_raw {have[ck]} != items sum {v:.3f}")
    for ck in have:
        if ck not in want_comp:
            c.err(path + ".composition", f"{ck} has no items")


def _banners(c: _Checker, bs: Any, path: str, doc: dict) -> None:
    if not isinstance(bs, list):
        c.err(path, "expected list")
        return
    kinds = []
    for i, b in enumerate(bs):
        p = f"{path}[{i}]"
        if not c.keys(b, p, BANNER_FIELDS):
            continue
        if c.enum(b["kind"], p + ".kind", BANNER_ORDER):
            kinds.append(b["kind"])
            if b["level"] != BANNER_LEVEL[b["kind"]]:
                c.err(p + ".level", f"{b['kind']} has level {BANNER_LEVEL[b['kind']]!r}")
        c.str_(b["text"], p + ".text")
    if len(set(kinds)) != len(kinds):
        c.err(path, "duplicate banner kinds")
    order = [BANNER_ORDER.index(k) for k in kinds]
    if order != sorted(order):
        c.err(path, "banners must follow priority " + " > ".join(BANNER_ORDER))
    rec = doc.get("rec") if isinstance(doc.get("rec"), dict) else {}
    bat = doc.get("battery") if isinstance(doc.get("battery"), dict) else {}
    if rec.get("running") is False and "recorder_off" not in kinds:
        c.err(path, "rec.running is false: recorder_off banner required")
    if rec.get("running") is True and "recorder_off" in kinds:
        c.err(path, "recorder_off banner while rec.running is true")
    if "clock_unsynced" in kinds and rec.get("clock_unsynced") is not True:
        c.err(path, "clock_unsynced banner needs rec.clock_unsynced")
    if (bat.get("plugged") is True) != ("charger_now" in kinds):
        c.err(path, "charger_now banner exactly when battery.plugged")


def validate(doc: Any) -> list[str]:
    """All violations of JSON v1 in doc (empty list = valid)."""
    c = _Checker()
    if not isinstance(doc, dict):
        return [f"$: expected object, got {type(doc).__name__}"]
    if is_error(doc):
        if c.keys(doc, "$", ("v", "error")):
            if doc["v"] != V or not _is_int(doc["v"]):
                c.err("v", f"expected {V}")
            c.str_(doc["error"], "error")
        return c.errs
    if not c.keys(doc, "$", TOP_KEYS):
        return c.errs
    if not _is_int(doc["v"]) or doc["v"] != V:
        c.err("v", f"expected {V}, got {doc['v']!r}")
    c.int_(doc["now"], "now", lo=0)
    c.int_(doc["tz_offset_min"], "tz_offset_min", lo=-720, hi=840)
    c.int_(doc["took_ms"], "took_ms", lo=0)

    rec = doc["rec"]
    if c.keys(rec, "rec", REC_KEYS):
        c.bool_(rec["running"], "rec.running")
        c.bool_(rec["degraded"], "rec.degraded")
        c.bool_(rec["fg_log"], "rec.fg_log")
        c.bool_(rec["clock_unsynced"], "rec.clock_unsynced")
        c.int_(rec["since"], "rec.since", lo=0, null=True)
        c.int_(rec["last_write_age_s"], "rec.last_write_age_s", lo=0, null=True)

    bat = doc["battery"]
    if c.keys(bat, "battery", BAT_KEYS):
        c.int_(bat["pct"], "battery.pct", lo=0, hi=100, null=True)
        c.enum(bat["status"], "battery.status", BAT_STATUS)
        c.bool_(bat["plugged"], "battery.plugged")
        c.int_(bat["health_pct"], "battery.health_pct", lo=0, hi=150, null=True)
        c.int_(bat["cycles"], "battery.cycles", lo=0, null=True)
        if bat["status"] in ("charging", "full", "not_charging") and bat["plugged"] is False:
            c.err("battery.plugged", f"status {bat['status']} implies plugged")

    co = doc["coeffs"]
    if c.keys(co, "coeffs", COEFF_KEYS):
        c.int_(co["version"], "coeffs.version", lo=1)
        c.bool_(co["calibrated"], "coeffs.calibrated")
        if co["date"] is not None and not (type(co["date"]) is str and _DATE.match(co["date"])):
            c.err("coeffs.date", f"expected YYYY-MM-DD or null, got {co['date']!r}")
        c.enum(co["source"], "coeffs.source", COEFF_SOURCES)

    rem = doc["remain"]
    if rem is not None and c.keys(rem, "remain", REMAIN_KEYS):
        c.num(rem["h"], "remain.h", lo=0)
        c.int_(rem["basis_h"], "remain.basis_h", lo=1)
        if isinstance(bat, dict) and bat.get("plugged") is True:
            c.err("remain", "must be null while plugged")

    dg = doc["diag"]
    if c.keys(dg, "diag", DIAG_KEYS):
        c.num(dg["unexplained_median_7d"], "diag.unexplained_median_7d", lo=0, hi=1, null=True)
        c.num(dg["floor_off_learned_mw"], "diag.floor_off_learned_mw", lo=0, null=True)
        c.num(dg["floor_off_model_mw"], "diag.floor_off_model_mw", lo=0)
        c.int_(dg["coeff_age_days"], "diag.coeff_age_days", lo=0, null=True)
        c.int_(dg["ledger_bytes"], "diag.ledger_bytes", lo=0)
        c.int_(dg["ledger_newest_age_s"], "diag.ledger_newest_age_s", lo=0, null=True)
        c.int_(dg["energy_age_s"], "diag.energy_age_s", lo=0, null=True)
        c.int_(dg["segments_flagged_7d"], "diag.segments_flagged_7d", lo=0)

    rg = doc["ranges"]
    if c.keys(rg, "ranges", RANGE_KEYS):
        for k in RANGE_KEYS:
            _range(c, rg[k], k, doc)
    return c.errs
