//! y700-batteryd - the battery page's resident recorder (linux/power/battery/DESIGN.md sections 1-2). A systemd user
//! service of user (Slice=background.slice, idle scheduling) that appends snapshots of absolute counters - CPU time per cgroup
//! unit, per-cluster busy time and frequency, GPU time per unit, wake-ups per unit, flightrec's energy totals - as JSON
//! lines to ~/.local/state/y700-battery/b-<boot8>.jsonl (line formats: snap.rs; files: ledger.rs). No D-Bus, no current
//! reads, no live.log: flightrec (root) integrates the battery current into /run/y700-flightrec/energy and announces
//! screen and power-direction changes by renaming /run/y700-flightrec/edge.
//!
//! What wakes it (one poll, no periodic timer of its own):
//!   - signalfd: TERM/INT -> a last snapshot + fdatasync, exit 0; USR1 (the page) -> a snapshot now, one per 10 s at most
//!   - inotify on /run/y700-flightrec, IN_MOVED_TO only, the name "edge" only: dpms or pw changed
//!   - the poll timeout: a snapshot every 300 s with the screen on, a checkpoint every 1800 s with it off
//!     (TimerSlackNSec=10s in the unit lets the kernel fold it into another wake-up)
//!   - a CLOCK_REALTIME timerfd armed for 2100 with TFD_TIMER_CANCEL_ON_SET: the wall clock was stepped -> a K line
//! Whatever woke it, the edge file is read again and its (dpms, pw) compared with the recorder's own (评审修订):
//! dpms changed -> an "on"/"off" snapshot; pw alone changed -> a "pw" snapshot, but not within 60 s of the last edge
//! snapshot (flightrec is Restart=always and rewrites the edge at every start: a crash loop must not drive full
//! snapshots); nothing changed -> nothing. The next timeout follows the dpms read.
//! 降级模式 (cov:0), checked at every wake: flightrec not running (daemon.pid + /proc/<pid>/comm), its energy line older
//! than 60 s (t=0 before its first data line: the start edge's t counts) or of another boot, no edge file, or no
//! inotify watch (flightrec makes the directory; an autologin session can come first, the watch is retried at every
//! wake): the screen state is read from card1-DSI-1/dpms, pw is unknown, the cadence is the same.
//! The thread scan (wk) runs only at the screen-off edge, the screen-off checkpoints and the screen-on edge; fdatasync
//! only at the screen-off edge, the screen-off checkpoints and TERM; the battery's status/capacity only at start and
//! at pw edges (each a firmware round trip).
//! Errors never end it (评审修订): a failed write, parse or unit read is logged once and skipped until the next planned
//! snapshot; nothing on the daemon's paths unwraps or panics.
//! Start order: signals blocked + signalfd, then the flock on <state>/lock (held elsewhere -> exit 0), then the pid file
//! the page signals ($XDG_RUNTIME_DIR/y700-battery/pid): a USR1 before the signalfd would have killed it.
//!
//! Usage: y700-batteryd                       the daemon (y700-batteryd.service)
//!        y700-batteryd --once                one full snapshot over 1 s to stdout; no lock, no ledger
//!        y700-batteryd --bench N             time N light snapshots and N thread scans; no lock, no ledger
//!        [--state-dir DIR] [--run-dir DIR]   instead of $XDG_STATE_HOME/y700-battery, $XDG_RUNTIME_DIR/y700-battery

/// eprintln! without its panic (fds::log_args); defined before the modules so that all of them see it
macro_rules! elog {
    ($($a:tt)*) => {
        $crate::fds::log_args(format_args!($($a)*))
    };
}

mod clock;
mod fds;
mod gpu;
mod ledger;
mod snap;
mod threads;
mod units;

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use clock::Clock;
use fds::{Inotify, Lock, LogOnce};
use gpu::Gpu;
use ledger::Ledger;
use snap::{Light, SLine};
use threads::Threads;
use units::Units;

const RUN_DIR: &str = "/run/y700-flightrec";
const DPMS: &str = "/sys/class/drm/card1-DSI-1/dpms";
const BAT: &str = "/sys/class/power_supply/qcom-battmgr-bat";
const CGROOT: &str = "/sys/fs/cgroup";
const IFACE: &str = "wlp1s0";
const ON_S: f64 = 300.0; // snapshot period, screen on
const OFF_S: f64 = 1800.0; // checkpoint period, screen off
const EDGE_GAP_S: f64 = 60.0; // pw-only edge snapshots at least this far apart
const REQ_GAP_S: f64 = 10.0; // USR1 honoured once per this
const STALE_MS: i64 = 60_000; // an energy line older than this: flightrec is not integrating
const PRUNE_EVERY_S: f64 = 86400.0;
const EARLY_S: f64 = 0.5; // a timeout this close to due counts as due
const USAGE: &str = "usage: y700-batteryd [--once | --bench N] [--state-dir DIR] [--run-dir DIR]";

#[derive(Clone, Copy, Debug, PartialEq)]
enum Why {
    Start,
    On,
    Off,
    Pw,
    Ck,
    Req,
    Term,
    Once,
}

impl Why {
    fn name(self) -> &'static str {
        match self {
            Why::Start => "start",
            Why::On => "on",
            Why::Off => "off",
            Why::Pw => "pw",
            Why::Ck => "ck",
            Why::Req => "req",
            Why::Term => "term",
            Why::Once => "once",
        }
    }
}

// ---- cadence (pure)
/// what the recorder believes and when it last wrote
struct Cad {
    dpms: Option<bool>,
    pw: Option<&'static str>,
    last_snap: f64,
    last_edge: f64,
    last_req: f64,
}

/// what one wake found
struct Seen {
    now: f64,
    dpms: Option<bool>,
    pw: Option<&'static str>,
    usr1: bool,
    term: bool,
}

struct Plan {
    why: Option<Why>,
    pw_edge: bool, // pw changed with this snapshot: read the battery's status and capacity
    wake_at: f64,
}

fn period(dpms: Option<bool>) -> f64 {
    if dpms == Some(false) {
        OFF_S
    } else {
        ON_S
    }
}

/// the snapshot (if any) this wake takes, and when to wake next. A first known value (the edge file appeared, a
/// degraded read worked) is taken silently; an unknown value never makes an edge.
fn decide(c: &mut Cad, s: &Seen) -> Plan {
    let dpms_edge = matches!((c.dpms, s.dpms), (Some(a), Some(b)) if a != b);
    let pw_changed = matches!((c.pw, s.pw), (Some(a), Some(b)) if a != b);
    if c.dpms.is_none() {
        c.dpms = s.dpms;
    }
    if c.pw.is_none() {
        c.pw = s.pw;
    }
    let why = if s.term {
        Some(Why::Term)
    } else if dpms_edge {
        Some(if s.dpms == Some(true) { Why::On } else { Why::Off })
    } else if pw_changed && s.now - c.last_edge >= EDGE_GAP_S {
        Some(Why::Pw)
    } else if s.usr1 && s.now - c.last_req >= REQ_GAP_S {
        Some(Why::Req)
    } else if s.now + EARLY_S >= c.last_snap + period(c.dpms) {
        Some(Why::Ck)
    } else {
        None
    };
    let mut pw_edge = false;
    if let Some(w) = why {
        c.last_snap = s.now;
        if matches!(w, Why::On | Why::Off | Why::Pw) {
            c.last_edge = s.now;
        }
        if w == Why::Req {
            c.last_req = s.now;
        }
        if s.dpms.is_some() {
            c.dpms = s.dpms;
        }
        if pw_changed {
            c.pw = s.pw;
            pw_edge = true;
        }
    }
    let mut wake_at = c.last_snap + period(c.dpms);
    if pw_changed && why.is_none() {
        wake_at = wake_at.min(c.last_edge + EDGE_GAP_S); // the deferred pw edge
    }
    Plan { why, pw_edge, wake_at }
}

/// when flightrec last wrote, ms: the energy line's t is its last data line's, 0 until the first one of the boot (up to
/// ~10 s after its first start); until then the edge file it writes at every start stands in
fn last_ms(energy_t: i64, edge_t: Option<f64>) -> i64 {
    if energy_t > 0 {
        return energy_t;
    }
    edge_t.filter(|t| t.is_finite() && *t > 0.0).map_or(0, |t| (t * 1000.0) as i64)
}

/// None when flightrec covers the battery (cov:1), else why not
fn degraded_why(alive: bool, energy_t: Option<i64>, now_ms: i64, edge: bool, watch: bool) -> Option<&'static str> {
    if !alive {
        return Some("flightrec is not running");
    }
    match energy_t {
        None => return Some("no energy line of this boot"),
        Some(t) if now_ms - t > STALE_MS => return Some("the energy line is older than 60 s"),
        _ => {}
    }
    if !edge {
        return Some("no edge file");
    }
    if !watch {
        return Some("no inotify watch on /run/y700-flightrec");
    }
    None
}

// ---- the recorder
struct Obs {
    dpms: Option<bool>,
    pw: Option<&'static str>,
    cov: bool,
    edge_t: Option<f64>,
    energy: Option<snap::Energy>,
}

struct Rec {
    boot_full: String,
    boot8: String,
    units: Units,
    gpu: Gpu,
    thr: Threads,
    light: Light,
    clock: Clock,
    ledger: Option<Ledger>, // None: --once / --bench
    log: LogOnce,
    written_cg: HashMap<u32, u64>, // what the ledger holds per unit since the last head
    written_gpu: HashMap<u32, (u64, u64)>,
    head: Option<&'static str>, // an H still to write first ("start" until the first group is written)
    last_off: f64,              // wall - mono at the last look (timerfd drained), for the size of a clock step
    degraded: Option<&'static str>,
    last_prune: f64,
    order: Vec<String>,
}

fn boot_id() -> String {
    fds::read_text(Path::new("/proc/sys/kernel/random/boot_id")).filter(|s| !s.is_empty()).unwrap_or_else(|| "noboot".into())
}

/// flightrec's boot8 (run.rs): the first 8 characters of the boot id
fn boot8(full: &str) -> String {
    full.chars().take(8).collect()
}

fn uid() -> u32 {
    // SAFETY: getuid takes no arguments and cannot fail
    unsafe { libc::getuid() }
}

impl Rec {
    fn new(boot_full: String, ledger: Option<Ledger>, clock: Clock) -> Rec {
        Rec {
            boot8: boot8(&boot_full),
            boot_full,
            units: Units::new(Path::new(CGROOT), uid()),
            gpu: Gpu::new(),
            thr: Threads::new(),
            light: Light::new(IFACE),
            clock,
            ledger,
            log: LogOnce::default(),
            written_cg: HashMap::new(),
            written_gpu: HashMap::new(),
            head: Some("start"),
            last_off: fds::wall() - fds::mono(),
            degraded: None,
            last_prune: fds::mono(),
            order: vec![],
        }
    }

    /// flightrec's files, or the degraded readings
    fn observe(&mut self, ino: Option<&mut Inotify>) -> Obs {
        let watch = ino.map_or(false, |i| i.ensure());
        let run = Path::new(RUN_DIR);
        let alive = fds::pid_running(&run.join("daemon.pid"), "y700-flightrec").is_some();
        let edge = fds::read_text(&run.join("edge")).and_then(|t| snap::parse_edge(&t));
        let energy = snap::read_stable(&run.join("energy"))
            .and_then(|t| snap::parse_energy(&t))
            .filter(|e| e.boot == self.boot8);
        let now_ms = (fds::mono() * 1000.0) as i64;
        let last = energy.as_ref().map(|e| last_ms(e.t, edge.map(|g| g.t)));
        let why = degraded_why(alive, last, now_ms, edge.is_some(), watch);
        if why != self.degraded {
            match why {
                Some(w) => elog!("degraded (cov:0): {w}; dpms from {DPMS}"),
                None => elog!("flightrec covers the battery again (cov:1)"),
            }
            self.degraded = why;
        }
        match (why, edge) {
            (None, Some(e)) => Obs { dpms: e.dpms, pw: e.pw, cov: true, edge_t: Some(e.t), energy },
            _ => {
                let dpms = fds::read_text(Path::new(DPMS)).and_then(|v| snap::parse_dpms(&v));
                Obs { dpms, pw: None, cov: false, edge_t: None, energy }
            }
        }
    }

    /// the reads that only set baselines (--once, --bench)
    fn baseline(&mut self) {
        self.units.refresh();
        self.gpu.pass(&self.units);
        let _ = self.thr.scan(&self.units);
    }

    fn snapshot(&mut self, why: Why, obs: &Obs, bat: bool) {
        let off = obs.dpms == Some(false);
        let scan = matches!(why, Why::Start | Why::On | Why::Off | Why::Once) || (why == Why::Ck && off);
        let flush = matches!(why, Why::Off | Why::Term) || (why == Why::Ck && off);
        // not for TERM: the last snapshot and its fdatasync must finish within TimeoutStopSec, the sync flag known
        // from the last ask stands
        if !self.clock.sync && why != Why::Term {
            self.clock.refresh();
        }
        self.units.refresh();
        let kwin = self.units.dir_of(units::KWIN_KEY).map(Path::to_path_buf);
        let ld = self.light.read(kwin.as_deref());
        self.gpu.pass(&self.units);
        self.gpu.keep(&self.units.live_ids());
        let wk = if scan { self.thr.scan(&self.units) } else { None };
        let (st, cap) = if bat { snap::battery(Path::new(BAT)) } else { (None, None) };
        // last_off is not taken here: only look() takes it, after draining the timerfd
        let (m, w) = (fds::mono(), fds::wall());
        let edge = if obs.cov && matches!(why, Why::On | Why::Off | Why::Pw) { obs.edge_t } else { None };
        let base = SLine {
            why: why.name(),
            m,
            w,
            sync: self.clock.sync,
            dpms: obs.dpms,
            pw: obs.pw,
            cov: obs.cov,
            edge,
            fr: obs.energy.as_ref().map(|e| e.fields.clone()),
            cl: ld.cl,
            ctx: ld.ctx,
            pkt: ld.pkt,
            x: ld.x,
            wk,
            st,
            cap,
            ..Default::default()
        };
        self.commit(base, flush);
        if obs.dpms == Some(true) && m - self.last_prune >= PRUNE_EVERY_S {
            self.prune(); // the first screen-on snapshot of a new day
        }
    }

    /// cg/new/gone/gpu: everything after a head (full), else what changed since the last S written
    fn fill(&self, mut s: SLine, full: bool) -> SLine {
        let rows = self.units.rows();
        s.cg = rows
            .iter()
            .filter_map(|r| {
                let u = r.usage?;
                (full || self.written_cg.get(&r.id) != Some(&u)).then_some((r.id, u))
            })
            .collect();
        if full {
            // the head's full U table says what is new or gone; ids from before the H are out of scope
            s.new = vec![];
            s.gone = vec![];
        } else {
            s.new = rows.iter().filter(|r| !r.announced).map(|r| r.id).collect();
            let mut g = self.units.gone.clone();
            g.sort_unstable();
            s.gone = g;
        }
        let mut gpu: Vec<(u32, (u64, u64))> = self
            .gpu
            .acc
            .iter()
            .filter(|(id, v)| if full { **v != (0, 0) } else { self.written_gpu.get(*id) != Some(*v) })
            .map(|(&id, &v)| (id, v))
            .collect();
        gpu.sort_unstable_by_key(|g| g.0);
        s.gpu = gpu;
        s
    }

    /// [H] + U lines (all after a head, else the units not announced yet) + S; None if the S line is too long
    fn group(&self, s: &SLine, head: Option<&str>, part: u32) -> Option<String> {
        let sl = snap::render_s(s);
        if sl.len() > ledger::LINE_MAX {
            return None;
        }
        let mut out = String::with_capacity(sl.len() + 8192);
        if let Some(h) = head {
            out.push_str(&snap::render_h(&self.boot_full, part, s.m, s.w, s.sync, h));
            out.push('\n');
        }
        for r in self.units.rows() {
            if head.is_some() || !r.announced {
                out.push_str(&snap::render_u(r.id, &r.key, r.ino));
                out.push('\n');
            }
        }
        out.push_str(&sl);
        out.push('\n');
        Some(out)
    }

    fn commit(&mut self, base: SLine, flush: bool) {
        if self.ledger.is_none() {
            let s = self.fill(base, true);
            println!("{}", snap::render_s(&s));
            return;
        }
        let prep = match self.ledger.as_mut() {
            Some(l) => l.prepare().map(|e| (e, l.part)).map_err(|e| format!("{}: {e}", l.name())),
            None => return,
        };
        let (headless, mut part) = match prep {
            Ok(v) => {
                self.log.clear("open");
                v
            }
            Err(e) => {
                self.log.log("open", &format!("ledger {e}: snapshot skipped, retried at the next one"));
                return;
            }
        };
        // headless: the part has no complete head yet - new, made again, or its head's write was cut short
        let mut head = self.head.or(if headless { Some("part") } else { None });
        let mut s = self.fill(base.clone(), head.is_some());
        let Some(mut text) = self.group(&s, head, part) else {
            self.log.log("long", "an S line over 64 KiB: snapshot skipped");
            return;
        };
        if self.ledger.as_ref().map_or(false, |l| ledger::rotation_due(l.size(), text.len())) {
            let r = match self.ledger.as_mut() {
                Some(l) => l.rotate().map(|_| l.part),
                None => return,
            };
            match r {
                Ok(p) => part = p,
                Err(e) => {
                    self.log.log("open", &format!("ledger: new part: {e}"));
                    return;
                }
            }
            head = Some(self.head.unwrap_or("part"));
            s = self.fill(base, true);
            text = match self.group(&s, head, part) {
                Some(t) => t,
                None => return,
            };
        }
        let res = match self.ledger.as_mut() {
            Some(l) => l.append(text.as_bytes()),
            None => return,
        };
        if let Err(e) = res {
            self.log.log("append", &format!("ledger append: {e} (retried at the next snapshot)"));
            return;
        }
        self.log.clear("append");
        self.units.mark_announced();
        if head.is_some() {
            self.written_cg.clear();
            self.written_gpu.clear();
        }
        for &(id, u) in &s.cg {
            self.written_cg.insert(id, u);
        }
        for &(id, v) in &s.gpu {
            self.written_gpu.insert(id, v);
        }
        let live = self.units.live_ids();
        self.written_cg.retain(|id, _| live.contains(id));
        self.written_gpu.retain(|id, _| live.contains(id));
        self.head = None;
        if flush {
            if let Some(Err(e)) = self.ledger.as_ref().map(|l| l.sync()) {
                self.log.log("sync", &format!("ledger fdatasync: {e}"));
            }
        }
    }

    /// the wall clock was set: a K line with the step against the last look (nothing in a part without its H yet)
    fn clock_step(&mut self) {
        let (m, w) = (fds::mono(), fds::wall());
        let step = (w - m) - self.last_off;
        self.last_off = w - m;
        self.clock.refresh();
        elog!("wall clock stepped by {step:.3} s; sync={} ({})", u8::from(self.clock.sync), self.clock.src);
        if self.head.is_some() {
            return;
        }
        let line = format!("{}\n", snap::render_k(m, w, self.clock.sync, self.clock.src, step));
        let Some(l) = self.ledger.as_mut() else { return };
        let r = match l.prepare() {
            Ok(false) => l.append(line.as_bytes()),
            Ok(true) => Ok(()), // a part without its head (deleted under us, a head cut short): the next S writes it
            Err(e) => Err(e),
        };
        if let Err(e) = r {
            self.log.log("append", &format!("ledger append: {e} (retried at the next snapshot)"));
        }
    }

    /// the look at the clocks every wake ends with. The offset is taken first and the timerfd drained after, so a
    /// step during this wake's work (chronyc, the scans) is measured against the offset from before it, and one just
    /// after the drain wakes the next poll with last_off still from before it.
    fn look(&mut self, cw: Option<&fds::ClockWatch>) {
        let off = fds::wall() - fds::mono();
        if cw.map_or(false, |c| c.stepped()) {
            self.clock_step();
        } else {
            self.last_off = off;
        }
    }

    fn prune(&mut self) {
        self.last_prune = fds::mono();
        let now_wall = if self.clock.sync { Some(fds::wall()) } else { None };
        if let Some(l) = self.ledger.as_ref() {
            let (n, b) = l.prune(&self.order, now_wall);
            if n > 0 {
                elog!("pruned {n} ledger files, {b} bytes");
            }
        }
    }
}

// ---- modes
enum Mode {
    Daemon,
    Once,
    Bench(usize),
}

struct Opts {
    state: PathBuf,
    run: PathBuf,
    mode: Mode,
}

fn opts() -> Result<Opts, String> {
    let env = |k: &str| std::env::var_os(k).filter(|v| !v.is_empty()).map(PathBuf::from);
    // a relative XDG_STATE_HOME is ignored (basedir spec), as refresh-auto's FG_DIR does: both find the same directory
    let mut state = match (env("XDG_STATE_HOME").filter(|p| p.is_absolute()), env("HOME")) {
        (Some(s), _) => Some(s.join("y700-battery")),
        (None, Some(h)) => Some(h.join(".local/state/y700-battery")),
        (None, None) => None,
    };
    let mut run = env("XDG_RUNTIME_DIR").unwrap_or_else(|| PathBuf::from(format!("/run/user/{}", uid()))).join("y700-battery");
    let mut mode = Mode::Daemon;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--state-dir" => state = Some(PathBuf::from(args.next().ok_or("--state-dir DIR")?)),
            "--run-dir" => run = PathBuf::from(args.next().ok_or("--run-dir DIR")?),
            "--once" => mode = Mode::Once,
            "--bench" => {
                let n = args.next().and_then(|s| s.parse::<usize>().ok()).filter(|&n| n >= 1).ok_or("--bench N (N >= 1)")?;
                mode = Mode::Bench(n);
            }
            "-h" | "--help" => return Err(USAGE.to_string()),
            _ => return Err(format!("unknown argument {a}\n{USAGE}")),
        }
    }
    let state = state.ok_or("neither XDG_STATE_HOME nor HOME is set: give --state-dir")?;
    Ok(Opts { state, run, mode })
}

fn daemon(o: &Opts) -> i32 {
    let sig = match fds::SigFd::new(&[libc::SIGTERM, libc::SIGINT, libc::SIGUSR1]) {
        Ok(s) => s,
        Err(e) => {
            elog!("signalfd: {e}");
            return 1;
        }
    };
    if let Err(e) = fs::create_dir_all(&o.state) {
        elog!("{}: {e}", o.state.display());
        return 1;
    }
    let _lock = match fds::try_lock(&o.state.join("lock")) {
        Lock::Held(f) => f,
        Lock::Busy => {
            elog!("another y700-batteryd holds {}/lock: exiting", o.state.display());
            return 0;
        }
        Lock::Failed(e) => {
            elog!("{}/lock: {e}", o.state.display());
            return 1;
        }
    };
    let pidf = o.run.join("pid");
    let pid_ok = fs::create_dir_all(&o.run).and_then(|_| fs::write(&pidf, format!("{}\n", std::process::id())));
    if let Err(e) = pid_ok {
        elog!("{}: {e} (the page cannot ask for a snapshot)", pidf.display());
    }
    let mut ino = match Inotify::new(Path::new(RUN_DIR)) {
        Ok(i) => Some(i),
        Err(e) => {
            elog!("inotify: {e} (degraded until restarted)");
            None
        }
    };
    let mut cw = match fds::ClockWatch::new() {
        Ok(c) => Some(c),
        Err(e) => {
            elog!("timerfd: {e} (clock steps not recorded)");
            None
        }
    };
    let off0 = fds::wall() - fds::mono(); // the offset the timerfd was armed against (Rec::new's comes after chronyc)
    let full = boot_id();
    let b8 = boot8(&full);
    let mut rec = Rec::new(full, Some(Ledger::open(&o.state, &b8)), Clock::new());
    rec.last_off = off0;
    rec.order = ledger::boot_order(&o.state, &b8);
    rec.prune();
    let obs = rec.observe(ino.as_mut());
    rec.snapshot(Why::Start, &obs, true);
    rec.look(cw.as_ref()); // a step during the start gets its K line, after the H
    let name = rec.ledger.as_ref().map(Ledger::name).unwrap_or_default();
    elog!(
        "started: boot {b8}, {}/{name}, {} units, {} gpu clients, {} threads, cov {}, clock sync {} ({})",
        o.state.display(),
        rec.units.live.len(),
        rec.gpu.clients,
        rec.thr.count,
        u8::from(obs.cov),
        u8::from(rec.clock.sync),
        rec.clock.src
    );
    let mut cad = Cad { dpms: obs.dpms, pw: obs.pw, last_snap: fds::mono(), last_edge: -1e9, last_req: -1e9 };
    let mut wake_at = cad.last_snap + period(cad.dpms);
    let (mut cw_last, mut cw_burst) = (-1e9f64, 0u32);
    loop {
        let ms = ((wake_at - fds::mono()).max(0.0) * 1000.0).ceil().min(86_400_000.0) as i32;
        let fdl = [sig.raw(), ino.as_ref().map_or(-1, |i| i.raw()), cw.as_ref().map_or(-1, |c| c.raw())];
        let r = fds::poll_in(&fdl, ms);
        let (mut term, mut usr1) = (false, false);
        if r.first() == Some(&true) {
            for s in sig.read() {
                match s as libc::c_int {
                    libc::SIGTERM | libc::SIGINT => term = true,
                    libc::SIGUSR1 => usr1 = true,
                    _ => {}
                }
            }
        }
        if r.get(1) == Some(&true) {
            if let Some(i) = ino.as_mut() {
                let _ = i.drain(b"edge"); // the edge file itself is read below, whatever woke us
            }
        }
        if r.get(2) == Some(&true) {
            let now = fds::mono();
            cw_burst = if now - cw_last < 1.0 { cw_burst + 1 } else { 0 };
            cw_last = now;
            if cw.as_ref().map_or(false, |c| c.stepped()) {
                rec.clock_step();
            }
            if cw_burst > 50 {
                elog!("timerfd keeps firing: clock steps no longer recorded");
                cw = None;
            }
        }
        let obs = rec.observe(ino.as_mut());
        let plan = decide(&mut cad, &Seen { now: fds::mono(), dpms: obs.dpms, pw: obs.pw, usr1, term });
        if let Some(why) = plan.why {
            rec.snapshot(why, &obs, plan.pw_edge);
        }
        if term {
            let _ = fs::remove_file(&pidf);
            elog!("TERM: last snapshot written, exiting");
            return 0;
        }
        rec.look(cw.as_ref());
        wake_at = plan.wake_at;
    }
}

fn once() -> i32 {
    let mut rec = Rec::new(boot_id(), None, Clock::new());
    let mut ino = Inotify::new(Path::new(RUN_DIR)).ok();
    rec.baseline();
    std::thread::sleep(Duration::from_secs(1));
    let obs = rec.observe(ino.as_mut());
    rec.snapshot(Why::Once, &obs, true);
    elog!(
        "{} units, {} gpu clients, {} threads; cov {}{}; clock sync {} ({}); gpu and wk over 1 s after a baseline",
        rec.units.live.len(),
        rec.gpu.clients,
        rec.thr.count,
        u8::from(obs.cov),
        rec.degraded.map(|d| format!(" ({d})")).unwrap_or_default(),
        u8::from(rec.clock.sync),
        rec.clock.src
    );
    0
}

fn stats(v: &mut [f64]) -> (f64, f64) {
    v.sort_by(|a, b| a.total_cmp(b));
    (v.get(v.len() / 2).copied().unwrap_or(0.0) * 1000.0, v.last().copied().unwrap_or(0.0) * 1000.0)
}

fn bench(n: usize) -> i32 {
    let mut rec = Rec::new(boot_id(), None, Clock::new());
    rec.baseline();
    let (mut lw, mut lc, mut tw, mut tc) = (vec![], vec![], vec![], vec![]);
    for _ in 0..n {
        let (w0, c0) = (fds::mono(), fds::cpu());
        rec.units.refresh();
        let kwin = rec.units.dir_of(units::KWIN_KEY).map(Path::to_path_buf);
        let _ = rec.light.read(kwin.as_deref());
        rec.gpu.pass(&rec.units);
        let _ = snap::read_stable(&Path::new(RUN_DIR).join("energy"));
        lw.push(fds::mono() - w0);
        lc.push(fds::cpu() - c0);
        let (w0, c0) = (fds::mono(), fds::cpu());
        let _ = rec.thr.scan(&rec.units);
        tw.push(fds::mono() - w0);
        tc.push(fds::cpu() - c0);
    }
    let ((lwm, lwx), (lcm, lcx)) = (stats(&mut lw), stats(&mut lc));
    let ((twm, twx), (tcm, tcx)) = (stats(&mut tw), stats(&mut tc));
    println!(
        "light snapshot ({} units, {} gpu clients) x{n}: wall median {lwm:.2} ms max {lwx:.2} ms, cpu median {lcm:.2} ms max {lcx:.2} ms",
        rec.units.live.len(),
        rec.gpu.clients
    );
    println!(
        "thread scan ({} threads) x{n}: wall median {twm:.2} ms max {twx:.2} ms, cpu median {tcm:.2} ms max {tcx:.2} ms",
        rec.thr.count
    );
    0
}

fn main() {
    let o = match opts() {
        Ok(o) => o,
        Err(e) => {
            elog!("{e}");
            std::process::exit(2);
        }
    };
    let rc = match o.mode {
        Mode::Daemon => daemon(&o),
        Mode::Once => once(),
        Mode::Bench(n) => bench(n),
    };
    std::process::exit(rc);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::units::Found;

    fn cad(dpms: bool) -> Cad {
        Cad { dpms: Some(dpms), pw: Some("dis"), last_snap: 0.0, last_edge: -1e9, last_req: -1e9 }
    }

    fn seen(now: f64, dpms: Option<bool>, pw: Option<&'static str>) -> Seen {
        Seen { now, dpms, pw, usr1: false, term: false }
    }

    #[test]
    fn cadence() {
        let mut c = cad(true);
        // nothing changed: no snapshot, due at 300
        let p = decide(&mut c, &seen(100.0, Some(true), Some("dis")));
        assert_eq!((p.why, p.wake_at), (None, 300.0));
        // a timeout a little early still counts
        assert_eq!(decide(&mut c, &seen(299.6, Some(true), Some("dis"))).why, Some(Why::Ck));
        // the screen goes off: an edge snapshot, the period becomes 1800 s
        let p = decide(&mut c, &seen(310.0, Some(false), Some("dis")));
        assert_eq!((p.why, p.wake_at), (Some(Why::Off), 2110.0));
        // pw flips 20 s after that edge: deferred to 60 s after it
        let p = decide(&mut c, &seen(330.0, Some(false), Some("chg")));
        assert_eq!((p.why, p.wake_at), (None, 370.0));
        let p = decide(&mut c, &seen(370.0, Some(false), Some("chg")));
        assert_eq!((p.why, p.pw_edge), (Some(Why::Pw), true));
        assert_eq!(c.pw, Some("chg"));
        // flightrec restarting rewrites the same edge: nothing
        assert_eq!(decide(&mut c, &seen(380.0, Some(false), Some("chg"))).why, None);
        // USR1: once per 10 s
        let req = |now: f64| Seen { now, dpms: Some(false), pw: Some("chg"), usr1: true, term: false };
        assert_eq!(decide(&mut c, &req(400.0)).why, Some(Why::Req));
        assert_eq!(decide(&mut c, &req(405.0)).why, None);
        assert_eq!(decide(&mut c, &req(411.0)).why, Some(Why::Req));
        // the screen comes on and power flips with it: one "on" snapshot, the battery read with it
        let p = decide(&mut c, &seen(420.0, Some(true), Some("dis")));
        assert_eq!((p.why, p.pw_edge, p.wake_at), (Some(Why::On), true, 720.0));
        // a dpms edge is never held back by the 60 s rule
        assert_eq!(decide(&mut c, &seen(425.0, Some(false), Some("dis"))).why, Some(Why::Off));
        // TERM wins over everything
        let p = decide(&mut c, &Seen { now: 426.0, dpms: Some(true), pw: Some("dis"), usr1: true, term: true });
        assert_eq!(p.why, Some(Why::Term));
    }

    #[test]
    fn unknown_values() {
        // degraded at start (dpms unreadable, pw unknown): the screen-on period; first values taken silently
        let mut c = Cad { dpms: None, pw: None, last_snap: 0.0, last_edge: -1e9, last_req: -1e9 };
        let p = decide(&mut c, &seen(10.0, None, None));
        assert_eq!((p.why, p.wake_at), (None, 300.0));
        let p = decide(&mut c, &seen(20.0, Some(false), Some("dis")));
        assert_eq!((p.why, p.wake_at), (None, 1800.0));
        // flightrec gone again: unknown values never make an edge
        assert_eq!(decide(&mut c, &seen(30.0, None, None)).why, None);
        assert_eq!((c.dpms, c.pw), (Some(false), Some("dis")));
    }

    #[test]
    fn degraded() {
        let now = 100_000;
        assert_eq!(degraded_why(true, Some(99_000), now, true, true), None);
        assert!(degraded_why(false, Some(99_000), now, true, true).is_some());
        assert!(degraded_why(true, None, now, true, true).is_some());
        assert!(degraded_why(true, Some(39_999), now, true, true).is_some(), "61 s old");
        assert_eq!(degraded_why(true, Some(40_000), now, true, true), None, "60 s old");
        assert!(degraded_why(true, Some(99_000), now, false, true).is_some());
        assert!(degraded_why(true, Some(99_000), now, true, false).is_some());
    }

    #[test]
    fn energy_freshness() {
        // the energy line's t once flightrec has written a data line; t=0 (none yet this boot): its start edge's t
        assert_eq!(last_ms(31_540_012, Some(7341.9)), 31_540_012);
        assert_eq!(last_ms(0, Some(95.5)), 95_500);
        assert_eq!(last_ms(0, None), 0);
        assert_eq!(degraded_why(true, Some(last_ms(0, Some(95.0))), 100_000, true, true), None);
        assert!(degraded_why(true, Some(last_ms(0, Some(30.0))), 100_000, true, true).is_some());
    }

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("y700-batteryd-test-{}-{tag}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        let _ = fs::create_dir_all(&d);
        d
    }

    fn found(key: &str, ino: u64) -> Found {
        Found { key: key.to_string(), ino, dir: PathBuf::from("/nonexistent") }
    }

    fn set_usage(r: &mut Rec, key: &str, v: u64) {
        if let Some(u) = r.units.live.get_mut(key) {
            u.usage = Some(v);
        }
    }

    fn lines(p: &Path) -> Vec<String> {
        fs::read_to_string(p).unwrap_or_default().lines().map(str::to_string).collect()
    }

    #[test]
    fn heads_deltas_and_parts() {
        let d = tmpdir("rec");
        let mut r = Rec::new("t0000001-77d0".into(), Some(Ledger::open(&d, "t0000001")), Clock::fixed(true));
        let app = "u/app.slice/a.scope";
        r.units.apply(vec![found("/", 1), found(units::KWIN_KEY, 50), found(app, 100)]);
        for (k, v) in [("/", 1000), (units::KWIN_KEY, 200), (app, 30)] {
            set_usage(&mut r, k, v);
        }
        let base = |why: &'static str| SLine { why, m: 18.42, w: 40213.7, sync: true, ..Default::default() };
        r.commit(base("start"), false);
        let p0 = d.join("b-t0000001.jsonl");
        let l = lines(&p0);
        assert_eq!(l.len(), 5);
        assert!(l[0].starts_with("{\"k\":\"H\",\"v\":1,\"boot\":\"t0000001-77d0\",\"part\":0,"), "{}", l[0]);
        assert!(l[0].ends_with("\"why\":\"start\"}"));
        assert_eq!(l[1], "{\"k\":\"U\",\"id\":1,\"p\":\"/\",\"ino\":1}");
        assert_eq!(l[2], "{\"k\":\"U\",\"id\":2,\"p\":\"u/session.slice/plasma-kwin_wayland.service\",\"ino\":50}");
        assert_eq!(l[3], "{\"k\":\"U\",\"id\":3,\"p\":\"u/app.slice/a.scope\",\"ino\":100}");
        assert!(l[4].contains("\"cg\":{\"1\":1000,\"2\":200,\"3\":30}"), "{}", l[4]);
        assert!(!l[4].contains("\"new\""));
        // only what changed; a unit appearing gets its U line first and is listed as new
        set_usage(&mut r, app, 45);
        r.units.apply(vec![found("/", 1), found(units::KWIN_KEY, 50), found(app, 100), found("s/b.service", 7)]);
        set_usage(&mut r, "s/b.service", 9);
        r.commit(base("ck"), false);
        let l = lines(&p0);
        assert_eq!(l.len(), 7);
        assert_eq!(l[5], "{\"k\":\"U\",\"id\":4,\"p\":\"s/b.service\",\"ino\":7}");
        assert!(l[6].contains("\"cg\":{\"3\":45,\"4\":9},\"new\":[4],"), "{}", l[6]);
        // a unit gone
        r.units.apply(vec![found("/", 1), found(units::KWIN_KEY, 50), found("s/b.service", 7)]);
        r.commit(base("ck"), false);
        let l = lines(&p0);
        assert_eq!(l.len(), 8);
        assert!(l[7].contains("\"cg\":{},\"gone\":[3],"), "{}", l[7]);
        // a full part: the next group goes to part 1, headed by H why=part and the whole table
        if let Some(lg) = r.ledger.as_mut() {
            let mut pad = vec![b'x'; (ledger::PART_MAX - lg.size()) as usize - 50];
            pad.push(b'\n');
            lg.append(&pad).unwrap();
        }
        set_usage(&mut r, "/", 1500);
        r.commit(base("off"), true);
        let l1 = lines(&d.join("b-t0000001.1.jsonl"));
        assert_eq!(l1.len(), 5);
        assert!(l1[0].contains("\"part\":1,") && l1[0].ends_with("\"why\":\"part\"}"), "{}", l1[0]);
        assert!(l1[4].contains("\"cg\":{\"1\":1500,\"2\":200,\"4\":9}"), "{}", l1[4]);
        assert!(!l1[4].contains("\"gone\"") && !l1[4].contains("\"new\""));
        // a clock step goes in as a K line
        r.last_off -= 100.0;
        r.clock_step();
        let l1 = lines(&d.join("b-t0000001.1.jsonl"));
        assert!(l1.last().map_or(false, |k| k.starts_with("{\"k\":\"K\",") && k.contains("\"step\":100.")), "{:?}", l1.last());
        // a restart within the boot writes on in part 1, after a newline closing any half line, with H why=start
        let mut r2 = Rec::new("t0000001-77d0".into(), Some(Ledger::open(&d, "t0000001")), Clock::fixed(false));
        r2.units.apply(vec![found("/", 1)]);
        r2.commit(base("start"), false);
        let l1 = lines(&d.join("b-t0000001.1.jsonl"));
        assert!(l1.iter().filter(|x| x.contains("\"why\":\"start\"")).count() == 2);
        let _ = fs::remove_dir_all(&d);
    }
}
