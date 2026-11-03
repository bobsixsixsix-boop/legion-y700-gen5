"""Reference implementation of y700-flightrec's battery energy accumulator (linux/power/flightrec/src/acc.rs).

Same algorithm, same integer rounding, same fixed-width line: both run the shared cases in
linux/power/flightrec/fixtures/acc/cases.txt (cut from runs/diag/flightrec by make-fixtures.py there; the expected
lines in it come from here) and must agree to the byte. The report reads the recorder's counters with fields() /
Acc.parse(); nothing here runs on the recorder's path.

Per data line (DESIGN.md section 2, 积分规则, with the 评审修订 zero-reading rule):
  - a reading is VALID (voltage and current both read, nonzero), ZERO (read fine, current exactly 0 and the battery
    status not Discharging: on the charger - full, held at the limit, bypass) or MISSING (a failed read, which the
    recorder's num() turns into 0, or a 0 while Discharging). The recorder prints all of these zeros as -0mW.
  - dt > 60 s since the line before: the whole step is gap, nothing integrated (the reading still counts below).
  - otherwise ton/toff take the step by this line's dpms (dpms other than On/Off keeps the last state), bl takes
    level x ms while on, and the energy side:
      no valid reading yet this boot -> tzero, whatever the reading;
      the line before was MISSING (a missing run is open) or this one is -> the step waits in tz, per dpms bucket;
      ZERO -> tzero;
      VALID after VALID/ZERO -> trapezoid e = (lb+cur)/2*dt: > 0 discharge into don/dton or doff/dtoff by this line's
      dpms, < 0 charge into chg/tchg, exactly 0 into tzero.
  - a missing run ends at the next VALID or ZERO line: more than 30 min since the last valid reading -> gap;
    else a positive mean (lb+cur)/2 with cur > 0 backfills each bucket at that mean (don/dton, doff/dtoff);
    else (cur < 0, a ZERO, or a mean <= 0 after charging) -> tzero. A run that passes 30 min goes to gap at once.
  - pw: VALID/ZERO readings > +20 mW vote dis, < -20 mW chg, anything in between resets the count; MISSING ones do
    not count; 3 votes in a row flip it. It only says when to snapshot, never whether the charger is in.
  - every time is CLOCK_MONOTONIC ms, energy is kept in uJ (mW x ms) rounded per step and written as mJ.
Time partition (tested): dton + dtoff + tchg + tzero + tz + gap = last t - first t of the boot.
"""
import math
import re

GAP_DT_MS = 60_000                      # a longer step is not integrated (a stall, a restart): gap
MISSING_MAX_MS = 30 * 60_000            # a missing run longer than this since the last valid reading: gap
PW_MW = 20.0                            # |reading| above this votes for a power direction
PW_LINES = 3                            # votes in a row before pw flips
MAX13 = 9_999_999_999_999               # every number field is 13 wide: a rewrite in place leaves no residue
LB_MAX = 999_999_999_999                # lb is a sign and 12 digits
WIDTH = 321                             # the energy line without its newline
NUM_FIELDS = ("t", "n", "ton", "toff", "don", "doff", "dton", "dtoff", "chg", "tchg", "tz", "tzero", "gap", "bl",
              "lb", "lbt")
VALID, ZERO, MISSING = "valid", "zero", "missing"
_UNSIGNED = re.compile(r"\+?[0-9]+\Z")  # what Rust's u64::from_str takes
_SIGNED = re.compile(r"[+-]?[0-9]+\Z")  # i64::from_str


def ms(t):
    """CLOCK_MONOTONIC s -> ms, rounded half up (t > 0)"""
    return int(math.floor(t * 1000.0 + 0.5)) if math.isfinite(t) and t > 0 else 0


def uj(x):
    """a positive energy in uJ rounded half up; anything else 0"""
    return int(math.floor(x + 0.5)) if math.isfinite(x) and x > 0 else 0


def mw_int(v):
    """a reading rounded half away from zero (f64::round)"""
    if not math.isfinite(v):
        return 0
    r = math.floor(abs(v) + 0.5)
    return int(-r if v < 0 else r)


def norm_boot(boot):
    """the boot id as the line carries it: 8 ASCII letters/digits, padded with '-'"""
    b = "".join(c for c in boot if c.isascii() and c.isalnum())[:8]
    return b + "-" * (8 - len(b))


def classify(mw, ok, status):
    """(kind, reading mW) of one line: status is the battery status the recorder read when the current was exactly 0"""
    if not ok or not math.isfinite(mw):
        return MISSING, 0.0
    if mw != 0.0:
        return VALID, float(mw)
    if status and status != "Discharging":
        return ZERO, 0.0
    return MISSING, 0.0


def _int(v):
    """a field _SIGNED / _UNSIGNED took, as Rust's from_str reads it: leading zeros never overflow there, however many,
    so they go before int() (which refuses more than 4300 digits); None past 20 significant digits (beyond 64 bits)"""
    sig = v.lstrip("+-").lstrip("0") or "0"
    if len(sig) > 20:
        return None
    return -int(sig) if v.startswith("-") else int(sig)


def fields(line):
    """the key=value fields of an energy line (first of each key), or None if it is not a v1 line"""
    w = line.split()
    if not w or w[0] != "v1":
        return None
    d = {}
    for x in w[1:]:
        k, sep, v = x.partition("=")
        if sep and k not in d:
            d[k] = v
    return d


class Acc:
    """the counters of one boot; step() per data line, render() the energy line, edge() the edge line"""

    def __init__(self, boot):
        self.boot = norm_boot(boot)
        self.t = None                   # ms of the last line; None before the first line of the boot
        self.n = 0
        self.ton = self.toff = 0
        self.don = self.doff = 0        # uJ (the line has mJ)
        self.dton = self.dtoff = 0
        self.chg = 0                    # uJ
        self.tchg = 0
        self.pend = [0, 0]              # an open missing run, [off, on] ms (the line has the sum: tz)
        self.tzero = 0
        self.gap = 0
        self.bl = 0
        self.lb = None                  # last valid reading, mW (ZERO = 0); None before the first one of the boot
        self.lbt = 0                    # its time, ms (0 = none)
        self.on = False
        self.pw = "unk"
        self.cand = "unk"
        self.streak = 0

    @classmethod
    def parse(cls, line, boot):
        """the counters back from an energy line if it is v1 and from this boot (a restart within the boot), else None.
        The open run's split by dpms is not in the line: tz comes back in the line's dpms bucket."""
        st = cls(boot)
        d = fields(line)
        if d is None or d.get("boot") != st.boot:
            return None
        num = {}
        for k in NUM_FIELDS:
            v = d.get(k)
            if v is None:
                return None
            if k == "lb":
                x = _int(v) if _SIGNED.match(v) else None
                if x is None or not -(1 << 63) <= x < (1 << 63):
                    return None
            else:
                x = _int(v) if _UNSIGNED.match(v) else None
                if x is None or x > MAX13:
                    return None
            num[k] = x
        if d.get("dpms") not in ("On", "Off") or d.get("pw") not in ("unk", "dis", "chg"):
            return None
        st.t = num["t"] if num["t"] > 0 else None
        st.n = num["n"]
        st.ton, st.toff = num["ton"], num["toff"]
        st.don, st.doff = num["don"] * 1000, num["doff"] * 1000
        st.dton, st.dtoff = num["dton"], num["dtoff"]
        st.chg, st.tchg = num["chg"] * 1000, num["tchg"]
        st.tzero, st.gap, st.bl = num["tzero"], num["gap"], num["bl"]
        st.on = d["dpms"] == "On"
        st.pend[1 if st.on else 0] = num["tz"]
        st.lbt = num["lbt"]
        st.lb = float(num["lb"]) if st.lbt > 0 else None
        st.pw = d["pw"]
        return st

    def begin(self, dpms):
        """at the recorder's start (fresh or resumed): the screen state of its baseline sample"""
        if dpms == "On":
            self.on = True
        elif dpms == "Off":
            self.on = False

    def step(self, t, mw, ok, status, dpms, bl):
        """one data line; True when the edge file is due (dpms or pw changed)"""
        now = ms(t)
        on = True if dpms == "On" else False if dpms == "Off" else self.on
        edge = on != self.on
        self.on = on
        self.n += 1
        kind, v = classify(mw, ok, status)
        b = 1 if on else 0
        if self.t is not None:
            prev = self.t
            dt = max(0, now - prev)
            open_run = self.lb is not None and prev > self.lbt   # the line before had no usable reading
            if dt > GAP_DT_MS:
                self.gap += dt
            else:
                if on:
                    self.ton += dt
                    if bl is not None:
                        self.bl += max(0, bl) * dt
                else:
                    self.toff += dt
                if self.lb is None:
                    self.tzero += dt
                elif open_run or kind == MISSING:
                    self.pend[b] += dt
                elif kind == ZERO:
                    self.tzero += dt
                else:
                    self._trapezoid(self.lb, v, dt, on)
            if self.lb is not None:
                pend = self.pend[0] + self.pend[1]
                long_run = now - self.lbt > MISSING_MAX_MS
                if kind == MISSING:
                    if long_run:
                        self.gap += pend
                        self.pend = [0, 0]
                elif pend > 0:
                    p = (self.lb + v) / 2.0 if kind == VALID and v > 0 else 0.0
                    if long_run:
                        self.gap += pend
                    elif p > 0:
                        self.doff += uj(p * self.pend[0])
                        self.dtoff += self.pend[0]
                        self.don += uj(p * self.pend[1])
                        self.dton += self.pend[1]
                    else:
                        self.tzero += pend
                    self.pend = [0, 0]
        if kind == VALID:
            self.lb, self.lbt = v, now
        elif kind == ZERO:
            self.lb, self.lbt = 0.0, now
        if kind != MISSING and self._vote(v):
            edge = True
        self.t = now if self.t is None else max(self.t, now)
        return edge

    def _trapezoid(self, l, v, d, on):
        x = (l + v) / 2.0 * d
        if x > 0:
            if on:
                self.don += uj(x)
                self.dton += d
            else:
                self.doff += uj(x)
                self.dtoff += d
        elif x < 0:
            self.chg += uj(-x)
            self.tchg += d
        else:
            self.tzero += d

    def _vote(self, v):
        w = "dis" if v > PW_MW else "chg" if v < -PW_MW else None
        if w is None or w == self.pw:
            self.streak = 0
            return False
        if w == self.cand:
            self.streak += 1
        else:
            self.cand, self.streak = w, 1
        if self.streak >= PW_LINES:
            self.pw, self.streak = w, 0
            return True
        return False

    def render(self):
        """the energy line, without its newline"""
        def c(x):
            return min(max(x, 0), MAX13)
        lb = max(-LB_MAX, min(LB_MAX, mw_int(self.lb))) if self.lb is not None else 0
        return ("v1 boot=%s t=%013d n=%013d ton=%013d toff=%013d don=%013d doff=%013d dton=%013d dtoff=%013d chg=%013d "
                "tchg=%013d tz=%013d tzero=%013d gap=%013d bl=%013d lb=%+013d lbt=%013d dpms=%s pw=%s") % (
            self.boot, c(self.t or 0), c(self.n), c(self.ton), c(self.toff), c(self.don // 1000), c(self.doff // 1000),
            c(self.dton), c(self.dtoff), c(self.chg // 1000), c(self.tchg), c(self.pend[0] + self.pend[1]),
            c(self.tzero), c(self.gap), c(self.bl), lb, c(self.lbt), "On " if self.on else "Off", self.pw)

    def edge(self, t):
        """the edge line for a change at t (s), without its newline"""
        return "v1 t=%.1f dpms=%s pw=%s" % (t, "On" if self.on else "Off", self.pw)


# ---- the shared fixture file (linux/power/flightrec/fixtures/acc/cases.txt) ----
#   case NAME / note TEXT / end
#   boot B                      a fresh count for boot B
#   begin T DPMS                the recorder's start: begin(DPMS), an edge at T
#   l T MW OK STATUS DPMS BL    a data line; STATUS '-' = not read (current not 0), '_' stands for a space; BL '-' = none
#   restart B T DPMS            the recorder restarts in boot B: parse(render(), B) or a fresh count, begin, an edge
#   expect LINE                 render() now must equal LINE
#   edge LINE                   the next edge emitted must equal LINE (end: none may be left over)

def _status(tok):
    return None if tok == "-" else tok.replace("_", " ")


class Runner:
    """runs the directives of one case; t0 = the first line's ms of the current count (for the time partition)"""

    def __init__(self):
        self.st = None
        self.t0 = None

    def do(self, cmd, w):
        """one directive (boot, begin, l, restart); returns the edge lines it emitted"""
        if cmd == "boot":
            self.st, self.t0 = Acc(w[0]), None
            return []
        if cmd == "begin":
            self.st.begin(w[1])
            return [self.st.edge(float(w[0]))]
        if cmd == "l":
            t = float(w[0])
            if self.t0 is None:
                self.t0 = ms(t)
            due = self.st.step(t, float(w[1]), w[2] == "1", _status(w[3]), w[4], None if w[5] == "-" else int(w[5]))
            return [self.st.edge(t)] if due else []
        if cmd == "restart":
            st = Acc.parse(self.st.render(), w[0])
            if st is None:
                st, self.t0 = Acc(w[0]), None
            st.begin(w[2])
            self.st = st
            return [st.edge(float(w[1]))]
        raise ValueError("unknown directive %r" % cmd)


def check_cases(text):
    """runs every case of a fixture file: ({name: Runner at the end}, [failures])"""
    runners, fails = {}, []
    name, run, edges, seen = None, None, [], 0

    def close():
        if name is not None and seen != len(edges):
            fails.append("%s: edges not in the fixture: %r" % (name, edges[seen:]))

    for no, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        cmd, _, rest = line.partition(" ")
        if cmd == "case":
            close()
            name, run, edges, seen = rest, Runner(), [], 0
            runners[name] = run
        elif cmd == "note":
            pass
        elif cmd == "end":
            close()
            name = None
        elif cmd == "expect":
            got = run.st.render()
            if got != rest:
                fails.append("%s line %d:\n  want %s\n  got  %s" % (name, no, rest, got))
        elif cmd == "edge":
            got = edges[seen] if seen < len(edges) else None
            if got != rest:
                fails.append("%s line %d: edge want %r got %r" % (name, no, rest, got))
            seen += 1
        else:
            edges.extend(run.do(cmd, rest.split()))
    close()
    return runners, fails
