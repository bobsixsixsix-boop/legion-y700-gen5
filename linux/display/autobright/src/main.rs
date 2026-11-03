// y700-autobright: automatic screen brightness from the ambient light sensor (owner, 2026-10-15).
//
// Plasma 6.6's PowerDevil has no ambient-light mode; the sensor is there (iio-sensor-proxy on the system bus:
// net.hadess.SensorProxy, HasAmbientLight, LightLevel in lux, live once claimed). Brightness goes through KDE's own API
// (org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0, 0..MaxBrightness, linear to the aw99706 backlight), so
// the control centre's slider and PowerDevil stay in sync - unlike wluma/clight, which write the sysfs backlight behind
// PowerDevil's back.
//
//   - curve: brightness fraction over log10(lux + 1) (CURVE below), times the owner's learned factor;
//   - steady: change only when the smoothed lux left a +/-25 % band around the level of the last change, brightening
//     after 1.5 s, darkening after 4 s (a hand over the sensor does nothing); each change ramps over 0.8 s with the OSD
//     suppressed; changes under 1.5 % are skipped;
//   - learning: a brightness change that is not ours (the owner moved the slider) sets the factor to owner/curve at the
//     current light, kept in ~/.config/y700/autobright.json. The first start takes the current brightness as the
//     owner's choice, so switching it on never jumps;
//   - screen off (DPMS): nothing changes and the light sensor is released; on wake it is claimed again and the first
//     reading is applied at once. The same when iio-sensor-proxy appears on the bus (late start, restart): until then
//     the service just waits.
// Run by y700-autobright.service (user); on/off/status: y700-autobright-ctl.
//
// Rust port (2026-11-03) of the Python service (last Python version: git ea2b225 linux/display/y700-autobright, with
// its test bed test-autobright.py; README "自动亮度"). Behaviour, log lines and the preference file are the same;
// deliberate differences are marked RUST:. Where Python's CPU went: a GLib timer woke it every second, screen on or
// off, to read /sys/class/drm/*/dpms and re-check the band - 0.019 % of a core and 1.0 wakeup/s with the screen dark
// and the sensor released (11-03); with the screen lit every light reading (~6 a second) also went through GDBus's
// worker thread, the main loop and the interpreter. Here the screen state comes as KWin events (src/wl.rs) and the
// band, ramp and forget timers are exact deadlines, so a dark screen costs no wakeups at all and a lit one a short
// wakeup per reading.

mod dbus;
mod wl;

use dbus::{properties_changed, strings, Arg, Bus, Msg, Val, SIGNAL, SYSTEM_BUS};
use std::collections::VecDeque;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Instant;
use wl::Wl;

// (lux, fraction of max brightness) - interpolated over log10(lux + 1)
const CURVE: [(f64, f64); 9] =
    [(0.0, 0.06), (3.0, 0.10), (10.0, 0.16), (40.0, 0.26), (100.0, 0.36), (300.0, 0.50), (800.0, 0.65), (2000.0, 0.82), (5000.0, 1.0)];
const BAND: f64 = 0.25; // relative lux change that triggers an adjustment
const BRIGHTEN_S: f64 = 1.5; // how long the light must stay outside the band
const DARKEN_S: f64 = 4.0;
const TAU_S: f64 = 1.5; // lux smoothing time constant
const MIN_FRAC: f64 = 0.02;
const MIN_STEP: f64 = 0.015;
const RAMP_STEPS: usize = 8;
const RAMP_S: f64 = 0.1;
const FORGET_S: f64 = 1.5; // our values still count as ours this long after a ramp
const SUPPRESS_OSD: u32 = 0x1;

const SENSOR: &str = "net.hadess.SensorProxy";
const SENSOR_PATH: &str = "/net/hadess/SensorProxy";
const KDE: &str = "org.kde.ScreenBrightness";
const KDE_PATH: &str = "/org/kde/ScreenBrightness/display0";
const KDE_IFACE: &str = "org.kde.ScreenBrightness.Display";
const SENSOR_MATCH: &str = "type='signal',sender='net.hadess.SensorProxy',path='/net/hadess/SensorProxy',\
    interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'";
const OWNER_MATCH: &str = "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',\
    member='NameOwnerChanged',arg0='net.hadess.SensorProxy'";
const BRIGHTNESS_MATCH: &str = "type='signal',sender='org.kde.ScreenBrightness',path='/org/kde/ScreenBrightness/display0',\
    interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'";

fn say(msg: &str) {
    println!("{msg}");
    #[cfg(test)]
    tests::LOGGED.with(|l| l.borrow_mut().push(msg.to_string()));
}

fn curve(lux: f64) -> f64 {
    let x = (lux.max(0.0) + 1.0).log10();
    let pts = CURVE.map(|(l, f)| ((l + 1.0).log10(), f));
    if x <= pts[0].0 {
        return pts[0].1;
    }
    for w in pts.windows(2) {
        let ((x0, f0), (x1, f1)) = (w[0], w[1]);
        if x <= x1 {
            return f0 + (f1 - f0) * (x - x0) / (x1 - x0);
        }
    }
    pts[pts.len() - 1].1
}

fn clamp_factor(f: f64) -> f64 {
    f.clamp(0.25, 4.0)
}

/// The learned factor from the preference file; None when there is none (or it is unreadable): the first run.
// shortcut: a hand parse of the one number this program writes; a real JSON parser if the file ever holds more.
fn load(conf: &Path) -> Option<f64> {
    let s = fs::read_to_string(conf).ok()?;
    let rest = s.split_once("\"factor\"")?.1.trim_start().strip_prefix(':')?.trim_start();
    let end = rest.find(|c: char| !(c.is_ascii_digit() || "+-.eE".contains(c))).unwrap_or(rest.len());
    rest[..end].parse().ok()
}

/// Written as Python's json.dump wrote it ({"factor": 1.25}), through a temp file.
fn save(conf: &Path, factor: f64) -> io::Result<()> {
    fs::create_dir_all(conf.parent().unwrap_or(Path::new(".")))?;
    let tmp = conf.with_extension("json.tmp");
    fs::write(&tmp, format!("{{\"factor\": {factor:?}}}"))?;
    fs::rename(&tmp, conf)
}

/// What the logic does to the world: the sensor claim, the brightness, the preference file.
trait Out {
    /// ClaimLight / ReleaseLight; the error reply's text on failure
    fn sensor(&mut self, method: &str) -> Result<(), String>;
    fn brightness(&mut self) -> Option<i64>;
    fn set_brightness(&mut self, v: i64);
    fn save(&mut self, factor: f64);
}

/// The service's state, apart from where its events come from. Times are seconds on the monotonic clock.
struct Auto<O: Out> {
    out: O,
    max: i64,
    factor: f64,
    owner: bool,   // iio-sensor-proxy is on the bus
    claimed: bool, // our ClaimLight is in force: only then is a LightLevel change a reading
    was_on: bool,
    ema: Option<f64>,
    ref_lux: Option<f64>,   // smoothed lux at the last change
    out_since: Option<f64>, // when the lux left the band
    ours: Vec<i64>,         // brightness values we set and have not seen echoed back yet
    ramp: VecDeque<f64>,    // fractions still to set, one every RAMP_S
    ramp_at: f64,
    forgets: Vec<f64>, // when `ours` is cleared (one per finished ramp, as Python's timeouts)
    last_t: f64,
}

impl<O: Out> Auto<O> {
    fn new(out: O, max: i64, factor: Option<f64>, owner: bool, on: bool, lux: f64, now: f64) -> Self {
        let mut a = Auto {
            out,
            max,
            factor: factor.unwrap_or(1.0),
            owner,
            claimed: false,
            was_on: on,
            ema: None,
            ref_lux: None,
            out_since: None,
            ours: Vec::new(),
            ramp: VecDeque::new(),
            ramp_at: 0.0,
            forgets: Vec::new(),
            last_t: now,
        };
        if on {
            a.claim(true); // started with the screen off: no claim, no readings until it is on
        }
        let b = a.out.brightness();
        if factor.is_none() {
            // first run: today's brightness is the owner's choice
            let cur = b.filter(|&b| b != 0).map_or(max as f64 / 2.0, |b| b as f64) / max as f64;
            a.factor = if lux > 0.0 { clamp_factor(cur / curve(lux).max(1e-3)) } else { 1.0 };
            a.out.save(a.factor);
        }
        let b = b.map_or("None".to_string(), |b| b.to_string());
        let absent = if owner { "" } else { ", light sensor service not there yet" };
        say(&format!("start: lux {lux:.0}, brightness {b}/{max}, factor {:.2}{absent}", a.factor));
        a
    }

    fn claim(&mut self, on: bool) {
        // iio-sensor-proxy not on the bus (no sensors at boot, a test kernel, restarting): nothing to claim or release;
        // on_owner claims when it is back
        self.claimed = false;
        if !self.owner {
            return;
        }
        match self.out.sensor(if on { "ClaimLight" } else { "ReleaseLight" }) {
            Ok(()) => self.claimed = on,
            // RUST: the error as "<D-Bus error name>: <text>", where GLib wrote "GDBus.Error:<name>: <text>"
            Err(e) => say(&format!("{} light: {e}", if on { "claim" } else { "release" })),
        }
    }

    /// iio-sensor-proxy came or went (2026-10-31 audit: absent at start it made the service restart every 5 s; restarted
    /// while we ran, the new one held no claim of ours and the brightness froze). The new process's first LightLevel
    /// is dropped (not claimed yet), and the first real reading is applied at once, as after a wake.
    fn on_owner(&mut self, present: bool) {
        self.owner = present;
        if !present {
            self.claimed = false;
            say("light sensor service gone");
            return;
        }
        if self.was_on {
            self.claim(true);
        }
        (self.ema, self.ref_lux, self.out_since) = (None, None, None);
        say(&format!("light sensor service back{}", if self.claimed { ": light sensor claimed" } else { "" }));
    }

    fn on_screen(&mut self, on: bool, now: f64) {
        if on != self.was_on {
            // screen off: let go of the light sensor, so iio-sensor-proxy, the system bus and this process stop waking
            // several times a second for readings nobody uses (power audit 2026-10-15); screen on: claim it again - the
            // first reading after that starts a fresh average and is applied at once (ref None)
            self.claim(on);
            (self.ema, self.ref_lux, self.out_since) = (None, None, None);
            say(match (on, self.claimed) {
                (true, true) => "screen on: light sensor claimed",
                (true, false) => "screen on: light sensor not claimed",
                (false, _) => "screen off: light sensor released",
            });
        }
        self.was_on = on;
        self.evaluate(now);
    }

    fn on_reading(&mut self, lux: f64, now: f64) {
        if !self.claimed {
            return;
        }
        let dt = now - self.last_t;
        self.last_t = now;
        self.ema = Some(match self.ema {
            None => lux,
            Some(e) => e + (1.0 - (-dt / TAU_S).exp()) * (lux - e),
        });
        self.evaluate(now);
    }

    fn target(&self, lux: f64) -> f64 {
        (curve(lux) * self.factor).clamp(MIN_FRAC, 1.0)
    }

    fn threshold(&self, ema: f64, r: f64) -> f64 {
        if ema > r * (1.0 + BAND) + 2.0 {
            BRIGHTEN_S
        } else {
            DARKEN_S
        }
    }

    fn evaluate(&mut self, now: f64) {
        let Some(ema) = self.ema else { return };
        if !self.was_on || !self.ramp.is_empty() {
            return;
        }
        let Some(r) = self.ref_lux else { return self.apply(ema, "start/wake", now) };
        let (hi, lo) = (r * (1.0 + BAND) + 2.0, r * (1.0 - BAND) - 2.0); // +-2 lux: no flapping in the dark
        if lo <= ema && ema <= hi {
            self.out_since = None;
            return;
        }
        let since = *self.out_since.get_or_insert(now);
        // the same sum as deadline(), so the wakeup it asks for always finds the time up
        if now >= since + self.threshold(ema, r) {
            self.apply(ema, "light changed", now);
        }
    }

    fn apply(&mut self, lux: f64, why: &str, now: f64) {
        (self.ref_lux, self.out_since) = (Some(lux), None);
        // RUST: the current brightness is asked for here (Properties.Get); Python read GDBusProxy's cache of it, which
        // the same PropertiesChanged signals kept up to date
        let cur = self.out.brightness().unwrap_or(0) as f64 / self.max as f64;
        let tgt = self.target(lux);
        if (tgt - cur).abs() < MIN_STEP {
            return;
        }
        say(&format!("{why}: lux {lux:.0} -> brightness {cur:.2} -> {tgt:.2}"));
        self.ramp = (0..RAMP_STEPS).map(|i| cur + (tgt - cur) * (i + 1) as f64 / RAMP_STEPS as f64).collect();
        self.ramp_at = now + RAMP_S;
    }

    fn on_brightness(&mut self, b: i64) {
        // ours: KDE may echo a value rounded through the 4095-step backlight, so match within a few units
        let mine: Vec<i64> = self.ours.iter().copied().filter(|v| (v - b).abs() <= 8).collect();
        if !mine.is_empty() || !self.ramp.is_empty() {
            self.ours.retain(|v| !mine.contains(v));
            return;
        }
        // not ours: the owner moved the slider (PowerDevil's idle dimming is off on this tablet)
        let Some(ema) = self.ema.filter(|&e| e > 0.0) else { return };
        let f = clamp_factor((b as f64 / self.max as f64) / curve(ema).max(1e-3));
        if (f - self.factor).abs() > 0.02 {
            self.factor = f;
            self.out.save(f);
            say(&format!("owner set {b}/{} at lux {ema:.0}: factor {f:.2}", self.max));
        }
        self.ref_lux = Some(ema); // and stay there until the light really changes
    }

    /// The next time on_timer has something to do; None: nothing until the next event.
    fn deadline(&self) -> Option<f64> {
        let ramp = (!self.ramp.is_empty()).then_some(self.ramp_at);
        let band = match (self.ema, self.ref_lux, self.out_since) {
            (Some(e), Some(r), Some(since)) if self.was_on && self.ramp.is_empty() => Some(since + self.threshold(e, r)),
            _ => None,
        };
        self.forgets.iter().copied().chain(ramp).chain(band).min_by(f64::total_cmp)
    }

    fn on_timer(&mut self, now: f64) {
        if self.forgets.iter().any(|&t| now >= t) {
            self.ours.clear();
            self.forgets.retain(|&t| now < t);
        }
        if !self.ramp.is_empty() && now >= self.ramp_at {
            let v = (self.ramp.pop_front().unwrap() * self.max as f64).round_ties_even() as i64;
            if !self.ours.contains(&v) {
                self.ours.push(v);
            }
            self.out.set_brightness(v);
            if self.ramp.is_empty() {
                self.forgets.push(now + FORGET_S);
            } else {
                self.ramp_at = now + RAMP_S;
            }
        }
        // RUST: also right after the last ramp step, where Python's 1 s tick looked again within a second
        self.evaluate(now);
    }
}

struct Real {
    sys: Bus,
    ses: Bus,
    conf: PathBuf,
}

impl Out for Real {
    fn sensor(&mut self, method: &str) -> Result<(), String> {
        self.sys.call(SENSOR, SENSOR_PATH, SENSOR, method, &[]).map(drop).map_err(|e| e.to_string())
    }

    fn brightness(&mut self) -> Option<i64> {
        match self.ses.get(KDE, KDE_PATH, KDE_IFACE, "Brightness") {
            Ok(Val::Int(b)) => Some(b),
            _ => None,
        }
    }

    fn set_brightness(&mut self, v: i64) {
        // fire and forget, as Python's Gio call; a session bus that is gone shows up in the main loop
        let _ = self.ses.send(KDE, KDE_PATH, KDE_IFACE, "SetBrightness", &[Arg::I32(v as i32), Arg::U32(SUPPRESS_OSD)]);
    }

    fn save(&mut self, factor: f64) {
        // RUST: a failed write is logged and the service goes on (in Python the exception ended the callback)
        if let Err(e) = save(&self.conf, factor) {
            say(&format!("cannot save {}: {e}", self.conf.display()));
        }
    }
}

/// Where the screen's power state comes from.
enum Screen {
    Kwin(Wl),
    /// RUST: only without KWin's events - what Python always did: /sys/class/drm/*/dpms every second. `retry`: try
    /// KWin again on every tick (not when it lacks the protocol).
    Sysfs { dpms: Vec<PathBuf>, retry: bool, next: f64 },
}

impl Screen {
    fn on(&self) -> bool {
        match self {
            Screen::Kwin(w) => w.screen_on(),
            Screen::Sysfs { dpms, .. } => sysfs_on(dpms),
        }
    }
}

fn without_kwin(e: &io::Error, now: f64) -> Screen {
    say(&format!("no KWin screen events ({e}); checking the screen every second"));
    Screen::Sysfs { dpms: dpms_files(), retry: e.kind() != io::ErrorKind::Unsupported, next: now + 1.0 }
}

/// Only connected connectors: the disconnected DP-1 and the Writeback connector report dpms "On" forever, which made the
/// first version believe the screen was always on (found 2026-10-15; DSI-1 stays "connected" while its dpms goes Off).
fn dpms_files() -> Vec<PathBuf> {
    let Ok(dir) = fs::read_dir("/sys/class/drm") else { return Vec::new() };
    dir.flatten()
        .map(|e| e.path())
        .filter(|d| d.join("dpms").exists() && fs::read_to_string(d.join("status")).is_ok_and(|s| s.trim() == "connected"))
        .map(|d| d.join("dpms"))
        .collect()
}

fn sysfs_on(dpms: &[PathBuf]) -> bool {
    dpms.is_empty() || dpms.iter().any(|p| fs::read_to_string(p).is_ok_and(|s| s.starts_with("On")))
}

fn start(now: f64) -> io::Result<(Auto<Real>, Option<String>, Screen)> {
    let mut sys = Bus::connect(SYSTEM_BUS)?;
    let mut ses = Bus::session()?;
    sys.add_match(SENSOR_MATCH)?;
    sys.add_match(OWNER_MATCH)?;
    ses.add_match(BRIGHTNESS_MATCH)?;
    let sensor = sys.name_owner(SENSOR)?;
    let lux = match sensor.as_ref().map(|_| sys.get(SENSOR, SENSOR_PATH, SENSOR, "LightLevel")) {
        Some(Ok(Val::F64(l))) => l,
        _ => 0.0,
    };
    let max = match ses.get(KDE, KDE_PATH, KDE_IFACE, "MaxBrightness") {
        Ok(Val::Int(m)) if m != 0 => m,
        _ => 10000,
    };
    // RUST: one of these two lines at every start (the checklist reads the last line about KWin screen events)
    let screen = match Wl::open() {
        Ok(w) => {
            say("watching KWin screen events");
            Screen::Kwin(w)
        }
        Err(e) => without_kwin(&e, now),
    };
    let conf = PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".config/y700/autobright.json");
    let factor = load(&conf);
    let on = screen.on();
    Ok((Auto::new(Real { sys, ses, conf }, max, factor, sensor.is_some(), on, lux, now), sensor, screen))
}

/// A signal off the system bus: the sensor's readings (from its current owner only) and its owner coming and going.
fn on_system(auto: &mut Auto<Real>, sensor: &mut Option<String>, m: &Msg, now: f64) {
    if m.kind != SIGNAL {
        return;
    }
    if m.member == "NameOwnerChanged" && m.sender == "org.freedesktop.DBus" {
        if let [name, _, new] = &strings(m)[..] {
            if name == SENSOR {
                *sensor = (!new.is_empty()).then(|| new.clone());
                auto.on_owner(sensor.is_some());
            }
        }
    } else if m.member == "PropertiesChanged" && m.path == SENSOR_PATH && sensor.as_deref() == Some(m.sender.as_str()) {
        if let Some((iface, props)) = properties_changed(m) {
            for (k, v) in props {
                if let (SENSOR, "LightLevel", Val::F64(lux)) = (iface.as_str(), k.as_str(), v) {
                    auto.on_reading(lux, now);
                }
            }
        }
    }
}

/// A signal off the session bus: KDE's brightness changed (the session bus is the owner's own: no sender check).
fn on_session(auto: &mut Auto<Real>, m: &Msg) {
    if m.kind != SIGNAL || m.member != "PropertiesChanged" || m.path != KDE_PATH {
        return;
    }
    if let Some((iface, props)) = properties_changed(m) {
        for (k, v) in props {
            if let (KDE_IFACE, "Brightness", Val::Int(b)) = (iface.as_str(), k.as_str(), v) {
                auto.on_brightness(b);
            }
        }
    }
}

/// RUST: a bus that closes ends the service with a line in the journal. Python's GDBus connection raised SIGTERM on
/// itself (exit-on-close), silently; both are a clean stop, which Restart=on-failure leaves alone.
fn lost(bus: &str, e: io::Error) -> ! {
    say(&format!("{bus} bus lost: {e}"));
    std::process::exit(0)
}

fn main() {
    let t0 = Instant::now();
    let now = || t0.elapsed().as_secs_f64();
    let (mut auto, mut sensor, mut screen) = match start(now()) {
        Ok(s) => s,
        Err(e) => {
            say(&format!("cannot start: {e}"));
            std::process::exit(1)
        }
    };
    loop {
        // signals read off the sockets, or while a call waited for its reply
        loop {
            if let Some(m) = auto.out.sys.pending.pop_front() {
                on_system(&mut auto, &mut sensor, &m, now());
            } else if let Some(m) = auto.out.ses.pending.pop_front() {
                on_session(&mut auto, &m);
            } else {
                break;
            }
        }
        let t = now();
        let tick = match &screen {
            Screen::Sysfs { next, .. } => Some(*next),
            Screen::Kwin(_) => None,
        };
        let timeout = auto.deadline().into_iter().chain(tick).min_by(f64::total_cmp);
        let timeout = timeout.map_or(-1, |d| ((d - t) * 1000.0).ceil().clamp(0.0, 3.6e6) as i32);
        let wl_fd = match &screen {
            Screen::Kwin(w) => w.fd(),
            Screen::Sysfs { .. } => -1,
        };
        let mut fds = [auto.out.sys.fd(), auto.out.ses.fd(), wl_fd].map(|fd| libc::pollfd { fd, events: libc::POLLIN, revents: 0 });
        if unsafe { libc::poll(fds.as_mut_ptr(), 3, timeout) } < 0 {
            let e = io::Error::last_os_error();
            if e.kind() != io::ErrorKind::Interrupted {
                say(&format!("poll: {e}"));
                std::process::exit(1);
            }
            continue;
        }
        let t = now();
        if fds[0].revents != 0 {
            match auto.out.sys.read() {
                Ok(m) => auto.out.sys.pending.push_back(m),
                Err(e) => lost("system", e),
            }
        }
        if fds[1].revents != 0 {
            match auto.out.ses.read() {
                Ok(m) => auto.out.ses.pending.push_back(m),
                Err(e) => lost("session", e),
            }
        }
        if fds[2].revents != 0 {
            if let Screen::Kwin(w) = &mut screen {
                match w.read() {
                    Ok(()) => auto.on_screen(w.screen_on(), t),
                    Err(e) => screen = without_kwin(&e, t), // KWin restarted or crashed: sysfs until it is back
                }
            }
        }
        if matches!(&screen, Screen::Sysfs { next, .. } if t >= *next) {
            if matches!(screen, Screen::Sysfs { retry: true, .. }) {
                if let Ok(w) = Wl::open() {
                    say("KWin screen events back");
                    screen = Screen::Kwin(w);
                }
            }
            if let Screen::Sysfs { next, .. } = &mut screen {
                *next = t + 1.0;
            }
            auto.on_screen(screen.on(), t);
        }
        auto.on_timer(t);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    thread_local! {
        pub static LOGGED: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
    }

    fn logged(line: &str) -> bool {
        LOGGED.with(|l| l.borrow().iter().any(|s| s == line))
    }

    /// iio-sensor-proxy and PowerDevil as the logic sees them; Brightness stays 5000 (no echo) unless a test says so.
    #[derive(Default)]
    struct Fake {
        owner: bool,
        held: bool, // a client's ClaimLight is in force: iio-sensor-proxy only reads the sensor then
        calls: Vec<String>,
        set: Vec<i64>,
        saved: Vec<f64>,
        bright: Option<i64>,
    }

    impl Out for Fake {
        fn sensor(&mut self, method: &str) -> Result<(), String> {
            if !self.owner {
                return Err(format!("org.freedesktop.DBus.Error.ServiceUnknown: The name {SENSOR} was not provided by any .service files"));
            }
            self.calls.push(method.to_string());
            self.held = method == "ClaimLight";
            Ok(())
        }
        fn brightness(&mut self) -> Option<i64> {
            self.bright
        }
        fn set_brightness(&mut self, v: i64) {
            self.set.push(v);
        }
        fn save(&mut self, f: f64) {
            self.saved.push(f);
        }
    }

    fn start(owner: bool, lux: f64, factor: Option<f64>) -> Auto<Fake> {
        LOGGED.with(|l| l.borrow_mut().clear());
        Auto::new(Fake { owner, bright: Some(5000), ..Fake::default() }, 10000, factor, owner, true, lux, 0.0)
    }

    /// A reading, sent only while somebody holds a claim (as iio-sensor-proxy does).
    fn reading(a: &mut Auto<Fake>, lux: f64, t: f64) {
        if a.out.held {
            a.on_reading(lux, t);
        }
    }

    fn vanish(a: &mut Auto<Fake>) {
        (a.out.owner, a.out.held) = (false, false);
        a.on_owner(false);
    }

    fn appear(a: &mut Auto<Fake>) {
        (a.out.owner, a.out.held) = (true, false); // a new process: nobody's claim
        a.on_owner(true);
    }

    /// Runs the ramp and the forget timer to the end, the clock moving to each deadline.
    fn settle(a: &mut Auto<Fake>, t: &mut f64) {
        while !a.ramp.is_empty() || !a.forgets.is_empty() {
            *t = a.deadline().unwrap();
            a.on_timer(*t);
        }
    }

    fn want(a: &Auto<Fake>, lux: f64) -> i64 {
        (a.target(lux) * 10000.0).round_ties_even() as i64
    }

    // A1-A5, B1-B4, C1-C3: test-autobright.py's cases (2026-10-31 audit), with the signals in the order the bus sends
    // them instead of GDBusProxy's replay.

    #[test]
    fn sensor_service_absent_at_start_then_appears() {
        let mut a = start(false, 0.0, None); // A1: no error, so no 5 s restart loop
        assert!(a.out.calls.is_empty()); // A2: nothing claimed while it is absent
        assert!(logged("start: lux 0, brightness 5000/10000, factor 1.00, light sensor service not there yet"));
        a.on_reading(0.0, 0.5); // a LightLevel from before our claim is not a reading
        a.out.owner = true;
        a.on_owner(true);
        assert_eq!(a.out.calls, ["ClaimLight"]); // A3
        assert!(a.ema.is_none() && a.ramp.is_empty()); // A4
        assert!(logged("light sensor service back: light sensor claimed"));
        let mut t = 1.0;
        reading(&mut a, 2000.0, t);
        settle(&mut a, &mut t);
        assert_eq!(a.out.set.last(), Some(&want(&a, 2000.0))); // A5: the first real reading is applied at once
    }

    #[test]
    fn sensor_service_restarts_while_running() {
        let mut a = start(true, 300.0, None);
        assert_eq!(a.out.calls, ["ClaimLight"]); // B1
        let mut t = 0.5;
        reading(&mut a, 300.0, t);
        settle(&mut a, &mut t);
        let n = a.out.set.len();
        vanish(&mut a);
        assert!(logged("light sensor service gone"));
        t += 10.0; // the restart took a while: a stray 0 would weigh fully in the average
        a.on_reading(0.0, t);
        appear(&mut a);
        assert_eq!(a.out.calls, ["ClaimLight", "ClaimLight"]); // B2: claimed again on the new owner
        for _ in 0..6 {
            t += 1.0; // well past DARKEN_S with that 0 if it had counted
            a.on_timer(t);
        }
        assert_eq!(a.out.set.len(), n); // B3
        reading(&mut a, 20.0, t);
        settle(&mut a, &mut t);
        assert_eq!(a.out.set.last(), Some(&want(&a, 20.0))); // B4: the new owner's readings drive the brightness
    }

    #[test]
    fn sensor_service_back_while_the_screen_is_off() {
        let mut a = start(true, 300.0, None);
        a.on_screen(false, 1.0);
        assert!(logged("screen off: light sensor released"));
        vanish(&mut a);
        appear(&mut a);
        assert_eq!(a.out.calls, ["ClaimLight", "ReleaseLight"]); // C1: not claimed on the new owner while dark
        assert!(logged("light sensor service back"));
        a.on_screen(true, 2.0);
        assert_eq!(a.out.calls.last().unwrap(), "ClaimLight"); // C2
        assert!(a.claimed && logged("screen on: light sensor claimed"));
        a.on_screen(false, 3.0);
        vanish(&mut a);
        a.on_screen(true, 4.0);
        assert!(!a.claimed && logged("screen on: light sensor not claimed")); // C3
    }

    #[test]
    fn waits_out_the_band_then_ramps() {
        let mut a = start(true, 300.0, Some(1.0));
        assert!(a.out.saved.is_empty()); // not a first run
        reading(&mut a, 300.0, 0.0); // start/wake: already the curve's 0.50, under MIN_STEP: nothing set
        assert!(a.out.set.is_empty() && a.ref_lux == Some(300.0));
        reading(&mut a, 360.0, 0.2); // inside +-25 % (+-2 lux): no timer at all
        assert_eq!(a.deadline(), None);
        // brighter: 1.5 s outside the band
        reading(&mut a, 2000.0, 10.0);
        assert_eq!(a.deadline(), Some(11.5));
        a.on_timer(11.4);
        assert!(a.ramp.is_empty());
        a.on_timer(11.5);
        assert_eq!(a.ramp.len(), 8);
        let lux = a.ref_lux.unwrap();
        assert!(logged(&format!("light changed: lux {lux:.0} -> brightness 0.50 -> {:.2}", a.target(lux))));
        assert!((a.deadline().unwrap() - 11.6).abs() < 1e-9); // the first step 0.1 s later
        let (cur, tgt) = (0.5, a.target(lux));
        let mut t = 11.5;
        settle(&mut a, &mut t);
        let steps: Vec<i64> = (1..=8).map(|i| ((cur + (tgt - cur) * i as f64 / 8.0) * 10000.0).round_ties_even() as i64).collect();
        assert_eq!(a.out.set, steps);
        assert!((t - (11.5 + 0.8 + 1.5)).abs() < 1e-9, "{t}"); // last step 0.8 s after the change, forgotten 1.5 s later
        assert!(a.ours.is_empty() && a.deadline().is_none());
        // darker: a hand over the sensor for 3 s does nothing, 4 s does
        reading(&mut a, 2.0, 20.0);
        assert_eq!(a.deadline(), Some(24.0));
        reading(&mut a, 2000.0, 23.0);
        assert_eq!(a.deadline(), None);
        a.on_timer(24.0);
        assert_eq!(a.out.set.len(), 8);
        reading(&mut a, 2.0, 30.0);
        a.on_timer(33.9);
        assert!(a.ramp.is_empty());
        a.on_timer(34.0);
        assert_eq!(a.ramp.len(), 8);
    }

    #[test]
    fn a_ramp_end_looks_at_the_band_again() {
        let mut a = start(true, 300.0, Some(1.0));
        reading(&mut a, 300.0, 0.0);
        reading(&mut a, 2000.0, 10.0);
        a.on_timer(11.5);
        let mut t = 11.5;
        while a.ramp.len() > 4 {
            t = a.deadline().unwrap();
            a.on_timer(t);
        }
        reading(&mut a, 2.0, t + 0.05); // dark again mid-ramp: not looked at until the ramp is done
        assert!(a.out_since.is_none());
        while !a.ramp.is_empty() {
            t = a.deadline().unwrap();
            a.on_timer(t);
        }
        assert_eq!(a.out_since, Some(t)); // the band timer starts at the last step
        a.on_timer(t + FORGET_S);
        assert_eq!(a.deadline(), Some(t + DARKEN_S));
    }

    #[test]
    fn owner_moves_the_slider() {
        let mut a = start(true, 300.0, Some(1.0));
        let mut t = 0.0;
        reading(&mut a, 300.0, t);
        a.on_brightness(7000); // not ours: factor = 0.70 / curve(300) = 1.40, kept
        assert_eq!(a.out.saved, [1.4]);
        assert!(logged("owner set 7000/10000 at lux 300: factor 1.40"));
        a.on_brightness(7050); // 1.41: within 0.02, not saved again
        assert_eq!(a.out.saved.len(), 1);
        // our own ramp: every value during it, and its echoes (within 8) until 1.5 s after, are ours
        reading(&mut a, 2000.0, 10.0);
        a.on_timer(11.5);
        a.on_brightness(1);
        while !a.ramp.is_empty() {
            t = a.deadline().unwrap();
            a.on_timer(t);
        }
        let last = *a.out.set.last().unwrap();
        a.on_brightness(last + 8);
        assert_eq!(a.out.saved.len(), 1);
        assert!(!a.ours.contains(&last)); // seen: no longer expected
        a.on_brightness(a.out.set[6] - 3); // an echo that came late, before the forget timer
        assert_eq!(a.out.saved.len(), 1);
        a.on_timer(t + FORGET_S);
        a.on_brightness(10000); // after it: the owner's
        assert_eq!(a.out.saved.len(), 2);
        // nothing learned in the dark (ema 0), and the factor is kept within 0.25-4
        let mut a = start(true, 0.0, Some(1.0));
        t = 0.0;
        reading(&mut a, 0.0, t);
        settle(&mut a, &mut t);
        a.on_brightness(9000);
        assert!(a.out.saved.is_empty());
        let mut a = start(true, 1.0, Some(1.0));
        t = 0.0;
        reading(&mut a, 1.0, t);
        settle(&mut a, &mut t);
        a.on_brightness(10000); // 1.0 / curve(1 lux) = 12.5
        assert_eq!(a.out.saved, [4.0]);
    }

    #[test]
    fn first_run_takes_todays_brightness() {
        let mut a = Auto::new(Fake { owner: true, bright: Some(6179), ..Fake::default() }, 10000, None, true, true, 300.0, 0.0);
        assert!((a.factor - 0.6179 / 0.5).abs() < 1e-9 && a.out.saved == [a.factor]);
        reading(&mut a, 300.0, 0.1); // so the first reading changes nothing
        assert!(a.ramp.is_empty());
        let a = start(true, 0.0, None); // no light (or no reading yet): factor 1
        assert_eq!(a.out.saved, [1.0]);
        let a = Auto::new(Fake { owner: true, ..Fake::default() }, 10000, None, true, true, 300.0, 0.0);
        assert_eq!(a.out.saved, [1.0]); // no Brightness: half of max at 300 lux (0.50)
        assert!(logged("start: lux 300, brightness None/10000, factor 1.00"));
        let a = start(true, 300.0, Some(1.7));
        assert!(a.out.saved.is_empty() && a.factor == 1.7);
    }

    #[test]
    fn screen_off_costs_nothing() {
        let mut a = Auto::new(Fake { owner: true, bright: Some(5000), ..Fake::default() }, 10000, Some(1.0), true, false, 300.0, 0.0);
        assert!(a.out.calls.is_empty()); // started dark: no claim
        a.on_reading(300.0, 1.0);
        assert!(a.ema.is_none() && a.deadline().is_none()); // no readings, no timers: poll() sleeps
        a.on_screen(true, 2.0);
        assert_eq!(a.out.calls, ["ClaimLight"]);
        reading(&mut a, 3000.0, 2.1);
        assert!(logged(&format!("start/wake: lux 3000 -> brightness 0.50 -> {:.2}", a.target(3000.0)))); // at once
        let mut t = 2.1;
        settle(&mut a, &mut t);
        reading(&mut a, 3.0, t); // out of the band...
        a.on_screen(false, t + 1.0); // ...and the screen goes off before it counts
        assert_eq!(a.out.calls, ["ClaimLight", "ReleaseLight"]);
        assert!(a.deadline().is_none() && !a.out.held);
    }

    #[test]
    fn curve_points() {
        for (lux, f) in CURVE {
            assert!((curve(lux) - f).abs() < 1e-12, "{lux}");
        }
        assert_eq!((curve(-5.0), curve(1e6)), (0.06, 1.0));
        let mut prev = 0.0;
        for lux in (0..6000).step_by(7) {
            let f = curve(lux as f64);
            assert!(f >= prev);
            prev = f;
        }
        // between 100 and 300 lux, linear in log10(lux + 1)
        let x = |l: f64| (l + 1.0).log10();
        assert!((curve(170.0) - (0.36 + 0.14 * (x(170.0) - x(100.0)) / (x(300.0) - x(100.0)))).abs() < 1e-12);
    }

    #[test]
    fn preference_file() {
        let dir = std::env::temp_dir().join(format!("y700-autobright-test-{}", std::process::id()));
        let conf = dir.join("y700/autobright.json");
        assert_eq!(load(&conf), None);
        save(&conf, 1.25).unwrap();
        assert_eq!(fs::read_to_string(&conf).unwrap(), "{\"factor\": 1.25}");
        assert_eq!(load(&conf), Some(1.25));
        save(&conf, 1.0).unwrap();
        assert_eq!(fs::read_to_string(&conf).unwrap(), "{\"factor\": 1.0}"); // as json.dump writes it
        assert!(!dir.join("y700/autobright.json.tmp").exists());
        fs::write(&conf, "{\"factor\": 1.7046874999999998}").unwrap(); // the Python version's
        assert_eq!(load(&conf), Some(1.7046874999999998));
        fs::write(&conf, "{}").unwrap();
        assert_eq!(load(&conf), None);
        fs::write(&conf, "{\"factor\": \"x\"").unwrap();
        assert_eq!(load(&conf), None);
        fs::remove_dir_all(&dir).unwrap();
    }

    /// On the tablet, as the session user: the real KWin and buses, read only (no claim, no brightness change).
    ///   runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
    ///     target/release/deps/y700_autobright-* --ignored --nocapture live
    #[test]
    #[ignore]
    fn live() {
        let wl = Wl::open().unwrap();
        let sysfs = sysfs_on(&dpms_files());
        println!("screen on: KWin {}, sysfs {sysfs}", wl.screen_on());
        assert_eq!(wl.screen_on(), sysfs);
        let mut sys = Bus::connect(SYSTEM_BUS).unwrap();
        let owner = sys.name_owner(SENSOR).unwrap();
        println!("{SENSOR}: {owner:?}");
        if owner.is_some() {
            println!("LightLevel {:?}", sys.get(SENSOR, SENSOR_PATH, SENSOR, "LightLevel").unwrap());
        }
        let mut ses = Bus::session().unwrap();
        let b = ses.get(KDE, KDE_PATH, KDE_IFACE, "Brightness").unwrap();
        let max = ses.get(KDE, KDE_PATH, KDE_IFACE, "MaxBrightness").unwrap();
        println!("Brightness {b:?} of {max:?}");
        assert!(matches!((b, max), (Val::Int(_), Val::Int(10000))));
        for rule in [SENSOR_MATCH, OWNER_MATCH] {
            sys.add_match(rule).unwrap();
        }
        ses.add_match(BRIGHTNESS_MATCH).unwrap();
    }
}
