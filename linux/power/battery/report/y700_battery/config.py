"""Coefficients and rules (DESIGN.md 6b.b 系数和规则从哪来), the only other module besides sources.py that
touches the file system.

Lookup order, first usable file wins; a file that does not parse is skipped with a note on stderr:
- coeffs: ~/.config/y700-battery/coeffs-v<N>.json with the highest N (source "user", skipped in --from so a
  replay depends only on the capture and the package), then /usr/local/share/y700-battery/ (source "package"),
  then the dev tree linux/power/battery/ two levels above this package (source "dev");
- rules.json: /usr/local/share/y700-battery/ then the dev tree.
Nothing found: ConfigError with the exact page text 「找不到系数文件」 / 「找不到 rules.json」.

SHARE_DIR / DEV_DIR / user_dir() are module attributes so tests can point them elsewhere.
"""

from __future__ import annotations

import json
import math
import os
import re
import sys
from pathlib import Path
from typing import Any, Optional

from .types import Coeffs, Rules

SHARE_DIR = "/usr/local/share/y700-battery"
DEV_DIR = str(Path(__file__).resolve().parents[2])      # y700_battery -> report -> battery
RULES_NAME = "rules.json"
NO_COEFFS = "找不到系数文件"
NO_RULES = "找不到 rules.json"
_COEFF_FILE = re.compile(r"^coeffs-v([1-9][0-9]{0,5})\.json$")
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_NUM_RULES = ("full_pct", "weak_charger_mw", "weak_charger_drop_pct", "d_min_pct", "apps_min_pct")
_INT_RULES = ("loose_plug_merge_s", "just_full_s", "segment_max_s", "short_on_merge_s", "min_split_s")
_LIST_RULES = ("launcher_prefixes", "parents", "ui", "sys", "desktop_classes", "x11_classes", "hidden_ok")
_POSITIVE = ("fmax_little", "fmax_big", "g_fref_mhz", "R0", "ctx_per_wake", "V_nom")    # model.py divides by them


class ConfigError(Exception):
    """No usable coeffs / rules file: str(e) is the whole error text for the error document."""


def user_dir(env: Optional[dict] = None) -> str:
    """~/.config/y700-battery ($XDG_CONFIG_HOME honoured when it is absolute, as everywhere else on the desktop)."""
    env = os.environ if env is None else env
    base = env.get("XDG_CONFIG_HOME") or ""
    if not os.path.isabs(base):
        base = os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "y700-battery")


def _note(msg: str) -> None:
    try:
        print("y700-battery-report: " + msg, file=sys.stderr)
    except (OSError, ValueError):
        pass


def _num(v: Any, what: str) -> float:
    if type(v) not in (int, float) or not math.isfinite(v):
        raise ValueError(f"{what} 不是数字：{v!r}")
    return float(v)


# ---------------------------------------------------------------------------------------------
# Parsers (pure)
# ---------------------------------------------------------------------------------------------

def parse_coeffs(text: str, source: str, path: str) -> Coeffs:
    """coeffs-v<N>.json text -> Coeffs. ValueError (Chinese reason) when it is not usable.

    Each entry is {"value": ..., "unit", "src", "date", "ci95"} (a bare number is accepted too); B's value is
    [[level, mW], ...]. Keys starting with "_" are comments. Missing coefficients are not an error: model.py
    falls back to the v1 values for them."""
    d = json.loads(text)
    if not isinstance(d, dict):
        raise ValueError("不是 JSON 对象")
    ver = d.get("version")
    if type(ver) is not int or ver < 1:
        raise ValueError(f"version 不对：{ver!r}")
    cal = d.get("calibrated", False)
    if type(cal) is not bool:
        raise ValueError(f"calibrated 不是 true/false：{cal!r}")
    date = d.get("date")
    if date is not None and not (type(date) is str and _DATE.match(date)):
        raise ValueError(f"date 不是 YYYY-MM-DD：{date!r}")
    co = d.get("coeffs")
    if not isinstance(co, dict):
        raise ValueError("没有 coeffs 表")
    values: dict[str, float] = {}
    b_points: list[tuple[float, float]] = []
    for k, v in co.items():
        if k.startswith("_"):
            continue
        val = v.get("value") if isinstance(v, dict) else v
        if k == "B":
            if not isinstance(val, list) or len(val) < 2:
                raise ValueError("B 至少要两个点")
            pts = []
            for p in val:
                if not (isinstance(p, list) and len(p) == 2):
                    raise ValueError(f"B 的点不对：{p!r}")
                pts.append((_num(p[0], "B 的亮度"), _num(p[1], "B 的功率")))
            b_points = sorted(pts)
        else:
            values[k] = _num(val, k)
            if k in _POSITIVE and values[k] <= 0:
                raise ValueError(f"{k} 要大于 0：{val!r}")
    return Coeffs(version=ver, calibrated=cal, date=date, source=source, path=path,  # type: ignore[arg-type]
                  values=values, b_points=b_points)


def parse_rules(text: str) -> Rules:
    """rules.json text -> Rules. Missing keys keep the defaults of types.Rules; wrong types are a ValueError."""
    d = json.loads(text)
    if not isinstance(d, dict):
        raise ValueError("不是 JSON 对象")
    r = Rules()
    for k in _NUM_RULES:
        if k in d:
            setattr(r, k, _num(d[k], k))
    for k in _INT_RULES:
        if k in d:
            v = d[k]
            if type(v) is not int or v < 0:
                raise ValueError(f"{k} 不是非负整数：{v!r}")
            setattr(r, k, v)
    for k in _LIST_RULES:
        if k in d:
            v = d[k]
            if not (isinstance(v, list) and all(type(x) is str for x in v)):
                raise ValueError(f"{k} 不是字符串列表")
            setattr(r, k, list(v))
    if "aliases" in d:
        v = d["aliases"]
        if not (isinstance(v, dict) and all(type(a) is str and type(b) is str for a, b in v.items())):
            raise ValueError("aliases 不是字符串到字符串的表")
        r.aliases = {a: b for a, b in v.items() if not a.startswith("_")}
    if "labels" in d:
        v = d["labels"]
        if not (isinstance(v, list) and all(isinstance(p, list) and len(p) == 2 and type(p[0]) is str
                                            and type(p[1]) is str and p[1] for p in v)):
            raise ValueError("labels 不是 [通配, 名字] 的列表")
        r.labels = [(g, n) for g, n in v]
    return r


# ---------------------------------------------------------------------------------------------
# Lookup (file system)
# ---------------------------------------------------------------------------------------------

def _read(path: str) -> Optional[str]:
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8")
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as e:
        _note(f"读不了 {path}：{e}")
        return None


def _versions(d: str) -> list[str]:
    """coeffs-v<N>.json files of d, highest N first."""
    try:
        names = os.listdir(d)
    except OSError:
        return []
    found = []
    for n in names:
        m = _COEFF_FILE.match(n)
        if m:
            found.append((int(m.group(1)), os.path.join(d, n)))
    return [p for _, p in sorted(found, reverse=True)]


def coeff_dirs(from_mode: bool) -> list[tuple[str, str]]:
    """(directory, source) in lookup order."""
    out = [] if from_mode else [(user_dir(), "user")]
    return out + [(SHARE_DIR, "package"), (DEV_DIR, "dev")]


def load_coeffs(from_mode: bool) -> Coeffs:
    """The first usable coeffs file in lookup order (see the module docstring)."""
    for d, source in coeff_dirs(from_mode):
        for path in _versions(d):
            text = _read(path)
            if text is None:
                continue
            try:
                return parse_coeffs(text, source, path)
            except ValueError as e:      # json.JSONDecodeError is a ValueError too
                _note(f"跳过坏的系数文件 {path}：{e}")
    raise ConfigError(NO_COEFFS)


def load_rules() -> Rules:
    """The first usable rules.json: the package copy, then the dev tree."""
    for d in (SHARE_DIR, DEV_DIR):
        path = os.path.join(d, RULES_NAME)
        text = _read(path)
        if text is None:
            continue
        try:
            return parse_rules(text)
        except ValueError as e:
            _note(f"跳过坏的 {path}：{e}")
    raise ConfigError(NO_RULES)


def coeffs_doc(c: Coeffs) -> Optional[dict]:
    """The raw JSON of the coeffs file c came from (--fit writes its suggestion as an edited copy of it)."""
    text = _read(c.path) if c.path else None
    if text is None:
        return None
    try:
        d = json.loads(text)
    except ValueError:
        return None
    return d if isinstance(d, dict) else None
