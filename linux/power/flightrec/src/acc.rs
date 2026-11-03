//! The battery page's energy accumulator (linux/power/battery/DESIGN.md sections 1-2). After every data line the
//! recorder writes, step() integrates its bat= reading into this boot's counters, and the line is rewritten in place
//! in /run/y700-flightrec/energy - fixed width, pwrite at offset 0, never a rename: y700-batteryd watches the
//! directory for IN_MOVED_TO and must not wake every 10 s. /run/y700-flightrec/edge (edge.tmp + rename) is what wakes
//! it: written once at every start, then only when dpms or the debounced power direction changes.
//! Here because the recorder already wakes every 10 s with the screen off and already reads bat and dpms: no wakeup of
//! its own, and the totals outlive live.log trimming (cut to its last 512 KiB, ~5 h at 10 s) and y700-batteryd
//! restarts.
//!
//! energy, 0644, 321 bytes + newline (every number 13 wide, lb a sign and 12 digits, dpms and pw 3 wide), e.g.
//!   v1 boot=3f2a9c1e t=0000031540012 n=0000000003154 ton=... toff= don= doff= dton= dtoff= chg= tchg= tz= tzero= gap=
//!   bl= lb=+000000000412 lbt=0000031540012 dpms=Off pw=dis
//! t, ton, toff, dton, dtoff, tchg, tz, tzero, gap, lbt: CLOCK_MONOTONIC ms; don, doff, chg: mJ; bl: backlight level x
//! ms; lb: the last valid reading, mW (lbt 0: none yet); n: data lines; pw dis|chg|unk. A reader takes it when two
//! reads in a row agree.
//! edge, 0644: "v1 t=7341.9 dpms=Off pw=dis".
//!
//! Per data line (DESIGN.md section 2, 积分规则, with the 评审修订 zero-reading rule):
//!   - a reading is Valid (voltage and current both read, nonzero), Zero (read fine, current exactly 0 and the battery
//!     status not Discharging: on the charger - full, held at the limit, bypass) or Missing (a failed read, which
//!     num() turns into 0, or a 0 while Discharging). live.log prints every one of these zeros as -0mW.
//!   - dt > 60 s since the line before: the whole step is gap, nothing integrated (the reading still counts below).
//!   - otherwise ton/toff take the step by this line's dpms (anything but On/Off keeps the last state), bl takes
//!     level x ms while on, and: no valid reading yet this boot -> tzero; the line before Missing (a run is open) or
//!     this one -> the step waits in tz, per dpms bucket; Zero -> tzero; Valid after Valid/Zero -> trapezoid
//!     (lb+cur)/2*dt, > 0 into don/dton or doff/dtoff by this line's dpms, < 0 into chg/tchg, exactly 0 into tzero.
//!   - a run ends at the next Valid or Zero: more than 30 min since the last valid reading -> gap; a positive mean
//!     (lb+cur)/2 with cur > 0 backfills each bucket at that mean; anything else (cur < 0, a Zero, a mean <= 0 after
//!     charging) -> tzero. A run goes to gap as soon as it passes 30 min.
//!   - pw: Valid/Zero readings > +20 mW vote dis, < -20 mW chg, in between reset the count, Missing ones do not
//!     count; 3 in a row flip it. It only says when to snapshot, never whether the charger is in.
//!   - a restart within the boot (the file's boot id is this boot's) goes on from the file, and the step over the
//!     restart is integrated like any other; another boot starts from zero. The open run's split by dpms is not in
//!     the line (tz comes back in the line's dpms bucket), nor the pw vote count (starts again).
//! Energy is kept in uJ (mW x ms) rounded per step; the line has mJ. Time partition: dton + dtoff + tchg + tzero + tz +
//! gap = last t - first t of the boot.
//! The same algorithm in Python is linux/power/battery/report/y700_battery/acc_ref.py; both run the cases in
//! fixtures/acc/cases.txt (cut from runs/diag/flightrec by make-fixtures.py there) and must agree to the byte.
//! State is pure (no I/O). Acc does the I/O and swallows every error (the first one is logged): it never panics and
//! never stops the recorder.
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{FileExt, OpenOptionsExt};

use super::Sample;

const GAP_DT_MS: i64 = 60_000; // a longer step is not integrated (a stall, a restart): gap
const MISSING_MAX_MS: i64 = 30 * 60_000; // a missing run longer than this since the last valid reading: gap
const PW_MW: f64 = 20.0; // |reading| above this votes for a power direction
const PW_LINES: u32 = 3; // votes in a row before pw flips
const MAX13: u64 = 9_999_999_999_999; // every number field is 13 wide: a rewrite in place leaves no residue
const LB_MAX: i64 = 999_999_999_999; // lb is a sign and 12 digits

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Pw {
    Unk,
    Dis,
    Chg,
}

impl Pw {
    fn as_str(self) -> &'static str {
        match self {
            Pw::Unk => "unk",
            Pw::Dis => "dis",
            Pw::Chg => "chg",
        }
    }

    fn parse(s: &str) -> Option<Pw> {
        match s {
            "unk" => Some(Pw::Unk),
            "dis" => Some(Pw::Dis),
            "chg" => Some(Pw::Chg),
            _ => None,
        }
    }
}

/// what one data line says about the battery
#[derive(Clone, Copy, PartialEq, Debug)]
enum Reading {
    Valid(f64), // mW, + = drawn from the battery
    Zero,       // really 0: on the charger
    Missing,    // no usable reading
}

/// status: the battery status the recorder read when the current was exactly 0 (None: not read, or the read failed)
fn classify(mw: f64, ok: bool, status: Option<&str>) -> Reading {
    if !ok || !mw.is_finite() {
        return Reading::Missing;
    }
    if mw != 0.0 {
        return Reading::Valid(mw);
    }
    match status {
        Some(s) if !s.is_empty() && s != "Discharging" => Reading::Zero,
        _ => Reading::Missing,
    }
}

/// CLOCK_MONOTONIC s -> ms, rounded half up (t > 0)
fn ms(t: f64) -> i64 {
    if t.is_finite() && t > 0.0 {
        (t * 1000.0 + 0.5).floor() as i64
    } else {
        0
    }
}

/// a positive energy in uJ rounded half up, anything else 0
fn uj(x: f64) -> u64 {
    if x.is_finite() && x > 0.0 {
        (x + 0.5).floor() as u64
    } else {
        0
    }
}

/// a reading rounded half away from zero, the same way acc_ref.py does it
fn mw_int(v: f64) -> i64 {
    if !v.is_finite() {
        return 0;
    }
    let r = (v.abs() + 0.5).floor();
    (if v < 0.0 { -r } else { r }) as i64
}

/// the boot id as the line carries it: 8 ASCII letters/digits, padded with '-'
fn norm_boot(boot: &str) -> String {
    let mut b: String = boot.chars().filter(|c| c.is_ascii_alphanumeric()).take(8).collect();
    while b.len() < 8 {
        b.push('-');
    }
    b
}

fn add(c: &mut u64, d: u64) {
    *c = c.saturating_add(d);
}

fn field<'a>(kv: &[(&'a str, &'a str)], k: &str) -> Option<&'a str> {
    kv.iter().find(|p| p.0 == k).map(|p| p.1)
}

fn num(kv: &[(&str, &str)], k: &str) -> Option<u64> {
    field(kv, k)?.parse::<u64>().ok().filter(|x| *x <= MAX13)
}

/// the counters of one boot (acc_ref.Acc)
#[derive(Clone, Debug, PartialEq)]
struct State {
    boot: String,
    t: Option<i64>, // ms of the last line; None before the first line of the boot
    n: u64,
    ton: u64,
    toff: u64,
    don: u64, // uJ (the line has mJ)
    doff: u64,
    dton: u64,
    dtoff: u64,
    chg: u64, // uJ
    tchg: u64,
    pend: [u64; 2], // an open missing run, [off, on] ms (the line has the sum: tz)
    tzero: u64,
    gap: u64,
    bl: u64,
    lb: Option<f64>, // last valid reading, mW (Zero = 0); None before the first one of the boot
    lbt: i64,        // its time, ms (0 = none)
    on: bool,
    pw: Pw,
    cand: Pw,    // the direction being voted for
    streak: u32, // its votes in a row
}

impl State {
    fn new(boot: &str) -> State {
        State {
            boot: norm_boot(boot),
            t: None,
            n: 0,
            ton: 0,
            toff: 0,
            don: 0,
            doff: 0,
            dton: 0,
            dtoff: 0,
            chg: 0,
            tchg: 0,
            pend: [0, 0],
            tzero: 0,
            gap: 0,
            bl: 0,
            lb: None,
            lbt: 0,
            on: false,
            pw: Pw::Unk,
            cand: Pw::Unk,
            streak: 0,
        }
    }

    /// the counters back from an energy line if it is v1 and this boot's (a restart within the boot), else None
    fn parse(line: &str, boot: &str) -> Option<State> {
        let mut st = State::new(boot);
        let mut w = line.split_whitespace();
        if w.next()? != "v1" {
            return None;
        }
        let kv: Vec<(&str, &str)> = w.filter_map(|x| x.split_once('=')).collect();
        if field(&kv, "boot")? != st.boot {
            return None;
        }
        let t = num(&kv, "t")?;
        st.n = num(&kv, "n")?;
        st.ton = num(&kv, "ton")?;
        st.toff = num(&kv, "toff")?;
        st.don = num(&kv, "don")? * 1000;
        st.doff = num(&kv, "doff")? * 1000;
        st.dton = num(&kv, "dton")?;
        st.dtoff = num(&kv, "dtoff")?;
        st.chg = num(&kv, "chg")? * 1000;
        st.tchg = num(&kv, "tchg")?;
        let tz = num(&kv, "tz")?;
        st.tzero = num(&kv, "tzero")?;
        st.gap = num(&kv, "gap")?;
        st.bl = num(&kv, "bl")?;
        let lb: i64 = field(&kv, "lb")?.parse().ok()?;
        let lbt = num(&kv, "lbt")?;
        st.on = match field(&kv, "dpms")? {
            "On" => true,
            "Off" => false,
            _ => return None,
        };
        st.pw = Pw::parse(field(&kv, "pw")?)?;
        st.t = if t > 0 { Some(t as i64) } else { None };
        let on = st.on;
        *st.pend_mut(on) = tz;
        st.lbt = lbt as i64;
        st.lb = if lbt > 0 { Some(lb as f64) } else { None };
        Some(st)
    }

    /// at the recorder's start (fresh or resumed): the screen state of its baseline sample
    fn begin(&mut self, dpms: &str) {
        match dpms {
            "On" => self.on = true,
            "Off" => self.on = false,
            _ => {}
        }
    }

    fn pend_mut(&mut self, on: bool) -> &mut u64 {
        if on {
            &mut self.pend[1]
        } else {
            &mut self.pend[0]
        }
    }

    /// one data line: t (CLOCK_MONOTONIC s), the bat reading (mW, + = drawn from the battery), whether voltage and
    /// current both read, the battery status read on a zero current, dpms, the backlight level (read with the screen
    /// on). True when the edge file is due: dpms or pw changed.
    fn step(&mut self, t: f64, mw: f64, ok: bool, status: Option<&str>, dpms: &str, bl: Option<i64>) -> bool {
        let now = ms(t);
        let on = match dpms {
            "On" => true,
            "Off" => false,
            _ => self.on, // "?": the read failed
        };
        let mut edge = on != self.on;
        self.on = on;
        self.n = self.n.saturating_add(1);
        let r = classify(mw, ok, status);
        if let Some(prev) = self.t {
            let dt = (now - prev).max(0);
            let d = dt as u64;
            // the line before had no usable reading: this step has no start value either
            let open = self.lb.is_some() && prev > self.lbt;
            if dt > GAP_DT_MS {
                add(&mut self.gap, d);
            } else {
                if on {
                    add(&mut self.ton, d);
                    if let Some(level) = bl {
                        add(&mut self.bl, (level.max(0) as u64).saturating_mul(d));
                    }
                } else {
                    add(&mut self.toff, d);
                }
                match (self.lb, r) {
                    (None, _) => add(&mut self.tzero, d), // no valid reading yet this boot
                    (Some(_), _) if open => add(self.pend_mut(on), d),
                    (Some(_), Reading::Missing) => add(self.pend_mut(on), d),
                    (Some(_), Reading::Zero) => add(&mut self.tzero, d),
                    (Some(l), Reading::Valid(v)) => self.trapezoid(l, v, d, on),
                }
            }
            if let Some(l) = self.lb {
                let pend = self.pend[0].saturating_add(self.pend[1]);
                let long_run = now - self.lbt > MISSING_MAX_MS;
                match r {
                    Reading::Missing => {
                        if long_run {
                            add(&mut self.gap, pend);
                            self.pend = [0, 0];
                        }
                    }
                    _ if pend > 0 => {
                        // the run ends here
                        let p = match r {
                            Reading::Valid(v) if v > 0.0 => (l + v) / 2.0,
                            _ => 0.0,
                        };
                        if long_run {
                            add(&mut self.gap, pend);
                        } else if p > 0.0 {
                            let (off_ms, on_ms) = (self.pend[0], self.pend[1]);
                            add(&mut self.doff, uj(p * off_ms as f64));
                            add(&mut self.dtoff, off_ms);
                            add(&mut self.don, uj(p * on_ms as f64));
                            add(&mut self.dton, on_ms);
                        } else {
                            add(&mut self.tzero, pend);
                        }
                        self.pend = [0, 0];
                    }
                    _ => {}
                }
            }
        }
        let v = match r {
            Reading::Valid(v) => Some(v),
            Reading::Zero => Some(0.0),
            Reading::Missing => None,
        };
        if let Some(v) = v {
            self.lb = Some(v);
            self.lbt = now;
            if self.vote(v) {
                edge = true;
            }
        }
        self.t = Some(self.t.map_or(now, |p| p.max(now)));
        edge
    }

    fn trapezoid(&mut self, l: f64, v: f64, d: u64, on: bool) {
        let x = (l + v) / 2.0 * d as f64;
        if x > 0.0 {
            if on {
                add(&mut self.don, uj(x));
                add(&mut self.dton, d);
            } else {
                add(&mut self.doff, uj(x));
                add(&mut self.dtoff, d);
            }
        } else if x < 0.0 {
            add(&mut self.chg, uj(-x));
            add(&mut self.tchg, d);
        } else {
            add(&mut self.tzero, d);
        }
    }

    /// one vote for the power direction; true when pw flips
    fn vote(&mut self, v: f64) -> bool {
        let w = if v > PW_MW {
            Pw::Dis
        } else if v < -PW_MW {
            Pw::Chg
        } else {
            Pw::Unk
        };
        if w == Pw::Unk || w == self.pw {
            self.streak = 0;
            return false;
        }
        if w == self.cand {
            self.streak += 1;
        } else {
            self.cand = w;
            self.streak = 1;
        }
        if self.streak >= PW_LINES {
            self.pw = w;
            self.streak = 0;
            return true;
        }
        false
    }

    /// the energy line, without its newline
    fn render(&self) -> String {
        let c = |x: u64| x.min(MAX13);
        let lb = self.lb.map_or(0, mw_int).clamp(-LB_MAX, LB_MAX);
        format!(
            "v1 boot={} t={:013} n={:013} ton={:013} toff={:013} don={:013} doff={:013} dton={:013} dtoff={:013} \
             chg={:013} tchg={:013} tz={:013} tzero={:013} gap={:013} bl={:013} lb={:+013} lbt={:013} dpms={} pw={}",
            self.boot,
            c(self.t.unwrap_or(0).max(0) as u64),
            c(self.n),
            c(self.ton),
            c(self.toff),
            c(self.don / 1000),
            c(self.doff / 1000),
            c(self.dton),
            c(self.dtoff),
            c(self.chg / 1000),
            c(self.tchg),
            c(self.pend[0].saturating_add(self.pend[1])),
            c(self.tzero),
            c(self.gap),
            c(self.bl),
            lb,
            c(self.lbt.max(0) as u64),
            if self.on { "On " } else { "Off" },
            self.pw.as_str()
        )
    }

    /// the edge line for a change at t (s), without its newline
    fn edge(&self, t: f64) -> String {
        format!("v1 t={:.1} dpms={} pw={}", t, if self.on { "On" } else { "Off" }, self.pw.as_str())
    }
}

/// the files: <run_dir>/energy rewritten in place after every data line, <run_dir>/edge replaced on a change
pub struct Acc {
    st: State,
    energy: String,
    edge: String,
    file: Option<File>, // energy, kept open and rewritten with pwrite at offset 0
    truncate: bool,     // a fresh count: cut whatever an older line left, before the first write
    logged: bool,       // the first I/O error is logged, the rest swallowed
}

impl Acc {
    /// at start, after the baseline sample: resume this boot's counters from the energy file (a restart within the
    /// boot), else start from zero; write the energy line and the edge file now (the edge at every start)
    pub fn open(run_dir: &str, boot: &str, s: &Sample) -> Acc {
        let energy = format!("{run_dir}/energy");
        let mut txt = String::new();
        let read = File::open(&energy).and_then(|f| f.take(4096).read_to_string(&mut txt));
        let resumed = if read.is_ok() { State::parse(&txt, boot) } else { None };
        let truncate = resumed.is_none();
        let mut st = resumed.unwrap_or_else(|| State::new(boot));
        st.begin(&s.dpms);
        let mut a = Acc { st, energy, edge: format!("{run_dir}/edge"), file: None, truncate, logged: false };
        a.write_energy();
        a.write_edge(s.t);
        a
    }

    /// after every data line written (never the HEADER/MODE/MARK/STOP lines). Energy first: when y700-batteryd wakes
    /// on the edge, the line that made it is already in the energy file.
    pub fn line(&mut self, s: &Sample) {
        let edge = self.st.step(s.t, s.bat_mw, s.bat_ok, s.bat_st.as_deref(), &s.dpms, s.bl);
        self.write_energy();
        if edge {
            self.write_edge(s.t);
        }
    }

    /// the same length every time, so an overwrite never leaves a tail of the line before
    fn write_energy(&mut self) {
        if self.file.is_none() {
            match OpenOptions::new().write(true).create(true).mode(0o644).open(&self.energy) {
                Ok(f) => {
                    if self.truncate {
                        self.truncate = false;
                        if let Err(e) = f.set_len(0) {
                            self.warn("energy", &e);
                        }
                    }
                    self.file = Some(f);
                }
                Err(e) => {
                    self.warn("energy", &e);
                    return;
                }
            }
        }
        let line = format!("{}\n", self.st.render());
        let res = match &self.file {
            Some(f) => f.write_all_at(line.as_bytes(), 0),
            None => Ok(()),
        };
        if let Err(e) = res {
            self.file = None; // opened again with the next line
            self.warn("energy", &e);
        }
    }

    /// edge.tmp + rename: y700-batteryd wakes on IN_MOVED_TO of "edge" only
    fn write_edge(&mut self, t: f64) {
        let tmp = format!("{}.tmp", self.edge);
        let txt = format!("{}\n", self.st.edge(t));
        let done = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o644)
            .open(&tmp)
            .and_then(|mut f| f.write_all(txt.as_bytes()))
            .and_then(|_| fs::rename(&tmp, &self.edge));
        if let Err(e) = done {
            self.warn("edge", &e);
        }
    }

    /// writeln! rather than eprintln!: that one panics when stderr is gone
    fn warn(&mut self, what: &str, e: &io::Error) {
        if !self.logged {
            self.logged = true;
            let _ = writeln!(io::stderr(), "acc: {what}: {e} (later acc errors are not logged)");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const CASES: &str = include_str!("../fixtures/acc/cases.txt");
    const WIDTH: usize = 321; // the energy line without its newline

    /// a case's state and the first line's ms of its current count (acc_ref.Runner)
    struct Run {
        st: State,
        t0: Option<i64>,
    }

    fn status(tok: &str) -> Option<String> {
        if tok == "-" {
            None
        } else {
            Some(tok.replace('_', " "))
        }
    }

    /// one directive (boot, begin, l, restart); returns the edge lines it emitted (acc_ref.Runner.do)
    fn exec(run: &mut Option<Run>, cmd: &str, w: &[&str]) -> Vec<String> {
        let f = |i: usize| w[i].parse::<f64>().unwrap();
        match cmd {
            "boot" => {
                *run = Some(Run { st: State::new(w[0]), t0: None });
                vec![]
            }
            "begin" => {
                let r = run.as_mut().unwrap();
                r.st.begin(w[1]);
                vec![r.st.edge(f(0))]
            }
            "l" => {
                let r = run.as_mut().unwrap();
                let t = f(0);
                if r.t0.is_none() {
                    r.t0 = Some(ms(t));
                }
                let bl = if w[5] == "-" { None } else { Some(w[5].parse::<i64>().unwrap()) };
                let st = status(w[3]);
                if r.st.step(t, f(1), w[2] == "1", st.as_deref(), w[4], bl) {
                    vec![r.st.edge(t)]
                } else {
                    vec![]
                }
            }
            "restart" => {
                let r = run.as_mut().unwrap();
                let line = r.st.render();
                match State::parse(&line, w[0]) {
                    Some(st) => r.st = st,
                    None => {
                        r.st = State::new(w[0]);
                        r.t0 = None;
                    }
                }
                r.st.begin(w[2]);
                vec![r.st.edge(f(1))]
            }
            _ => panic!("unknown directive {cmd}"),
        }
    }

    fn run_case(name: &str, block: &[(usize, &str)], runs: &mut HashMap<String, Run>, fails: &mut Vec<String>) {
        let mut run: Option<Run> = None;
        let mut edges: Vec<String> = Vec::new();
        let mut seen = 0usize;
        for &(no, line) in block {
            let (cmd, rest) = line.split_once(' ').unwrap_or((line, ""));
            match cmd {
                "note" | "end" => {}
                "expect" => {
                    let got = run.as_ref().map(|r| r.st.render()).unwrap_or_default();
                    if got != rest {
                        fails.push(format!("{name} line {no}:\n  want {rest}\n  got  {got}"));
                    }
                }
                "edge" => {
                    let got = edges.get(seen).cloned().unwrap_or_default();
                    if got != rest {
                        fails.push(format!("{name} line {no}: edge want {rest:?} got {got:?}"));
                    }
                    seen += 1;
                }
                _ => {
                    let w: Vec<&str> = rest.split_whitespace().collect();
                    edges.extend(exec(&mut run, cmd, &w));
                }
            }
        }
        if seen != edges.len() {
            fails.push(format!("{name}: edges not in the fixture: {:?}", &edges[seen.min(edges.len())..]));
        }
        if let Some(r) = run {
            runs.insert(name.to_string(), r);
        }
    }

    /// every case of the shared file: (state at the end by name, failures) - acc_ref.check_cases
    fn check_cases(text: &str) -> (HashMap<String, Run>, Vec<String>) {
        let mut runs: HashMap<String, Run> = HashMap::new();
        let mut fails: Vec<String> = Vec::new();
        let mut name: Option<String> = None;
        let mut block: Vec<(usize, &str)> = Vec::new();
        for (i, raw) in text.lines().enumerate() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some(n) = line.strip_prefix("case ") {
                if let Some(prev) = name.take() {
                    run_case(&prev, &block, &mut runs, &mut fails);
                }
                name = Some(n.to_string());
                block.clear();
            } else {
                block.push((i + 1, line));
            }
        }
        if let Some(prev) = name.take() {
            run_case(&prev, &block, &mut runs, &mut fails);
        }
        (runs, fails)
    }

    fn cases() -> HashMap<String, Run> {
        let (runs, fails) = check_cases(CASES);
        assert!(fails.is_empty(), "{}", fails.join("\n"));
        runs
    }

    fn st(name: &str) -> State {
        cases()[name].st.clone()
    }

    #[test]
    fn shared_fixtures() {
        let runs = cases();
        assert_eq!(runs.len(), 14);
        for name in ["690a169c-66030", "690a169c-66620", "690a169c-66870", "974b286c-21327"] {
            assert!(runs.contains_key(name), "{name} missing");
        }
    }

    /// every ms between the first and the last line of a count is in exactly one energy-side bucket
    #[test]
    fn time_partition() {
        for (name, r) in cases() {
            let s = &r.st;
            let elapsed = s.t.unwrap_or(0) - r.t0.unwrap_or(0);
            let sum = s.dton + s.dtoff + s.tchg + s.tzero + s.pend[0] + s.pend[1] + s.gap;
            assert_eq!(sum as i64, elapsed, "{name}");
            assert!((s.ton + s.toff) as i64 <= elapsed, "{name}");
        }
    }

    #[test]
    fn render_parse_roundtrip() {
        for (name, r) in cases() {
            let line = r.st.render();
            assert_eq!(line.len(), WIDTH, "{name}");
            let back = State::parse(&line, &r.st.boot).unwrap();
            assert_eq!(back.render(), line, "{name}");
        }
    }

    // ---- the numbers worked out by hand (tests/test_acc_ref.py HandComputed asserts the same) ----

    #[test]
    fn hand_690a169c_66030_backfill() {
        // 66000.2 +118, 66010.2 +1003, 66020.2 +626 (On), 58 missing lines (two On), 66610.2 +153 (Off)
        let s = st("690a169c-66030");
        assert_eq!((s.don, s.dton, s.ton), (5_605_000 + 8_145_000 + 7_790_000, 40_000, 40_000));
        assert_eq!((s.doff, s.dtoff, s.toff), (222_015_000, 570_000, 570_000)); // 389.5 mW x 570 s
        assert_eq!((s.tzero, s.gap, s.pend, s.n, s.pw), (0, 0, [0, 0], 62, Pw::Dis));
        assert_eq!(s.bl, 410 * 40_000);
    }

    #[test]
    fn hand_pw_debounce() {
        let s = st("pw-debounce");
        assert_eq!((s.don, s.doff, s.chg), (1_525_000, 3_525_000, 3_000_000));
        assert_eq!((s.ton, s.toff, s.dton, s.dtoff, s.tchg, s.tzero), (20_000, 100_000, 20_000, 40_000, 30_000, 30_000));
        assert_eq!((s.bl, s.lb, s.pw, s.on), (1_000_000, Some(-100.0), Pw::Chg, false));
    }

    #[test]
    fn hand_gap_dt() {
        let s = st("gap-dt");
        assert_eq!((s.gap, s.ton, s.dton, s.don), (360_000, 40_000, 40_000, 27_000_000));
        assert_eq!((s.bl, s.lb, s.pw, s.n), (70_000_000, Some(900.0), Pw::Dis, 7));
    }

    #[test]
    fn hand_missing_30min() {
        let s = st("missing-30min");
        assert_eq!((s.gap, s.doff, s.dtoff, s.toff), (1_900_000, 375_000_000, 1_850_000, 3_750_000));
        assert_eq!((s.pend, s.n, s.lbt), ([0, 0], 76, 3_850_000));
    }

    #[test]
    fn hand_zero_plugged() {
        let s = st("zero-plugged");
        assert_eq!((s.chg, s.tchg, s.doff, s.dtoff), (104_000_000, 40_000, 10_000_000, 30_000));
        assert_eq!((s.tzero, s.toff, s.gap, s.pw), (60_000, 130_000, 0, Pw::Dis));
    }

    #[test]
    fn hand_boot_start() {
        let s = st("boot-start");
        assert_eq!((s.tzero, s.doff, s.dtoff, s.toff, s.lb), (20_000, 8_500_000, 30_000, 50_000, Some(350.0)));
    }

    #[test]
    fn hand_restart_same_boot() {
        let s = st("restart-same-boot");
        assert_eq!((s.n, s.t, s.don, s.doff, s.dtoff, s.toff), (4, Some(50_000), 5_000_000, 12_000_000, 30_000, 30_000));
        assert_eq!((s.bl, s.pw), (2_000_000, Pw::Unk));
    }

    #[test]
    fn hand_restart_new_boot() {
        let s = st("restart-new-boot");
        assert_eq!((s.boot.as_str(), s.n, s.t, s.don, s.ton, s.lb), ("bbbb2222", 1, Some(70_000), 0, 0, Some(100.0)));
    }

    #[test]
    fn hand_64370_plugged_vs_discharging() {
        // the same 50 zero lines: on the charger they are tzero one by one; as a missing run after lb = -8315 the mean
        // (-8315+127)/2 is negative, so the run (510 s with its closing step) is tzero too, not discharge
        let (p, d) = (st("690a169c-64370-plugged"), st("690a169c-64370-dischg"));
        assert_eq!(p.tzero, 500_000);
        assert_eq!(d.tzero, 510_000);
        assert_eq!(p.doff - d.doff, 635_000); // (0+127)/2 x 10 s, only when the zeros were real
        assert_eq!(p.chg, d.chg);
    }

    // ---- rules and format (tests/test_acc_ref.py Rules / Format) ----

    #[test]
    fn classify_rules() {
        assert_eq!(classify(-0.0, false, None), Reading::Missing);
        assert_eq!(classify(-0.0, true, None), Reading::Missing);
        assert_eq!(classify(-0.0, true, Some("Discharging")), Reading::Missing);
        assert_eq!(classify(-0.0, true, Some("")), Reading::Missing);
        assert_eq!(classify(0.0, true, Some("Full")), Reading::Zero);
        assert_eq!(classify(-0.0, true, Some("Not charging")), Reading::Zero);
        assert_eq!(classify(312.4, true, None), Reading::Valid(312.4));
        assert_eq!(classify(312.4, false, None), Reading::Missing);
        assert_eq!(classify(f64::NAN, true, None), Reading::Missing);
    }

    #[test]
    fn rounding() {
        assert_eq!((ms(66030.2), ms(0.0005), ms(-1.0)), (66_030_200, 1, 0));
        assert_eq!((uj(2.5), uj(2.4999), uj(-3.0)), (3, 2, 0));
        assert_eq!((mw_int(-0.5), mw_int(0.5), mw_int(-0.0)), (-1, 1, 0));
    }

    #[test]
    fn edge_only_on_change() {
        let mut a = State::new("edgetest");
        a.begin("Off");
        let due: Vec<bool> = (1..8).map(|i| a.step(10.0 * i as f64, 300.0, true, None, "Off", None)).collect();
        assert_eq!(due, vec![false, false, true, false, false, false, false]); // pw unk -> dis at the 3rd
        assert!(a.step(80.0, 300.0, true, None, "On", Some(900)));
        assert!(!a.step(90.0, 300.0, true, None, "?", None));
        assert!(a.step(100.0, 300.0, true, None, "Off", None));
        assert_eq!(a.edge(100.0), "v1 t=100.0 dpms=Off pw=dis");
    }

    #[test]
    fn fresh_line() {
        let line = State::new("3f2a9c1e-77d0-4b1e").render();
        assert_eq!(
            line,
            "v1 boot=3f2a9c1e t=0000000000000 n=0000000000000 ton=0000000000000 toff=0000000000000 \
             don=0000000000000 doff=0000000000000 dton=0000000000000 dtoff=0000000000000 chg=0000000000000 \
             tchg=0000000000000 tz=0000000000000 tzero=0000000000000 gap=0000000000000 bl=0000000000000 \
             lb=+000000000000 lbt=0000000000000 dpms=Off pw=unk"
        );
        assert_eq!(line.len(), WIDTH);
    }

    #[test]
    fn width_fixed_at_the_limits() {
        let mut a = State::new("noboot");
        assert_eq!(a.boot, "noboot--");
        a.on = true;
        a.pw = Pw::Chg;
        a.t = Some(1_000_000_000_000_000);
        a.n = 100_000_000_000_000;
        a.don = u64::MAX;
        a.chg = 5;
        a.bl = 10_000_000_000_000;
        a.gap = MAX13;
        a.lb = Some(-3.0e15);
        a.lbt = 1;
        let line = a.render();
        assert_eq!(line.len(), WIDTH);
        assert!(line.contains(" t=9999999999999 "));
        assert!(line.contains(" chg=0000000000000 ")); // 5 uJ is 0 mJ
        assert!(line.contains(" lb=-999999999999 "));
        assert!(line.contains(" dpms=On  pw=chg"));
    }

    #[test]
    fn parse_rejects() {
        let good = State::new("abcd1234").render();
        assert!(State::parse(&good, "abcd1234").is_some());
        assert!(State::parse(&format!("{good}\n"), "abcd1234-5678").is_some()); // the boot is cut to 8 like the line's
        assert!(State::parse(&good, "abcd9999").is_none());
        assert!(State::parse(&format!("v2{}", &good[2..]), "abcd1234").is_none());
        assert!(State::parse(&good.replace(" gap=0000000000000", ""), "abcd1234").is_none());
        assert!(State::parse(&good.replace("dpms=Off", "dpms=?  "), "abcd1234").is_none());
        assert!(State::parse(&good.replace("pw=unk", "pw=xyz"), "abcd1234").is_none());
        assert!(State::parse(&good.replace("n=0000000000000", "n=10000000000000"), "abcd1234").is_none());
        assert!(State::parse(&good.replace("n=0000000000000", "n=00000000000_0"), "abcd1234").is_none());
        // any number of leading zeros parses (acc_ref.py strips them before int(), which stops at 4300 digits)
        let long0 = format!("n={}7", "0".repeat(5000));
        assert_eq!(State::parse(&good.replace("n=0000000000000", &long0), "abcd1234").map(|s| s.n), Some(7));
        let long1 = format!("n=1{}", "0".repeat(5000));
        assert!(State::parse(&good.replace("n=0000000000000", &long1), "abcd1234").is_none());
        let longlb = format!("lb=-1{}", "0".repeat(5000));
        assert!(State::parse(&good.replace("lb=+000000000000", &longlb), "abcd1234").is_none());
        assert!(State::parse("", "abcd1234").is_none());
        assert!(State::parse("garbage", "abcd1234").is_none());
    }

    #[test]
    fn resume_keeps_the_open_run() {
        let mut a = State::new("runtest1");
        a.step(10.0, 400.0, true, None, "On", Some(10));
        a.step(20.0, -0.0, false, None, "On", Some(10));
        let mut b = State::parse(&a.render(), "runtest1").unwrap();
        assert_eq!((b.pend, b.lb, b.lbt, b.t), ([0, 10_000], Some(400.0), 10_000, Some(20_000)));
        b.step(30.0, 200.0, true, None, "On", Some(10));
        assert_eq!((b.don, b.dton, b.pend), (300 * 20_000, 20_000, [0, 0]));
    }

    /// the I/O layer in a scratch run dir: both files at start, the count resumed in the same boot and zeroed in
    /// another, errors swallowed when the directory cannot be written
    #[test]
    fn io_layer() {
        let dir = std::env::temp_dir().join(format!("y700-acc-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let d = dir.to_string_lossy().into_owned();
        let read = |name: &str| fs::read_to_string(dir.join(name)).unwrap();
        let sample = |t: f64, dpms: &str| Sample { t, bat_mw: 300.0, bat_ok: true, dpms: dpms.to_string(), ..Default::default() };

        let mut a = Acc::open(&d, "cafe0001", &sample(10.0, "Off"));
        assert_eq!(read("edge"), "v1 t=10.0 dpms=Off pw=unk\n");
        assert_eq!(read("energy"), format!("{}\n", State::new("cafe0001").render()));
        for i in 1..=4 {
            a.line(&sample(10.0 + 10.0 * i as f64, "Off"));
        }
        assert_eq!(read("energy").len(), WIDTH + 1);
        assert!(read("energy").contains(" n=0000000000004 "));
        assert_eq!(read("edge"), "v1 t=40.0 dpms=Off pw=dis\n");
        assert!(!dir.join("edge.tmp").exists());

        let b = Acc::open(&d, "cafe0001", &sample(55.0, "On"));
        assert_eq!(b.st.n, 4);
        assert_eq!(read("edge"), "v1 t=55.0 dpms=On pw=dis\n");
        let c = Acc::open(&d, "beef0002", &sample(5.0, "Off"));
        assert_eq!(c.st.n, 0);
        assert!(read("energy").starts_with("v1 boot=beef0002 t=0000000000000 n=0000000000000 "));
        assert_eq!(read("energy").len(), WIDTH + 1);

        let bad = dir.join("energy").join("x").to_string_lossy().into_owned(); // a file is in the way
        let mut z = Acc::open(&bad, "cafe0001", &sample(5.0, "Off"));
        z.line(&sample(15.0, "Off"));
        assert!(z.logged);
        let _ = fs::remove_dir_all(&dir);
    }
}
