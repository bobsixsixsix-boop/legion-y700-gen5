//! The decision: when the panel goes to the video's rate and back. The Python daemon's RefreshAuto class ported method
//! for method (same names, same order of checks, same log lines), with every side effect behind the Out trait so that
//! the tests below run it on a virtual clock - test-retry-offline.py's fake GLib, test-log-fg.py's on_call cases and
//! the scenarios of test-refresh-auto.sh / test-refresh-auto-2.sh that need no live session. GLib's timeout sources
//! are deadlines here (Timers), fired by the main loop in deadline order; a source id is the timer's id.
//!
//! Numbers keep Python's int / float distinction (Num): the config may hold 120 or 120.0, and the log lines and the
//! status print what Python printed.

use crate::fg::{py_isspace, Fg};
use crate::json::{self, py_bool, J};
use crate::say;
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::fmt;

/// One timing family (0066), switched in place (0065).
pub const INPLACE: [i64; 3] = [120, 60, 30];
/// A foreign switch to one of these is the owner's new base; 30 never is.
pub const BASE_CHOICES: [i64; 4] = [60, 90, 120, 164];

#[derive(Clone, Copy, Debug)]
pub enum Num {
    I(i64),
    F(f64),
}

impl Num {
    pub fn f(self) -> f64 {
        match self {
            Num::I(i) => i as f64,
            Num::F(f) => f,
        }
    }
    /// Python's int(): toward zero.
    pub fn int(self) -> i64 {
        match self {
            Num::I(i) => i,
            Num::F(f) => f as i64,
        }
    }
    /// The integer it equals, if any: 30.0 finds the mode 30 as it did in a Python dict.
    pub fn key(self) -> Option<i64> {
        match self {
            Num::I(i) => Some(i),
            Num::F(f) if f.fract() == 0.0 && f.abs() < 9.2e18 => Some(f as i64),
            Num::F(_) => None,
        }
    }
    pub fn in_(self, set: &[i64]) -> bool {
        set.iter().any(|&s| self == Num::I(s))
    }
    pub fn json(self) -> J {
        match self {
            Num::I(i) => J::Int(i),
            Num::F(f) => J::Float(f),
        }
    }
}

impl PartialEq for Num {
    fn eq(&self, o: &Num) -> bool {
        match (self, o) {
            (Num::I(a), Num::I(b)) => a == b,
            _ => self.f() == o.f(),
        }
    }
}

impl PartialOrd for Num {
    fn partial_cmp(&self, o: &Num) -> Option<Ordering> {
        match (self, o) {
            (Num::I(a), Num::I(b)) => a.partial_cmp(b),
            _ => self.f().partial_cmp(&o.f()),
        }
    }
}

/// str() of the number, as the log lines print it (120, 120.0).
impl fmt::Display for Num {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Num::I(i) => write!(f, "{i}"),
            Num::F(x) => f.write_str(&json::py_float(*x)),
        }
    }
}

pub fn mode_name(hz: Num) -> String {
    format!("1904x3040@{hz}")
}

/// ~/.config/y700-refresh-auto.json.
#[derive(Clone, Debug, PartialEq)]
pub struct Cfg {
    pub enabled: bool,
    pub base_hz: Num,
    pub enter_delay_s: Num,
    pub touch_hold_s: Num,
    /// 0 = base: an unknown rate may be 24/25 fps (judder at 30/60 Hz)
    pub unknown_fps_hz: Num,
    pub danmaku_min_hz: Num,
    /// [min_fps, max_fps, hz] on the effective fps (fps x speed); first match wins; hz 0 = base; no match -> base.
    /// Only rates that divide the panel rate evenly (judder-free) are lowered; 24/25/48/50 fps stay at the base: 120 is
    /// 5 x 24, while 24 fps at 60 Hz is 3:2 judder and 25/50 fps judder 17 ms at 60 Hz vs 8 ms at 120 ("follow the source").
    pub map: Vec<[Num; 3]>,
}

impl Default for Cfg {
    fn default() -> Cfg {
        use Num::{F, I};
        Cfg {
            enabled: true,
            base_hz: I(120),
            enter_delay_s: F(1.5),
            touch_hold_s: F(3.0),
            unknown_fps_hz: I(0),
            danmaku_min_hz: I(60),
            map: vec![[F(29.0), F(31.0), I(30)], [F(58.0), F(61.0), I(60)], [F(14.5), F(15.5), I(30)], [F(19.5), F(20.5), I(60)], [F(9.5), F(10.5), I(30)]],
        }
    }
}

/// A number the config takes: int or float, not bool. RUST: not inf either - Python took it and then failed in int().
fn num_of(v: &J) -> Option<Num> {
    match v {
        J::Int(i) => Some(Num::I(*i)),
        J::Float(f) if f.is_finite() => Some(Num::F(*f)),
        _ => None,
    }
}

fn map_of(v: &J) -> Option<Vec<[Num; 3]>> {
    let J::Arr(rows) = v else { return None };
    let any = |x: &J| match x {
        J::Int(i) => Some(Num::I(*i)),
        J::Float(f) => Some(Num::F(*f)),
        _ => None,
    };
    rows.iter()
        .map(|r| match r {
            // RUST: a non-finite hz is refused (Python's int() raised on it inside every decision)
            J::Arr(x) if x.len() == 3 => Some([any(&x[0])?, any(&x[1])?, num_of(&x[2])?]),
            _ => None,
        })
        .collect()
}

impl Cfg {
    /// load_cfg(): the defaults, with every value of the file that has the right type (a number >= 0; a list of
    /// [number, number, number] for map); the others are logged and left at the default, unknown keys skipped. No file
    /// (None) or a file that is no JSON object: the defaults, silently.
    pub fn load(text: Option<&str>) -> Cfg {
        let mut cfg = Cfg::default();
        let Some(Ok(J::Obj(kv))) = text.map(json::parse) else { return cfg };
        for (k, v) in &kv {
            let ok = match k.as_str() {
                "enabled" => matches!(v, J::Bool(_)).then(|| cfg.enabled = *v == J::Bool(true)).is_some(),
                "map" => map_of(v).map(|m| cfg.map = m).is_some(),
                "base_hz" | "enter_delay_s" | "touch_hold_s" | "unknown_fps_hz" | "danmaku_min_hz" => match num_of(v) {
                    Some(n) if n.f() >= 0.0 => {
                        *cfg.num_mut(k) = n;
                        true
                    }
                    _ => false,
                },
                _ => continue,
            };
            if !ok {
                say(&format!("config: ignoring {k}={} (wrong type)", json::py_repr(v)));
            }
        }
        cfg
    }

    fn num_mut(&mut self, k: &str) -> &mut Num {
        match k {
            "base_hz" => &mut self.base_hz,
            "enter_delay_s" => &mut self.enter_delay_s,
            "touch_hold_s" => &mut self.touch_hold_s,
            "unknown_fps_hz" => &mut self.unknown_fps_hz,
            _ => &mut self.danmaku_min_hz,
        }
    }

    /// The file as save_cfg() writes it: json.dump(cfg, indent=1), the defaults' key order.
    pub fn to_json(&self) -> String {
        let n = |k: &str, v: Num| (k.to_string(), v.json());
        json::dump_indent(
            &J::Obj(vec![
                ("enabled".into(), J::Bool(self.enabled)),
                n("base_hz", self.base_hz),
                n("enter_delay_s", self.enter_delay_s),
                n("touch_hold_s", self.touch_hold_s),
                n("unknown_fps_hz", self.unknown_fps_hz),
                n("danmaku_min_hz", self.danmaku_min_hz),
                ("map".into(), J::Arr(self.map.iter().map(|r| J::Arr(r.iter().map(|x| x.json()).collect())).collect())),
            ]),
            1,
        )
    }
}

pub fn pick_hz(fps: f64, cfg: &Cfg, base: Num) -> Num {
    let or_base = |h: i64| if h != 0 { Num::I(h) } else { base };
    if fps == 0.0 || fps <= 0.0 {
        return or_base(cfg.unknown_fps_hz.int());
    }
    for [lo, hi, hz] in &cfg.map {
        if lo.f() <= fps && fps <= hi.f() {
            return or_base(hz.int());
        }
    }
    base
}

/// A player state file ($XDG_RUNTIME_DIR/y700-video/*, written by the wiliwili patch and the mpv script).
#[derive(Clone, Debug, PartialEq)]
pub struct St {
    pub pid: i64,
    pub playing: bool,
    pub fullscreen: bool,
    pub osd: bool,
    pub danmaku: bool,
    pub fps: f64,
}

impl St {
    fn json(&self) -> J {
        let b = |k: &str, v: bool| (k.to_string(), J::Bool(v));
        J::Obj(vec![("pid".into(), J::Int(self.pid)), b("playing", self.playing), b("fullscreen", self.fullscreen), b("osd", self.osd),
            b("danmaku", self.danmaku), ("fps".into(), J::Float(self.fps))])
    }
}

/// Python's reading of a state file: key=value lines (universal newlines, stripped, split at the first '='), the last of
/// a key wins; None where it raised (not UTF-8, a pid or fps that int() / float() refuse).
pub fn parse_state(raw: &[u8]) -> Option<St> {
    let text = std::str::from_utf8(raw).ok()?.replace("\r\n", "\n").replace('\r', "\n");
    let mut kv: BTreeMap<&str, &str> = BTreeMap::new();
    for line in text.split('\n').filter(|l| l.contains('=')) {
        let (k, v) = line.trim_matches(py_isspace).split_once('=').unwrap();
        kv.insert(k, v);
    }
    let flag = |k: &str| kv.get(k) == Some(&"1");
    // shortcut: int() / float() also take digit separators ("1_000") and non-ASCII digits; no writer makes them
    let pid = match kv.get("pid") {
        Some(v) => v.trim_matches(py_isspace).parse().ok()?,
        None => 0,
    };
    let fps = match kv.get("fps") {
        Some(v) if !v.is_empty() => v.trim_matches(py_isspace).parse().ok()?,
        _ => 0.0,
    };
    Some(St { pid, playing: flag("playing"), fullscreen: flag("fullscreen"), osd: flag("osd"), danmaku: flag("danmaku"), fps })
}

static EMPTY: J = J::Arr(Vec::new());

/// The dynamic operations on parsed JSON that kscreen-doctor -j's handling uses, failing with Python's words.
fn py_get<'a>(j: &'a J, k: &str) -> Result<Option<&'a J>, String> {
    match j {
        J::Obj(_) => Ok(j.get(k)),
        _ => Err(format!("'{}' object has no attribute 'get'", j.type_name())),
    }
}

fn py_iter(j: &J) -> Result<Vec<J>, String> {
    match j {
        J::Arr(v) => Ok(v.clone()),
        J::Obj(kv) => Ok(kv.iter().map(|(k, _)| J::Str(k.clone())).collect()),
        J::Str(s) => Ok(s.chars().map(|c| J::Str(c.to_string())).collect()),
        _ => Err(format!("'{}' object is not iterable", j.type_name())),
    }
}

fn py_startswith(j: &J, p: &str) -> Result<bool, String> {
    match j {
        J::Str(s) => Ok(s.starts_with(p)),
        _ => Err(format!("'{}' object has no attribute 'startswith'", j.type_name())),
    }
}

/// int(round(x)): halves to even.
fn py_round(j: &J) -> Result<i64, String> {
    match j {
        J::Int(i) => Ok(*i),
        J::Bool(b) => Ok(*b as i64),
        J::Float(f) if f.is_nan() => Err("cannot convert float NaN to integer".into()),
        J::Float(f) if f.is_infinite() => Err("cannot convert float infinity to integer".into()),
        J::Float(f) => Ok(f.round_ties_even() as i64),
        _ => Err(format!("type {} doesn't define __round__ method", j.type_name())),
    }
}

fn num_is(j: &J, n: i64) -> bool {
    match j {
        J::Int(i) => *i == n,
        J::Float(f) => *f == n as f64,
        J::Bool(b) => *b as i64 == n,
        _ => false,
    }
}

fn utf8(raw: &[u8]) -> Result<&str, String> {
    // shortcut: the reason is always "invalid start byte" (Python also says "invalid continuation byte" and others)
    std::str::from_utf8(raw).map_err(|e| {
        let at = e.valid_up_to();
        format!("'utf-8' codec can't decode byte 0x{:02x} in position {at}: invalid start byte", raw[at])
    })
}

/// kwin_hz(): KWin's mode of the DSI output in kwinoutputconfig.json, None if anything is off.
pub fn kwin_hz_of(text: &str) -> Option<i64> {
    let j = json::parse(text).ok()?;
    for blk in py_iter(&j).ok()? {
        if py_get(&blk, "name").ok()? == Some(&J::Str("outputs".into())) {
            for o in py_iter(py_get(&blk, "data").ok()?.unwrap_or(&EMPTY)).ok()? {
                if py_get(&o, "connectorName").ok()?.map_or(String::new(), json::py_str).starts_with("DSI") {
                    let x = match o.get("mode")?.get("refreshRate")? {
                        J::Int(i) => *i as f64 / 1000.0,
                        J::Float(f) => f / 1000.0,
                        J::Bool(b) => *b as i64 as f64 / 1000.0,
                        _ => return None,
                    };
                    return py_round(&J::Float(x)).ok();
                }
            }
        }
    }
    None
}

/// The current mode of the DSI output in kscreen-doctor -j's output (current_hz()'s fallback).
pub fn current_of(raw: &[u8]) -> Option<i64> {
    let j = json::parse(utf8(raw).ok()?).ok()?;
    for o in py_iter(py_get(&j, "outputs").ok()?.unwrap_or(&EMPTY)).ok()? {
        if py_startswith(py_get(&o, "name").ok()?.unwrap_or(&J::Str(String::new())), "DSI").ok()? {
            let cur = json::py_str(py_get(&o, "currentModeId").ok()?.unwrap_or(&J::Null));
            for m in py_iter(py_get(&o, "modes").ok()?.unwrap_or(&EMPTY)).ok()? {
                if json::py_str(py_get(&m, "id").ok()?.unwrap_or(&J::Null)) == cur {
                    return py_round(py_get(&m, "refreshRate").ok()?.unwrap_or(&J::Int(0))).ok();
                }
            }
        }
    }
    None
}

/// Everything the decision does to the world.
pub trait Out {
    /// CLOCK_MONOTONIC in s (time.monotonic())
    fn now(&self) -> f64;
    /// kwin_hz(): kwinoutputconfig.json's DSI mode
    fn kwin_hz(&mut self) -> Option<i64>;
    /// kscreen-doctor -j's stdout, or why it did not run (GLib's words)
    fn kscreen_json(&mut self) -> Result<Vec<u8>, String>;
    /// Starts kscreen-doctor output.<output>.mode.<mode>; its end comes back as Ra::on_mode_done.
    fn switch(&mut self, output: &str, mode: &str) -> Result<(), String>;
    /// SIGKILL to that kscreen-doctor (force_exit(); its end still comes back)
    fn kill_switch(&mut self);
    /// SIGKILL and reap it: stop()'s, so that it cannot land after the restore
    fn stop_switch(&mut self);
    /// timeout 8 kscreen-doctor output.DSI-1.mode.<mode>, waited for (restore())
    fn restore_mode(&mut self, mode: &str) -> Result<(), String>;
    /// screen_on()
    fn screen_on(&mut self) -> bool;
    /// RUST: the screen state comes as KWin's events (Ra::on_screen) instead of the 1 s tick
    fn screen_events(&self) -> bool;
    fn save_cfg(&mut self, cfg: &Cfg) -> Result<(), String>;
    /// attach_touch(): touch, pen and volume keys are read only while a video wants a lower rate
    fn touch(&mut self, on: bool);
    fn touch_attached(&self) -> bool;
    /// a player state file's bytes, None if unreadable
    fn read_state(&mut self, name: &str) -> Option<Vec<u8>>;
    /// /proc/<pid> exists
    fn pid_exists(&self, pid: i64) -> bool;
    /// unlink_if(): removes the state file if it still says pid=<pid>
    fn unlink_if(&mut self, name: &str, pid: i64);
    /// a pidfd on the player (once per pid); its exit comes back as Ra::on_player_exit
    fn watch_pid(&mut self, pid: i64);
    fn unwatch_pid(&mut self, pid: i64);
    fn take_sleep_lock(&mut self);
    fn release_sleep_lock(&mut self);
}

#[derive(Clone, Debug, PartialEq)]
enum T {
    Modes,
    Retry,
    Enter(String),
    Hold,
    Dpms,
    Kwin,
    Kill,
    After(String),
    SleepRelease,
}

/// GLib's timeout sources as deadlines; due ones fire in deadline order, then in the order they were added.
#[derive(Default)]
struct Timers {
    q: Vec<(f64, u64, T)>,
    seq: u64,
}

impl Timers {
    fn add(&mut self, at: f64, t: T) -> u64 {
        self.seq += 1;
        self.q.push((at, self.seq, t));
        self.seq
    }
    fn remove(&mut self, id: u64) {
        self.q.retain(|e| e.1 != id);
    }
    fn next(&self) -> Option<f64> {
        self.q.iter().map(|e| e.0).min_by(f64::total_cmp)
    }
    fn pop_due(&mut self, now: f64) -> Option<T> {
        let q = &self.q;
        let i = (0..q.len()).filter(|&i| q[i].0 <= now).min_by(|&a, &b| q[a].0.total_cmp(&q[b].0).then(q[a].1.cmp(&q[b].1)))?;
        Some(self.q.remove(i).2)
    }
}

pub struct Ra<O: Out> {
    pub out: O,
    pub cfg: Cfg,
    pub fg: Fg,
    pub output: String,
    pub modes: BTreeMap<i64, String>,
    warned: Vec<Num>,
    pub cur_hz: Option<i64>,
    /// (hz, until): a switch of ours not yet seen in kwinoutputconfig.json
    expected: Option<(Num, f64)>,
    /// hz -> when we asked for it, until it is seen landed (a late KWin write is still ours)
    requested: Vec<(Num, f64)>,
    /// state file name -> state, in the order they came (a Python dict)
    pub players: Vec<(String, St)>,
    /// (resourceClass, covers, pid)
    pub active: (String, bool, i64),
    pub last_touch: f64,
    pub locked: bool,
    /// the owner chose a mode while a video wanted another: no override until things change
    pub manual: bool,
    backoff_until: f64,
    pub fails: u32,
    /// after a failed switch: no kscreen-doctor before retry_at (fail())
    retry_at: f64,
    /// a DSI dpms node exists (the screen-off guard can work)
    pub dpms: bool,
    /// the rate the running kscreen-doctor switches to (mode_proc)
    switching: Option<Num>,
    pending: bool,
    /// touches right after our own switch (see on_touch)
    shield_until: f64,
    shielded: u64,
    /// RUST: the screen-off guard is on and waits for KWin's event (the tick, dpms_src, runs only without KWin's events,
    /// or while the screen is off and the panel still below the base)
    watching: bool,
    timers: Timers,
    retry_src: Option<u64>,
    enter_src: Option<u64>,
    hold_src: Option<u64>,
    dpms_src: Option<u64>,
    kwin_src: Option<u64>,
    kill_src: Option<u64>,
}

impl<O: Out> Ra<O> {
    pub fn new(out: O, cfg: Cfg, fg: Fg) -> Ra<O> {
        Ra {
            out,
            cfg,
            fg,
            output: "DSI-1".into(),
            modes: BTreeMap::new(),
            warned: Vec::new(),
            cur_hz: None,
            expected: None,
            requested: Vec::new(),
            players: Vec::new(),
            active: (String::new(), false, 0),
            last_touch: 0.0,
            locked: false,
            manual: false,
            backoff_until: 0.0,
            fails: 0,
            retry_at: 0.0,
            dpms: false,
            switching: None,
            pending: false,
            shield_until: 0.0,
            shielded: 0,
            watching: false,
            timers: Timers::default(),
            retry_src: None,
            enter_src: None,
            hold_src: None,
            dpms_src: None,
            kwin_src: None,
            kill_src: None,
        }
    }

    fn after_ms(&mut self, ms: i64, t: T) -> u64 {
        let at = self.out.now() + ms as f64 / 1000.0;
        self.timers.add(at, t)
    }

    pub fn next_deadline(&self) -> Option<f64> {
        self.timers.next()
    }

    /// Fires every timer that is due.
    pub fn on_timer(&mut self) {
        let now = self.out.now();
        while let Some(t) = self.timers.pop_due(now) {
            match t {
                T::Modes => self.retry_modes(),
                T::Retry => {
                    self.retry_src = None;
                    self.evaluate("retry after a failed switch");
                }
                T::Enter(why) => self.on_enter(&why),
                T::Hold => self.on_hold_end(),
                T::Dpms => self.on_dpms_tick(),
                T::Kwin => self.check_kwin(),
                T::Kill => self.on_mode_timeout(),
                T::After(why) => self.evaluate(&why),
                T::SleepRelease => self.out.release_sleep_lock(),
            }
        }
    }

    pub fn modes_list(&self) -> String {
        format!("[{}]", self.modes.keys().map(i64::to_string).collect::<Vec<_>>().join(", "))
    }

    fn cur_is(&self, hz: Num) -> bool {
        self.cur_hz.is_some_and(|c| hz == Num::I(c))
    }

    /// expecting() in (None, hz)
    fn expecting_in(&mut self, hz: Num) -> bool {
        self.expecting().map_or(true, |e| e == hz)
    }

    fn at_base(&mut self) -> bool {
        let base = self.cfg.base_hz;
        self.cur_is(base) && self.expecting_in(base)
    }

    // ---------------------------------------------------------------- modes / switching
    pub fn read_modes(&mut self) {
        let r = match self.out.kscreen_json() {
            Ok(raw) => self.take_modes(&raw),
            Err(e) => Err(e),
        };
        if let Err(e) = r {
            say(&format!("kscreen-doctor -j failed: {e}"));
        }
        if self.modes.is_empty() {
            self.after_ms(2000, T::Modes);
        }
    }

    /// What read_modes() takes from kscreen-doctor -j: the DSI output's name and its 1904x3040 modes (whatever came
    /// before an error stays, as in Python).
    fn take_modes(&mut self, raw: &[u8]) -> Result<(), String> {
        let j = json::parse(utf8(raw)?)?;
        for o in py_iter(py_get(&j, "outputs")?.unwrap_or(&EMPTY))? {
            let name = py_get(&o, "name")?.cloned().unwrap_or(J::Str(String::new()));
            if py_startswith(&name, "DSI")? {
                self.output = json::py_str(&name);
                for m in py_iter(py_get(&o, "modes")?.unwrap_or(&EMPTY))? {
                    let hz = py_round(py_get(&m, "refreshRate")?.unwrap_or(&J::Int(0)))?;
                    let size = py_get(&m, "size")?.cloned().unwrap_or(J::Obj(Vec::new()));
                    if py_get(&size, "height")?.is_some_and(|h| num_is(h, 3040) || num_is(h, 1904)) {
                        self.modes.insert(hz, mode_name(Num::I(hz)));
                    }
                }
            }
        }
        Ok(())
    }

    fn retry_modes(&mut self) {
        self.read_modes();
        if !self.modes.is_empty() {
            say(&format!("modes {}", self.modes_list()));
            self.evaluate("modes read");
        }
    }

    /// current_hz(): KWin's mode from kwinoutputconfig.json, else kscreen-doctor's current mode.
    pub fn current_hz(&mut self) -> Option<i64> {
        if let Some(hz) = self.out.kwin_hz() {
            return Some(hz);
        }
        current_of(&self.out.kscreen_json().ok()?)
    }

    fn expecting(&mut self) -> Option<Num> {
        if self.expected.is_some_and(|e| self.out.now() > e.1) {
            self.expected = None;
        }
        self.expected.map(|e| e.0)
    }

    fn set_hz(&mut self, hz: Num, why: &str) {
        let Some(mode) = hz.key().and_then(|k| self.modes.get(&k)).cloned() else {
            if !self.warned.contains(&hz) {
                say(&format!("no {hz} Hz mode known ({}): not switching ({why})", self.modes_list()));
                self.warned.push(hz);
            }
            return;
        };
        if self.switching.is_some() {
            // one kscreen-doctor at a time; on_mode_done looks again at once
            self.pending = true;
            return;
        }
        if self.cur_is(hz) && self.expecting_in(hz) {
            return;
        }
        let now = self.out.now();
        if self.fails > 0 && now < self.retry_at {
            if self.retry_src.is_none() {
                let ms = ((self.retry_at - now) * 1000.0) as i64 + 1;
                self.retry_src = Some(self.after_ms(ms, T::Retry));
            }
            return;
        }
        say(&format!("{} -> {hz} Hz ({why})", self.cur_hz.map_or("None".into(), |c| c.to_string())));
        if let Err(e) = self.out.switch(&self.output.clone(), &mode) {
            say(&format!("kscreen-doctor did not start: {e}"));
            self.fail();
            return;
        }
        let now = self.out.now();
        self.switching = Some(hz);
        self.expected = Some((hz, now + 5.0));
        match self.requested.iter_mut().find(|r| r.0 == hz) {
            Some(r) => r.1 = now,
            None => self.requested.push((hz, now)),
        }
        self.kill_src = Some(self.after_ms(5000, T::Kill));
        if hz != self.cfg.base_hz {
            self.watch_dpms();
        }
    }

    fn on_mode_timeout(&mut self) {
        say("kscreen-doctor still running after 5 s: killed");
        self.kill_src = None;
        self.out.kill_switch(); // its end comes back, on_mode_done cleans up
    }

    fn fail(&mut self) {
        // The next try waits 1, 2, 4 ... 30 s. backoff_until only stops LOWERING: going back to the base was retried by
        // on_mode_done's 300 ms re-look and the 1 Hz screen-off tick with no delay at all - a kscreen-doctor every
        // ~0.35 s for as long as switching failed (10-19 audit, simulated: 170+ in 60 s screen off).
        self.fails += 1;
        let now = self.out.now();
        self.retry_at = now + if self.fails > 5 { 30.0 } else { (1u32 << (self.fails - 1)) as f64 };
        if self.fails >= 3 {
            self.backoff_until = now + 60.0;
            say("3 failed switches in a row: no lowering for 60 s");
        }
    }

    /// The running kscreen-doctor ended (ok: exit status 0).
    pub fn on_mode_done(&mut self, ok: bool) {
        if let Some(id) = self.kill_src.take() {
            self.timers.remove(id);
        }
        let Some(hz) = self.switching.take() else { return };
        let now = self.current_hz();
        if now.is_some() {
            self.cur_hz = now;
        }
        let landed = now.is_some_and(|n| hz == Num::I(n));
        if landed || !ok {
            self.expected = None;
        }
        if landed {
            self.requested.retain(|r| r.0 != hz); // landed: a later switch to this rate is not ours
        }
        if ok && landed {
            self.fails = 0;
            if hz != self.cfg.base_hz {
                self.shield_until = self.out.now() + 1.5;
            }
        } else if !ok {
            say(&format!("kscreen-doctor did not switch to {hz} Hz"));
            self.fail();
        }
        let (want, _) = self.want();
        if self.pending || want != hz {
            self.pending = false;
            self.after_ms(0, T::After("after switch".into()));
        } else {
            self.after_ms(300, T::After("after switch".into()));
        }
    }

    fn watch_dpms(&mut self) {
        if self.out.screen_events() {
            self.watching = true; // RUST: KWin says when the screen goes off (on_screen); no tick while it is lit
        } else if self.dpms_src.is_none() {
            self.dpms_src = Some(self.after_ms(1000, T::Dpms));
        }
    }

    /// The 1 s screen-off tick. dpms_src stays set while it runs, as the GLib source did: a watch_dpms() in here arms
    /// no second one.
    fn on_dpms_tick(&mut self) {
        if self.at_base() {
            self.dpms_src = None;
            self.watching = false;
            return;
        }
        if !self.out.screen_on() {
            self.drop_to_base("screen off"); // KWin keeps the mode for the off pipeline: the next wake is at the base
        } else if self.out.screen_events() {
            // RUST: lit (again) with KWin's events at hand: they take over until the screen goes off
            self.dpms_src = None;
            self.watching = true;
            return;
        }
        self.dpms_src = Some(self.after_ms(1000, T::Dpms));
    }

    /// RUST: KWin's DPMS state changed (src/wl.rs). Below the base, a screen going off goes back to the base at once
    /// and then every second while it stays off and the switch has not landed (the tick's retries); at the base the
    /// guard ends, as the tick ended itself.
    pub fn on_screen(&mut self) {
        if !self.watching || self.dpms_src.is_some() {
            return;
        }
        if self.at_base() {
            self.watching = false;
        } else if !self.out.screen_on() {
            self.watching = false;
            self.drop_to_base("screen off");
            self.dpms_src = Some(self.after_ms(1000, T::Dpms));
        }
    }

    /// RUST: KWin's events went away (KWin restarted): the guard falls back to the 1 s tick.
    pub fn on_events_lost(&mut self) {
        if self.watching {
            self.watching = false;
            self.watch_dpms();
        }
    }

    // ---------------------------------------------------------------- KWin's mode file
    /// kwinoutputconfig.json was written.
    pub fn on_kwinconf(&mut self) {
        if self.kwin_src.is_none() {
            // coalesce the burst of events of one QSaveFile write
            self.kwin_src = Some(self.after_ms(100, T::Kwin));
        }
    }

    fn check_kwin(&mut self) {
        self.kwin_src = None;
        let Some(hz) = self.out.kwin_hz() else { return };
        if self.cur_hz == Some(hz) {
            return;
        }
        let exp = self.expecting();
        self.cur_hz = Some(hz);
        let h = Num::I(hz);
        // ours: the switch we are waiting for, or an earlier request of ours that had not landed yet (e.g. 30 landing
        // after a touch already asked for the base). A request that HAS landed was removed from requested, so the
        // owner later picking that same rate (control centre tile) is not mistaken for ours (10-16 test 2: 164 -> 120).
        let asked = self.requested.iter().find(|r| r.0 == h).map_or(-1e9, |r| r.1);
        let late = self.out.now() - asked < 10.0;
        self.requested.retain(|r| r.0 != h);
        if exp == Some(h) {
            self.expected = None;
            return;
        }
        if late {
            self.evaluate("late write of our switch");
            return;
        }
        let vt = self.video_target();
        if !h.in_(&BASE_CHOICES) || vt == Some(h) {
            // 30, or the rate the video wants anyway (the display watchdog's "back to the current mode"): not a choice
            say(&format!("mode changed to {hz} Hz by someone else: not taken as the base"));
            self.evaluate("foreign mode");
            return;
        }
        say(&format!("mode changed to {hz} Hz by someone else: new base {hz} Hz"));
        self.cfg.base_hz = h;
        if let Err(e) = self.out.save_cfg(&self.cfg) {
            say(&e); // RUST: the error where Python logged a traceback; like there, the rest is skipped
            return;
        }
        if vt.is_some() {
            self.manual = true;
        }
        self.evaluate("new base");
    }

    // ---------------------------------------------------------------- players
    /// An event in the state directory: a file written or moved in (gone false), deleted or moved out (gone true).
    pub fn on_statedir(&mut self, name: &str, gone: bool) {
        if name.is_empty() || name.ends_with(".tmp") {
            return;
        }
        let changed = if gone { self.pop_player(name) } else { self.read_player(name) };
        if changed {
            self.evaluate("player state");
        }
    }

    fn pop_player(&mut self, name: &str) -> bool {
        let n = self.players.len();
        self.players.retain(|p| p.0 != name);
        self.players.len() != n
    }

    fn summary(&self, st: Option<&St>) -> Option<(bool, bool, bool, bool, Num)> {
        st.map(|s| (s.playing, s.fullscreen, s.osd, s.danmaku, pick_hz(s.fps, &self.cfg, self.cfg.base_hz)))
    }

    /// True when something that matters for the decision changed.
    pub fn read_player(&mut self, name: &str) -> bool {
        let old = self.players.iter().find(|p| p.0 == name).map(|p| p.1.clone());
        let Some(st) = self.out.read_state(name).as_deref().and_then(parse_state) else { return self.pop_player(name) };
        if st.pid == 0 || !self.out.pid_exists(st.pid) {
            self.out.unlink_if(name, st.pid);
            return self.pop_player(name);
        }
        match self.players.iter_mut().find(|p| p.0 == name) {
            Some(p) => p.1 = st.clone(),
            None => self.players.push((name.to_string(), st.clone())),
        }
        self.out.watch_pid(st.pid);
        if old.as_ref().map_or(true, |o| o.pid != st.pid || (o.playing, o.fullscreen) != (st.playing, st.fullscreen)) {
            self.manual = false;
        }
        self.summary(old.as_ref()) != self.summary(Some(&st)) || old.map(|o| o.pid) != Some(st.pid)
    }

    /// A player's pidfd said it exited.
    pub fn on_player_exit(&mut self, pid: i64) {
        self.out.unwatch_pid(pid);
        let gone: Vec<String> = self.players.iter().filter(|p| p.1.pid == pid).map(|p| p.0.clone()).collect();
        for n in gone {
            self.pop_player(&n);
            self.out.unlink_if(&n, pid);
        }
        say(&format!("player {pid} exited"));
        self.evaluate("player exited");
    }

    // ---------------------------------------------------------------- inputs
    /// The power key was pressed.
    pub fn on_power(&mut self) {
        self.last_touch = self.out.now();
        self.drop_to_base("power key"); // the screen is about to go off (or on): base first
        self.schedule_hold();
    }

    /// Touch, pen or volume-key input (drained by the caller).
    pub fn on_touch(&mut self) {
        let now = self.out.now();
        if now < self.shield_until {
            // the control centre saw the touch screen send phantom touches right after a mode switch (its own 90/164
            // switches, full modesets). The in-place 120/60/30 switches showed none in the 10-16 tests; if they ever
            // do, ignoring them here keeps a switch from undoing itself. Counted in the status ("shielded_touches").
            self.shielded += 1;
            return;
        }
        self.last_touch = now;
        let base = self.cfg.base_hz;
        if !self.cur_is(base) || !self.expecting_in(base) || self.enter_src.is_some() {
            self.drop_to_base("touch");
        }
        self.schedule_hold();
    }

    fn schedule_hold(&mut self) {
        if self.hold_src.is_none() {
            let ms = (self.cfg.touch_hold_s.f() * 1000.0) as i64 + 50;
            self.hold_src = Some(self.after_ms(ms, T::Hold));
        }
    }

    fn on_hold_end(&mut self) {
        self.hold_src = None;
        let left = self.cfg.touch_hold_s.f() - (self.out.now() - self.last_touch);
        if left > 0.05 {
            self.hold_src = Some(self.after_ms((left * 1000.0) as i64 + 50, T::Hold));
            return;
        }
        self.evaluate("touch hold over");
    }

    // ---------------------------------------------------------------- session
    /// org.freedesktop.ScreenSaver.ActiveChanged
    pub fn on_lock(&mut self, locked: bool) {
        self.locked = locked;
        if locked {
            self.drop_to_base("lock screen");
        } else {
            self.evaluate("unlocked");
        }
    }

    /// logind's PrepareForSleep
    pub fn on_sleep(&mut self, start: bool) {
        if start {
            self.drop_to_base("sleep");
            self.after_ms(1500, T::SleepRelease); // let the switch land, then let logind go on
        } else {
            self.out.take_sleep_lock();
            self.evaluate("resumed");
        }
    }

    /// activeWindow(s resourceClass, b covers, i pid) from the KWin script (the reply has gone out already).
    pub fn on_active_window(&mut self, cls: &str, covers: bool, pid: i64) {
        if pid != self.active.2 {
            self.manual = false;
        }
        self.active = (cls.to_string(), covers, pid);
        self.evaluate(&format!("active window {} (pid {pid}, covers {})", if cls.is_empty() { "-" } else { cls }, py_bool(covers)));
        let now = self.out.now();
        self.fg.log(now, cls, covers, pid); // after the decision, never in its way
    }

    pub fn status(&mut self) -> String {
        let now = self.out.now();
        let opt = |n: Option<Num>| n.map_or(J::Null, Num::json);
        let (expected, target) = (self.expecting(), self.video_target());
        let (cls, covers, pid) = self.active.clone();
        let kv = |k: &str, v: J| (k.to_string(), v);
        json::dumps(&J::Obj(vec![
            kv("base_hz", self.cfg.base_hz.json()),
            kv("cur_hz", self.cur_hz.map_or(J::Null, J::Int)),
            kv("expected_hz", opt(expected)),
            kv("video_target", opt(target)),
            kv("active", J::Arr(vec![J::Str(cls), J::Bool(covers), J::Int(pid)])),
            kv("players", J::Obj(self.players.iter().map(|(n, s)| (n.clone(), s.json())).collect())),
            kv("manual", J::Bool(self.manual)),
            kv("locked", J::Bool(self.locked)),
            kv("touch_age_s", J::Float(json::round1(now - self.last_touch))),
            kv("touch_attached", J::Bool(self.out.touch_attached())),
            kv("shielded_touches", J::Int(self.shielded as i64)),
            kv("backoff", J::Bool(self.backoff_until > now)),
            kv("fg_log_errors", J::Int(self.fg.errors as i64)),
        ]))
    }

    pub fn start_line(&self, touch_inputs: usize) -> String {
        let players: Vec<String> = self.players.iter().map(|p| json::py_str_repr(&p.0)).collect();
        format!("start: base {} Hz, now {} Hz, modes {}, locked {}, players [{}], touch inputs {touch_inputs}", self.cfg.base_hz,
            self.cur_hz.map_or("None".into(), |c| c.to_string()), self.modes_list(), py_bool(self.locked), players.join(", "))
    }

    // ---------------------------------------------------------------- decision
    pub fn video_target(&self) -> Option<Num> {
        let (covers, pid) = (self.active.1, self.active.2);
        if !covers || pid == 0 {
            return None;
        }
        let st = self.players.iter().map(|p| &p.1).find(|s| s.pid == pid)?;
        if !(st.playing && st.fullscreen && !st.osd) {
            return None;
        }
        let hz = pick_hz(st.fps, &self.cfg, self.cfg.base_hz);
        Some(if st.danmaku && hz < self.cfg.danmaku_min_hz { self.cfg.danmaku_min_hz } else { hz })
    }

    /// (hz, recheck): recheck = touched recently, look again when the hold is over.
    fn want(&mut self) -> (Num, bool) {
        let base = self.cfg.base_hz;
        let now = self.out.now();
        if !self.cfg.enabled || self.locked || self.manual || now < self.backoff_until || !self.dpms {
            return (base, false);
        }
        let Some(v) = self.video_target() else { return (base, false) };
        if v >= base || !base.in_(&INPLACE) || !v.in_(&INPLACE) {
            return (base, false);
        }
        if now - self.last_touch < self.cfg.touch_hold_s.f() {
            return (base, true);
        }
        (v, false)
    }

    fn drop_to_base(&mut self, why: &str) {
        if let Some(id) = self.enter_src.take() {
            self.timers.remove(id);
        }
        let base = self.cfg.base_hz;
        if !self.cur_is(base) || !self.expecting_in(base) {
            self.set_hz(base, why);
        }
    }

    pub fn evaluate(&mut self, why: &str) {
        let on = self.video_target().is_some();
        self.out.touch(on);
        let (hz, recheck) = self.want();
        if recheck {
            self.schedule_hold();
        }
        if hz == self.cfg.base_hz {
            self.drop_to_base(why);
            return;
        }
        if self.enter_src.is_none() && (!self.cur_is(hz) || !self.expecting_in(hz)) {
            let ms = (self.cfg.enter_delay_s.f() * 1000.0) as i64;
            self.enter_src = Some(self.after_ms(ms, T::Enter(why.to_string())));
        }
    }

    fn on_enter(&mut self, why: &str) {
        self.enter_src = None;
        let (hz, recheck) = self.want();
        if recheck {
            self.schedule_hold();
        }
        if hz != self.cfg.base_hz && self.out.screen_on() {
            let pid = self.active.2;
            self.set_hz(hz, &format!("{why}: fullscreen video for pid {pid}"));
        }
    }

    /// SIGTERM / SIGINT: STOP into the foreground log, end an in-flight switch, put the base back.
    pub fn stop(&mut self) {
        let now = self.out.now();
        self.fg.mark(now, "STOP"); // never fails: the restore below always runs
        if self.switching.take().is_some() {
            self.out.stop_switch(); // an in-flight switch must not land after ours
        }
        let (kwin, base) = (self.out.kwin_hz(), self.cfg.base_hz);
        restore(kwin, base, "exit", |m| self.out.restore_mode(m));
    }
}

/// restore(): put the base back if the panel is left below it (ExecStopPost: also after a crash or SIGKILL).
pub fn restore(now: Option<i64>, base: Num, why: &str, run: impl FnOnce(&str) -> Result<(), String>) {
    let Some(now) = now else { return };
    if Num::I(now) != base && (now == 30 || now == 60) && base.in_(&BASE_CHOICES) {
        say(&format!("{why}: {now} -> {base} Hz"));
        if let Err(e) = run(&mode_name(base)) {
            say(&format!("{why}: kscreen-doctor failed: {e}"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fg::tests::{claude, Tree};
    use crate::tests::{logged_count, logged_since};
    use std::path::PathBuf;

    /// KWin, kscreen-doctor, the screen, the state directory and /proc as the decision sees them (test-retry-offline.py's
    /// fakes): a switch "runs" for kd.1 s and, if kd.0, sets KWin's mode and writes kwinoutputconfig.json.
    #[derive(Default)]
    struct Fake {
        t: f64,
        hz: i64,
        screen: bool,
        events: bool,
        kd: (bool, f64),
        proc: Option<(f64, String, bool)>,
        started: Vec<(f64, String)>,
        files: BTreeMap<String, String>,
        alive: Vec<i64>,
        watched: Vec<i64>,
        touch: bool,
        restored: Vec<String>,
        saved: Vec<Num>,
        sleep_lock: bool,
    }

    impl Out for Fake {
        fn now(&self) -> f64 {
            self.t
        }
        fn kwin_hz(&mut self) -> Option<i64> {
            Some(self.hz)
        }
        fn kscreen_json(&mut self) -> Result<Vec<u8>, String> {
            Err("not in these tests".into())
        }
        fn switch(&mut self, output: &str, mode: &str) -> Result<(), String> {
            assert_eq!((output, self.proc.is_none()), ("DSI-1", true));
            self.started.push((self.t, mode.into()));
            self.proc = Some((self.t + self.kd.1, mode.into(), self.kd.0));
            Ok(())
        }
        fn kill_switch(&mut self) {
            if let Some(p) = &mut self.proc {
                (p.0, p.2) = (self.t, false);
            }
        }
        fn stop_switch(&mut self) {
            self.proc = None;
        }
        fn restore_mode(&mut self, mode: &str) -> Result<(), String> {
            self.restored.push(mode.into());
            Ok(())
        }
        fn screen_on(&mut self) -> bool {
            self.screen
        }
        fn screen_events(&self) -> bool {
            self.events
        }
        fn save_cfg(&mut self, cfg: &Cfg) -> Result<(), String> {
            self.saved.push(cfg.base_hz);
            Ok(())
        }
        fn touch(&mut self, on: bool) {
            self.touch = on;
        }
        fn touch_attached(&self) -> bool {
            self.touch
        }
        fn read_state(&mut self, name: &str) -> Option<Vec<u8>> {
            self.files.get(name).map(|s| s.as_bytes().to_vec())
        }
        fn pid_exists(&self, pid: i64) -> bool {
            self.alive.contains(&pid)
        }
        fn unlink_if(&mut self, name: &str, pid: i64) {
            if self.files.get(name).is_some_and(|s| s.split_whitespace().any(|w| w == format!("pid={pid}"))) {
                self.files.remove(name);
            }
        }
        fn watch_pid(&mut self, pid: i64) {
            if !self.watched.contains(&pid) {
                self.watched.push(pid);
            }
        }
        fn unwatch_pid(&mut self, pid: i64) {
            self.watched.retain(|p| *p != pid);
        }
        fn take_sleep_lock(&mut self) {
            self.sleep_lock = true;
        }
        fn release_sleep_lock(&mut self) {
            self.sleep_lock = false;
        }
    }

    /// The daemon as its start leaves it, minus D-Bus / files / evdev (test-retry-offline.py's daemon()).
    fn daemon() -> Ra<Fake> {
        let fake = Fake { t: 1000.0, hz: 120, screen: true, kd: (true, 0.2), sleep_lock: true, ..Fake::default() };
        let mut a = Ra::new(fake, Cfg::default(), Fg::at(PathBuf::from("/nonexistent/y700-battery"), "/proc", "/sys/fs/cgroup"));
        a.modes = [30, 60, 90, 120, 164].map(|h| (h, mode_name(Num::I(h)))).into();
        a.cur_hz = Some(120);
        a.dpms = true;
        a
    }

    /// Runs the virtual clock for secs: timers and the fake kscreen-doctor's end, in time order.
    fn run(a: &mut Ra<Fake>, secs: f64) {
        let end = a.out.t + secs;
        loop {
            let proc = a.out.proc.as_ref().map(|p| p.0);
            let Some(next) = proc.into_iter().chain(a.next_deadline()).min_by(f64::total_cmp) else { break };
            if next > end {
                break;
            }
            a.out.t = a.out.t.max(next);
            if proc == Some(next) {
                let (_, mode, ok) = a.out.proc.take().unwrap();
                if ok {
                    a.out.hz = mode.rsplit('@').next().unwrap().parse().unwrap();
                    a.on_kwinconf();
                }
                a.on_mode_done(ok);
            } else {
                a.on_timer();
            }
        }
        a.out.t = end;
    }

    fn state(pid: i64, playing: bool, fullscreen: bool, fps: f64) -> String {
        format!("pid={pid}\nplaying={}\nfullscreen={}\nosd=0\ndanmaku=0\nfps={fps:.3}\n", playing as u8, fullscreen as u8)
    }

    /// mpv's script writes its state file (tmp + rename: one MOVED_TO).
    fn mpv(a: &mut Ra<Fake>, playing: bool, fullscreen: bool, fps: f64) {
        if !a.out.alive.contains(&4242) {
            a.out.alive.push(4242);
        }
        a.out.files.insert("mpv-4242".into(), state(4242, playing, fullscreen, fps));
        a.on_statedir("mpv-4242", false);
    }

    /// test-retry-offline.py's video(): a fullscreen player, the active window.
    fn video(a: &mut Ra<Fake>, fps: f64) {
        mpv(a, true, true, fps);
        a.active = ("mpv".into(), true, 4242);
        a.evaluate("player state");
    }

    fn touch(a: &mut Ra<Fake>) {
        a.last_touch = a.out.t;
        a.drop_to_base("touch");
    }

    #[test]
    fn decide() {
        // --decide-test's table
        let cfg = Cfg::default();
        for (fps, want) in [(29.97, 30), (30.0, 30), (59.94, 60), (60.0, 60), (23.976, 120), (24.0, 120), (25.0, 120), (50.0, 120),
            (48.0, 120), (45.0, 120), (120.0, 120), (90.0, 120), (0.0, 120), (15.0, 30), (20.0, 60), (10.0, 30), (144.0, 120), (37.5, 120)]
        {
            assert_eq!(pick_hz(fps, &cfg, Num::I(120)), Num::I(want), "{fps}");
        }
        assert_eq!(pick_hz(f64::NAN, &cfg, Num::I(120)), Num::I(120));
        let odd = Cfg { unknown_fps_hz: Num::F(60.7), map: vec![[Num::I(29), Num::I(31), Num::F(0.0)]], ..Cfg::default() };
        assert!(matches!(pick_hz(-1.0, &odd, Num::I(120)), Num::I(60))); // int(60.7)
        assert!(matches!(pick_hz(30.0, &odd, Num::F(120.0)), Num::F(_))); // hz 0: the base, as it is
    }

    #[test]
    fn config() {
        let before = logged_count();
        assert_eq!(Cfg::load(None), Cfg::default());
        assert_eq!(Cfg::load(Some("[1]")), Cfg::default());
        assert_eq!(Cfg::load(Some("{\"base_hz\": ")), Cfg::default());
        assert_eq!(Cfg::default().to_json(), "{\n \"enabled\": true,\n \"base_hz\": 120,\n \"enter_delay_s\": 1.5,\n \"touch_hold_s\": 3.0,\n \"unknown_fps_hz\": 0,\n \"danmaku_min_hz\": 60,\n \"map\": [\n  [\n   29.0,\n   31.0,\n   30\n  ],\n  [\n   58.0,\n   61.0,\n   60\n  ],\n  [\n   14.5,\n   15.5,\n   30\n  ],\n  [\n   19.5,\n   20.5,\n   60\n  ],\n  [\n   9.5,\n   10.5,\n   30\n  ]\n ]\n}");
        assert!(logged_since(before).is_empty());
        let c = Cfg::load(Some("{\"base_hz\": 164.0, \"x\": 1, \"enabled\": 0, \"touch_hold_s\": -1, \"danmaku_min_hz\": true, \
            \"enter_delay_s\": \"2\", \"unknown_fps_hz\": Infinity, \"map\": [[1, 2, 30], [0, 1e9, 60]], \"base_hz\": 90}"));
        assert_eq!((c.base_hz, c.enabled, c.touch_hold_s, c.map.len()), (Num::I(90), true, Num::F(3.0), 2));
        assert!(matches!(c.base_hz, Num::I(90))); // the last of a repeated key
        assert_eq!(logged_since(before), ["config: ignoring enabled=0 (wrong type)", "config: ignoring touch_hold_s=-1 (wrong type)",
            "config: ignoring danmaku_min_hz=True (wrong type)", "config: ignoring enter_delay_s='2' (wrong type)",
            "config: ignoring unknown_fps_hz=inf (wrong type)"]);
        let before = logged_count();
        for bad in ["[[1, 2]]", "[[1, 2, true]]", "[[1, 2, NaN]]", "[1]", "{}"] {
            assert_eq!(Cfg::load(Some(&format!("{{\"map\": {bad}}}"))).map, Cfg::default().map);
        }
        assert_eq!(logged_since(before).len(), 5);
        // a float base is kept a float: saved and printed as such
        let c = Cfg::load(Some("{\"base_hz\": 60.0, \"map\": [[-Infinity, Infinity, 30]]}"));
        assert!(c.to_json().contains("\"base_hz\": 60.0") && c.to_json().contains("[\n   -Infinity,\n   Infinity,\n   30\n  ]"));
        assert_eq!((format!("{}", c.base_hz), mode_name(c.base_hz)), ("60.0".into(), "1904x3040@60.0".into()));
    }

    #[test]
    fn state_files() {
        let st = parse_state(b"pid=4242\nplaying=1\nfullscreen=1\nosd=0\ndanmaku=1\nfps=29.970\n").unwrap();
        assert_eq!(st, St { pid: 4242, playing: true, fullscreen: true, osd: false, danmaku: true, fps: 29.97 });
        // CR line ends, padding, a later line wins, no fps, a key without '=' ignored
        let st = parse_state(b"pid=1\r\n  playing=1 \rplaying=0\nfps=\nfullscreen\n pid = 7\n").unwrap();
        assert_eq!((st.pid, st.playing, st.fps), (1, false, 0.0)); // "pid " is another key
        assert_eq!(parse_state(b"").map(|s| s.pid), Some(0));
        assert_eq!(parse_state(b"pid=x\n"), None);
        assert_eq!(parse_state(b"fps=fast\n"), None);
        assert_eq!(parse_state(b"pid=1\xff\n"), None);
        assert!(parse_state(b"fps=nan\n").unwrap().fps.is_nan());
    }

    #[test]
    fn kwin_and_kscreen_json() {
        let kconf = r#"[{"name": "outputs", "data": [{"connectorName": "DP-1", "mode": {"refreshRate": 60000}},
            {"connectorName": "DSI-1", "mode": {"refreshRate": 119880, "width": 1904}}]}, {"name": "setups"}]"#;
        assert_eq!(kwin_hz_of(kconf), Some(120));
        assert_eq!(kwin_hz_of(&kconf.replace("119880", "30500")), Some(30)); // 30.5: halves to even
        assert_eq!(kwin_hz_of(&kconf.replace("119880", "\"x\"")), None);
        assert_eq!(kwin_hz_of("{"), None);
        let kd = br#"{"outputs": [{"name": "DSI-1", "currentModeId": "3", "modes": [
            {"id": "1", "refreshRate": 120.00199890136719, "size": {"height": 3040, "width": 1904}},
            {"id": "2", "refreshRate": 59.99, "size": {"height": 3040, "width": 1904}},
            {"id": "3", "refreshRate": 29.5, "size": {"height": 3040, "width": 1904}},
            {"id": "4", "refreshRate": 60.0, "size": {"height": 1080, "width": 1920}}]}]}"#;
        assert_eq!(current_of(kd), Some(30));
        let mut a = daemon();
        a.modes.clear();
        a.output = String::new();
        a.take_modes(kd).unwrap();
        assert_eq!((a.output.as_str(), a.modes_list()), ("DSI-1", "[30, 60, 120]".to_string()));
        assert_eq!(a.modes[&30], "1904x3040@30");
        assert_eq!(a.take_modes(b"").unwrap_err(), "Expecting value: line 1 column 1 (char 0)");
        assert_eq!(a.take_modes(b"[]").unwrap_err(), "'list' object has no attribute 'get'");
        assert_eq!(a.take_modes(b"{\"outputs\": 5}").unwrap_err(), "'int' object is not iterable");
        assert_eq!(a.take_modes(b"{\"outputs\": [{\"name\": 1}]}").unwrap_err(), "'int' object has no attribute 'startswith'");
        assert_eq!(a.take_modes(b"{\"outputs\": [{\"name\": \"DSI-1\", \"modes\": [{\"refreshRate\": \"x\"}]}]}").unwrap_err(),
            "type str doesn't define __round__ method");
        assert_eq!(a.take_modes(b"\xff").unwrap_err(), "'utf-8' codec can't decode byte 0xff in position 0: invalid start byte");
        // no modes: kscreen-doctor -j is asked again every 2 s, and the decision runs once they are there
        let before = logged_count();
        let mut a = daemon();
        a.modes.clear();
        a.read_modes();
        run(&mut a, 4.5);
        assert_eq!(logged_since(before), ["kscreen-doctor -j failed: not in these tests"; 3]);
    }

    // ---------------------------------------------------------------- test-retry-offline.py
    #[test]
    fn fail_on_and_fail_off() {
        // 60 s of failing switches; with 1, 2, 4, 8, 16, 30 s waits that is at most ~8 starts
        for screen in [true, false] {
            let mut a = daemon();
            video(&mut a, 30.0);
            run(&mut a, 3.0);
            let lowered = a.out.hz;
            a.out.kd = (false, 0.05);
            let n0 = a.out.started.len();
            a.out.screen = screen;
            touch(&mut a);
            run(&mut a, 60.0);
            let n = a.out.started.len() - n0;
            assert!(lowered == 30 && n <= 10, "screen {screen}: lowered to {lowered}, {n} started");
        }
    }

    #[test]
    fn recover() {
        // the screen goes off at 30 Hz (must go back to the base), switching fails 5 s, then works: tries at 0, 1, 3, 7 s
        for events in [false, true] {
            let mut a = daemon();
            a.out.events = events;
            video(&mut a, 30.0);
            run(&mut a, 3.0);
            assert_eq!(a.out.hz, 30);
            a.out.kd = (false, 0.05);
            a.out.screen = false;
            a.on_screen();
            run(&mut a, 5.0);
            a.out.kd = (true, 0.2);
            run(&mut a, 5.0);
            assert!(a.out.hz == 120 && a.fails == 0, "events {events}: hz={} fails={}", a.out.hz, a.fails);
        }
    }

    #[test]
    fn normal() {
        // lowering after 1.5 s, back at once on a touch
        let mut a = daemon();
        video(&mut a, 30.0);
        run(&mut a, 1.0);
        let h1 = a.out.hz;
        run(&mut a, 1.0);
        let h2 = a.out.hz;
        touch(&mut a);
        run(&mut a, 0.5);
        assert_eq!((h1, h2, a.out.hz), (120, 30, 120));
        assert_eq!(a.out.started.iter().map(|s| s.1.as_str()).collect::<Vec<_>>(), ["1904x3040@30", "1904x3040@120"]);
        assert_eq!(a.out.started[0].0, 1001.5); // enter_delay_s after the report
    }

    // ---------------------------------------------------------------- test-refresh-auto.sh / -2.sh, offline
    #[test]
    fn video_session() {
        let before = logged_count();
        let mut a = daemon();
        video(&mut a, 30.0);
        run(&mut a, 2.0);
        assert_eq!((a.out.hz, a.out.touch, a.out.watched.clone()), (30, true, vec![4242]));
        mpv(&mut a, false, true, 30.0); // paused
        run(&mut a, 1.0);
        assert_eq!((a.out.hz, a.out.touch), (120, false));
        mpv(&mut a, true, true, 30.0);
        run(&mut a, 2.0);
        assert_eq!(a.out.hz, 30);
        mpv(&mut a, true, true, 60.0); // a 60 fps clip
        run(&mut a, 2.0);
        assert_eq!(a.out.hz, 60);
        mpv(&mut a, true, false, 60.0); // left fullscreen
        run(&mut a, 1.0);
        assert_eq!(a.out.hz, 120);
        mpv(&mut a, true, true, 60.0);
        run(&mut a, 2.0);
        assert_eq!(a.out.hz, 60);
        // speed: the script writes the effective fps
        for (fps, hz) in [(90.0, 120), (120.0, 120), (60.0, 60)] {
            mpv(&mut a, true, true, fps);
            run(&mut a, 2.0);
            assert_eq!(a.out.hz, hz, "{fps} fps");
        }
        // quit: the pidfd fires, the state file goes
        a.out.alive.clear();
        a.on_player_exit(4242);
        run(&mut a, 1.0);
        assert_eq!((a.out.hz, a.out.files.len(), a.players.len(), a.out.watched.len()), (120, 0, 0, 0));
        let logs = logged_since(before);
        assert_eq!(logs[0], "120 -> 30 Hz (player state: fullscreen video for pid 4242)");
        assert_eq!(logs[1], "30 -> 120 Hz (player state)");
        assert_eq!(logs[logs.len() - 2..], ["player 4242 exited", "60 -> 120 Hz (player exited)"]);
        assert!(logs.iter().all(|l| l.contains(" -> ") || l == "player 4242 exited"), "{logs:?}");
    }

    #[test]
    fn danmaku_and_unknown() {
        let mut a = daemon();
        a.active = ("wiliwili".into(), true, 4242);
        a.out.alive.push(4242);
        a.out.files.insert("wiliwili".into(), "pid=4242\nplaying=1\nfullscreen=1\nosd=0\ndanmaku=1\nfps=30.000\n".into());
        a.on_statedir("wiliwili", false);
        run(&mut a, 2.0);
        assert_eq!(a.out.hz, 60); // danmaku: at least danmaku_min_hz
        a.out.files.insert("wiliwili".into(), "pid=4242\nplaying=1\nfullscreen=1\nosd=1\ndanmaku=1\nfps=30.000\n".into());
        a.on_statedir("wiliwili.tmp", false); // the writer's temp file: nothing
        run(&mut a, 1.0);
        assert_eq!(a.out.hz, 60);
        a.on_statedir("wiliwili", false); // the OSD is up
        run(&mut a, 1.0);
        assert_eq!(a.out.hz, 120);
        a.out.files.insert("wiliwili".into(), "pid=4242\nplaying=1\nfullscreen=1\nfps=0\n".into());
        a.on_statedir("wiliwili", false);
        run(&mut a, 3.0);
        assert_eq!(a.out.hz, 120); // unknown fps: the base
        a.out.files.remove("wiliwili");
        a.on_statedir("wiliwili", true); // deleted
        assert!(a.players.is_empty());
        // a state file of a process that is gone is removed; one with pid=0 too (unlink_if matches "pid=0")
        a.out.files.insert("mpv-9".into(), state(9, true, true, 30.0));
        a.out.files.insert("odd".into(), "playing=1\n".into());
        a.out.files.insert("zero".into(), "pid=0\n".into());
        for n in ["mpv-9", "odd", "zero"] {
            a.on_statedir(n, false);
        }
        assert_eq!(a.out.files.keys().collect::<Vec<_>>(), ["odd"]);
    }

    #[test]
    fn screen_off_guard() {
        for events in [false, true] {
            let mut a = daemon();
            a.out.events = events;
            video(&mut a, 30.0);
            run(&mut a, 2.0);
            assert_eq!(a.out.hz, 30);
            assert_eq!(a.dpms_src.is_some(), !events, "the tick runs only without KWin's events");
            run(&mut a, 30.0);
            // while a video plays at 30 Hz: with KWin's events nothing at all is pending, without them the 1 s tick
            assert_eq!(a.timers.q.len(), !events as usize, "events {events}: {:?}", a.timers.q);
            a.out.screen = false;
            a.on_screen(); // KWin's event (nothing without events)
            run(&mut a, if events { 0.3 } else { 1.3 });
            assert_eq!(a.out.hz, 120, "events {events}");
            run(&mut a, 2.0);
            assert_eq!((a.dpms_src, a.watching, a.timers.q.len()), (None, false, 0), "events {events}");
            // never lowered with the screen off; lit again and a state change: down again
            mpv(&mut a, false, true, 30.0);
            mpv(&mut a, true, true, 30.0);
            run(&mut a, 3.0);
            assert_eq!(a.out.hz, 120);
            a.out.screen = true;
            a.on_screen();
            mpv(&mut a, false, true, 30.0);
            mpv(&mut a, true, true, 30.0);
            run(&mut a, 2.0);
            assert_eq!(a.out.hz, 30, "events {events}");
        }
        // KWin's events go away below the base: back to the tick
        let mut a = daemon();
        a.out.events = true;
        video(&mut a, 30.0);
        run(&mut a, 2.0);
        a.out.events = false;
        a.on_events_lost();
        a.out.screen = false;
        run(&mut a, 1.3);
        assert_eq!(a.out.hz, 120);
    }

    #[test]
    fn power_lock_sleep() {
        let mut a = daemon();
        video(&mut a, 30.0);
        run(&mut a, 2.0);
        a.on_power();
        run(&mut a, 0.5);
        assert_eq!(a.out.hz, 120);
        run(&mut a, 4.5); // the hold is over (3.05 s), then enter_delay_s: down again
        assert_eq!(a.out.hz, 30);
        a.on_lock(true);
        run(&mut a, 3.0);
        assert_eq!(a.out.hz, 120);
        a.on_lock(false);
        run(&mut a, 2.0);
        assert_eq!(a.out.hz, 30);
        a.on_sleep(true);
        run(&mut a, 1.0);
        assert_eq!((a.out.hz, a.out.sleep_lock), (120, true));
        run(&mut a, 1.0);
        assert!(!a.out.sleep_lock); // released 1.5 s after PrepareForSleep
        a.on_sleep(false);
        assert!(a.out.sleep_lock);
        run(&mut a, 2.0);
        assert_eq!(a.out.hz, 30);
        // a touch while lowered: base, then down again after the hold; one right after our own switch is shielded
        run(&mut a, 5.0);
        a.on_touch();
        run(&mut a, 0.5);
        assert_eq!(a.out.hz, 120);
        run(&mut a, 4.5);
        assert_eq!(a.out.hz, 30);
        a.on_touch();
        assert_eq!(a.shielded, 1);
        assert_eq!(a.out.hz, 30);
    }

    #[test]
    fn foreign_switches() {
        let before = logged_count();
        let mut a = daemon();
        video(&mut a, 60.0);
        run(&mut a, 2.0);
        assert_eq!(a.out.hz, 60);
        mpv(&mut a, false, true, 60.0); // paused
        run(&mut a, 1.0);
        assert_eq!(a.out.hz, 120);
        // a foreign switch to 30 is not taken as the base; the daemon goes back to it
        a.out.hz = 30;
        a.on_kwinconf();
        run(&mut a, 1.0);
        assert_eq!((a.out.hz, a.cfg.base_hz, a.out.saved.len()), (120, Num::I(120), 0));
        // watchdog-style 120 -> 60 while a 60 fps video wants 60
        mpv(&mut a, true, true, 60.0);
        run(&mut a, 2.0);
        assert_eq!(a.out.hz, 60);
        a.out.hz = 120;
        a.on_kwinconf();
        run(&mut a, 1.0);
        a.out.hz = 60;
        a.on_kwinconf();
        run(&mut a, 2.0);
        assert_eq!(a.cfg.base_hz, Num::I(120));
        mpv(&mut a, false, true, 60.0);
        run(&mut a, 1.0);
        assert_eq!(a.out.hz, 120);
        // 164 from the tile: the new base; a 30 fps video is not lowered (164 <-> 30 would be a full modeset)
        a.out.hz = 164;
        a.on_kwinconf();
        run(&mut a, 1.0);
        assert_eq!((a.cfg.base_hz, a.out.saved.last()), (Num::I(164), Some(&Num::I(164))));
        let n = a.out.started.len();
        mpv(&mut a, true, true, 30.0);
        run(&mut a, 5.0);
        assert_eq!((a.out.hz, a.out.started.len()), (164, n));
        // back to 120 while the video plays: the new base, and the owner's choice is respected until the state changes
        a.out.hz = 120;
        a.on_kwinconf();
        run(&mut a, 3.0);
        assert_eq!((a.cfg.base_hz, a.manual, a.out.hz), (Num::I(120), true, 120));
        mpv(&mut a, false, true, 30.0);
        mpv(&mut a, true, true, 30.0);
        run(&mut a, 2.0);
        assert_eq!((a.manual, a.out.hz), (false, 30));
        let logs = logged_since(before);
        for l in ["mode changed to 30 Hz by someone else: not taken as the base", "mode changed to 60 Hz by someone else: not taken as the base",
            "mode changed to 164 Hz by someone else: new base 164 Hz", "mode changed to 120 Hz by someone else: new base 120 Hz"]
        {
            assert!(logs.iter().any(|x| x == l), "{l}: {logs:?}");
        }
    }

    #[test]
    fn late_write_and_kill() {
        let before = logged_count();
        let mut a = daemon();
        // kscreen-doctor hangs: killed after 5 s, counted as a failure
        a.out.kd = (true, 30.0);
        video(&mut a, 30.0);
        run(&mut a, 7.0);
        assert_eq!((a.fails, a.out.hz, a.out.proc.is_none()), (1, 120, true));
        let logs = logged_since(before);
        assert_eq!(logs[1..], ["kscreen-doctor still running after 5 s: killed", "kscreen-doctor did not switch to 30 Hz"]);
        // its write landing late (within 10 s of asking) is ours: no new base
        a.out.hz = 30;
        a.on_kwinconf();
        run(&mut a, 0.2);
        assert_eq!((a.cfg.base_hz, a.cur_hz), (Num::I(120), Some(30)));
        assert!(logged_since(before).iter().all(|l| !l.contains("someone else")));
    }

    #[test]
    fn no_mode_and_no_dpms() {
        let before = logged_count();
        let mut a = daemon();
        a.cfg.map[0][2] = Num::I(45);
        video(&mut a, 30.0);
        run(&mut a, 2.0);
        video(&mut a, 30.0);
        run(&mut a, 2.0);
        assert_eq!(a.out.hz, 120);
        let logs = logged_since(before);
        assert!(logs.is_empty(), "45 is not in place: never asked for {logs:?}");
        a.cfg.map[0][2] = Num::I(30);
        a.modes.remove(&30);
        video(&mut a, 30.0);
        run(&mut a, 2.0);
        video(&mut a, 30.0);
        run(&mut a, 2.0);
        assert_eq!(logged_since(before), ["no 30 Hz mode known ([60, 90, 120, 164]): not switching (player state: fullscreen video for pid 4242)"]);
        let mut a = daemon();
        a.dpms = false;
        video(&mut a, 30.0);
        run(&mut a, 3.0);
        assert_eq!(a.out.started.len(), 0);
    }

    // ---------------------------------------------------------------- test-log-fg.py: on_call, start / stop, status
    #[test]
    fn report_decides_then_logs() {
        let t = Tree::new("oncall");
        let mut a = daemon();
        a.fg = t.fg();
        let before = logged_count();
        a.on_active_window("mpv", true, 999999);
        assert_eq!(a.active, ("mpv".to_string(), true, 999999));
        assert_eq!(t.lines(), ["1000.00 999999 1 - - - mpv\n"]);
        assert!(logged_since(before).is_empty());
        // a dead pid after a known one: the old unit's usage still closes its segment
        let t = Tree::new("oncall2");
        let mut a = daemon();
        a.fg = t.fg();
        t.pid(16803, &format!("0::{}\n", claude()));
        t.cpu(&claude(), 812345);
        a.on_active_window("Claude", true, 16803);
        a.out.t = 1010.5;
        t.cpu(&claude(), 900000);
        a.on_active_window("mpv", false, 999999);
        a.out.t = 1011.0;
        a.on_active_window("mpv", true, 999999);
        assert_eq!(t.lines(), [format!("1000.00 16803 1 812345 - {} Claude\n", claude()), "1010.50 999999 0 - 900000 - mpv\n".into(),
            "1011.00 999999 1 - - - mpv\n".into()]);
        // the decision ran before the line: a fullscreen player reported is lowered whatever the log does
        std::fs::remove_file(t.path(None)).unwrap();
        std::fs::create_dir(t.path(None)).unwrap(); // the log's name taken by a directory: open() fails
        video(&mut a, 30.0);
        a.on_active_window("mpv", true, 4242);
        a.on_active_window("mpv", true, 4242);
        run(&mut a, 2.0);
        assert_eq!((a.out.hz, a.fg.errors), (30, 2));
        assert_eq!(logged_since(before).iter().filter(|l| l.starts_with("foreground log failed")).count(), 1);
    }

    #[test]
    fn status_reply() {
        let t = Tree::new("status");
        let mut a = daemon();
        a.fg = t.fg();
        a.fg.errors = 4;
        a.out.t = 24547.2;
        assert_eq!(a.status(), "{\"base_hz\": 120, \"cur_hz\": 120, \"expected_hz\": null, \"video_target\": null, \"active\": [\"\", false, 0], \
            \"players\": {}, \"manual\": false, \"locked\": false, \"touch_age_s\": 24547.2, \"touch_attached\": false, \"shielded_touches\": 0, \
            \"backoff\": false, \"fg_log_errors\": 4}");
        assert!(t.names().is_empty()); // a status call writes nothing
        a.out.t = 1000.0;
        a.last_touch = 0.0;
        video(&mut a, 29.97);
        run(&mut a, 1.6); // the switch to 30 is running
        let s = a.status();
        assert!(s.contains("\"cur_hz\": 120, \"expected_hz\": 30, \"video_target\": 30, \"active\": [\"mpv\", true, 4242], \"players\": {\"mpv-4242\": \
            {\"pid\": 4242, \"playing\": true, \"fullscreen\": true, \"osd\": false, \"danmaku\": false, \"fps\": 29.97}}"), "{s}");
        assert!(s.contains("\"touch_age_s\": 1001.6, \"touch_attached\": true"), "{s}");
        assert_eq!(a.start_line(3), "start: base 120 Hz, now 120 Hz, modes [30, 60, 90, 120, 164], locked False, players ['mpv-4242'], touch inputs 3");
    }

    #[test]
    fn start_stop() {
        let t = Tree::new("startstop");
        let mut a = daemon();
        a.fg = t.fg();
        t.pid(16803, &format!("0::{}\n", claude()));
        t.cpu(&claude(), 100);
        a.fg.mark(1000.0, "START");
        a.out.t = 1000.25;
        a.on_active_window("Claude", true, 16803);
        a.out.t = 1100.5;
        a.stop();
        assert!(a.out.restored.is_empty()); // at the base: nothing to restore
        a.out.t = 1200.0;
        a.fg.mark(1200.0, "START"); // a restart: no prev_usage across it
        a.on_active_window("Claude", true, 16803);
        assert_eq!(t.lines(), ["1000.00 START\n".to_string(), format!("1000.25 16803 1 100 - {} Claude\n", claude()), "1100.50 STOP\n".into(),
            "1200.00 START\n".into(), format!("1200.00 16803 1 100 - {} Claude\n", claude())]);
        // stopped while a switch to 30 is in flight and KWin already at 30: the switch is ended, the base put back,
        // even though the log fails
        let before = logged_count();
        std::fs::remove_file(t.path(None)).unwrap();
        std::fs::create_dir(t.path(None)).unwrap();
        a.out.kd = (true, 3.0);
        video(&mut a, 30.0);
        run(&mut a, 1.6);
        assert!(a.out.proc.is_some());
        a.out.hz = 30;
        a.stop();
        assert_eq!((a.out.proc.is_none(), a.out.restored.clone(), a.fg.errors), (true, vec!["1904x3040@120".to_string()], 1));
        assert_eq!(logged_since(before)[2..], ["exit: 30 -> 120 Hz"]);
        let before = logged_count();
        restore(Some(60), Num::I(90), "restore", |_| Err("g-exec-error-quark: x (8)".into()));
        restore(Some(30), Num::I(30), "restore", |_| panic!("30 is never a base to restore"));
        restore(Some(90), Num::I(120), "restore", |_| panic!("only 30 and 60 are put back"));
        restore(None, Num::I(120), "restore", |_| panic!("KWin's mode unknown"));
        assert_eq!(logged_since(before), ["restore: 60 -> 90 Hz", "restore: kscreen-doctor failed: g-exec-error-quark: x (8)"]);
    }
}
