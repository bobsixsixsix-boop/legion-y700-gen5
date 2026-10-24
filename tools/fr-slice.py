#!/usr/bin/env python3
"""fr-slice.py [options] LOG [LOG ...]: cut Y700 flight-recorder logs into windows and print per-window power numbers.

Plan M-1 (linux/power/PLAN-deep-powersave.md:119-123, 2026-10-19). Offline, Win11 or anywhere: reads copies of
/var/log/y700-flightrec/flightrec-<boot>.log or the gzipped rows exp-collect.sh keeps in runs/*/flightrec-*.log.gz
(gzip is picked by the .gz suffix, "-" is stdin). Read-only: it writes nothing except --out. Exit 0 when it ran
(void windows and "no windows" included), 2 on a usage error (bad option, unreadable LOG, bad --window).

Row format (linux/power/flightrec/src/main.rs:24-31, assembled in fmt() main.rs:327-331) - space separated
key=value, every count a delta since the previous row:
  t=<CLOCK_MONOTONIC s> at=<HH:MM:SS> up=<s> bat=<+/-mW, + = drawn from the battery> dpms=<On|Off>
  wifi=<operstate>/+<packets> gov= aco= aso= dl= busy= ctxt= irqt= irq=<top-3 name:count> c0=wfi:,ret:,rej: c1=...
  pd=cl0:<use>/<rej>,cl1:..,sys:..   qs=apss:<entries>/+<ms>,cxsd:..,aosd:..,ddr:..
Rows are parsed as key=value tokens, never by position: a token without "=" continues the previous value (irq names
such as "Function call interrup", HEADER's at=<date> <time>, of which only the <time> is kept as the line's at=);
every key that is not one of the structural ones is kept as a knob column (today gov aco aso dl; M-6 may add u0=
and more), so the layouts before and after M-6 both parse. Lines of one file are put in t= order (stable sort per
HEADER segment) = R11. Other lines: HEADER ... (recorder start, run.rs:328-329), MODE fast|slow t= at= reason=
(cadence switch, run.rs:230-236), STOP t= at= (SIGTERM, run.rs:386), MARK t= at= <text> (y700-flightrec --mark,
run.rs:156-158). Anything else is counted as an unknown line, never fatal. A UTF-8 BOM (a log re-saved by a Win11
editor) is skipped; CRLF is fine.

Days: a log is one file per boot (main.rs:11-12) and at= has no date, so a boot longer than 24 h repeats every wall
clock. The tool numbers the days of a file from 1 at the first line, +1 at every midnight wrap (at= jumping back by
more than 12 h between consecutive lines in t= order; a small backward NTP step is not a wrap) and prints the day
table in the file's header line when there is more than one day (at= and t= range and rows of each day).

Windows come from MARK lines (three grammars, applied together) and from --window:
  1. legacy  "<STEP> start [<N>min]" ... "<STEP> end[ anything]" - what cx-exp.sh emits today (cx-exp.sh:155 and
     :95, e.g. "E3a start 15min" / "E3a end aco=N aso=N"): the rows strictly between the two MARKs, exactly
     exp-collect.sh:33-45. A second start of the same STEP before its end closes the first (close=restart); no end
     MARK = the rows run to the end of the file (close=eof), as exp-collect.sh does after a reset. One difference
     from exp-collect.sh: a STOP or HEADER line (recorder restart, e.g. flightrec/deploy.sh) inside an open window
     closes it here (close=stop|header, noted "no end MARK"), while exp-collect.sh's awk keeps summing to the end
     MARK; none of the nine 2026-10-18 runs/*/flightrec-*.log.gz has a STOP or HEADER inside, so the ground truth
     is unaffected - pre-cut by line range if such a run must be summed across the restart.
  2. new     "<STEP>:<N>" - plan appendix D (PLAN:727-728), STEP = noop | E3a | E3a+K=<knob> | DIAG | B=<bench>:
     the window starts at that MARK and ends at the next MARK of any kind or N minutes later, whichever comes first.
     A single-word MARK without ":<N>" ("E3a", "DIAG:stuck") is accepted too and ends at the next MARK; that is
     wider than appendix D's STEP set (any one-word MARK opens a window), accepted because today's emitters
     (cx-exp.sh:37, y700-diag-pack.sh:128/:133) write no one-word free text - if one appears, it shows up as a
     window with its own label and is easy to ignore.
     FINDING (2026-10-19, run.rs:188-201): the recorder's --mark raises the 1 s cadence flag only when the second
     word is "start" (and drops it on "end"), so a "<STEP>:<N>" MARK leaves the recorder at its 10 s idle cadence
     (main.rs:16-19) until M-2 (P1.5) teaches mark() this grammar. A window cut from such a log has about 1/10 of
     the rows per minute; --settle and --min-rows are in seconds and rows and do not know that, and the block
     prints a "no MODE fast" note for such windows.
  3. "ABORT:<reason>" - R8: the window it falls into and every window after it are void (reason recorded). "After"
     is by t= (CLOCK_MONOTONIC, strictly increasing within a boot) for every grammar, --window included: a manual
     window is void when the ABORT's t= is at or before the window's last row.
     "DIAG:<name>", "DIAG:<N>", "DIAG:<name>:<N>", "DIAG:<name> start [<N>min]" ... "DIAG:<name> end" - R12: the
     window is reported, but void=diag, i.e. it gets no power verdict (the diagnostics wake the SoC themselves).
  --window LABEL=HH:MM:SS-HH:MM:SS (repeatable): a wall-clock slice like runs/day-20261018/slices.sh:6-19 -
     inclusive, string compare on at=, applied once per LOG given (one window per LOG, never pooled across files).
     A window that crosses midnight (start > end) is out of scope and refused (exit 2): at= has no date, cut such
     a night with two windows. On a log with more than one day (see Days) the slice takes the rows of EVERY day
     that has that wall clock; the tool then voids it (multi-day, with the days listed in a note) instead of
     printing a mean that belongs to no day, and the window is void multi-day as well whenever its rows span more
     t= than the window is long (+5 s slack: a clock step inside the window, or a wrap the 12 h rule missed).
     --day N (1-based, the numbering of the file's day table) restricts every --window of this run to that day's
     rows; a day the log does not have gives an empty window with a note. Pre-cutting the log is the alternative:
     sed -n 'A,Bp' by line numbers, or by a MARK pair, e.g.
       sed -n '/MARK .* E3a start 30min/,/MARK .* E3a end/p' LOG | python -X utf8 -I tools/fr-slice.py - --window ...
     (check `grep -n MARK LOG` first: a STEP run twice in one boot gives two ranges).

Per window (text; --json gives the same as a list of dicts): label, nominal at= range (MARK at= or the --window
bounds) and the kept rows' actual at= range, rows kept / in the window / dropped by --settle (R1, default 60 s,
measured from the MARK, or from the first row of a --window; --settle 0 reproduces exp-collect.sh and slices.sh
exactly), rows without bat= (dropped, R2), zero reads (bat=0 is a dropped gauge read, exp-collect.sh:37-39,
2026-10-16: left out and counted; a real zero crossing reads 0 as well, so this is what R3 can be here),
charging rows (bat<0 = current into the battery: they void the window per plan 3.3 unless --allow-charging; the
mean still includes them, as exp-collect.sh:39 and slices.sh:10 do), bat mean and median in mW, span t1-t0, rows/s,
dpms histogram (R5: more than one value = dpms-changed, void), knob histograms (gov aco aso dl and every unknown
column), pd use/rej sums and per-second rates cl0/cl1/sys (use/span like slices.sh:13/:19), qs entries and +ms
sums with residency % (ms/10/span, exp-collect.sh:44), wifi operstate histogram and packets, the NVT touch
interrupts seen in irq= (a lower bound, see R6 below), the day(s) of the file the rows belong to, MODE lines and
other MARKs inside the window, notes, and the VOID list: none / charging / dpms-changed / multi-day (--window only,
see Days) / abort:<reason> / diag / too-few-rows<N (--min-rows, default 10) / no-bat-rows. After the blocks: one
line per window in slices.sh's printf columns (slices.sh:19), so that runs/day-20261018/slices-0840.txt can be
compared by eye; "VOID ..." is appended only when the window is void. Per-second rates divide by the kept rows'
span t1-t0 as exp-collect.sh:43 does (span 0 -> 0.0/s); slices.sh:17 divides by 1 s when the span is 0, so for a
window of one row (void too-few-rows anyway) the two one-liners differ in the rate columns - the only exception to
"--settle 0 reproduces slices.sh".

Rules of plan 3.4 (PLAN:428-430) implemented here: R1 settle, R2 missing bat=, R3 (as the 0 mW drop above), R5
dpms change, R8 ABORT, R11 order by t=, R12 DIAG. Not implemented because the recorder has no column for them yet
(all need a recorder change first, listed so nobody believes a "VOID none" covers them):
  R4  temperature >45 C: no temperature column in the row.
  R6  NVT touch interrupts >=3: irq= holds only the row's top-3 names, so NVT-ts* is counted only when it made the
      top 3 (printed as nvt_irq_lb, a lower bound, never a verdict); needs a dedicated column.
  R7  Tailscale down: wifi= is the operstate (up/down), not tailscale's BackendState.
  R13 tailscaled/powerdevil restart +-60 s: needs the journal (unit restarts are not in the log).
  R14 "context lost" / GL_GUILTY_CONTEXT_RESET -> ABORT: journal data; here only an explicit MARK ABORT counts.
  R15 NVT-ts-spi delta per screen-on window: same limit as R6 (top-3 only).
R9 (median over repeated arms) and R10 (void count per night) are across windows and belong to the night's
verdict file (appendix C, PLAN:720-722), not to one slice run.

P1 obligation (PLAN:122 and :458): copy /var/log/y700-flightrec/flightrec-*.log of the 10-17 and 10-18 nights into
runs/diag/flightrec/ (gzipped, see runs/diag/README.md) and reproduce with this tool, within 5 mW, README.md:1550 (the 2026-10-17 night
bullet "0.30 / 0.27 / 0.27 W": E3a 30 min 01:51-02:21 at t+1/12/23 min, and the 00:50 all-off 5 min baseline
0.33 W) and README.md:1567 (the 2026-10-18 bullet "E3a 305 mW": E3a 305 mW, cx-auto E3a 267 mW, E3b 274, E3c 285,
all-off 331 mW = the windows of runs/day-20261018/slices-0840.txt, cut with --settle 0 and the same --window
bounds); the README line numbers are those of the 2026-10-19 working tree, grep the quoted text if they drifted.
Mind the days (above): the 10-17 night is in boot 690a169c, which ran 2026-10-16 19:08:37 .. 2026-10-18 05:50:06
(runs/E3a-20261018-0710/summary.txt:3-5) and therefore also holds the 10-18 night at the same wall clock - E0
00:48:55-01:08:57, E4@E3a 01:24:13-02:04:17 (723 mW, panel blinking, runs/E4-E3a-20261018-0124/summary.txt:53),
E3b 02:19:33-02:49:37 (the MARKs in runs/E0-20261018-0048, E4-E3a-20261018-0124 and E3b-20261018-0219
flightrec-*.log.gz). In that file day 1 = 10-16 from 19:08, day 2 = 10-17, day 3 = 10-18 until 05:50: the 10-17
windows need --day 2 (or a pre-cut), otherwise they come out void multi-day with the 10-18 rows mixed in. The 10-18
day test is in boot 974b286c (from 05:50:06); unless the tablet was rebooted before 2026-10-19 07:00 that file holds
a 10-19 day at the same wall clock too, so use --day 1 there. Until the copies exist the only real rows in the repo
are runs/*/flightrec-*.log.gz: tools/test-fr-slice.py checks this tool against their summary.txt (exp-collect.sh's
sums, e.g. runs/E3a-20261018-0710/summary.txt:52-55: rows=902, cl0 use=15506, bat mean 310 mW, 2026-10-18) and
against slices.sh's awk.

Usage: python -X utf8 -I tools/fr-slice.py [--settle S] [--window LABEL=HH:MM:SS-HH:MM:SS ...] [--day N] [--no-marks]
           [--allow-charging] [--min-rows N] [--json] [--out FILE] LOG [LOG ...]
  python -X utf8 -I tools/fr-slice.py --settle 0 linux/power/cx-collapse/runs/E3a-20261018-0710/flightrec-E3a.log.gz
  python -X utf8 -I tools/fr-slice.py --settle 0 --day 2 --window E3a-t1=01:52:00-01:52:59 runs/diag/flightrec/flightrec-690a169c.log.gz
"""
import argparse
import gzip
import json
import re
import statistics
import sys
from collections import Counter

STRUCT_KEYS = frozenset(("t", "at", "up", "bat", "dpms", "wifi", "busy", "ctxt", "irqt", "irq", "c0", "c1", "pd", "qs"))
KNOB_ORDER = ("gov", "aco", "aso", "dl")
PD_ORDER = ("cl0", "cl1", "sys")
QS_ORDER = ("apss", "cxsd", "aosd", "ddr")
KEY_RE = re.compile(r"^([A-Za-z0-9_]+)=(.*)$", re.S)
BAT_RE = re.compile(r"^([-+]?\d+)mW$")
MARK_RE = re.compile(r"^MARK t=(\S+) at=(\S+)\s*(.*)$")
MODE_RE = re.compile(r"^MODE (\S+) t=(\S+) at=(\S+)")
STOP_RE = re.compile(r"^STOP t=(\S+) at=(\S+)")
WINDOW_RE = re.compile(r"^([^=\s]+)=(\d\d:\d\d:\d\d)-(\d\d:\d\d:\d\d)$")
EPS = 1e-6
DAY_WRAP_S = 12 * 3600   # at= jumping back by more than this between consecutive lines = midnight, a new day
DAY_SLACK_S = 5.0        # a --window's rows may span this much more t= than the window is long (at= is 1 s coarse, NTP slew)


# ---------------------------------------------------------------- parsing
def kv_tokens(s):
    """'k=v k2=v with spaces k3=v' -> [[key, value], ...]; a token without '=' continues the previous value."""
    out = []
    for tok in s.split():
        m = KEY_RE.match(tok)
        if m:
            out.append([m.group(1), m.group(2)])
        elif out:
            out[-1][1] += " " + tok
    return out


def to_int(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        return None


def to_float(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def hms_s(at):
    """'HH:MM:SS' -> seconds since midnight; None when it is not that shape."""
    m = re.match(r"^(\d\d):(\d\d):(\d\d)$", at or "")
    return (int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))) if m else None


def parse_pairs(s):
    """'cl0:34/0,cl1:9/0,sys:27/0' or 'apss:26/+353,...' -> {name: (a, b)}; '-' or junk -> {}."""
    out = {}
    if not s or s == "-":
        return out
    for item in s.split(","):
        name, sep, ab = item.partition(":")
        if not sep:
            continue
        a, sep2, b = ab.partition("/")
        if not sep2:
            continue
        ai, bi = to_int(a.lstrip("+")), to_int(b.lstrip("+"))
        if ai is None or bi is None:
            continue
        out[name] = (ai, bi)
    return out


def parse_irq(s):
    """'arch_timer:256,Function call interrup:74' -> {name: count}."""
    out = {}
    if not s or s == "-":
        return out
    for item in s.split(","):
        name, sep, n = item.rpartition(":")
        ni = to_int(n) if sep else None
        if ni is not None:
            out[name] = ni
    return out


def parse_row(line, lineno):
    d = {}
    for k, v in kv_tokens(line):
        d[k] = v
    t = to_float(d.get("t"))
    if t is None:
        return None
    m = BAT_RE.match(d.get("bat", ""))
    state, _, pk = d.get("wifi", "").partition("/")
    return {
        "kind": "row", "t": t, "at": d.get("at", ""), "lineno": lineno, "raw": line,
        "bat": int(m.group(1)) if m else None,  # None = no bat= (R2); 0 = dropped gauge read
        "dpms": d.get("dpms"),
        "wifi": state or None, "wifi_pk": to_int(pk.lstrip("+")) or 0,
        "pd": parse_pairs(d.get("pd", "")), "qs": parse_pairs(d.get("qs", "")), "irq": parse_irq(d.get("irq", "")),
        "params": {k: v for k, v in d.items() if k not in STRUCT_KEYS},
    }


def parse_line(line, lineno):
    if line.startswith("t="):
        r = parse_row(line, lineno)
        if r:
            return r
    if line.startswith("MARK"):
        m = MARK_RE.match(line)
        if m:
            return {"kind": "mark", "t": to_float(m.group(1)), "at": m.group(2), "text": m.group(3).strip(), "lineno": lineno, "raw": line}
        return {"kind": "mark", "t": None, "at": "", "text": line[4:].strip(), "lineno": lineno, "raw": line}
    if line.startswith("MODE"):
        m = MODE_RE.match(line)
        return {"kind": "mode", "t": to_float(m.group(2)) if m else None, "at": m.group(3) if m else "", "lineno": lineno, "raw": line}
    if line.startswith("STOP"):
        m = STOP_RE.match(line)
        return {"kind": "stop", "t": to_float(m.group(1)) if m else None, "at": m.group(2) if m else "", "lineno": lineno, "raw": line}
    if line.startswith("HEADER"):
        # at=<date> <time> (run.rs:328-329): keep the <time> so that a window closed by a HEADER prints HH:MM:SS
        at = dict(kv_tokens(line)).get("at", "").split()
        return {"kind": "header", "t": None, "at": at[-1] if at else "", "lineno": lineno, "raw": line}
    return {"kind": "other", "t": None, "at": "", "lineno": lineno, "raw": line}


def number_days(lines):
    """Give every line (in t= order) a "day" (1-based, +1 at each midnight wrap of at=) and return the day table:
    [{day, first_at, last_at, first_t, last_t, rows}]. at= has no date (main.rs:24), so this is the only way to
    tell the days of a boot log apart."""
    table, day, prev = [], 1, None
    for ln in lines:
        cur = hms_s(ln.get("at"))
        if cur is not None:
            if prev is not None and cur < prev - DAY_WRAP_S:
                day += 1
            prev = cur
        ln["day"] = day
        if cur is None:
            continue
        if not table or table[-1]["day"] != day:
            table.append({"day": day, "first_at": ln["at"], "last_at": ln["at"], "first_t": ln["t"], "last_t": ln["t"], "rows": 0})
        d = table[-1]
        d["last_at"] = ln["at"]
        if ln["t"] is not None:
            d["last_t"] = ln["t"]
            if d["first_t"] is None:
                d["first_t"] = ln["t"]
        if ln["kind"] == "row":
            d["rows"] += 1
    return table


def parse_log(text_lines):
    """-> (lines in t= order, stats). R11: each HEADER-delimited segment is stable-sorted by t=; a line without
    t= (HEADER, odd MARK) keeps the t= of the line before it. stats["days"] is the day table of number_days()."""
    parsed = []
    for i, raw in enumerate(text_lines, 1):
        line = raw.rstrip("\r\n")
        if not line.strip():
            continue
        parsed.append(parse_line(line, i))
    segments, cur = [], []
    for ln in parsed:
        if ln["kind"] == "header" and cur:
            segments.append(cur)
            cur = []
        cur.append(ln)
    if cur:
        segments.append(cur)
    ordered = []
    for seg in segments:
        keys, last = [], float("-inf")
        for ln in seg:
            if ln["t"] is not None:
                last = ln["t"]
            keys.append(last)
        order = sorted(range(len(seg)), key=keys.__getitem__)
        ordered.extend(seg[i] for i in order)
    stats = Counter(ln["kind"] for ln in ordered)
    stats["reordered"] = sum(1 for a, b in zip(parsed, ordered) if a is not b)
    stats["days"] = number_days(ordered)
    return ordered, stats


# ---------------------------------------------------------------- MARK grammar
def is_diag(step):
    return step == "DIAG" or step.startswith("DIAG:")


def classify_mark(text):
    """MARK text -> {kind: legacy_start | legacy_end | step | abort | other, step, minutes, diag, reason}."""
    w = text.split()
    c = {"kind": "other", "step": "", "minutes": None, "diag": False, "reason": ""}
    if not w:
        return c
    w0 = w[0]
    if w0 == "ABORT" or w0.startswith("ABORT:"):
        c.update(kind="abort", reason=(w0[len("ABORT:"):] + " " + " ".join(w[1:])).strip() or "-")
        return c
    if len(w) >= 2 and w[1] in ("start", "end"):
        minutes = None
        if w[1] == "start" and len(w) >= 3 and w[2].endswith("min"):
            minutes = to_float(w[2][:-3])
        c.update(kind="legacy_" + w[1], step=w0, minutes=minutes, diag=is_diag(w0))
        return c
    if len(w) == 1:
        head, sep, tail = w0.rpartition(":")
        if sep and head and tail.isdigit():
            c.update(kind="step", step=head, minutes=float(tail), diag=is_diag(head))
        else:
            c.update(kind="step", step=w0, minutes=None, diag=is_diag(w0))
        return c
    return c


# ---------------------------------------------------------------- windows
def new_window(label, grammar, source, start_t, start_at, start_text, minutes=None, diag=False, limit_t=None):
    return {
        "label": label, "step": label, "grammar": grammar, "diag": diag, "source": source,
        "start_t": start_t, "start_at": start_at, "start_text": start_text, "minutes": minutes, "limit_t": limit_t,
        "end_t": None, "end_at": None, "end_text": None, "close": None, "abort_reason": None,
        "rows": [], "modes": [], "marks_inside": [],
        "day": None, "ndays": 1, "window_len": None,   # --day, days in the log, --window length in s (manual only)
    }


def close_window(w, t, at, reason, text=None):
    w["end_t"], w["end_at"], w["close"], w["end_text"] = t, at, reason, text
    if w["end_at"] is None:
        w["end_at"] = w["rows"][-1]["at"] if w["rows"] else w["start_at"]


def mark_windows(lines, source):
    """Windows from MARK lines (grammars 1-3 of the header). Returns (windows, aborts)."""
    wins, open_, aborts = [], [], []
    last_t, last_at = None, ""
    for ln in lines:
        k = ln["kind"]
        if ln["t"] is not None:
            last_t = ln["t"]
        if ln.get("at"):
            last_at = ln["at"]
        if k == "row":
            for w in list(open_):
                if w["limit_t"] is not None and ln["t"] > w["limit_t"] + EPS:
                    close_window(w, w["limit_t"], None, "minutes")
                    open_.remove(w)
                else:
                    w["rows"].append(ln)
        elif k == "mode":
            for w in open_:
                w["modes"].append(ln["raw"])
        elif k == "mark":
            c = classify_mark(ln["text"])
            t, at = (ln["t"] if ln["t"] is not None else last_t), ln["at"] or last_at
            for w in list(open_):
                if w["grammar"] == "step":
                    close_window(w, t, at, "abort" if c["kind"] == "abort" else "next-mark", ln["text"])
                elif c["kind"] == "abort":
                    close_window(w, t, at, "abort", ln["text"])
                elif c["kind"] == "legacy_end" and c["step"] == w["step"]:
                    close_window(w, t, at, "end-mark", ln["text"])
                elif c["kind"] == "legacy_start" and c["step"] == w["step"]:
                    close_window(w, t, at, "restart", ln["text"])
                else:
                    w["marks_inside"].append(ln["raw"])
                    continue
                open_.remove(w)
            if c["kind"] == "abort":
                aborts.append({"t": t, "at": at, "reason": c["reason"]})
            elif c["kind"] == "legacy_start":
                w = new_window(c["step"], "legacy", source, t, at, ln["text"], c["minutes"], c["diag"])
                open_.append(w)
                wins.append(w)
            elif c["kind"] == "step":
                limit = t + c["minutes"] * 60.0 if (c["minutes"] is not None and t is not None) else None
                w = new_window(c["step"], "step", source, t, at, ln["text"], c["minutes"], c["diag"], limit)
                open_.append(w)
                wins.append(w)
        elif k in ("stop", "header"):
            for w in open_:
                close_window(w, ln["t"] if ln["t"] is not None else last_t, ln.get("at") or None, k)
            open_.clear()
    for w in open_:
        close_window(w, last_t, None, "eof")
    for w in wins:
        if w["end_t"] is None:
            w["end_t"] = w["start_t"]
        for a in aborts:
            if a["t"] is not None and w["end_t"] is not None and w["end_t"] >= a["t"] - EPS:
                w["abort_reason"] = a["reason"]
                break
    seen = Counter()
    for w in wins:
        seen[w["label"]] += 1
        if seen[w["label"]] > 1:
            w["label"] = "%s#%d" % (w["label"], seen[w["label"]])
    return wins, aborts


def manual_window(lines, aborts, label, a, b, source, day=None, ndays=1):
    """slices.sh:8-9: rows whose at= is between A and B inclusive (string compare); with day, only that day's."""
    inside = [ln for ln in lines if ln.get("at") and a <= ln["at"] <= b and (day is None or ln["day"] == day)]
    rows = [ln for ln in inside if ln["kind"] == "row"]
    w = new_window(label, "manual", source, rows[0]["t"] if rows else None, a, "--window %s=%s-%s" % (label, a, b))
    w["rows"] = rows
    w["modes"] = [ln["raw"] for ln in inside if ln["kind"] == "mode"]
    w["marks_inside"] = [ln["raw"] for ln in inside if ln["kind"] == "mark"]
    sa, sb = hms_s(a), hms_s(b)
    w["day"], w["ndays"], w["window_len"] = day, ndays, (sb - sa) if (sa is not None and sb is not None) else None
    close_window(w, rows[-1]["t"] if rows else None, b, "window")
    # R8 by t= (a boot log can hold several days at the same wall clock, so at= cannot order an ABORT against the
    # window); an ABORT without t= (odd MARK line) falls back to the wall clock
    for ab in aborts:
        if ab["t"] is not None and rows:
            hit = ab["t"] <= rows[-1]["t"] + EPS
        else:
            hit = bool(ab["at"]) and ab["at"] <= b
        if hit:
            w["abort_reason"] = ab["reason"]
            break
    return w


# ---------------------------------------------------------------- numbers
def summarize(w, settle, allow_charging, min_rows):
    rows = w["rows"]
    ref = w["start_t"] if w["grammar"] != "manual" else (rows[0]["t"] if rows else None)
    kept = [r for r in rows if ref is None or r["t"] - ref >= settle - EPS]
    n = len(kept)
    nobat = sum(1 for r in kept if r["bat"] is None)
    zero = sum(1 for r in kept if r["bat"] == 0)
    vals = [r["bat"] for r in kept if r["bat"] not in (None, 0)]
    charging = sum(1 for v in vals if v < 0)
    t0, t1 = (kept[0]["t"], kept[-1]["t"]) if n else (None, None)
    span = (t1 - t0) if n > 1 else 0.0
    rate = (lambda x: x / span if span > 0 else 0.0)
    dpms = Counter(r["dpms"] for r in kept if r["dpms"] is not None)
    knobs = {}
    for r in kept:
        for k, v in r["params"].items():
            knobs.setdefault(k, Counter())[v] += 1
    pd_use, pd_rej = Counter(), Counter()
    for r in kept:
        for k, (u, rj) in r["pd"].items():
            pd_use[k] += u
            pd_rej[k] += rj
    qs_n, qs_ms = Counter(), Counter()
    for r in kept:
        for k, (c, ms) in r["qs"].items():
            qs_n[k] += c
            qs_ms[k] += ms
    pd_names = [k for k in PD_ORDER if k in pd_use] + sorted(k for k in pd_use if k not in PD_ORDER)
    qs_names = [k for k in QS_ORDER if k in qs_n] + sorted(k for k in qs_n if k not in QS_ORDER)
    knob_names = [k for k in KNOB_ORDER if k in knobs] + sorted(k for k in knobs if k not in KNOB_ORDER)
    void = []
    if w["abort_reason"] is not None:
        void.append("abort:" + w["abort_reason"])
    if w["diag"]:
        void.append("diag")
    if charging and not allow_charging:
        void.append("charging")
    if len(dpms) > 1:
        void.append("dpms-changed")
    notes = []
    days = sorted(set(r["day"] for r in rows))
    if w["grammar"] == "manual" and rows:
        # all rows of the window, not only the kept ones: --settle could drop every row of the first day
        span_all = rows[-1]["t"] - rows[0]["t"]
        if len(days) > 1:
            void.append("multi-day")
            notes.append("rows of days %s of this log share the wall clock %s-%s (at= has no date, one file per boot): "
                         "use --day N or pre-cut the log" % (",".join(str(d) for d in days), w["start_at"], w["end_at"]))
        elif w["window_len"] is not None and span_all > w["window_len"] + DAY_SLACK_S:
            void.append("multi-day")
            notes.append("the rows span %.0f s of t= but the window is %d s long: a clock step or a midnight wrap inside "
                         "(at= has no date): pre-cut the log" % (span_all, w["window_len"]))
    if n < min_rows:
        void.append("too-few-rows<%d" % min_rows)
    if not vals:
        void.append("no-bat-rows")
    if w["grammar"] == "manual" and w["day"] is not None and w["day"] > w["ndays"]:
        notes.append("--day %d: this log has %d day(s) by at= wrap" % (w["day"], w["ndays"]))
    if w["grammar"] == "legacy" and w["close"] != "end-mark":
        notes.append("no end MARK: closed by %s" % w["close"])
    if w["grammar"] == "step" and not any(m.startswith("MODE fast") for m in w["modes"]):
        notes.append("no MODE fast inside: a \"<STEP>:<N>\" MARK does not raise the recorder's 1 s cadence until M-2")
    if charging and allow_charging:
        notes.append("%d charging rows kept in the mean (--allow-charging)" % charging)
    for k in knob_names:
        if len(knobs[k]) > 1:
            notes.append("knob %s changed inside the window: %s" % (k, hist_str(knobs[k])))
    if w["grammar"] == "manual" and not rows:
        notes.append("no rows with at= in that range")
    return {
        "label": w["label"], "step": w["step"], "grammar": w["grammar"], "diag": w["diag"], "source": w["source"],
        "start_at": w["start_at"], "end_at": w["end_at"], "start_t": w["start_t"], "end_t": w["end_t"],
        "start_text": w["start_text"], "end_text": w["end_text"], "close": w["close"], "minutes": w["minutes"],
        "rows_at": [kept[0]["at"], kept[-1]["at"]] if n else [None, None],
        "days": days, "day": w["day"], "ndays": w["ndays"], "window_len_s": w["window_len"],
        "rows": n, "rows_in_window": len(rows), "settle_dropped": len(rows) - n, "settle_s": settle,
        "nobat_rows": nobat, "zero_reads": zero, "charging_rows": charging,
        "bat_n": len(vals),
        "bat_mean": (sum(vals) / len(vals)) if vals else None,
        "bat_median": float(statistics.median(vals)) if vals else None,
        "span_s": span, "rows_per_s": ((n - 1) / span) if span > 0 else 0.0,
        "dpms": dict(dpms),
        "knobs": {k: dict(knobs[k]) for k in knob_names},
        "pd": {k: {"use": pd_use[k], "rej": pd_rej[k], "per_s": rate(pd_use[k])} for k in pd_names},
        "qs": {k: {"entries": qs_n[k], "ms": qs_ms[k], "pct": rate(qs_ms[k] / 10.0)} for k in qs_names},
        "wifi": dict(Counter(r["wifi"] for r in kept if r["wifi"])),
        "wifi_packets": sum(r["wifi_pk"] for r in kept),
        "nvt_irq_lb": sum(c for r in kept for name, c in r["irq"].items() if name.startswith("NVT-ts")),
        "modes": list(w["modes"]), "marks_inside": list(w["marks_inside"]),
        "void": void, "ok": not void, "notes": notes, "abort_reason": w["abort_reason"],
    }


# ---------------------------------------------------------------- text output
def hist_str(c):
    return " ".join("%s:%d" % (k, c[k]) for k in sorted(c))


def fmt_mw(v):
    return "%.0f mW" % v if v is not None else "-"


def block(s):
    lines = []
    how = {"legacy": "legacy MARK", "step": "MARK", "manual": "--window"}[s["grammar"]]
    head = "== %s  %s-%s  %s \"%s\"" % (s["label"], s["start_at"], s["end_at"], how, s["start_text"])
    if s["end_text"]:
        head += " .. \"%s\"" % s["end_text"]
    head += "  close=%s  [%s]" % (s["close"], s["source"])
    lines.append(head)
    lines.append("   rows %d kept (%d in window, %d dropped by --settle %g; %d without bat=, %d zero reads, %d charging rows)  at %s-%s%s"
                 % (s["rows"], s["rows_in_window"], s["settle_dropped"], s["settle_s"], s["nobat_rows"], s["zero_reads"],
                    s["charging_rows"], s["rows_at"][0], s["rows_at"][1],
                    ("  day %s of %d" % (",".join(str(d) for d in s["days"]) or "-", s["ndays"])) if s["ndays"] > 1 else ""))
    lines.append("   bat mean %s  median %s  (n=%d)  span %.0f s  %.2f rows/s"
                 % (fmt_mw(s["bat_mean"]), fmt_mw(s["bat_median"]), s["bat_n"], s["span_s"], s["rows_per_s"]))
    knobs = "  ".join("%s %s" % (k, hist_str(Counter(v))) for k, v in s["knobs"].items())
    lines.append("   dpms %s  | %s" % (hist_str(Counter(s["dpms"])) or "-", knobs or "-"))
    lines.append("   pd  " + ("  ".join("%s %d/%d = %.1f/s" % (k, v["use"], v["rej"], v["per_s"]) for k, v in s["pd"].items()) or "-"))
    lines.append("   qs  " + ("  ".join("%s +%d / +%d ms = %.0f %%" % (k, v["entries"], v["ms"], v["pct"]) for k, v in s["qs"].items()) or "-"))
    lines.append("   wifi %s +%d pkts  nvt_irq_lb %d" % (hist_str(Counter(s["wifi"])) or "-", s["wifi_packets"], s["nvt_irq_lb"]))
    for m in s["modes"]:
        lines.append("   " + m)
    for m in s["marks_inside"]:
        lines.append("   inside: " + m)
    for note in s["notes"]:
        lines.append("   note: " + note)
    lines.append("   VOID " + (" ".join(s["void"]) if s["void"] else "none"))
    return "\n".join(lines)


def one_line(s):
    """slices.sh:19 printf columns; the dpms/aco histograms carry a trailing space each, as in awk."""
    pd = s["pd"]
    per = lambda k: pd[k]["per_s"] if k in pd else 0.0
    d = "".join("%s:%d " % (k, v) for k, v in sorted(s["dpms"].items()))
    aco = s["knobs"].get("aco", {})
    e = "".join("%s:%d " % (k, v) for k, v in sorted(aco.items()))
    line = "%-10s %s-%s rows %4d  bat %4.0f mW  cl0 %5.1f/s  cl1 %5.1f/s  sys %5.1f/s  apss %3.0f%%  cxsd +%d  | dpms %s aco %s" % (
        s["label"], s["start_at"], s["end_at"], s["rows"], s["bat_mean"] if s["bat_mean"] is not None else 0.0,
        per("cl0"), per("cl1"), per("sys"), s["qs"]["apss"]["pct"] if "apss" in s["qs"] else 0.0,
        s["qs"]["cxsd"]["entries"] if "cxsd" in s["qs"] else 0, d, e)
    if s["void"]:
        line += " VOID " + " ".join(s["void"])
    return line


# ---------------------------------------------------------------- driver
def read_lines(path):
    """utf-8-sig: a BOM (a log re-saved by a Win11 editor) would otherwise hide the first line, usually a MARK."""
    if path == "-":
        text = sys.stdin.read()
        return text[1:].splitlines() if text.startswith("\ufeff") else text.splitlines()
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8-sig", errors="replace") as f:
        return f.read().splitlines()


def slice_file(path, text_lines, windows, settle, allow_charging, min_rows, use_marks=True, day=None):
    """All windows of one log: (summaries, stats, aborts). day: --day N for the manual windows."""
    lines, stats = parse_log(text_lines)
    ndays = len(stats["days"])
    wins, aborts = mark_windows(lines, path)
    if not use_marks:
        wins = []
    for w in wins:
        w["ndays"] = ndays
    for label, a, b in windows:
        wins.append(manual_window(lines, aborts, label, a, b, path, day, ndays))
    return [summarize(w, settle, allow_charging, min_rows) for w in wins], stats, aborts


def parse_window_arg(spec):
    """'LABEL=HH:MM:SS-HH:MM:SS' -> (label, a, b); None when malformed or crossing midnight."""
    m = WINDOW_RE.match(spec)
    if not m or m.group(2) > m.group(3):
        return None
    return m.group(1), m.group(2), m.group(3)


def render_text(results):
    out = []
    for path, sums, stats, aborts in results:
        out.append("# %s: %d rows, %d MARK, %d MODE, %d HEADER, %d STOP, %d unknown lines, %d reordered by t=; %d windows%s" % (
            path, stats["row"], stats["mark"], stats["mode"], stats["header"], stats["stop"], stats["other"], stats["reordered"],
            len(sums), "; ABORT at %s (%s)" % (aborts[0]["at"], aborts[0]["reason"]) if aborts else ""))
        days = stats["days"]
        if len(days) > 1:
            out.append("#   %d days by at= wrap (at= has no date; --window takes every day unless --day N): %s" % (
                len(days), "; ".join("day %d %s-%s t=%s-%s %d rows" % (
                    d["day"], d["first_at"], d["last_at"], "%.0f" % d["first_t"] if d["first_t"] is not None else "-",
                    "%.0f" % d["last_t"] if d["last_t"] is not None else "-", d["rows"]) for d in days)))
        for s in sums:
            out.append(block(s))
    out.append("== one line per window, slices.sh columns (label at=-at= rows bat cl0/s cl1/s sys/s apss% cxsd | dpms aco)")
    for _, sums, _, _ in results:
        for s in sums:
            out.append(one_line(s))
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="fr-slice.py", formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Cut Y700 flight-recorder logs (plain or .gz) into windows from MARK lines and/or --window, and print "
                    "per-window bat mean/median, pd rates, qs residency and a VOID reason list. Read-only: writes only --out.",
        epilog="MARK grammars: legacy \"<STEP> start [<N>min]\" .. \"<STEP> end\"; new \"<STEP>:<N>\" (ends at the next MARK or "
               "after N min); \"ABORT:<reason>\" voids everything after it; \"DIAG:<name>\" windows get no power verdict.\n"
               "--window compares at= as strings, inclusive, like runs/day-20261018/slices.sh; a window crossing midnight "
               "(start > end) is out of scope - cut it as two windows. at= has no date and a log is one file per boot, so "
               "on a boot longer than 24 h one --window takes every day with that wall clock: such a window is void "
               "multi-day; pass --day N (the file's day table is printed when it has more than one day) or pre-cut the "
               "log. Exit 0 when it ran, 2 on a usage error.")
    ap.add_argument("logs", nargs="+", metavar="LOG", help="flightrec-<boot>.log, a runs/*/flightrec-*.log.gz, or - for stdin")
    ap.add_argument("--settle", type=float, default=60.0, metavar="S",
                    help="seconds dropped at the start of every window (R1, default 60); 0 reproduces exp-collect.sh and slices.sh")
    ap.add_argument("--window", action="append", default=[], metavar="LABEL=HH:MM:SS-HH:MM:SS",
                    help="manual wall-clock window on at= (inclusive, string compare); repeatable; must not cross midnight")
    ap.add_argument("--day", type=int, default=None, metavar="N",
                    help="restrict every --window to day N of each LOG (1 = from the first line, +1 per midnight wrap of at=)")
    ap.add_argument("--no-marks", action="store_true", help="no windows from MARK lines, only --window")
    ap.add_argument("--allow-charging", action="store_true", help="rows with bat<0 do not void the window")
    ap.add_argument("--min-rows", type=int, default=10, metavar="N", help="fewer kept rows than this voids the window (default 10)")
    ap.add_argument("--json", action="store_true", help="print a JSON list of window dicts instead of text")
    ap.add_argument("--out", metavar="FILE", help="write the output there instead of stdout (the only file this tool writes)")
    a = ap.parse_args(argv)
    if a.settle < 0:
        ap.error("--settle must be >= 0")
    if a.min_rows < 0:
        ap.error("--min-rows must be >= 0")
    windows = []
    for spec in a.window:
        pw = parse_window_arg(spec)
        if pw is None:
            ap.error("bad --window %r: want LABEL=HH:MM:SS-HH:MM:SS with start <= end (crossing midnight is out of scope)" % spec)
        windows.append(pw)
    if a.no_marks and not windows:
        ap.error("--no-marks without --window leaves nothing to cut")
    if a.day is not None and a.day < 1:
        ap.error("--day must be >= 1 (days are numbered from 1 at the first line of each LOG)")
    if a.day is not None and not windows:
        ap.error("--day only applies to --window slices (MARK windows are bounded by t= already)")
    results = []
    for path in a.logs:
        try:
            text_lines = read_lines(path)
        except (OSError, EOFError, gzip.BadGzipFile) as e:
            ap.error("cannot read %s: %s" % (path, e))
        sums, stats, aborts = slice_file(path, text_lines, windows, a.settle, a.allow_charging, a.min_rows, not a.no_marks, a.day)
        results.append((path, sums, stats, aborts))
    if a.json:
        text = json.dumps([s for _, sums, _, _ in results for s in sums], indent=1) + "\n"
    else:
        text = render_text(results)
    if a.out:
        try:
            with open(a.out, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
        except OSError as e:
            ap.error("cannot write %s: %s" % (a.out, e))
    else:
        sys.stdout.write(text)
    if not any(sums for _, sums, _, _ in results):
        print("fr-slice: no windows (no MARK pairs and no --window)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
