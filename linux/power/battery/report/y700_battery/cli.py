"""y700-battery-report command line (DESIGN.md 6b.b, pipeline of 6b.d).

    y700-battery-report [--json | --text | --fit] [--from DIR] [--now EPOCH] [--tz-offset MIN]

Exit codes are 0 and 2 only. Every failure (usage, missing coeffs / rules, a self-check that does not pass, any
uncaught exception) still prints a JSON error document {"v":1,"error":"..."} on stdout, because the page parses
whatever comes out; tracebacks and the full self-check list go to stderr. The report never writes a file.
"""

from __future__ import annotations

import argparse
import gc
import json
import math
import os
import sys
import time
import traceback
from typing import Any, Optional

from . import apps, config, contract, journal, ledger, model, out, ranges, sources, upower
from .types import Inputs, LiveBattery, RecState, Report

REC_FRESH_S = 2400          # 6b.b: no rec-running.txt -> running when the newest ledger line is this recent
NEED_NUMPY = "--fit 要 numpy"
SELF_CHECK = "报表自检没通过："
CRASH = "报表出错：{kind}: {msg}"
TZ_MIN, TZ_MAX = -720, 840


class UsageError(Exception):
    """Bad command line: becomes 「报表出错：UsageError: …」."""


class _Exit(Exception):
    def __init__(self, code: int):
        super().__init__(code)
        self.code = code


class _Parser(argparse.ArgumentParser):
    """argparse that raises instead of exiting, so even a usage error ends in the error document."""

    def error(self, message: str) -> Any:     # type: ignore[override]
        raise UsageError(message)

    def exit(self, status: int = 0, message: Optional[str] = None) -> Any:   # type: ignore[override]
        if message:
            _err(message.rstrip("\n"))
        raise _Exit(status)


def _parser() -> _Parser:
    p = _Parser(prog="y700-battery-report", add_help=True,
                description="电池使用情况页面的报表：读用电账本、前台日志、UPower 历史和 journal，算出各项用电。")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--json", dest="mode", action="store_const", const="json",
                   help="JSON v1 写到 stdout（默认）")
    g.add_argument("--text", dest="mode", action="store_const", const="text",
                   help="给人和 agent 看的明细：各段、各项的 J / mW / Wh、对账、标记")
    g.add_argument("--fit", dest="mode", action="store_const", const="fit",
                   help="用账本拟合系数，打印建议的 coeffs-v<N+1>.json，不写文件（要 numpy）")
    p.add_argument("--from", dest="from_dir", metavar="DIR", help="回放一份采集目录，不读实时文件")
    p.add_argument("--now", type=float, metavar="EPOCH", help="覆盖「现在」（Unix 秒）")
    p.add_argument("--tz-offset", dest="tz_offset", type=int, metavar="MIN",
                   help="覆盖时区，UTC 偏移分钟数（东八区是 480）")
    p.set_defaults(mode="json")
    return p


def parse_args(argv: Optional[list[str]]) -> argparse.Namespace:
    a = _parser().parse_args(argv)
    if a.now is not None and not (math.isfinite(a.now) and a.now > 0):
        raise UsageError(f"--now 不是有效的时间：{a.now}")
    if a.tz_offset is not None and not TZ_MIN <= a.tz_offset <= TZ_MAX:
        raise UsageError(f"--tz-offset 超出 {TZ_MIN}..{TZ_MAX}：{a.tz_offset}")
    return a


# ---------------------------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------------------------

def _write(stream: Any, text: str) -> None:
    """UTF-8 regardless of the locale the page starts us in (python3 -I ignores PYTHONIOENCODING)."""
    buf = getattr(stream, "buffer", None)
    if buf is not None:
        stream.flush()
        buf.write(text.encode("utf-8"))
        buf.flush()
    else:
        stream.write(text)


def _out(text: str) -> None:
    """The one write of the result to stdout. A reader that went away (`--text | head`) is not the report's
    failure: no traceback and no second document. stdout is pointed at /dev/null so the interpreter's own flush
    at exit does not complain either."""
    try:
        _write(sys.stdout, text)
    except BrokenPipeError:
        try:
            fd = os.open(os.devnull, os.O_WRONLY)
            os.dup2(fd, sys.stdout.fileno())
            os.close(fd)
        except (OSError, ValueError):
            pass


def _err(msg: str) -> None:
    try:
        _write(sys.stderr, msg + "\n")
    except (OSError, ValueError):
        pass


def dumps(doc: dict) -> str:
    return json.dumps(doc, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n"


def error_doc(msg: str) -> dict:
    return {"v": contract.V, "error": msg}


def crash_text(e: BaseException) -> str:
    return CRASH.format(kind=type(e).__name__, msg=str(e))


# ---------------------------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------------------------

def load_inputs(from_dir: Optional[str], now: Optional[float], tz_offset: Optional[int]) -> Inputs:
    """Everything parsed (6b.d pipeline up to Inputs)."""
    src = sources.open_sources(from_dir, now, tz_offset)
    coeffs = config.load_coeffs(from_mode=src.from_dir is not None)
    rules = config.load_rules()
    led = ledger.read_dir(src.state_dir)
    src.now = ledger.assign_clocks(led, sources.boot8_of(src.boot_id), src.now, src.mono_now)
    steps = {b.boot8: ledger.steps(b) for b in led.boots}
    lives = {b.boot8: ledger.lives(b) for b in led.boots}
    hist = upower.load(src, led)
    fixes = journal.attach(journal.parse(src.journal_lines), led, lives)
    return Inputs(src=src, coeffs=coeffs, rules=rules, ledger=led, history=hist, steps=steps, lives=lives,
                  fixes=fixes, apps=apps.AppIndex(src.desktop, rules))


def health_pct(bat: LiveBattery) -> Optional[int]:
    """charge_full / charge_full_design in whole percent (half up), None when either is missing."""
    cf, cfd = bat.charge_full_uah, bat.charge_full_design_uah
    if not cf or not cfd or cf <= 0 or cfd <= 0:
        return None
    return max(0, min(150, int(math.floor(cf * 100 / cfd + 0.5))))


def rec_state(inp: Inputs) -> RecState:
    """Recorder status from the live check (or rec-running.txt) and the ledger itself."""
    src, led = inp.src, inp.ledger
    cur8 = sources.boot8_of(src.boot_id)
    cur = next((b for b in led.boots if b.boot8 == cur8), None)
    newest = ledger.newest_wall(led)
    since = None
    for b in led.boots:
        m0 = ledger.first_m(b)
        if m0 is None:
            continue
        t = b.t(m0) if b.offset is not None else min(s.w for s in b.snaps) if b.snaps else None
        if t is not None and (since is None or t < since):
            since = t
    age = None if newest is None else max(0.0, src.now - newest)
    running = src.rec_running if src.rec_running is not None else (age is not None and age <= REC_FRESH_S)
    degraded = bool(cur is not None and cur.snaps and not cur.snaps[-1].cov)
    fg_log = False
    if cur is not None and cur.fg and src.fg_dir_exists:
        marks = [e.kind for e in sorted(cur.fg, key=lambda e: e.m) if e.kind in ("start", "stop")]
        fg_log = not marks or marks[-1] != "stop"
        refresh = [lf for uk, lf in inp.lives.get(cur8 or "", {}).items() if uk[0] == model.REFRESH_KEY]
        if refresh and all(lf.gone_m is not None for lf in refresh):
            fg_log = False      # refresh-auto's unit is gone: nothing writes the fg log any more
    return RecState(running=bool(running), degraded=degraded, since=since, last_write_age_s=age,
                    fg_log=fg_log, clock_unsynced=bool(cur is not None and cur.clock == "now"))


def build_report(inp: Inputs, t0: Optional[float] = None) -> tuple[Report, dict]:
    """(Report, {range key: [model.GroupDetail]}) from the parsed inputs (6b.d pipeline after Inputs)."""
    rngs = ranges.build(inp)
    res, details = {}, {}
    for k in contract.RANGE_KEYS:
        res[k], details[k] = model.attribute_detail(rngs[k], inp)
    src = inp.src
    rep = Report(now=src.now, tz_offset_min=int(src.tz_offset_min), took_ms=0, rec=rec_state(inp),
                 battery=src.battery, health_pct=health_pct(src.battery), coeffs=inp.coeffs, ranges=res,
                 remain=model.remain(inp), diag=model.diag(inp, res))
    if t0 is not None:
        rep.took_ms = _ms(t0)
    return rep, details


def _ms(t0: float) -> int:
    return max(0, int(round((time.perf_counter() - t0) * 1000)))


def run_json(inp: Inputs, t0: float) -> tuple[dict, list[str]]:
    rep, _ = build_report(inp, t0)
    doc = out.to_json(rep)
    doc["took_ms"] = _ms(t0)
    return doc, contract.validate(doc)


# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------

def main(argv: Optional[list[str]] = None) -> int:
    t0 = time.perf_counter()
    # A short-lived process: the parsed ledger is a few hundred thousand objects that all live until exit, and the
    # cyclic collector rescanned them for nothing (11-15 % of a 40-day run). Reference counting still frees
    # everything that is dropped. At the end, what is still alive is frozen: the interpreter's own collection at
    # exit then skips it too (another 0.1-0.3 s on 40 days). The collector is switched back on for in-process
    # callers (the tests); only cycles among the objects frozen here are never collected there.
    gc_on = gc.isenabled()
    gc.disable()
    try:
        return _main(argv, t0)
    finally:
        gc.freeze()
        if gc_on:
            gc.enable()


def _main(argv: Optional[list[str]], t0: float) -> int:
    try:
        args = parse_args(argv)
    except _Exit as e:
        return 0 if e.code == 0 else 2
    except UsageError as e:
        _err("y700-battery-report: " + str(e))
        _out(dumps(error_doc(crash_text(e))))
        return 2
    try:
        inp = load_inputs(args.from_dir, args.now, args.tz_offset)
        if args.mode == "json":
            doc, errs = run_json(inp, t0)
            if errs:
                for e in errs:
                    _err("自检：" + e)
                _out(dumps(error_doc(SELF_CHECK + errs[0])))
                return 2
            _out(dumps(doc))
            return 0
        if args.mode == "text":
            rep, details = build_report(inp, t0)
            doc = out.to_json(rep)
            doc["took_ms"] = rep.took_ms = _ms(t0)
            _out(out.to_text(rep, details, doc, contract.validate(doc)))
            return 0
        from . import fit as F
        try:
            res = F.fit(inp)
        except F.NeedNumpy:
            _err(NEED_NUMPY)
            _out(dumps(error_doc(NEED_NUMPY)))
            return 2
        except F.FitError as e:
            _err("y700-battery-report: " + str(e))
            _out(dumps(error_doc(str(e))))
            return 2
        _err(F.summary(res))
        _out(F.format_fit(res))
        return 0
    except config.ConfigError as e:
        _err("y700-battery-report: " + str(e))
        _out(dumps(error_doc(str(e))))
        return 2
    except Exception as e:      # noqa: BLE001 - the page must always get a document
        _err(traceback.format_exc().rstrip("\n"))
        try:
            _out(dumps(error_doc(crash_text(e))))
        except (OSError, ValueError):
            pass
        return 2
