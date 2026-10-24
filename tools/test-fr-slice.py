#!/usr/bin/env python3
"""test-fr-slice.py [FR_SLICE]: offline test of tools/fr-slice.py (plan M-1, 2026-10-19). No tablet, no network.

  a) ground truth: every linux/power/cx-collapse/runs/*/summary.txt that carries exp-collect.sh's four result lines
     (the nine 2026-10-18 runs; at least three must be found; SKIP, not a FAIL, when no flightrec-*.log.gz is there
     at all, as in the public repository, which leaves the raw logs out): fr-slice --settle 0 on that dir's flightrec-*.log.gz,
     legacy MARK pair, must give the same rows, cl0/cl1/sys use and rej sums, qs entries/ms sums, span, rows/s,
     residency, bat mean (%.0f), bat row count and zero-read count. The 2026-10-16 dirs have the older summary
     (no bat line; E3a-20261016-0408 holds two runs and its rows=3607 is their sum, PROTOCOL.md:241 "rows=3607",
     2026-10-19 working tree): there only rows and pd sums over all windows of the file are compared.
  b) synthetic logs in a temp dir: both column layouts (today's and a hypothetical post-M-6 one with u0= and two
     invented columns), the three MARK grammars, ABORT, DIAG, zero reads, missing bat=, a dpms flip, charging rows,
     settle dropping, --window, R11 reordering, HEADER/MODE/STOP/junk lines, a HEADER closing a legacy window, the
     days of a boot log longer than 24 h (day table, --window void multi-day, --day N, R8 by t= across days, the
     t= span rule), a UTF-8 BOM + CRLF copy, CLI exit codes, --json and --out.
  c) cross-check: runs/day-20261018/slices.sh itself (its awk, read from the file, not copied) through Git Bash on a
     synthetic log, compared with fr-slice --window --settle 0: rows, bat mean, cl0/cl1/sys per second, apss %,
     cxsd entries, dpms and aco histograms. SKIP (printed, not a FAIL) when no Git Bash is found: on Windows
     shutil.which("bash") returns the WSL launcher in System32, which is not it.
Prints PASS/FAIL per check and "ALL PASS" at the end; exit 1 on any FAIL.
Run: python -X utf8 -I tools/test-fr-slice.py
"""
import gzip
import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
RUNS = REPO / "linux" / "power" / "cx-collapse" / "runs"
FR_PATH = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else HERE / "fr-slice.py"
loader = importlib.machinery.SourceFileLoader("frslice", str(FR_PATH))
fr = importlib.util.module_from_spec(importlib.util.spec_from_loader("frslice", loader))
loader.exec_module(fr)

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok)))
    print("%s %s%s" % ("PASS" if ok else "FAIL", name, ("  -- " + str(detail)) if (detail and not ok) else ""))
    return bool(ok)


# ---------------------------------------------------------------- synthetic rows
IRQ = "arch_timer:256,Function call interrup:74,apss_cpucp_mbox:11"


def at(t, base_h=7):
    s = int(t)
    return "%02d:%02d:%02d" % (base_h + s // 3600, (s // 60) % 60, s % 60)


def row(t, bat="+300mW", dpms="Off", aco="Y", aso="Y", pd="cl0:30/0,cl1:10/0,sys:25/0",
        qs="apss:25/+350,cxsd:0/+0,aosd:0/+0,ddr:0/+0", layout="old", irq=IRQ, wall=None):
    """One recorder row (main.rs:327-331 layout); layout="new" adds u0= (PLAN:404) and two invented columns
    (ssh=, x9=) to stand in for whatever M-6 appends - only "unknown keys are kept" is being tested. wall= sets
    at= explicitly (the multi-day logs), otherwise at= is 07:00:00 + t."""
    batf = "" if bat is None else " bat=%s" % bat
    knobs = "gov=teo aco=%s aso=%s dl=off" % (aco, aso)
    tail = ""
    if layout == "new":
        knobs += " u0=0 ssh=0"
        tail = " x9=foo"
    return ("t=%.1f at=%s up=%.2f%s dpms=%s wifi=up/+3 %s busy=0.4 ctxt=418 irqt=382 irq=%s "
            "c0=wfi:58,ret:254,rej:0 c1=wfi:12,ret:37,rej:0 pd=%s qs=%s%s") % (t, wall if wall is not None else at(t), t, batf, dpms, knobs, irq, pd, qs, tail)


def mark(t, text):
    return "MARK t=%.1f at=%s %s" % (t, at(t), text)


def mode(t, fast, reason="experiment-mark"):
    return "MODE %s t=%.1f at=%s reason=%s" % ("fast" if fast else "slow", t, at(t), reason)


def run_fr(lines, windows=(), settle=0.0, allow_charging=False, min_rows=10, use_marks=True, name="synthetic.log", day=None):
    """-> (summaries, stats, aborts) of fr-slice on in-memory lines."""
    return fr.slice_file(name, list(lines), list(windows), settle, allow_charging, min_rows, use_marks, day)


# ---------------------------------------------------------------- a) ground truth
RE_ROWS = re.compile(r"^rows=(\d+)\s+cl0 use=(\d+) rej=(\d+)\s+cl1 use=(\d+) rej=(\d+)\s+sys use=(\d+)(?: rej=(\d+))?", re.M)
RE_QS = re.compile(r"^qcom_stats entries / ms summed: apss \+(\d+) / \+(\d+) ms\s+cxsd \+(\d+) / \+(\d+)\s+aosd \+(\d+) / \+(\d+)\s+ddr \+(\d+) / \+(\d+)", re.M)
RE_SPAN = re.compile(r"^span (\d+) s \(([\d.]+) rows/s\)\s+residency apss (\d+) %\s+cxsd (\d+) %\s+aosd (\d+) %\s+ddr (\d+) %", re.M)
RE_BAT = re.compile(r"^bat mean (-?\d+) mW over (\d+) rows \((\d+) zero reads left out\)", re.M)
RE_SEL = re.compile(r"^== selected run:[^\n]*\n(MARK [^\n]*)\n(MARK [^\n]*)\n", re.M)


def ground_truth():
    full, partial = 0, 0
    for sp in sorted(RUNS.glob("*/summary.txt")):
        txt = sp.read_text(encoding="utf-8", errors="replace")
        m_rows = RE_ROWS.search(txt)
        gzs = sorted(sp.parent.glob("flightrec-*.log.gz"))
        if not m_rows or not gzs:
            continue
        gz = gzs[0]
        tag = sp.parent.name
        sums, stats, aborts = fr.slice_file(str(gz), fr.read_lines(str(gz)), [], 0.0, False, 10)
        m_qs, m_span, m_bat, m_sel = RE_QS.search(txt), RE_SPAN.search(txt), RE_BAT.search(txt), RE_SEL.search(txt)
        if not (m_qs and m_span and m_bat and m_sel):
            # 2026-10-16 summaries: rows/pd only, summed over every window in the file
            partial += 1
            got = {"rows": sum(s["rows"] for s in sums)}
            for k in ("cl0", "cl1", "sys"):
                got[k] = sum(s["pd"].get(k, {"use": 0})["use"] for s in sums)
            want = {"rows": int(m_rows[1]), "cl0": int(m_rows[2]), "cl1": int(m_rows[4]), "sys": int(m_rows[6])}
            check("ground-truth(old summary) %s rows/pd over %d windows" % (tag, len(sums)), got == want, "got %s want %s" % (got, want))
            continue
        full += 1
        start_text = re.sub(r"^MARK t=\S+ at=\S+\s*", "", m_sel[1])
        end_text = re.sub(r"^MARK t=\S+ at=\S+\s*", "", m_sel[2])
        cands = [s for s in sums if s["start_text"] == start_text]
        if not check("ground-truth %s: one legacy window for %r" % (tag, start_text), len(cands) == 1 and len(sums) == 1, [s["start_text"] for s in sums]):
            continue
        s = cands[0]
        # E4 flashes the panel 20 s on / 20 s off by design (cx-exp.sh:162-166; README.md:1552, the "E4" bullet of the
        # 2026-10-17 night, line of the 2026-10-19 working tree), so its windows are rightly void dpms-changed (R5);
        # every other 2026-10-18 run must be clean
        want_void = ["dpms-changed"] if tag.startswith("E4-") else []
        got = {
            "rows": s["rows"], "end": s["end_text"], "close": s["close"], "grammar": s["grammar"], "void": s["void"],
            "cl0": (s["pd"]["cl0"]["use"], s["pd"]["cl0"]["rej"]), "cl1": (s["pd"]["cl1"]["use"], s["pd"]["cl1"]["rej"]),
            "sys": (s["pd"]["sys"]["use"], s["pd"]["sys"]["rej"]),
            "qs": tuple((s["qs"][k]["entries"], s["qs"][k]["ms"]) for k in ("apss", "cxsd", "aosd", "ddr")),
            "span": "%.0f" % s["span_s"], "rate": "%.2f" % s["rows_per_s"],
            "res": tuple("%.0f" % s["qs"][k]["pct"] for k in ("apss", "cxsd", "aosd", "ddr")),
            "bat": "%.0f" % s["bat_mean"], "bat_n": s["bat_n"], "zero": s["zero_reads"],
        }
        want = {
            "rows": int(m_rows[1]), "end": end_text, "close": "end-mark", "grammar": "legacy", "void": want_void,
            "cl0": (int(m_rows[2]), int(m_rows[3])), "cl1": (int(m_rows[4]), int(m_rows[5])), "sys": (int(m_rows[6]), int(m_rows[7])),
            "qs": tuple((int(m_qs[i]), int(m_qs[i + 1])) for i in (1, 3, 5, 7)),
            "span": m_span[1], "rate": m_span[2], "res": tuple(m_span[i] for i in (3, 4, 5, 6)),
            "bat": m_bat[1], "bat_n": int(m_bat[2]), "zero": int(m_bat[3]),
        }
        diff = {k: (got[k], want[k]) for k in want if got[k] != want[k]}
        check("ground-truth %s: rows/pd/qs/span/bat == summary.txt" % tag, not diff, diff)
        # the text one-liner must carry the same numbers
        line = fr.one_line(s)
        check("ground-truth %s: one-liner carries rows and bat" % tag, ("rows %4d" % want["rows"]) in line and ("bat %4.0f mW" % float(want["bat"])) in line, line)
    if not any(RUNS.glob("*/flightrec-*.log.gz")):
        print("SKIP ground-truth: no flightrec-*.log.gz under linux/power/cx-collapse/runs/ (raw recorder logs, not shipped)")
        return
    check("ground-truth: at least 3 full summaries found (got %d full, %d old)" % (full, partial), full >= 3)


# ---------------------------------------------------------------- b) synthetic
def synth_legacy():
    """legacy pair, MODE lines, settle, HEADER/STOP/junk, both layouts and R11 reordering."""
    lines = ["HEADER boot=deadbeef at=2026-10-19 07:00:00 kernel=7.3.0 interval=1.0 sync=5 idle_interval=10.0 idle_sync=6 "
             "iface=wlp1s0 pstore_archived=0 gov=teo aco=N aso=N dl=off cmdline=a=b cpuidle_psci_domain.allow_cluster_off=0",
             mode(0.5, False, "idle")]
    lines += [row(t, aco="N", aso="N", pd="cl0:0/1,cl1:0/2,sys:0/0", qs="apss:0/+0,cxsd:0/+0,aosd:0/+0,ddr:0/+0") for t in range(1, 10)]
    lines.append(mark(10, "E3a start 2min"))
    lines.append(mode(10.1, True))
    body = [row(t, bat="+%dmW" % (280 + (t % 7) * 10), layout=("new" if t % 2 else "old")) for t in range(11, 131)]
    # R11: two rows swapped in file order
    body[50], body[51] = body[51], body[50]
    lines += body
    lines.append("garbage line that is not a row")
    lines.append("")
    lines.append(mark(131, "E3a end aco=N aso=N"))
    lines += [row(t, aco="N", aso="N") for t in range(132, 140)]
    lines.append("STOP t=140.0 at=%s" % at(140))
    sums, stats, aborts = run_fr(lines, settle=0.0)
    check("legacy: one window, grammar legacy, closed by end MARK", len(sums) == 1 and sums[0]["grammar"] == "legacy" and sums[0]["close"] == "end-mark", [(s["grammar"], s["close"]) for s in sums])
    s = sums[0]
    check("legacy: rows strictly between the MARKs (120)", s["rows"] == 120 and s["rows_in_window"] == 120, s["rows"])
    check("legacy: label/step/at range from the MARKs", s["label"] == "E3a" and s["start_at"] == at(10) and s["end_at"] == at(131), (s["label"], s["start_at"], s["end_at"]))
    want_mean = sum(280 + (t % 7) * 10 for t in range(11, 131)) / 120.0
    check("legacy: bat mean over all rows", abs(s["bat_mean"] - want_mean) < 1e-9, (s["bat_mean"], want_mean))
    check("legacy: pd sums and rates (cl0 30*120 / span 119)", s["pd"]["cl0"]["use"] == 3600 and abs(s["pd"]["cl0"]["per_s"] - 3600 / 119.0) < 1e-9 and s["pd"]["sys"]["use"] == 3000, s["pd"])
    check("legacy: apss residency = ms/10/span", abs(s["qs"]["apss"]["pct"] - (350 * 120) / 10.0 / 119.0) < 1e-9, s["qs"])
    check("legacy: MODE fast inside, no notes, VOID none", s["modes"] == [mode(10.1, True)] and s["void"] == [] and s["ok"] and s["notes"] == [], (s["modes"], s["void"], s["notes"]))
    check("legacy: both layouts parsed, unknown keys kept as knobs (u0/ssh/x9 on 60 rows)", s["knobs"].get("u0") == {"0": 60} and s["knobs"].get("x9") == {"foo": 60} and s["knobs"]["aco"] == {"Y": 120}, s["knobs"])
    check("legacy: trailing unknown column did not break qs/pd of new-layout rows", s["qs"]["apss"]["entries"] == 25 * 120 and s["pd"]["cl1"]["use"] == 1200, s["qs"])
    check("legacy: R11 reorder by t= (2 lines moved, rows ascending)", stats["reordered"] == 2 and s["rows_at"] == [at(11), at(130)], (stats["reordered"], s["rows_at"]))
    check("legacy: HEADER/STOP/junk counted, not fatal", stats["header"] == 1 and stats["stop"] == 1 and stats["other"] == 1 and stats["row"] == 137, dict(stats))
    sums60, _, _ = run_fr(lines, settle=60.0)
    s60 = sums60[0]
    check("legacy: --settle 60 drops rows with t < MARK+60 (kept 61 of 120)", s60["rows"] == 61 and s60["settle_dropped"] == 59 and s60["rows_at"][0] == at(70), (s60["rows"], s60["settle_dropped"], s60["rows_at"]))
    # no end MARK: rows run to the end of the file, noted, not void
    cut = lines[:lines.index(mark(131, "E3a end aco=N aso=N"))]
    sums_eof, _, _ = run_fr(cut)
    check("legacy: missing end MARK -> close=eof, noted, numbers still there", sums_eof[0]["close"] == "eof" and sums_eof[0]["rows"] == 120 and any("no end MARK" in n for n in sums_eof[0]["notes"]) and sums_eof[0]["void"] == [], (sums_eof[0]["close"], sums_eof[0]["notes"]))
    # a second start of the same step closes the first
    twice = lines[:5] + [mark(5, "E3a start 1min")] + lines[5:]
    sums_tw, _, _ = run_fr(twice)
    check("legacy: restart of the same STEP closes the first window (labels E3a, E3a#2)", [s["label"] for s in sums_tw] == ["E3a", "E3a#2"] and sums_tw[0]["close"] == "restart" and sums_tw[1]["rows"] == 120, [(s["label"], s["close"], s["rows"]) for s in sums_tw])
    # a HEADER (recorder restart) inside an open window closes it, and its at=<date> <time> prints as the time only
    reboot = [mark(10, "E3a start 5min")] + [row(t) for t in range(11, 100)] + \
             ["HEADER boot=cafef00d at=2026-10-19 %s kernel=7.3.0 interval=1.0 sync=5 idle_interval=10.0 idle_sync=6 iface=wlp1s0" % at(100)] + \
             [row(t) for t in range(1, 50)] + [mark(50, "E3a end aco=N aso=N")]
    sums_rb, stats_rb, _ = run_fr(reboot)
    s = sums_rb[0]
    check("legacy: HEADER inside the window -> close=header, end_at is HH:MM:SS (no date), 89 rows", len(sums_rb) == 1 and s["close"] == "header" and s["end_at"] == at(100) and s["rows"] == 89 and stats_rb["header"] == 1, (s["close"], s["end_at"], s["rows"]))
    check("legacy: the one-liner keeps the at=-at= column with a HEADER close", fr.one_line(s).startswith("%-10s %s-%s rows   89" % ("E3a", at(10), at(100))), fr.one_line(s))


def synth_new_grammar():
    """<STEP>:<N>, next-MARK and N-minute closing, ABORT (R8), DIAG (R12), bare single-word MARK, other MARKs."""
    lines = [row(t) for t in range(1, 10)]
    lines.append(mark(10, "noop:2"))                       # ends after 120 s (t=130) - before the next MARK
    lines += [row(t) for t in range(11, 201)]
    lines.append(mark(201, "E3a+K=rtcsync:1"))             # 60 s limit, but the ABORT at 231 comes first
    lines += [row(t) for t in range(202, 231)]
    lines.append(mark(231, "ABORT:owner picked up the tablet"))
    lines += [row(t) for t in range(232, 250)]
    lines.append(mark(250, "DIAG:whoawake:5"))             # name and minutes
    lines += [row(t) for t in range(251, 300)]
    lines.append(mark(300, "E3a"))                         # bare single word: window to the next MARK
    lines += [row(t) for t in range(301, 330)]
    lines.append(mark(330, "owner says hello"))            # not a window; closes the bare one
    lines += [row(t) for t in range(331, 340)]
    sums, stats, aborts = run_fr(lines)
    labels = [(s["label"], s["grammar"], s["close"]) for s in sums]
    check("new: four windows noop / E3a+K=rtcsync / DIAG:whoawake / E3a, none for the free-text MARK",
          labels == [("noop", "step", "minutes"), ("E3a+K=rtcsync", "step", "abort"), ("DIAG:whoawake", "step", "next-mark"), ("E3a", "step", "next-mark")], labels)
    noop, rtc, diag, bare = sums
    check("new: noop:2 ends 120 s after its MARK (rows t=11..130)", noop["rows"] == 120 and noop["minutes"] == 2 and noop["rows_at"] == [at(11), at(130)], (noop["rows"], noop["rows_at"]))
    check("new: noop window before the ABORT is not void, but notes the missing MODE fast (M-2 finding)", noop["void"] == [] and any("MODE fast" in n for n in noop["notes"]), (noop["void"], noop["notes"]))
    check("new: E3a+K=rtcsync cut by the ABORT, void abort:<reason>", rtc["rows"] == 29 and rtc["void"] == ["abort:owner picked up the tablet"] and rtc["abort_reason"] == "owner picked up the tablet", (rtc["rows"], rtc["void"]))
    check("new: ABORT recorded with at=", aborts == [{"t": 231.0, "at": at(231), "reason": "owner picked up the tablet"}], aborts)
    check("new: DIAG:<name>:<N> after the ABORT: diag, void has abort and diag, numbers still reported",
          diag["diag"] and diag["void"] == ["abort:owner picked up the tablet", "diag"] and diag["minutes"] == 5 and diag["bat_mean"] == 300.0 and diag["rows"] == 49, (diag["void"], diag["minutes"], diag["rows"]))
    check("new: bare 'E3a' MARK runs to the next MARK of any kind", bare["rows"] == 29 and bare["end_text"] == "owner says hello" and "abort:owner picked up the tablet" in bare["void"], (bare["rows"], bare["end_text"], bare["void"]))
    # DIAG in every spelling
    for text, want_step in (("DIAG:5", "DIAG"), ("DIAG:stuck", "DIAG:stuck"), ("DIAG:stuck:3", "DIAG:stuck")):
        c = fr.classify_mark(text)
        check("new: classify %r -> step %r, diag" % (text, want_step), c["kind"] == "step" and c["step"] == want_step and c["diag"], c)
    c = fr.classify_mark("DIAG:stuck start 5min")
    check("new: classify legacy 'DIAG:stuck start 5min' -> legacy_start, diag, 5 min", c["kind"] == "legacy_start" and c["diag"] and c["minutes"] == 5.0, c)
    c = fr.classify_mark("B=offbench:20")
    check("new: classify 'B=offbench:20' -> step B=offbench, 20 min", c["kind"] == "step" and c["step"] == "B=offbench" and c["minutes"] == 20.0, c)
    c = fr.classify_mark("ABORT")
    check("new: classify bare 'ABORT' -> abort, reason '-'", c["kind"] == "abort" and c["reason"] == "-", c)
    # legacy DIAG pair: reported, void=diag only
    lines = [mark(10, "DIAG:stuck start 1min")] + [row(t) for t in range(11, 71)] + [mark(71, "DIAG:stuck end")]
    sums, _, _ = run_fr(lines)
    check("new: legacy 'DIAG:stuck start/end' pair -> one legacy diag window, void == [diag]", len(sums) == 1 and sums[0]["grammar"] == "legacy" and sums[0]["diag"] and sums[0]["void"] == ["diag"] and sums[0]["rows"] == 60, [(s["grammar"], s["void"], s["rows"]) for s in sums])
    # a legacy window hit by an ABORT
    lines = [mark(10, "E3a start 5min")] + [row(t) for t in range(11, 41)] + [mark(41, "ABORT:ssh")] + [row(t) for t in range(42, 60)] + [mark(60, "E3a end aco=N aso=N")]
    sums, _, _ = run_fr(lines)
    check("new: legacy window cut by ABORT -> close=abort, void abort:ssh, 30 rows", len(sums) == 1 and sums[0]["close"] == "abort" and sums[0]["void"] == ["abort:ssh"] and sums[0]["rows"] == 30, [(s["close"], s["void"], s["rows"]) for s in sums])


def synth_bat_rules():
    """zero reads, missing bat=, charging rows, dpms flip, too few rows, median."""
    base = [mark(10, "E3a start 1min")]
    vals = []
    body = []
    for t in range(11, 71):
        i = t - 11
        if i < 3:
            body.append(row(t, bat="+0mW"))
        elif i < 5:
            body.append(row(t, bat="-0mW"))                # 2026-10-16 logs read "-0mW" (E1-20261016-0012)
        elif i < 9:
            body.append(row(t, bat=None))                  # no bat= column at all (R2)
        else:
            v = 250 + i
            vals.append(v)
            body.append(row(t, bat="+%dmW" % v))
    lines = base + body + [mark(71, "E3a end")]
    sums, _, _ = run_fr(lines)
    s = sums[0]
    check("bat: zero reads (+0/-0) counted 5, missing bat= 4, mean/median over the other 51", s["zero_reads"] == 5 and s["nobat_rows"] == 4 and s["bat_n"] == 51 and abs(s["bat_mean"] - sum(vals) / 51.0) < 1e-9 and s["bat_median"] == float(statistics.median(vals)), (s["zero_reads"], s["nobat_rows"], s["bat_n"], s["bat_mean"], s["bat_median"]))
    check("bat: zero/missing rows still count as rows (60) and are not void", s["rows"] == 60 and s["void"] == [], (s["rows"], s["void"]))
    # all zero reads -> no-bat-rows
    lines = [mark(10, "E1 start 1min")] + [row(t, bat="-0mW") for t in range(11, 71)] + [mark(71, "E1 end aco=N aso=-")]
    sums, _, _ = run_fr(lines)
    check("bat: every read zero -> bat_mean None, void no-bat-rows, 60 zero reads", sums[0]["bat_mean"] is None and sums[0]["void"] == ["no-bat-rows"] and sums[0]["zero_reads"] == 60, (sums[0]["bat_mean"], sums[0]["void"]))
    # charging rows
    lines = [mark(10, "E3a start 1min")] + [row(t, bat=("-500mW" if 30 <= t < 35 else "+300mW")) for t in range(11, 71)] + [mark(71, "E3a end")]
    sums, _, _ = run_fr(lines)
    s = sums[0]
    want_mean = (55 * 300 - 5 * 500) / 60.0
    check("bat: 5 charging rows void the window, mean still includes them (exp-collect.sh:39)", s["charging_rows"] == 5 and s["void"] == ["charging"] and abs(s["bat_mean"] - want_mean) < 1e-9, (s["charging_rows"], s["void"], s["bat_mean"]))
    sums, _, _ = run_fr(lines, allow_charging=True)
    check("bat: --allow-charging -> not void, noted", sums[0]["void"] == [] and any("charging rows kept" in n for n in sums[0]["notes"]), (sums[0]["void"], sums[0]["notes"]))
    # dpms flip (R5)
    lines = [mark(10, "E3a start 1min")] + [row(t, dpms=("On" if t >= 60 else "Off")) for t in range(11, 71)] + [mark(71, "E3a end")]
    sums, _, _ = run_fr(lines)
    check("dpms: flip inside the window -> histogram Off:49 On:11, void dpms-changed", sums[0]["dpms"] == {"Off": 49, "On": 11} and sums[0]["void"] == ["dpms-changed"], (sums[0]["dpms"], sums[0]["void"]))
    # knob change is a note, not a void
    lines = [mark(10, "E3a start 1min")] + [row(t, aco=("N" if t < 13 else "Y")) for t in range(11, 71)] + [mark(71, "E3a end")]
    sums, _, _ = run_fr(lines)
    check("knobs: aco N->Y inside the window is a note (N:2 Y:58), not void", sums[0]["knobs"]["aco"] == {"N": 2, "Y": 58} and sums[0]["void"] == [] and any(n.startswith("knob aco changed") for n in sums[0]["notes"]), (sums[0]["knobs"], sums[0]["notes"]))
    # too few rows
    lines = [mark(10, "E3a start 1min")] + [row(t) for t in range(11, 16)] + [mark(16, "E3a end")]
    sums, _, _ = run_fr(lines)
    check("rows: 5 rows -> void too-few-rows<10", sums[0]["void"] == ["too-few-rows<10"], sums[0]["void"])
    sums, _, _ = run_fr(lines, min_rows=3)
    check("rows: --min-rows 3 accepts 5 rows", sums[0]["void"] == [], sums[0]["void"])
    # NVT lower bound from the top-3 irq= column
    lines = [mark(10, "E3a start 1min")] + [row(t, irq="NVT-ts-spi:3,arch_timer:100,Function call interrup:5") for t in range(11, 71)] + [mark(71, "E3a end")]
    sums, _, _ = run_fr(lines)
    check("irq: NVT-ts-spi in the top-3 summed as nvt_irq_lb (180), irq names with spaces parsed", sums[0]["nvt_irq_lb"] == 180, sums[0]["nvt_irq_lb"])


def synth_window():
    """--window: inclusive string compare on at=, settle from the first row, --no-marks, crossing midnight refused."""
    lines = [row(t, bat="+%dmW" % (200 + t)) for t in range(0, 600)]     # 07:00:00 .. 07:09:59
    lines.insert(300, mark(299.5, "E3a start 2min"))
    lines.insert(400, mode(398.5, True))
    wins = [("w1", "07:02:00", "07:03:59"), ("w2", "07:09:30", "07:12:00"), ("empty", "08:00:00", "08:00:10")]
    sums, _, _ = run_fr(lines, windows=wins, use_marks=False)
    w1, w2, empty = sums
    check("window: --no-marks leaves only the manual windows", [s["label"] for s in sums] == ["w1", "w2", "empty"] and all(s["grammar"] == "manual" for s in sums), [s["label"] for s in sums])
    check("window: inclusive bounds (120 rows 07:02:00..07:03:59)", w1["rows"] == 120 and w1["rows_at"] == ["07:02:00", "07:03:59"] and w1["start_at"] == "07:02:00" and w1["end_at"] == "07:03:59", (w1["rows"], w1["rows_at"]))
    check("window: bat mean of the slice", abs(w1["bat_mean"] - sum(200 + t for t in range(120, 240)) / 120.0) < 1e-9, w1["bat_mean"])
    check("window: open end past the last row (30 rows), MARK/MODE inside listed", w2["rows"] == 30 and w2["modes"] == [] and w2["marks_inside"] == [], (w2["rows"], w2["modes"], w2["marks_inside"]))
    check("window: empty slice -> 0 rows, void too-few-rows and no-bat-rows, noted", empty["rows"] == 0 and empty["void"] == ["too-few-rows<10", "no-bat-rows"] and empty["bat_mean"] is None and any("no rows" in n for n in empty["notes"]), (empty["rows"], empty["void"]))
    sums, _, _ = run_fr(lines, windows=[("w3", "07:04:00", "07:07:00")], settle=60.0, use_marks=False)
    w3 = sums[0]
    check("window: --settle 60 drops the first 60 s after the slice's first row (181 -> 121)", w3["rows_in_window"] == 181 and w3["rows"] == 121 and w3["rows_at"][0] == "07:05:00" and w3["modes"] == [mode(398.5, True)] and w3["marks_inside"] == [mark(299.5, "E3a start 2min")], (w3["rows_in_window"], w3["rows"], w3["rows_at"], w3["modes"]))
    sums, _, _ = run_fr(lines, windows=[("w1", "07:02:00", "07:03:59")])
    check("window: MARK windows and --window together (E3a + w1)", [s["label"] for s in sums] == ["E3a", "w1"], [s["label"] for s in sums])
    # ABORT before the manual window voids it
    lines2 = lines[:50] + [mark(49.5, "ABORT:test")] + lines[50:]
    sums, _, _ = run_fr(lines2, windows=[("w1", "07:02:00", "07:03:59")], use_marks=False)
    check("window: ABORT earlier in the log voids a later manual window", sums[0]["void"] == ["abort:test"], sums[0]["void"])
    check("window: parse_window_arg refuses crossing midnight and junk", fr.parse_window_arg("x=23:00:00-01:00:00") is None and fr.parse_window_arg("x=1-2") is None and fr.parse_window_arg("lab=07:00:00-07:10:00") == ("lab", "07:00:00", "07:10:00"))


def synth_days():
    """A boot log longer than 24 h (one file per boot, at= has no date): the day table, --window void multi-day,
    --day N, R8 by t= across days, and the t= span rule for a clock step inside a window."""
    def wall(sec):
        sec %= 86400
        return "%02d:%02d:%02d" % (sec // 3600, (sec // 60) % 60, sec % 60)

    start = 1 * 3600 + 50 * 60                             # day 1 01:50:00, like boot 690a169c's 10-17 night
    header = "HEADER boot=690a169c at=2026-10-17 01:50:00 kernel=7.3.0 interval=1.0 sync=5 idle_interval=10.0 idle_sync=6 iface=wlp1s0"

    def drow(i):                                           # 10 s idle rows from t=1000; +300 mW on day 1, +600 mW on day 2
        sec = start + i * 10
        return row(1000.0 + i * 10, bat=("+600mW" if sec >= 86400 else "+300mW"), wall=wall(sec))

    lines = [header] + [drow(i) for i in range(26 * 360)]  # 26 h: day 1 = 01:50:00..23:59:50 (7980 rows), day 2 = 00:00:00..03:49:50 (1380)
    sums, stats, _ = run_fr(lines, windows=[("night", "01:52:00", "01:53:00")], use_marks=False)
    days = stats["days"]
    check("days: two days by at= wrap, table has at=/t=/rows of each",
          [(d["day"], d["first_at"], d["last_at"], d["first_t"], d["rows"]) for d in days] == [(1, "01:50:00", "23:59:50", 1000.0, 7980), (2, "00:00:00", "03:49:50", 80800.0, 1380)], days)
    s = sums[0]
    check("days: --window without --day pools both days -> VOID multi-day, days [1, 2], note names them, mean still printed",
          s["void"] == ["multi-day"] and s["days"] == [1, 2] and s["rows"] == 14 and s["bat_mean"] == 450.0 and any("days 1,2" in n for n in s["notes"]), (s["void"], s["days"], s["rows"], s["bat_mean"], s["notes"]))
    check("days: the one-liner carries VOID multi-day", fr.one_line(s).endswith(" VOID multi-day"), fr.one_line(s))
    w = [("night", "01:52:00", "01:54:59")]
    d1 = run_fr(lines, windows=w, use_marks=False, day=1)[0][0]
    d2 = run_fr(lines, windows=w, use_marks=False, day=2)[0][0]
    d3 = run_fr(lines, windows=w, use_marks=False, day=3)[0][0]
    check("days: --day 1 -> 18 rows at 300 mW, VOID none, day 1 of 2", d1["rows"] == 18 and d1["bat_mean"] == 300.0 and d1["void"] == [] and d1["day"] == 1 and d1["days"] == [1] and d1["ndays"] == 2, (d1["rows"], d1["bat_mean"], d1["void"], d1["day"], d1["days"]))
    check("days: --day 2 -> 18 rows at 600 mW, VOID none", d2["rows"] == 18 and d2["bat_mean"] == 600.0 and d2["void"] == [] and d2["days"] == [2], (d2["rows"], d2["bat_mean"], d2["void"]))
    check("days: --day 3 on a 2-day log -> empty window, noted", d3["rows"] == 0 and any("--day 3: this log has 2 day(s)" in n for n in d3["notes"]), (d3["rows"], d3["notes"]))
    # --settle 60 on a 1-min window drops every day-1 row: the verdict must still see both days (checked on all rows)
    s60 = run_fr(lines, windows=[("m", "01:52:00", "01:52:59")], settle=60.0, use_marks=False)[0][0]
    check("days: --settle 60 keeps only day-2 rows (6 of 12) but the window is still VOID multi-day", s60["rows_in_window"] == 12 and s60["rows"] == 6 and "multi-day" in s60["void"] and s60["days"] == [1, 2], (s60["rows_in_window"], s60["rows"], s60["void"]))
    # a MARK window on day 2 is bounded by t= and never multi-day
    i0 = (86400 - start) // 10 + 360                       # the 01:00:00 row of day 2
    t0 = 1000.0 + i0 * 10
    marked = list(lines)
    marked.insert(1 + i0, "MARK t=%.1f at=%s E3a start 5min" % (t0 - 0.5, wall(start + i0 * 10 - 1)))
    marked.insert(1 + i0 + 31, "MARK t=%.1f at=%s E3a end aco=N aso=N" % (t0 + 299.5, wall(start + i0 * 10 + 299)))
    sm, _, _ = run_fr(marked, windows=[("night", "01:52:00", "01:53:00")])
    check("days: a legacy MARK window on day 2 (30 rows, 600 mW) is VOID none, days [2]; the --window next to it is multi-day",
          [s["label"] for s in sm] == ["E3a", "night"] and sm[0]["rows"] == 30 and sm[0]["bat_mean"] == 600.0 and sm[0]["void"] == [] and sm[0]["days"] == [2] and sm[1]["void"] == ["multi-day"], [(s["label"], s["rows"], s["bat_mean"], s["void"], s["days"]) for s in sm])
    # R8 by t=: ABORT on day 1 at 03:00:00 voids the later day-1 window and the day-2 window, not the earlier day-1 one
    ia = (3 * 3600 - start) // 10
    aborted = list(lines)
    aborted.insert(1 + ia + 1, "MARK t=%.1f at=03:00:00 ABORT:test-day1" % (1000.0 + ia * 10 + 0.5))
    wins1 = [("d1early", "02:00:00", "02:10:00"), ("d1late", "07:00:00", "07:10:00")]
    a1, _, ab = run_fr(aborted, windows=wins1, use_marks=False, day=1)
    a2 = run_fr(aborted, windows=[("d2early", "01:00:00", "01:10:00")], use_marks=False, day=2)[0][0]
    check("days: ABORT recorded with t=", len(ab) == 1 and ab[0]["t"] == 1000.0 + ia * 10 + 0.5 and ab[0]["at"] == "03:00:00", ab)
    check("days: R8 by t= - day-1 window before the ABORT is VOID none (61 rows, 300 mW)", a1[0]["void"] == [] and a1[0]["rows"] == 61 and a1[0]["bat_mean"] == 300.0, (a1[0]["void"], a1[0]["rows"]))
    check("days: R8 by t= - day-1 window after the ABORT is void abort", a1[1]["void"] == ["abort:test-day1"], a1[1]["void"])
    check("days: R8 by t= - day-2 window at an earlier wall clock than the ABORT is void abort too (22 h later by t=)", a2["void"] == ["abort:test-day1"] and a2["bat_mean"] == 600.0, (a2["void"], a2["bat_mean"]))
    # the span rule: at= repeats inside a window without a midnight wrap (clock stepped back 59 s, under the 12 h rule)
    stepped = [row(float(t), wall=wall(start + 120 + t)) for t in range(0, 60)] + [row(5000.0 + t, bat="+500mW", wall=wall(start + 120 + t)) for t in range(0, 60)]
    sp, st, _ = run_fr(stepped, windows=[("m", "01:52:00", "01:52:59")], use_marks=False)
    check("days: a 59 s backward step is not a day wrap (1 day), but the window's 5059 s t= span > 59 s + slack -> VOID multi-day, noted",
          len(st["days"]) == 1 and sp[0]["void"] == ["multi-day"] and sp[0]["rows"] == 120 and any("clock step" in n for n in sp[0]["notes"]), (len(st["days"]), sp[0]["void"], sp[0]["rows"], sp[0]["notes"]))


def cli(tmp):
    """exit codes, --json, --out, text one-liner format, .gz input, BOM + CRLF input, --day usage errors."""
    log = tmp / "cli.log"
    lines = [row(t) for t in range(1, 10)] + [mark(10, "E3a start 1min")] + [row(t, bat="+%dmW" % (300 + t % 3)) for t in range(11, 71)] + [mark(71, "E3a end aco=N aso=N")]
    log.write_text("\n".join(lines) + "\n", encoding="utf-8")
    py = [sys.executable, "-X", "utf8", "-I", str(FR_PATH)]

    def run(*args):
        return subprocess.run(py + list(args), capture_output=True, text=True, encoding="utf-8")

    r = run()
    check("cli: no LOG -> exit 2", r.returncode == 2, r.returncode)
    r = run("--window", "x=23:00:00-01:00:00", str(log))
    check("cli: --window crossing midnight -> exit 2, message names it", r.returncode == 2 and "midnight" in r.stderr, (r.returncode, r.stderr[-200:]))
    r = run(str(tmp / "missing.log"))
    check("cli: unreadable LOG -> exit 2", r.returncode == 2, r.returncode)
    r = run("--settle", "-1", str(log))
    check("cli: --settle -1 -> exit 2", r.returncode == 2, r.returncode)
    r = run("--no-marks", str(log))
    check("cli: --no-marks without --window -> exit 2", r.returncode == 2, r.returncode)
    r = run("--day", "0", "--window", "w=%s-%s" % (at(20), at(40)), str(log))
    check("cli: --day 0 -> exit 2", r.returncode == 2, r.returncode)
    r = run("--day", "1", str(log))
    check("cli: --day without --window -> exit 2", r.returncode == 2, r.returncode)
    r = run("--settle", "0", str(log))
    check("cli: text run exits 0", r.returncode == 0 and r.stderr == "", (r.returncode, r.stderr[-200:]))
    one = [l for l in r.stdout.splitlines() if l.startswith("E3a ")]
    want = "%-10s %s-%s rows %4d  bat %4.0f mW  cl0 %5.1f/s  cl1 %5.1f/s  sys %5.1f/s  apss %3.0f%%  cxsd +%d  | dpms %s aco %s" % (
        "E3a", at(10), at(71), 60, 301.0, 30 * 60 / 59.0, 10 * 60 / 59.0, 25 * 60 / 59.0, 350 * 60 / 10.0 / 59.0, 0, "Off:60 ", "Y:60 ")
    check("cli: one-liner in slices.sh:19 columns", one == [want], (one, want))
    check("cli: block has VOID none and the MARK texts", "   VOID none" in r.stdout and "\"E3a start 1min\" .. \"E3a end aco=N aso=N\"" in r.stdout, r.stdout[:400])
    out = tmp / "out.json"
    r = run("--settle", "0", "--json", "--out", str(out), str(log))
    check("cli: --json --out writes the file, prints nothing", r.returncode == 0 and r.stdout == "" and out.exists(), (r.returncode, r.stdout[:100]))
    data = json.loads(out.read_text(encoding="utf-8"))
    check("cli: JSON is a list of window dicts with the numbers", isinstance(data, list) and len(data) == 1 and data[0]["rows"] == 60 and abs(data[0]["bat_mean"] - 301.0) < 1e-9 and data[0]["void"] == [] and data[0]["pd"]["cl0"]["use"] == 1800, data[0] if data else data)
    check("cli: --out file is LF only", b"\r" not in out.read_bytes())
    r = run("--window", "w=%s-%s" % (at(20), at(40)), "--settle", "0", str(log))
    check("cli: --window alongside MARK windows", r.returncode == 0 and "w          %s-%s rows   21" % (at(20), at(40)) in r.stdout, r.stdout[-300:])
    # gzip input and a no-window log
    gz = tmp / "cli.log.gz"
    with gzip.open(gz, "wt", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    r = run("--settle", "0", str(gz))
    check("cli: .gz input gives the same one-liner", one == [l for l in r.stdout.splitlines() if l.startswith("E3a ")], r.stdout[-300:])
    # a copy re-saved by a Win11 editor: UTF-8 BOM + CRLF, and the first line is the start MARK (as in every runs/*/flightrec-*.log.gz)
    bom = tmp / "bom.log"
    bom.write_bytes(b"\xef\xbb\xbf" + "\r\n".join(lines[9:]).encode("utf-8") + b"\r\n")
    r = run("--settle", "0", str(bom))
    check("cli: UTF-8 BOM + CRLF copy: the first-line MARK is seen (2 MARK, 0 unknown) and the one-liner is the same",
          r.returncode == 0 and " 2 MARK, " in r.stdout and " 0 unknown lines" in r.stdout and one == [l for l in r.stdout.splitlines() if l.startswith("E3a ")], r.stdout[:300])
    plain = tmp / "nomarks.log"
    plain.write_text("\n".join(row(t) for t in range(1, 20)) + "\n", encoding="utf-8")
    r = run(str(plain))
    check("cli: a log without MARKs: exit 0, 'no windows' on stderr", r.returncode == 0 and "no windows" in r.stderr, (r.returncode, r.stderr))


# ---------------------------------------------------------------- c) slices.sh cross-check
def git_bash():
    cands = []
    if os.name == "nt":
        for p in (os.environ.get("GIT_BASH"), r"C:\Program Files\Git\bin\bash.exe", r"C:\Program Files\Git\usr\bin\bash.exe"):
            if p and os.path.exists(p):
                cands.append(p)
        g = shutil.which("git")
        if g:
            p = os.path.join(os.path.dirname(os.path.dirname(g)), "bin", "bash.exe")
            if os.path.exists(p):
                cands.append(p)
        w = shutil.which("bash")
        if w and "system32" not in w.lower() and "windowsapps" not in w.lower():
            cands.append(w)
    else:
        w = shutil.which("bash")
        if w:
            cands.append(w)
    return cands[0] if cands else None


RE_SLICE = re.compile(r"^(\S+)\s+(\S+)-(\S+) rows\s+(\d+)  bat\s+(-?\d+) mW  cl0\s+([\d.]+)/s  cl1\s+([\d.]+)/s  sys\s+([\d.]+)/s  apss\s+(\d+)%  cxsd \+(\d+)  \| dpms (.*) aco (.*)$")


def slices_awk(tmp):
    sh = RUNS / "day-20261018" / "slices.sh"
    bash = git_bash()
    if not bash or not sh.exists():
        print("SKIP slices.sh cross-check: %s" % ("no Git Bash on this machine" if not bash else "no %s" % sh))
        return
    log = tmp / "xcheck.log"
    lines = []
    for i in range(0, 600):
        t = float(i)
        bat = "+0mW" if i % 50 == 7 else "+%dmW" % (280 + (i * 37) % 90)
        lines.append(row(t, bat=bat, dpms=("On" if 250 <= i < 262 else "Off"), aco=("Y" if i < 400 else "N"),
                         pd="cl0:%d/0,cl1:%d/1,sys:%d/0" % (i % 7, i % 3, i % 5),
                         qs="apss:%d/+%d,cxsd:%d/+0,aosd:0/+0,ddr:0/+0" % (i % 4, (i % 4) * 13, i % 2)))
    lines.insert(100, mark(99.5, "E3a start 5min"))
    lines.insert(200, mode(198.5, True))
    log.write_text("\n".join(lines) + "\n", encoding="utf-8")
    windows = [("lab", "07:02:00", "07:07:30"), ("tail", "07:06:00", "07:09:59")]
    env = dict(os.environ, FRL=str(log).replace("\\", "/"), LC_ALL="C")
    try:
        r = subprocess.run([bash, str(sh).replace("\\", "/")] + ["%s=%s-%s" % w for w in windows], env=env, capture_output=True, text=True, encoding="utf-8", timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        print("SKIP slices.sh cross-check: bash failed to run (%s)" % e)
        return
    if r.returncode != 0 or not r.stdout.strip():
        print("SKIP slices.sh cross-check: slices.sh exit %d, stderr %r" % (r.returncode, r.stderr[-300:]))
        return
    awk_lines = r.stdout.splitlines()
    sums, _, _ = run_fr(lines, windows=windows, use_marks=False)
    for (label, a, b), awk_line, s in zip(windows, awk_lines, sums):
        m = RE_SLICE.match(awk_line)
        if not check("slices.sh: awk output line for %s parses" % label, m, awk_line):
            continue
        # fr-slice appends " VOID ..." after the awk columns (the dpms flip at 07:04:10-07:04:21 voids "lab"): cut it
        our_line, _, our_void = fr.one_line(s).partition(" VOID ")
        ours = RE_SLICE.match(our_line)
        if not check("slices.sh: fr-slice one-liner for %s parses" % label, ours, our_line):
            continue
        check("slices.sh: %s VOID suffix is %r" % (label, "dpms-changed" if label == "lab" else ""), our_void == ("dpms-changed" if label == "lab" else ""), our_void)
        fields = ("label", "A", "B", "rows", "bat", "cl0/s", "cl1/s", "sys/s", "apss%", "cxsd", "dpms", "aco")
        got = dict(zip(fields, ours.groups()))
        want = dict(zip(fields, m.groups()))
        for k in ("dpms", "aco"):
            got[k], want[k] = sorted(got[k].split()), sorted(want[k].split())
        diff = {k: (got[k], want[k]) for k in fields if got[k] != want[k]}
        check("slices.sh: %s rows/bat/cl0/cl1/sys/apss/cxsd/dpms/aco equal (%s)" % (label, awk_line[:60].strip()), not diff, diff)
    want_zero = sum(1 for i in range(120, 451) if i % 50 == 7)
    check("slices.sh: zero reads were left out by both (%d in the first slice)" % want_zero, sums[0]["zero_reads"] == want_zero and sums[0]["rows"] == 331, (sums[0]["zero_reads"], sums[0]["rows"]))


# ---------------------------------------------------------------- main
def main():
    with tempfile.TemporaryDirectory(prefix="fr-slice-test-") as td:
        tmp = Path(td)
        ground_truth()
        synth_legacy()
        synth_new_grammar()
        synth_bat_rules()
        synth_window()
        synth_days()
        cli(tmp)
        slices_awk(tmp)
    failed = [n for n, ok in RESULTS if not ok]
    print("%d checks, %d failed" % (len(RESULTS), len(failed)))
    if failed:
        print("FAILED: " + "; ".join(failed))
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
