//! y700-hud-overlay: the game performance numbers. Since 2026-10-22 (the numbers moved into the
//! status bar) the service runs `--sampler`: no window, only the sampler, writing the cache files the status bar
//! reads (linux/dock/y700-shellbar: HudLine.qml after the clock in an app, HudWidget.qml as a desktop widget; over
//! a fullscreen app the bar moves to the Overlay layer). Without arguments it is still the old bar, described below;
//! nothing starts it any more (kept for a session without the shellbar, by hand).
//!
//! The bar: a click-through status line KWin draws above everything (layer-shell overlay layer), including
//! fullscreen games: FPS (via the game's MangoHud / Gallium HUD log), CPU busy/clock/temperature, GPU busy/clock/
//! temperature, surface temperature, THR while throttling, battery percentage (BAT; yellow from 20 %, red from 10 %,
//! read every 30 s; on the charger also the charge rate), whole-device power (on the charger: input power, voltage,
//! adapter type, battery rate; on PPS only voltage and the battery's charge rate, CHG: the charge pumps' input
//! current is not visible). The numbers come from `sampler.rs`, in this process.
//!
//! Rust since 2026-10-17 (a power-sensitive device: resident programs in Rust); before that the same program in Python
//! (y700-hud-overlay + y700_hud_sampler.py, git history). The A/B on the tablet, same unit, only ExecStart swapped:
//! in a game 0.79-0.81 % -> 0.60-0.62 % of a core, RSS 104 -> 77 MB; what is left is GTK laying out and GSK drawing
//! one frame a second (C code, the same in any language).
//!
//!   y700-hud-overlay --sampler    the sampler alone (y700-hud-overlay.service since 10-22; y700-hud-toggle starts/
//!                                 stops it, never enabled at boot - the owner objected to it autostarting): the
//!                                 bar's cadence, the 200 ms rate polls' majority as kv.hz, no GTK at all
//!   y700-hud-overlay              the overlay bar (GTK; until 10-22 the service's mode)
//!   y700-hud-overlay --line       one sample over a 1 s window, the status line on stdout (no GTK; `y700-hudinfo`
//!                                 uses it when the overlay's cache is not fresh)
//!   y700-hud-overlay --once       the same with the key=value pairs
//!   y700-hud-overlay --bench N    CPU per sample (user/kernel): N incremental samples, 10 with an fd-count rescan,
//!                                 10 with a deep walk
//!
//! Look: flat dark bar flush with the top-left corner, monospace with fixed column widths (nothing jitters), labels in
//! MangoHud's colours (CPU blue, GPU green, power pink), values white, yellow/red when hot or slow. No text-shadow:
//! GSK's blurred shadow smears the glyph edges and the whole line looks out of focus (2026-10-13). Two looks, chosen
//! by the mode file $XDG_RUNTIME_DIR/y700-hud.mode (y700-hud-toggle writes it, a file monitor applies it at once):
//! "full" = everything; "mini" = FPS, battery and power only. When the line is wider than the screen (portrait while
//! charging) the charger details are dropped from the right, see tail().
//!
//! Cadence: the panel only drops from 120 Hz to 60 after 1 s without a frame and to 30 after 5 s (msm idle_refresh),
//! so a bar repainting every second pinned it at 120 Hz and cost ~1.4 W at idle (2026-10-15). With a game drawing
//! the panel runs at the game's rate anyway: per second; without one every 6 s (not 5: 5 never let the panel reach
//! 30 Hz), and an unchanged line is not repainted. Without a game the first column shows HZ: the rate the panel
//! spent most of the interval at, polled every 200 ms (a single reading caught the panel just after our own repaint
//! had kicked it to 120). Screen off (DPMS, connected connectors only): no sampling, no drawing, the DPMS check every
//! 2 s; on wake the counters are primed and the first fresh line shown a second later.
//!
//! GPU resets: GTK draws with Vulkan (Turnip); after a GPU hang recovery (Chrome hanging the GPU, 2026-10-14) Turnip
//! reports VK_ERROR_DEVICE_LOST and GTK never recreates the device - the bar froze on its last frame. So stderr is
//! watched and on "device lost" the process exits 75; the unit restarts it (Restart=on-failure, no start limit).
//! (cairo rendering was not taken instead: the screen scale is 1.9 and cairo draws at 2x, the text goes soft.)
//!
//! Linking: libgtk4-layer-shell is the binary's first NEEDED library, loaded before libwayland-client, so - unlike
//! Python, whose interpreter had loaded GTK first - no LD_PRELOAD is needed. Built on the tablet against Ubuntu's
//! packaged crates (see Cargo.toml); `../install.sh` builds and installs.
mod sampler;

use gtk4 as gtk;
use gtk::prelude::*;
use gtk::{gdk, gio, glib};
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use sampler::{hz_of, Kv, Sampler, RS};
use std::cell::{Cell, RefCell};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Rc;
use std::time::{Duration, Instant};

const GAME_MS: u64 = 1000;
const IDLE_MS: u64 = 6000;
const CSS: &str = r#"
window { background: transparent; }
.hud { background-color: rgba(0, 0, 0, 0.66); padding: 3px 10px 4px 10px; }
.hud label { font-family: "Ubuntu Sans Mono", "DejaVu Sans Mono", monospace; font-weight: 700;
        font-size: 19px; color: #ffffff; }
"#;
// MangoHud's palette
const C_FPS: &str = "#ffffff";
const C_CPU: &str = "#2e97cb";
const C_GPU: &str = "#2e9762";
const C_POWER: &str = "#cc6a9b";
const C_BAT: &str = "#ff9078";
const C_SEP: &str = "#6f6f6f";
const C_OK: &str = "#ffffff";
const C_WARN: &str = "#fdfd09";
const C_BAD: &str = "#eb5b5b";

/// Self-heal after a GPU reset: fd 2 goes through a pipe, everything is passed on to the journal, and the
/// process exits with 75 when the GPU device is reported lost (systemd starts a fresh renderer).
fn watch_stderr() {
    const LOST: [&[u8]; 3] = [b"DEVICE_LOST", b"device has been lost", b"GPU faulted or hung"];
    unsafe {
        let mut p = [0i32; 2];
        if libc::pipe2(p.as_mut_ptr(), libc::O_CLOEXEC) != 0 {
            return;
        }
        let journal = libc::fcntl(2, libc::F_DUPFD_CLOEXEC, 0);
        if journal < 0 || libc::dup2(p[1], 2) < 0 {
            return;
        }
        libc::close(p[1]);
        let r = p[0];
        std::thread::spawn(move || {
            let (mut buf, mut tail) = ([0u8; 4096], Vec::<u8>::with_capacity(8192));
            loop {
                let n = libc::read(r, buf.as_mut_ptr().cast(), buf.len());
                if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                if n <= 0 {
                    return;
                }
                let chunk = &buf[..n as usize];
                libc::write(journal, chunk.as_ptr().cast(), chunk.len());
                tail.extend_from_slice(chunk);
                if tail.len() > 4096 {
                    tail.drain(..tail.len() - 4096);
                }
                if LOST.iter().any(|s| tail.windows(s.len()).any(|w| w == *s)) {
                    let m = b"y700-hud-overlay: GPU device lost (GPU reset); exiting so systemd starts a fresh renderer\n";
                    libc::write(journal, m.as_ptr().cast(), m.len());
                    libc::_exit(75);
                }
            }
        });
    }
}

fn esc(t: &str) -> String {
    t.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&#x27;")
}

fn span(text: &str, color: &str) -> String {
    format!("<span foreground=\"{color}\">{}</span>", esc(text))
}

/// colour for a number: white, yellow from warn, red from bad (reverse: low values are bad)
fn grade(v: f64, warn: f64, bad: f64, reverse: bool) -> &'static str {
    if reverse {
        if v <= bad { C_BAD } else if v <= warn { C_WARN } else { C_OK }
    } else if v >= bad {
        C_BAD
    } else if v >= warn {
        C_WARN
    } else {
        C_OK
    }
}

fn num(s: &str) -> f64 {
    s.parse().unwrap_or(0.0) // Python: float(kv.get(k) or 0)
}

/// The battery segment and the power segment, labels first like every other segment:
///   off the charger   BAT  62% | PWR  5.2W
///   charging          BAT  89% +15.3W | IN 19.8W  8.0V PD     (charge rate yellow; on PPS "IN    --  9.3V PPS":
///                                                              the charge pumps' input current is not readable)
///   on the charger, not charging: BAT 100% | PWR  4.5W  8.0V PD  (the device's draw; a negative rate in red)
/// Until 2026-10-20 the rate came last as "+15.3W batt" - a trailing "batt" read as a label whose number is
/// missing. `level` drops the charger details from the right until the bar fits the screen (portrait while
/// charging did not): 1 = no adapter type, 2 = no input voltage, 3 = no input segment. The level and the charge
/// rate always stay.
fn tail(kv: &Kv, level: u8) -> Vec<String> {
    let on = kv.on == "1";
    let bw = if kv.bat_w.is_empty() { None } else { Some(num(&kv.bat_w)) };
    let charging = on && bw.map_or(false, |b| b > 0.5);
    let pump = charging && kv.in_w.is_empty(); // charge pumps (PPS): input not measured, see sampler.rs
    let rate = bw.filter(|b| on && b.abs() >= 0.5); // a full battery on the charger shows no rate
    let mut out = vec![];
    if !kv.bat_pct.is_empty() || rate.is_some() {
        let mut b = span("BAT ", C_BAT)
            + &match kv.bat_pct.parse::<f64>() {
                Ok(p) => span(&format!("{p:3.0}%"), grade(p, 20.0, 10.0, true)),
                Err(_) => span("  --", C_SEP), // not read yet
            };
        if let Some(r) = rate {
            b += &(" ".to_string() + &span(&format!("{r:+.1}W"), if r > 0.0 { C_WARN } else { C_BAD }));
        }
        out.push(b);
    }
    if on && level >= 3 {
        return out;
    }
    let mut p = if pump {
        span("IN ", C_POWER) + &span("   --", C_SEP)
    } else if charging {
        span("IN ", C_POWER) + &span(&format!("{:4.1}W", num(&kv.in_w)), C_OK)
    } else {
        let sysw = num(&kv.sys_w);
        span("PWR ", C_POWER) + &span(&format!("{sysw:4.1}W"), grade(sysw, 12.0, 16.0, false))
    };
    if on && level < 2 && !kv.in_v.is_empty() {
        let v = num(&kv.in_v);
        if v > 0.5 {
            p += &(" ".to_string() + &span(&format!("{v:4.1}V"), if v < 6.0 { C_WARN } else { C_OK }));
            if level < 1 && !kv.adapter.is_empty() {
                p += &span(&format!(" {}", kv.adapter), C_SEP);
            }
        }
    }
    out.push(p);
    out
}

/// left/right padding of the bar (.hud in CSS), logical px
const PAD: i32 = 20;

struct Hud {
    s: RefCell<Sampler>,
    last: RefCell<Option<Kv>>,
    game: Cell<bool>,
    screen: Cell<bool>,
    hz_time: RefCell<Vec<(u32, u32)>>, // (rate, polls) in first-seen order
    dpms: Vec<String>,
    mode_path: String,
    label: RefCell<Option<gtk::Label>>,
    shown: RefCell<String>,
    tick: RefCell<Option<glib::SourceId>>,
    monitor: RefCell<Option<gio::FileMonitor>>,
}

impl Hud {
    fn read_kv(&self) -> Option<Kv> {
        // a sampling bug must not kill the bar
        match catch_unwind(AssertUnwindSafe(|| self.s.borrow_mut().sample())) {
            Ok(kv) => {
                *self.last.borrow_mut() = Some(kv.clone());
                Some(kv)
            }
            Err(_) => {
                eprintln!("sample failed: panic");
                None
            }
        }
    }

    fn mini(&self) -> bool {
        std::fs::read_to_string(&self.mode_path).map_or(false, |m| m.trim() == "mini")
    }

    fn panel_hz(&self) -> Option<u32> {
        majority(&mut self.hz_time.borrow_mut())
    }

    fn markup(&self, resample: bool) -> String {
        let kv = if resample || self.last.borrow().is_none() { self.read_kv() } else { self.last.borrow().clone() };
        let Some(kv) = kv else {
            self.game.set(false);
            return span("sampling...", C_SEP);
        };
        self.game.set(!kv.fps.is_empty());
        let sep = span(" | ", C_SEP);
        let mini = self.mini();
        let mut parts: Vec<String> = vec![];
        if !kv.fps.is_empty() {
            let fps = num(&kv.fps);
            parts.push(span("FPS ", C_FPS) + &span(&format!("{fps:3.0}"), grade(fps, 45.0, 28.0, true)));
        } else if !kv.hz.is_empty() {
            let hz = self.panel_hz().map(f64::from).filter(|h| *h != 0.0).unwrap_or_else(|| num(&kv.hz));
            parts.push(span("HZ  ", C_SEP) + &span(&format!("{hz:3.0}"), C_OK));
        } else if mini {
            parts.push(span("FPS ", C_FPS) + &span(" --", C_SEP));
        }
        if mini {
            return self.fit(parts, &kv, &sep);
        }
        let (cpu, cmhz, cc) = (num(&kv.cpu), num(&kv.cpu_mhz), num(&kv.cpu_c));
        parts.push(
            span("CPU ", C_CPU) + &span(&format!("{cpu:3.0}%"), grade(cpu, 80.0, 95.0, false)) + " "
                + &span(&format!("{cmhz:4.0}MHz"), C_OK) + " " + &span(&format!("{cc:2.0}°C"), grade(cc, 85.0, 95.0, false)),
        );
        let (gpu, gmhz, gc) = (num(&kv.gpu), num(&kv.gpu_mhz), num(&kv.gpu_c));
        // a low GPU clock only matters while the GPU is actually busy (idle = 160 MHz by design)
        let clk = if gpu >= 50.0 { grade(gmhz, 800.0, 650.0, true) } else { C_OK };
        parts.push(
            span("GPU ", C_GPU) + &span(&format!("{gpu:3.0}%"), grade(gpu, 85.0, 97.0, false)) + " "
                + &span(&format!("{gmhz:4.0}MHz"), clk) + " " + &span(&format!("{gc:2.0}°C"), grade(gc, 80.0, 90.0, false)),
        );
        let skin = num(&kv.skin_c);
        let mut t = span("SKIN ", C_POWER) + &span(&format!("{skin:2.0}°C"), grade(skin, 50.0, 56.0, false));
        if num(&kv.thr) as i64 != 0 {
            t += &(" ".to_string() + &span("THR", C_BAD));
        }
        parts.push(t);
        self.fit(parts, &kv, &sep)
    }

    /// head + the battery/power tail at the most detailed level whose bar fits the screen width
    fn fit(&self, head: Vec<String>, kv: &Kv, sep: &str) -> String {
        let mut text = String::new();
        for level in 0..=3u8 {
            let mut p = head.clone();
            p.extend(tail(kv, level));
            text = p.join(sep);
            if self.fits(&text) {
                break;
            }
        }
        text
    }

    /// does the bar with this markup fit the width of the screen it is on (logical px; rotation changes it)?
    fn fits(&self, text: &str) -> bool {
        let Some(lab) = self.label.borrow().clone() else { return true };
        let disp = lab.display();
        let mon = lab
            .native()
            .and_then(|n| n.surface())
            .and_then(|s| disp.monitor_at_surface(&s))
            .or_else(|| disp.monitors().item(0).and_then(|o| o.downcast::<gdk::Monitor>().ok()));
        let Some(mon) = mon else { return true };
        let layout = lab.create_pango_layout(None); // the label's own font (CSS)
        layout.set_markup(text);
        layout.pixel_size().0 + PAD <= mon.geometry().width()
    }

    fn show(&self, resample: bool) {
        let text = self.markup(resample);
        if *self.shown.borrow() != text {
            // an unchanged line is not repainted (no frame, no 120 Hz)
            if let Some(l) = self.label.borrow().as_ref() {
                l.set_markup(&text);
            }
            *self.shown.borrow_mut() = text;
        }
    }

    fn screen_on(&self) -> bool {
        screen_on(&mut self.s.borrow_mut(), &self.dpms)
    }
}

/// the rate the most polls saw since the last call, first seen on a tie; the votes are cleared
fn majority(t: &mut Vec<(u32, u32)>) -> Option<u32> {
    let mut best: Option<(u32, u32)> = None;
    for &(hz, n) in t.iter() {
        if best.map_or(true, |(_, bn)| n > bn) {
            best = Some((hz, n));
        }
    }
    t.clear();
    best.map(|b| b.0)
}

/// one 200 ms poll of the panel's refresh rate (msm idle_refresh_state) into the votes
fn vote(s: &mut Sampler, t: &mut Vec<(u32, u32)>) {
    if let Some(hz) = s.pv(RS, 4096).as_deref().and_then(hz_of).and_then(|h| h.parse::<u32>().ok()) {
        match t.iter_mut().find(|e| e.0 == hz) {
            Some(e) => e.1 += 1,
            None => t.push((hz, 1)),
        }
    }
}

/// any connected connector's DPMS On (no connector found: assume on)
fn screen_on(s: &mut Sampler, dpms: &[String]) -> bool {
    dpms.iter().any(|p| s.pv(p, 64).map_or(false, |v| v.starts_with("On"))) || dpms.is_empty()
}

/// only CONNECTED connectors count (the disconnected DP-1 and the Writeback connector say "On" forever)
fn dpms_paths() -> Vec<String> {
    let mut dpms = vec![];
    for e in std::fs::read_dir("/sys/class/drm").into_iter().flatten().flatten() {
        let (d, st) = (e.path().join("dpms"), e.path().join("status"));
        if d.exists() && std::fs::read_to_string(&st).map_or(false, |s| s.trim() == "connected") {
            dpms.push(d.to_string_lossy().into_owned());
        }
    }
    dpms
}

/// --sampler: the service's mode since 2026-10-22, the numbers without the bar (the status bar shows them). The
/// bar's rules in a plain loop: a 200 ms poll of the panel rate (and of DPMS), a sample per second while a game
/// draws and every 6 s without one (the status bar repaints only when a value changed, so the panel can still
/// drop to 30 Hz between samples, see the cadence note above), nothing with the screen off (DPMS every 2 s); on
/// wake the counters are primed without writing and the first fresh sample lands a second later. The cache
/// files stay while the screen is off (the bar is dark then) and go with the service (the unit's ExecStopPost).
fn run_sampler() -> glib::ExitCode {
    let dpms = dpms_paths();
    let mut s = Sampler::new(true);
    s.prime();
    let mut votes: Vec<(u32, u32)> = vec![];
    let mut screen = true;
    let mut next = Instant::now() + Duration::from_millis(600);
    loop {
        if !screen_on(&mut s, &dpms) {
            screen = false;
            std::thread::sleep(Duration::from_secs(2));
            continue;
        }
        if !screen {
            screen = true;
            s.prime();
            votes.clear();
            next = Instant::now() + Duration::from_millis(1000);
        }
        vote(&mut s, &mut votes);
        let now = Instant::now();
        if now >= next {
            s.hz_vote = majority(&mut votes).map(|h| h.to_string());
            // a sampling bug must not stop the numbers
            let game = match catch_unwind(AssertUnwindSafe(|| s.sample())) {
                Ok(kv) => !kv.fps.is_empty(),
                Err(_) => {
                    eprintln!("sample failed: panic");
                    false
                }
            };
            next = now + Duration::from_millis(if game { GAME_MS } else { IDLE_MS });
        }
        let left = next.saturating_duration_since(Instant::now());
        std::thread::sleep(left.clamp(Duration::from_millis(1), Duration::from_millis(200)));
    }
}

// ONE chain of ticks samples and draws; nothing else may sample in between (see the Python file)
fn schedule_tick(hud: &Rc<Hud>, ms: u64) {
    let h = hud.clone();
    *hud.tick.borrow_mut() = Some(glib::timeout_add_local_once(Duration::from_millis(ms), move || tick(&h)));
}

fn tick(hud: &Rc<Hud>) {
    hud.tick.borrow_mut().take(); // this source has fired
    if !hud.screen.get() {
        return; // screen off: the chain stops, wake() starts it again
    }
    hud.show(true);
    schedule_tick(hud, if hud.game.get() { GAME_MS } else { IDLE_MS });
}

fn wake(hud: &Rc<Hud>) {
    hud.read_kv(); // prime: an average over the whole screen-off time would be meaningless
    if let Some(id) = hud.tick.borrow_mut().take() {
        id.remove();
    }
    schedule_tick(hud, 1000);
}

fn poll_hz(hud: &Rc<Hud>) {
    let on = hud.screen_on();
    if on && !hud.screen.get() {
        wake(hud);
    }
    hud.screen.set(on);
    if on {
        let s = hud.s.borrow_mut().pv(RS, 4096);
        if let Some(hz) = s.as_deref().and_then(hz_of).and_then(|h| h.parse::<u32>().ok()) {
            let mut t = hud.hz_time.borrow_mut();
            match t.iter_mut().find(|e| e.0 == hz) {
                Some(e) => e.1 += 1,
                None => t.push((hz, 1)),
            }
        }
    }
    let h = hud.clone();
    glib::timeout_add_local_once(Duration::from_millis(if on { 200 } else { 2000 }), move || poll_hz(&h));
}

fn on_activate(app: &gtk::Application, hud: &Rc<Hud>) {
    // RUST: a second activation (a hand launch while the service runs) does not open a second bar
    if hud.label.borrow().is_some() {
        return;
    }
    let win = gtk::Window::builder().application(app).title("y700-hud-overlay").build();
    win.init_layer_shell();
    win.set_layer(Layer::Overlay);
    win.set_anchor(Edge::Top, true);
    win.set_anchor(Edge::Left, true);
    win.set_margin(Edge::Top, 0);
    win.set_margin(Edge::Left, 0);
    win.set_exclusive_zone(-1); // never push other windows around
    win.set_keyboard_mode(KeyboardMode::None);
    win.set_resizable(false); // size follows the content: the bar shrinks when switched to mini
    let prov = gtk::CssProvider::new();
    prov.load_from_data(CSS);
    if let Some(d) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(&d, &prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    }
    let first = span("sampling...", C_SEP);
    let lab = gtk::Label::new(None);
    lab.set_use_markup(true);
    lab.set_markup(&first);
    *hud.shown.borrow_mut() = first;
    let bx = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    bx.add_css_class("hud");
    bx.append(&lab);
    win.set_child(Some(&bx));
    win.present();
    *hud.label.borrow_mut() = Some(lab);
    schedule_tick(hud, 600); // the first line: 0.6 s after the priming sample
    let h = hud.clone();
    glib::timeout_add_local_once(Duration::from_millis(200), move || poll_hz(&h));
    // a switch full <-> mini applies at once, not at the next tick
    if let Ok(mon) = gio::File::for_path(&hud.mode_path).monitor_file(gio::FileMonitorFlags::NONE, gio::Cancellable::NONE) {
        let h = hud.clone();
        mon.connect_changed(move |_, _, _, _| h.show(false));
        *hud.monitor.borrow_mut() = Some(mon);
    }
    // rotation changes the screen width: lay the line out again at once (fits() picks the detail level)
    if let Some(d) = gdk::Display::default() {
        let ms = d.monitors();
        for i in 0..ms.n_items() {
            if let Some(m) = ms.item(i).and_then(|o| o.downcast::<gdk::Monitor>().ok()) {
                let h = hud.clone();
                m.connect_geometry_notify(move |_| h.show(false));
            }
        }
    }
    // input passes through: an empty input region
    match win.surface() {
        Some(surf) => surf.set_input_region(&gtk::cairo::Region::create()),
        None => println!("no click-through: no surface"),
    }
}

/// (user, system) CPU seconds of this process
fn cpu_us() -> (f64, f64) {
    let mut r: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut r) };
    let t = |v: libc::timeval| v.tv_sec as f64 + v.tv_usec as f64 / 1e6;
    (t(r.ru_utime), t(r.ru_stime))
}

/// --line / --once / --bench: the sampler alone, no GTK, no cache files (the overlay's are left alone)
fn cli(args: &[String]) -> Option<glib::ExitCode> {
    let mode = args.get(1)?.as_str();
    if !["--line", "--once", "--bench"].contains(&mode) {
        return None;
    }
    let mut s = Sampler::new(false);
    s.sample();
    std::thread::sleep(Duration::from_secs(1));
    let kv = s.sample();
    if mode != "--line" {
        for (k, v) in kv.pairs() {
            println!("{k}={v}");
        }
    }
    println!("{}", s.line);
    if mode == "--bench" {
        let n: usize = args.get(2).and_then(|a| a.parse().ok()).unwrap_or(200);
        let (u0, k0) = cpu_us();
        for _ in 0..n {
            s.sample();
        }
        let (u1, k1) = cpu_us();
        println!("incremental sample: {:.3} ms CPU each ({n} samples): user {:.3}, kernel {:.3}",
                 (u1 - u0 + k1 - k0) / n as f64 * 1e3, (u1 - u0) / n as f64 * 1e3, (k1 - k0) / n as f64 * 1e3);
        for deep in [false, true] {
            let (u0, k0) = cpu_us();
            for _ in 0..10 {
                s.force_rescan(deep);
                s.sample();
            }
            let (u1, k1) = cpu_us();
            println!("sample with a {} rescan: {:.2} ms CPU each: user {:.2}, kernel {:.2}", if deep { "deep" } else { "fd-count" },
                     (u1 - u0 + k1 - k0) / 10.0 * 1e3, (u1 - u0) / 10.0 * 1e3, (k1 - k0) / 10.0 * 1e3);
        }
    }
    Some(glib::ExitCode::SUCCESS)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn kv(on: &str, bat_w: &str, in_w: &str) -> Kv {
        Kv { on: on.into(), bat_w: bat_w.into(), in_w: in_w.into(), sys_w: "4.5".into(), in_v: "8.0".into(),
             adapter: "PD".into(), bat_pct: "89".into(), ..Default::default() }
    }
    #[test]
    fn majority_vote() {
        let mut t = vec![(120, 2), (60, 5), (30, 5)];
        assert_eq!(majority(&mut t), Some(60)); // most polls; first seen wins a tie
        assert!(t.is_empty());
        assert_eq!(majority(&mut t), None);
    }
    #[test]
    fn battery_level() {
        let k = |p: &str| Kv { bat_pct: p.into(), ..Default::default() };
        assert!(tail(&k(""), 0).len() == 1); // no BAT segment until read, PWR stays
        assert!(tail(&k("61"), 0)[0].contains(" 61%") && tail(&k("61"), 0)[0].contains(C_OK));
        assert!(tail(&k("20"), 0)[0].contains(C_WARN));
        assert!(tail(&k("9"), 0)[0].contains(C_BAD));
        assert!(tail(&k("100"), 0)[0].contains("100%"));
    }
    #[test]
    fn charging_levels() {
        let c = kv("1", "15.3267", "19.8");
        let t0 = tail(&c, 0).join("|");
        assert!(t0.contains("+15.3W") && t0.contains("IN ") && t0.contains("8.0V") && t0.contains(" PD"), "{t0}");
        assert!(!t0.contains("batt"));
        let t1 = tail(&c, 1).join("|");
        assert!(t1.contains("8.0V") && !t1.contains(" PD"));
        let t2 = tail(&c, 2).join("|");
        assert!(t2.contains("19.8W") && !t2.contains("8.0V"));
        let t3 = tail(&c, 3);
        assert!(t3.len() == 1 && t3[0].contains("+15.3W") && t3[0].contains(" 89%"));
    }
    #[test]
    fn charger_cases() {
        let pump = tail(&kv("1", "21.2", ""), 0).join("|");
        assert!(pump.contains("+21.2W") && pump.contains("--") && pump.contains(" PD"), "{pump}");
        let full = tail(&kv("1", "0.1", "4.6"), 0);
        assert!(full[0].ends_with("89%</span>") && full[1].contains("PWR"), "{full:?}"); // no rate when full
        let drain = tail(&kv("1", "-1.2", "3.0"), 0);
        assert!(drain[0].contains("-1.2W") && drain[0].contains(C_BAD) && drain[1].contains("PWR"));
        let off = tail(&kv("0", "", "0"), 3); // off the charger nothing is dropped
        assert!(off.len() == 2 && off[1].contains("PWR") && !off[1].contains("V<"));
    }
}

fn main() -> glib::ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if let Some(code) = cli(&args) {
        return code;
    }
    if args.get(1).map(String::as_str) == Some("--sampler") {
        return run_sampler();
    }
    watch_stderr();
    let rt = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    let dpms = dpms_paths();
    let mut s = Sampler::new(true);
    s.sample(); // primes the counters: busy values need a previous sample
    let hud = Rc::new(Hud {
        s: RefCell::new(s),
        last: RefCell::new(None),
        game: Cell::new(false),
        screen: Cell::new(true),
        hz_time: RefCell::new(vec![]),
        dpms,
        mode_path: format!("{rt}/y700-hud.mode"),
        label: RefCell::new(None),
        shown: RefCell::new(String::new()),
        tick: RefCell::new(None),
        monitor: RefCell::new(None),
    });
    let app = gtk::Application::builder().application_id("fyi.y700.HudOverlay").build();
    let h = hud.clone();
    app.connect_activate(move |app| on_activate(app, &h));
    // RUST: the exit status is g_application_run's (only a D-Bus registration error makes it 1, then systemd
    // retries); Python discarded it and exited 0
    app.run_with_args::<&str>(&[])
}
