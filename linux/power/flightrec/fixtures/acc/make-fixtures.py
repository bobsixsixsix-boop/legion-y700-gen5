#!/usr/bin/env python3
"""make-fixtures.py [--check] [LOG_DIR]: writes cases.txt here, the energy-accumulator cases shared by
src/acc.rs (cargo test on the tablet) and linux/power/battery/report/y700_battery/acc_ref.py (unittest on Win11).

Real excerpts are cut from the flight-recorder logs in LOG_DIR (default <repo>/runs/diag/flightrec:
flightrec-690a169c.log.gz, flightrec-974b286c.log.gz - copied off the tablet 10-21, NOT in git; this script is the
record of how the excerpts were taken). A log line gives t, bat and dpms; what the recorder now reads besides is not
in the old logs, so it is filled in here and said so in each case's note:
  - ok = 1 (voltage and current read) on every line: a failed read and a 0 while discharging both print -0mW and are
    both "missing" with status Discharging, so the choice does not change the result;
  - status: on -0mW lines the case's zero_status (Discharging while on battery), '-' (not read) on the others;
  - bl = 410 (about 10 %) on dpms=On lines: the backlight level is not logged.
The synthetic cases at the bottom are small enough to check by hand: tests/test_acc_ref.py and acc.rs's tests assert
the same hand-computed numbers on them. The expect/edge lines are computed with acc_ref; acc.rs must reproduce them.
--check: build in memory and compare with cases.txt (exit 1 if they differ). Run:
    tools/venv/Scripts/python -X utf8 -I -B linux/power/flightrec/fixtures/acc/make-fixtures.py
"""
import gzip
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]                       # acc -> fixtures -> flightrec -> power -> linux -> repo
sys.path.insert(0, str(REPO / "linux" / "power" / "battery" / "report"))
from y700_battery import acc_ref  # noqa: E402

OUT = HERE / "cases.txt"
BL_ON = 410                                  # synthetic backlight level on dpms=On lines of the real excerpts
LINE = re.compile(r"t=(\S+) at=\S+ up=\S+ bat=([+-]\d+)mW dpms=(\S+) ")

# name, log boot, first and last t (inclusive, the log's own text), status on -0mW lines, t's to expect after, note
EXCERPTS = [
    ("690a169c-66030", "690a169c", "66000.2", "66610.2", "Discharging", ["66600.2"],
     "58 -0mW lines in a row on battery (t=66030.2-66600.2), dpms On for two of them: the run waits in tz per "
     "dpms bucket and is backfilled at (626+153)/2 when +153 arrives"),
    ("690a169c-66620", "690a169c", "66610.2", "66850.2", "Discharging", ["66840.2"],
     "the next run, 23 lines (t=66620.2-66840.2), backfilled at (153+298)/2"),
    ("690a169c-66870", "690a169c", "66860.2", "67340.2", "Discharging", ["66990.2"],
     "13 lines from t=66870.2, then short runs among valid readings"),
    ("974b286c-21327", "974b286c", "21317.7", "21527.7", "Discharging", ["21397.7"],
     "8 lines from t=21327.7 (the 10 s cadence of the Rust recorder), backfilled at (150+227)/2"),
    ("690a169c-61030-plug", "690a169c", "60970.2", "61540.2", "Discharging", ["61350.2"],
     "the charger in at t=61030.2 (-16 W) and out at t=61360.2: the sign split, pw dis -> chg -> dis, two dpms On "
     "blips"),
    ("690a169c-64370-plugged", "690a169c", "64300.2", "64950.2", "Not charging", ["64860.2"],
     "charging stops at t=64370.2 and 50 -0mW lines follow until the charger goes out at t=64870.2: read here as "
     "on the charger (status Not charging, an assumption - DESIGN.md section 11 item 7), so they are tzero"),
    ("690a169c-64370-dischg", "690a169c", "64300.2", "64950.2", "Discharging", ["64860.2"],
     "the same lines read as a missing run (status Discharging): it ends at +127 with lb = -8315, the mean is "
     "negative, so the run goes to tzero, not into a discharge bucket"),
]

# synthetic cases: (name, note, directives); tests/test_acc_ref.py has the hand computation of each
SYNTHETIC = [
    ("pw-debounce",
     "votes: in-between resets, missing does not count, 3 in a row flip; dpms ? keeps the state; a mean of exactly "
     "0 is tzero",
     ["boot pwtest01", "begin 10.0 On",
      "l 10.0 +100 1 - On 100", "l 20.0 +100 1 - On 100", "l 30.0 +5 1 - ? -", "l 40.0 +100 1 - Off -",
      "l 50.0 -0 1 Discharging Off -", "l 60.0 +100 1 - ? -", "l 70.0 +100 1 - Off -", "l 80.0 -100 1 - Off -",
      "l 90.0 -100 1 - Off -", "l 100.0 +100 1 - Off -", "l 110.0 -100 1 - Off -", "l 120.0 -100 1 - Off -",
      "l 130.0 -100 1 - Off -"], []),
    ("gap-dt",
     "steps over 60 s are gap, inside a missing run too; bl is level x ms with the screen on",
     ["boot gaptest1", "begin 10.0 On",
      "l 10.0 +500 1 - On 1000", "l 20.0 +500 1 - On 1000", "l 200.0 +500 1 - On 1000", "l 210.0 +700 1 - On 2000",
      "l 220.0 -0 1 Discharging On 2000", "l 400.0 -0 1 Discharging On 2000", "l 410.0 +900 1 - On 2000"], []),
    ("missing-30min",
     "a missing run that passes 30 min since the last valid reading goes to gap at once; one of exactly 30 min is "
     "still backfilled",
     ["boot misstest", "begin 100.0 Off", "l 100.0 +200 1 - Off -"]
     + ["l %d.0 -0 0 - Off -" % t for t in range(150, 1951, 50)]
     + ["l 2000.0 +300 1 - Off -", "l 2050.0 +300 1 - Off -"]
     + ["l %d.0 -0 1 Discharging Off -" % t for t in range(2100, 3801, 50)]
     + ["l 3850.0 +100 1 - Off -"], ["1900.0", "1950.0", "3800.0"]),
    ("zero-plugged",
     "on the charger: a 0 with status Full / Not charging is tzero, a missing run that a ZERO or a charging "
     "reading ends is tzero; charge goes to chg/tchg",
     ["boot plugtest", "begin 10.0 Off",
      "l 10.0 +400 1 - Off -", "l 20.0 +400 1 - Off -", "l 30.0 -6000 1 - Off -", "l 40.0 -6000 1 - Off -",
      "l 50.0 -0 1 Full Off -", "l 60.0 -0 1 Full Off -", "l 70.0 -0 0 - Off -", "l 80.0 -0 1 Not_charging Off -",
      "l 90.0 -2000 1 - Off -", "l 100.0 -0 1 Discharging Off -", "l 110.0 -1500 1 - Off -",
      "l 120.0 +300 1 - Off -", "l 130.0 +300 1 - Off -", "l 140.0 +300 1 - Off -"], ["70.0"]),
    ("boot-start",
     "no valid reading yet this boot: zeros and the step that ends them are tzero; then a short run is backfilled",
     ["boot starttst", "begin 5.0 Off",
      "l 10.0 -0 0 - Off -", "l 20.0 -0 1 Discharging Off -", "l 30.0 +250 1 - Off -", "l 40.0 +250 1 - Off -",
      "l 50.0 -0 0 - Off -", "l 60.0 +350 1 - Off -"], []),
    ("restart-same-boot",
     "the recorder restarts within the boot: the count goes on from the file, the open run comes back in the "
     "line's dpms bucket and the step over the restart is integrated; pw votes start again",
     ["boot aaaa1111", "begin 10.0 On",
      "l 10.0 +500 1 - On 200", "l 20.0 +500 1 - On 200", "l 30.0 -0 1 Discharging Off -",
      "restart aaaa1111 45.0 Off", "l 50.0 +300 1 - Off -"], []),
    ("restart-new-boot",
     "a file from another boot is not resumed: the count starts from zero",
     ["boot aaaa1111", "begin 10.0 On",
      "l 10.0 +500 1 - On 200", "l 20.0 +500 1 - On 200",
      "restart bbbb2222 60.0 On", "l 70.0 +100 1 - On 50"], []),
]

HEADER = """\
# Energy-accumulator cases shared by linux/power/flightrec/src/acc.rs and
# linux/power/battery/report/y700_battery/acc_ref.py. Generated by make-fixtures.py (here) - do not edit by hand.
#   case NAME / note TEXT / end
#   boot B                      a fresh count for boot B
#   begin T DPMS                the recorder's start: begin(DPMS), an edge at T
#   l T MW OK STATUS DPMS BL    a data line: t s, bat mW as logged, voltage+current read (1/0), battery status read
#                               on a zero current ('-' none, '_' = space), dpms, backlight level ('-' none)
#   restart B T DPMS            the recorder restarts in boot B: resume from the energy line if B matches, else zero
#   expect LINE                 the energy line now
#   edge LINE                   the next edge line written
"""


def load(path):
    """data lines of a log: [(t text, bat text, dpms)]"""
    out = []
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as f:
        for l in f:
            m = LINE.match(l)
            if m:
                out.append(m.groups())
    return out


def emit(out, name, note, directives, checks):
    """runs the directives through acc_ref and writes them with the edges and expects they produce"""
    out.append("")
    out.append("case " + name)
    out.append("note " + note)
    run = acc_ref.Runner()
    for d in directives:
        out.append(d)
        cmd, _, rest = d.partition(" ")
        w = rest.split()
        for e in run.do(cmd, w):
            out.append("edge " + e)
        if cmd == "l" and w[0] in checks:
            out.append("expect " + run.st.render())
    out.append("expect " + run.st.render())
    out.append("end")


def build(log_dir):
    out = [HEADER.rstrip("\n")]
    logs = {}
    for name, boot, lo, hi, zero_status, checks, note in EXCERPTS:
        if boot not in logs:
            logs[boot] = load(log_dir / ("flightrec-%s.log.gz" % boot))
        rows = [r for r in logs[boot] if float(lo) <= float(r[0]) <= float(hi)]
        if not rows or rows[0][0] != lo or rows[-1][0] != hi:
            raise SystemExit("%s: t=%s..%s not found in flightrec-%s.log.gz" % (name, lo, hi, boot))
        st = zero_status.replace(" ", "_")
        directives = ["boot " + boot, "begin %s %s" % (rows[0][0], rows[0][2])]
        for t, bat, dpms in rows:
            directives.append("l %s %s 1 %s %s %s" % (t, bat, st if bat in ("-0", "+0") else "-", dpms,
                                                     BL_ON if dpms == "On" else "-"))
        src = ("runs/diag/flightrec/flightrec-%s.log.gz t=%s..%s (%d lines); ok=1, status %s on -0mW lines, "
               "bl=%d on On lines (filled in). " % (boot, lo, hi, len(rows), zero_status, BL_ON))
        emit(out, name, src + note, directives, checks)
    for name, note, directives, checks in SYNTHETIC:
        emit(out, name, "synthetic. " + note, directives, checks)
    return "\n".join(out) + "\n"


def main():
    args = sys.argv[1:]
    check = "--check" in args
    args = [a for a in args if a != "--check"]
    log_dir = Path(args[0]) if args else REPO / "runs" / "diag" / "flightrec"
    text = build(log_dir)
    runners, fails = acc_ref.check_cases(text)
    if fails:
        raise SystemExit("acc_ref does not reproduce its own cases:\n" + "\n".join(fails))
    if check:
        old = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if old != text:
            print("%s differs from what make-fixtures.py builds" % OUT)
            return 1
        print("%s: up to date (%d cases)" % (OUT, len(runners)))
        return 0
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("%s: %d cases" % (OUT, len(runners)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
