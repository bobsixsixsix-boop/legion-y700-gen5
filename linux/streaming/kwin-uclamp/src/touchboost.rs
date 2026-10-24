//! Touch boost (2026-10-21): raise the GPU's lowest clock the moment a finger lands on a screen edge, drop it again
//! right after the gesture. The edge gestures (cards, home, back, control centre) and their animations then render
//! at a clock that fits the 120 Hz frame, from the first frame on.
//!
//! Why the GPU and not the CPU (phones boost a big core): measured 10-21 with linux/gesture/tests/ts-boost-measure.sh
//! (hold up -> cards, two sideways drags, tap a card, flick home; 3-4 rounds per variant). During the gestures the
//! GPU stayed at its 160 MHz floor the whole time (simple_ondemand samples every 50 ms and the load never looked
//! high enough), KWin's GPU jobs took 6.1 ms median / 14.5 ms p95 from submit to done (one frame is 8.3 ms) and
//! 1.5-1.7 % of the frames in steady motion were lost. GPU floor 600 MHz: p95 7.6 ms, 1.13-1.17 % lost; 902 MHz:
//! p95 6.8 ms, 1.02-1.18 %. Big cores held at 3.13 GHz or KWin at uclamp.min 1024 changed nothing measurable:
//! KWin's main thread was 5-20 % busy and the little cores it runs on already sat at 2.7-2.9 GHz (uclamp 512).
//!
//! How: a thread reads every direct touch device (INPUT_PROP_DIRECT with ABS_MT_POSITION_X: the panel and the
//! tests' uinput clone y700-vtouch), found in /sys/class/input and again whenever /dev/input changes (inotify), so
//! it costs nothing while the screen is not touched. A first finger down within BOOST_EDGE_PERMILLE of any side
//! (native coordinates: all four sides, so the rotation does not matter) starts a session: GPU min_freq goes to
//! BOOST_GPU_MHZ at once. The last finger up keeps it BOOST_TAIL_MS more (the release animation), and a new touch
//! anywhere within BOOST_REARM_MS of that lift boosts again (dragging and tapping the cards). A session never lasts
//! more than BOOST_MAX_MS from its edge touch (a finger resting on the edge, a game): then the clock goes back and
//! only a new edge touch starts another. Restored = base_floor() (the helper profile floor, or y700-gpu-floor's while
//! it holds one; max_freq is never touched, so gpu-floor's Chrome-video ceiling stays). `--release`
//! (ExecStopPost) puts min_freq back to that floor if it was left at the boost value. y700-gpu-floor giving its floor
//! back (helper `gpu limits`) during a boost ends that boost early; harmless.
use std::fs;
use std::os::raw::{c_int, c_ulong, c_void};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

extern "C" {
    fn open(path: *const u8, flags: c_int, ...) -> c_int;
    fn read(fd: c_int, buf: *mut c_void, n: usize) -> isize;
    fn ioctl(fd: c_int, req: c_ulong, ...) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn poll(fds: *mut super::PollFd, nfds: c_ulong, timeout: c_int) -> c_int;
    fn inotify_init1(flags: c_int) -> c_int;
    fn inotify_add_watch(fd: c_int, path: *const u8, mask: u32) -> c_int;
}
const O_RDONLY_NONBLOCK_CLOEXEC: c_int = 0o4000 | 0o2000000;
const IN_CREATE: u32 = 0x100;
const IN_ATTRIB: u32 = 0x4;
const EV_SYN: u16 = 0;
const EV_KEY: u16 = 1;
const EV_ABS: u16 = 3;
const SYN_REPORT: u16 = 0;
const BTN_TOUCH: u16 = 0x14a;
const ABS_MT_POSITION_X: u16 = 0x35;
const ABS_MT_POSITION_Y: u16 = 0x36;
const INPUT_PROP_DIRECT: u32 = 1;
pub const GPU: &str = "/sys/class/devfreq/3d00000.gpu";

#[derive(Debug, PartialEq, Clone)]
pub struct BoostCfg {
    pub mhz: u32,
    pub tail_ms: u64,
    pub rearm_ms: u64,
    pub max_ms: u64,
    pub edge_permille: u32,
}

pub fn parse_boost(text: &str) -> BoostCfg {
    let mut c = BoostCfg { mhz: 600, tail_ms: 600, rearm_ms: 3000, max_ms: 10000, edge_permille: 20 };
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else { continue };
        let v = v.trim().trim_matches('"');
        let n = v.parse::<u64>();
        match (k.trim(), n) {
            ("BOOST_GPU_MHZ", Ok(n)) if n <= 2000 => c.mhz = n as u32,
            ("BOOST_TAIL_MS", Ok(n)) if n <= 5000 => c.tail_ms = n,
            ("BOOST_REARM_MS", Ok(n)) if n <= 30000 => c.rearm_ms = n,
            ("BOOST_MAX_MS", Ok(n)) if (100..=60000).contains(&n) => c.max_ms = n,
            ("BOOST_EDGE_PERMILLE", Ok(n)) if n <= 200 => c.edge_permille = n as u32,
            (k @ ("BOOST_GPU_MHZ" | "BOOST_TAIL_MS" | "BOOST_REARM_MS" | "BOOST_MAX_MS" | "BOOST_EDGE_PERMILLE"), _) => {
                eprintln!("{}: bad {k}={v:?}, keeping the default", super::CONF)
            }
            _ => {}
        }
    }
    c
}

/// bit `bit` of a sysfs bitmap ("661800000000000" or "400 0 0 0 0 0": hex words, most significant first)
pub fn has_bit(map: &str, bit: u32) -> bool {
    let words: Vec<&str> = map.split_whitespace().collect();
    let (w, b) = ((bit / 64) as usize, bit % 64);
    if w >= words.len() {
        return false;
    }
    u64::from_str_radix(words[words.len() - 1 - w], 16).map_or(false, |v| v >> b & 1 == 1)
}

/// eventN names of direct touch devices under `sysfs` (/sys/class/input)
pub fn touch_devices(sysfs: &Path) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(sysfs)
        .map(|d| {
            d.flatten()
                .filter_map(|e| {
                    let n = e.file_name().to_str()?.to_string();
                    let dev = e.path().join("device");
                    let props = fs::read_to_string(dev.join("properties")).ok()?;
                    let abs = fs::read_to_string(dev.join("capabilities/abs")).ok()?;
                    (n.starts_with("event") && has_bit(&props, INPUT_PROP_DIRECT) && has_bit(&abs, ABS_MT_POSITION_X as u32))
                        .then_some(n)
                })
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

/// what the session logic wants from the GPU
#[derive(Debug, PartialEq, Clone, Copy)]
pub enum Want {
    Boost,
    Idle,
}

/// the session state machine, time passed in so the tests can drive it
#[derive(Debug, Default)]
pub struct Session {
    start: Option<Instant>, // the edge touch that began it
    fingers_down: bool,
    last_up: Option<Instant>,
    pub boosted: bool,
}

impl Session {
    /// a first finger down (edge: within the margin of a side)
    pub fn down(&mut self, now: Instant, edge: bool, c: &BoostCfg) {
        self.fingers_down = true;
        let live = self.start.is_some()
            && (self.boosted || self.last_up.map_or(true, |u| now.duration_since(u) <= Duration::from_millis(c.rearm_ms)));
        if edge {
            self.start = Some(now); // every edge gesture gets its own BOOST_MAX_MS
        } else if !live {
            return;
        }
        self.last_up = None;
    }
    pub fn up(&mut self, now: Instant) {
        self.fingers_down = false;
        if self.start.is_some() {
            self.last_up = Some(now);
        }
    }
    /// what the GPU should be now, and when to look again (None: only on the next touch)
    pub fn tick(&mut self, now: Instant, c: &BoostCfg) -> (Want, Option<Instant>) {
        let Some(start) = self.start else { return (Want::Idle, None) };
        let cap = start + Duration::from_millis(c.max_ms);
        if now >= cap {
            *self = Session { boosted: self.boosted, ..Default::default() };
            return (Want::Idle, None);
        }
        if self.fingers_down {
            return (Want::Boost, Some(cap));
        }
        let up = self.last_up.unwrap_or(now);
        let tail = up + Duration::from_millis(c.tail_ms);
        let rearm = up + Duration::from_millis(c.rearm_ms);
        if now < tail {
            (Want::Boost, Some(tail.min(cap)))
        } else if now < rearm {
            (Want::Idle, Some(rearm.min(cap)))
        } else {
            self.start = None;
            (Want::Idle, None)
        }
    }
}

#[repr(C)]
#[derive(Default)]
struct InputEvent {
    sec: i64,
    usec: i64,
    kind: u16,
    code: u16,
    value: i32,
}
#[repr(C)]
#[derive(Default)]
struct AbsInfo {
    value: i32,
    minimum: i32,
    maximum: i32,
    fuzz: i32,
    flat: i32,
    resolution: i32,
}

struct Dev {
    name: String,
    fd: c_int,
    max: (i32, i32),
    pos: (i32, i32),
    touch: Option<bool>, // BTN_TOUCH seen in this frame
    down: bool,
}

fn cstr(p: &Path) -> Vec<u8> {
    let mut v = p.as_os_str().as_encoded_bytes().to_vec();
    v.push(0);
    v
}

fn abs_max(fd: c_int, code: u16) -> i32 {
    // EVIOCGABS(code) = _IOR('E', 0x40 + code, struct input_absinfo)
    let req = (2u64 << 30) | ((std::mem::size_of::<AbsInfo>() as u64) << 16) | (('E' as u64) << 8) | (0x40 + code as u64);
    let mut a = AbsInfo::default();
    if unsafe { ioctl(fd, req as c_ulong, &mut a as *mut AbsInfo) } == 0 { a.maximum } else { 0 }
}

fn open_dev(name: &str) -> Option<Dev> {
    let fd = unsafe { open(cstr(&Path::new("/dev/input").join(name)).as_ptr(), O_RDONLY_NONBLOCK_CLOEXEC) };
    if fd < 0 {
        return None;
    }
    let max = (abs_max(fd, ABS_MT_POSITION_X), abs_max(fd, ABS_MT_POSITION_Y));
    Some(Dev { name: name.into(), fd, max, pos: (-1, -1), touch: None, down: false })
}

pub fn is_edge(pos: (i32, i32), max: (i32, i32), permille: u32) -> bool {
    let m = |mx: i32| (mx as i64 * permille as i64 / 1000) as i32;
    let (mx, my) = (m(max.0), m(max.1));
    pos.0 >= 0 && pos.1 >= 0 && (pos.0 <= mx || pos.1 <= my || pos.0 >= max.0 - mx || pos.1 >= max.1 - my)
}

/// GPU min_freq: write, and the lowest available frequency
fn gpu_write(gpu: &Path, hz: u64) -> bool {
    fs::write(gpu.join("min_freq"), hz.to_string()).is_ok()
}
fn gpu_lowest(gpu: &Path) -> Option<u64> {
    fs::read_to_string(gpu.join("available_frequencies")).ok()?.split_whitespace().filter_map(|f| f.parse().ok()).min()
}
fn gpu_min(gpu: &Path) -> Option<u64> {
    fs::read_to_string(gpu.join("min_freq")).ok()?.trim().parse().ok()
}

/// the GPU floor of the active profile in `tb323fu-ctl gpu` output (MHz): `Profile: <name>`, and under `Floors:` the
/// lines `<name>: <min> <max>` (CpuRange above it has two-number lines too, so only that section counts)
pub fn helper_floor(text: &str) -> Option<u64> {
    let (mut profile, mut floors, mut in_floors) = (None, Vec::new(), false);
    for t in text.lines().map(str::trim) {
        if t == "Floors:" {
            in_floors = true;
            continue;
        }
        if let Some(v) = t.strip_prefix("Profile:") {
            profile = Some(v.trim().to_string());
        }
        if in_floors {
            let n: Option<(&str, Vec<u64>)> =
                t.split_once(':').map(|(a, b)| (a.trim(), b.split_whitespace().filter_map(|x| x.parse().ok()).collect()));
            match n {
                Some((name, v)) if v.len() == 2 => floors.push((name.to_string(), v[0])),
                _ => in_floors = false,
            }
        }
    }
    let p = profile?;
    floors.into_iter().find(|f| f.0 == p).map(|f| f.1)
}

/// what min_freq should be without a boost. NOT the min_freq read before boosting: devfreq reads back the effective
/// minimum, msm's wait-boost QoS requests included (linux/power/gpu-floor found that), so a boost that began during a
/// wait-boost would "restore" that boost for good. Instead: the helper's profile floor (tb323fu-helperd: balanced
/// 160, performance 461), raised to y700-gpu-floor's floor while that holds one (/run/y700-gpu-floor.state, first
/// line in Hz: a full-screen Chrome video), at least the lowest OPP.
fn base_floor(gpu: &Path) -> u64 {
    let helper = std::process::Command::new("tb323fu-ctl")
        .arg("gpu")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| helper_floor(&String::from_utf8_lossy(&o.stdout)))
        .map_or(0, |m| m * 1_000_000);
    let held = fs::read_to_string("/run/y700-gpu-floor.state")
        .ok()
        .and_then(|s| s.lines().next()?.trim().parse::<u64>().ok())
        .unwrap_or(0);
    helper.max(held).max(gpu_lowest(gpu).unwrap_or(0))
}

/// --release / start-up: a min_freq left at the boost value (daemon killed while boosted) goes back to the base floor
pub fn release(c: &BoostCfg) {
    let gpu = Path::new(GPU);
    let hz = c.mhz as u64 * 1_000_000;
    if c.mhz > 0 && gpu_min(gpu).map_or(false, |m| m >= hz) {
        let lo = base_floor(gpu);
        if lo > 0 && lo < hz && gpu_write(gpu, lo) {
            eprintln!("touch boost: GPU min_freq back to {} MHz", lo / 1_000_000);
        }
    }
}

pub fn run(c: BoostCfg) {
    let gpu = PathBuf::from(GPU);
    let hz = c.mhz as u64 * 1_000_000;
    release(&c);
    let ino = unsafe { inotify_init1(O_RDONLY_NONBLOCK_CLOEXEC) };
    if ino < 0 || unsafe { inotify_add_watch(ino, b"/dev/input\0".as_ptr(), IN_CREATE | IN_ATTRIB) } < 0 {
        eprintln!("touch boost: inotify on /dev/input failed, devices are only looked up once");
    }
    let mut devs: Vec<Dev> = Vec::new();
    let rescan = |devs: &mut Vec<Dev>| {
        let want = touch_devices(Path::new("/sys/class/input"));
        devs.retain(|d| {
            let keep = want.contains(&d.name);
            if !keep {
                unsafe { close(d.fd) };
            }
            keep
        });
        for n in want {
            if !devs.iter().any(|d| d.name == n) {
                if let Some(d) = open_dev(&n) {
                    eprintln!("touch boost: watching {n} ({}x{})", d.max.0 + 1, d.max.1 + 1);
                    devs.push(d);
                }
            }
        }
    };
    rescan(&mut devs);
    eprintln!(
        "touch boost: GPU min {} MHz on an edge touch, {} ms after the lift, re-armed {} ms, at most {} ms",
        c.mhz, c.tail_ms, c.rearm_ms, c.max_ms
    );
    let mut s = Session::default();
    let mut wrote = false;
    let (mut sessions, mut boosted_for, mut since, mut on_at) = (0u32, Duration::ZERO, Instant::now(), None::<Instant>);
    let mut next: Option<Instant> = None;
    loop {
        let mut fds: Vec<super::PollFd> = devs.iter().map(|d| super::PollFd { fd: d.fd, events: super::POLLIN, revents: 0 }).collect();
        if ino >= 0 {
            fds.push(super::PollFd { fd: ino, events: super::POLLIN, revents: 0 });
        }
        let timeout = next.map_or(-1, |t| t.saturating_duration_since(Instant::now()).as_millis() as c_int + 1);
        let r = unsafe { poll(fds.as_mut_ptr(), fds.len() as c_ulong, timeout) };
        if r < 0 && super::errno() != super::EINTR {
            eprintln!("touch boost: poll failed (errno {}), stopping", super::errno());
            break;
        }
        let (mut changed, mut gone, mut lifted) = (false, false, false);
        for (i, p) in fds.iter().enumerate() {
            if p.revents == 0 {
                continue;
            }
            if i == devs.len() {
                let mut buf = [0u8; 4096];
                while unsafe { read(ino, buf.as_mut_ptr() as *mut c_void, buf.len()) } > 0 {}
                changed = true;
                continue;
            }
            let d = &mut devs[i];
            let mut ev = [InputEvent::default(), InputEvent::default(), InputEvent::default(), InputEvent::default(),
                InputEvent::default(), InputEvent::default(), InputEvent::default(), InputEvent::default()];
            loop {
                let n = unsafe { read(d.fd, ev.as_mut_ptr() as *mut c_void, std::mem::size_of_val(&ev)) };
                if n <= 0 {
                    if n < 0 && super::errno() == 19 {
                        gone = true; // ENODEV: unplugged (vtouch quit)
                    }
                    break;
                }
                for e in &ev[..n as usize / std::mem::size_of::<InputEvent>()] {
                    match (e.kind, e.code) {
                        (EV_ABS, ABS_MT_POSITION_X) => d.pos.0 = e.value,
                        (EV_ABS, ABS_MT_POSITION_Y) => d.pos.1 = e.value,
                        (EV_KEY, BTN_TOUCH) => d.touch = Some(e.value != 0),
                        (EV_SYN, SYN_REPORT) => match d.touch.take() {
                            Some(true) if !d.down => {
                                d.down = true;
                                s.down(Instant::now(), is_edge(d.pos, d.max, c.edge_permille), &c);
                            }
                            Some(false) if d.down => {
                                d.down = false;
                                lifted = true;
                            }
                            _ => {}
                        },
                        _ => {}
                    }
                }
            }
        }
        if lifted && !devs.iter().any(|d| d.down) {
            s.up(Instant::now()); // the last finger on any touch device
        }
        if changed || gone {
            rescan(&mut devs);
        }
        let now = Instant::now();
        let (want, at) = s.tick(now, &c);
        next = at;
        match (want, s.boosted) {
            (Want::Boost, false) => {
                // first the write (the point is to be early), nothing read or started before it
                wrote = gpu_write(&gpu, hz);
                s.boosted = true; // also when the write failed: no retry on every event, the session just runs out
                sessions += wrote as u32;
                on_at = Some(now);
            }
            (Want::Idle, true) => {
                if wrote {
                    gpu_write(&gpu, base_floor(&gpu));
                }
                s.boosted = false;
                if let Some(t) = on_at.take() {
                    boosted_for += now - t;
                }
            }
            _ => {}
        }
        if sessions > 0 && !s.boosted && since.elapsed() >= Duration::from_secs(600) {
            eprintln!("touch boost: {sessions} boosts, {:.1} s at {} MHz in the last {} min", boosted_for.as_secs_f32(), c.mhz,
                since.elapsed().as_secs() / 60);
            (sessions, boosted_for, since) = (0, Duration::ZERO, Instant::now());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> BoostCfg {
        parse_boost("")
    }
    fn ms(t0: Instant, n: u64) -> Instant {
        t0 + Duration::from_millis(n)
    }

    #[test]
    fn config() {
        assert_eq!(cfg(), BoostCfg { mhz: 600, tail_ms: 600, rearm_ms: 3000, max_ms: 10000, edge_permille: 20 });
        let c = parse_boost("BOOST_GPU_MHZ=0\nBOOST_TAIL_MS=\"300\"\nBOOST_MAX_MS=50\nBOOST_EDGE_PERMILLE=999\n# BOOST_REARM_MS=1");
        assert_eq!(c, BoostCfg { mhz: 0, tail_ms: 300, rearm_ms: 3000, max_ms: 10000, edge_permille: 20 });
    }

    #[test]
    fn bitmaps_and_devices() {
        // the panel (NVTCapacitiveTouchScreen) and its pen, as the tablet's sysfs shows them
        assert!(has_bit("661800000000000", ABS_MT_POSITION_X as u32));
        assert!(!has_bit("f000003", ABS_MT_POSITION_X as u32));
        assert!(has_bit("400 0 0 0 0 0", BTN_TOUCH as u32));
        assert!(has_bit("2", INPUT_PROP_DIRECT) && !has_bit("0", INPUT_PROP_DIRECT) && !has_bit("", 1));
        let root = std::env::temp_dir().join(format!("y700-touchboost-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for (n, abs, prop) in [("event3", "661800000000000", "2"), ("event4", "f000003", "2"), ("event7", "0", "0"),
            ("event9", "661800000000000", "0"), ("event12", "661800000000000", "2")] {
            let d = root.join(n).join("device");
            fs::create_dir_all(d.join("capabilities")).unwrap();
            fs::write(d.join("capabilities/abs"), format!("{abs}\n")).unwrap();
            fs::write(d.join("properties"), format!("{prop}\n")).unwrap();
        }
        assert_eq!(touch_devices(&root), vec!["event12", "event3"]);
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn helper_profile_floor() {
        // `tb323fu-ctl gpu` on the tablet, 10-21 (CpuRange's two-number lines must not count as floors)
        let out = "Gpu:\n  CpuBoost: true\n  CpuLimits: \n      balanced: 384 3628 768 4396\n  CpuRange: \n      big: 768 4396\n\
                   \x20     little: 384 3628\n  Floors: \n      balanced: 160 1200\n      performance: 461 1200\n\
                   \x20     power-saver: 160 726\n  FollowPowerProfiles: false\n  Profile: balanced\n  WifiAvailable: true\n";
        assert_eq!(helper_floor(out), Some(160));
        assert_eq!(helper_floor(&out.replace("Profile: balanced", "Profile: performance")), Some(461));
        assert_eq!(helper_floor(&out.replace("Profile: balanced", "Profile: big")), None);
        assert_eq!(helper_floor(""), None);
    }

    #[test]
    fn edges() {
        let max = (1903, 3039); // 2 % = 38 / 60
        assert!(is_edge((950, 3035), max, 20) && is_edge((5, 1500), max, 20) && is_edge((1880, 10), max, 20));
        assert!(!is_edge((950, 1500), max, 20) && !is_edge((100, 100), max, 20) && !is_edge((-1, -1), max, 20));
    }

    #[test]
    fn a_card_gesture() {
        let c = cfg();
        let t = Instant::now();
        let mut s = Session::default();
        // a touch in the middle with no session: nothing
        s.down(t, false, &c);
        assert_eq!(s.tick(t, &c).0, Want::Idle);
        s.up(ms(t, 100));
        assert_eq!(s.tick(ms(t, 100), &c), (Want::Idle, None));
        // swipe up from the bottom edge and hold: boosted while down, then BOOST_TAIL_MS after the lift
        s.down(ms(t, 1000), true, &c);
        assert_eq!(s.tick(ms(t, 1000), &c), (Want::Boost, Some(ms(t, 11000))));
        s.boosted = true;
        s.up(ms(t, 2000));
        assert_eq!(s.tick(ms(t, 2000), &c), (Want::Boost, Some(ms(t, 2600))));
        assert_eq!(s.tick(ms(t, 2601), &c), (Want::Idle, Some(ms(t, 5000))));
        s.boosted = false;
        // looking at the cards for 2 s, then dragging them: boosted again (re-armed)
        s.down(ms(t, 4000), false, &c);
        assert_eq!(s.tick(ms(t, 4000), &c).0, Want::Boost);
        s.up(ms(t, 4300));
        assert_eq!(s.tick(ms(t, 4800), &c).0, Want::Boost);
        // nothing for 3 s after that: the session is over, a middle touch does not boost
        assert_eq!(s.tick(ms(t, 7300), &c), (Want::Idle, None));
        s.down(ms(t, 7400), false, &c);
        assert_eq!(s.tick(ms(t, 7400), &c).0, Want::Idle);
        s.up(ms(t, 7500));
    }

    #[test]
    fn capped() {
        let c = cfg();
        let t = Instant::now();
        let mut s = Session::default();
        // a finger resting on the edge (or a game): back to idle BOOST_MAX_MS after the edge touch
        s.down(t, true, &c);
        s.boosted = true;
        assert_eq!(s.tick(ms(t, 9999), &c).0, Want::Boost);
        assert_eq!(s.tick(ms(t, 10000), &c), (Want::Idle, None));
        s.boosted = false;
        // lifted, more middle touches: stay idle until a new edge touch
        s.up(ms(t, 12000));
        s.down(ms(t, 12100), false, &c);
        assert_eq!(s.tick(ms(t, 12100), &c).0, Want::Idle);
        s.up(ms(t, 12200));
        s.down(ms(t, 12300), true, &c);
        assert_eq!(s.tick(ms(t, 12300), &c), (Want::Boost, Some(ms(t, 22300))));
        // back gestures one after the other: each edge touch restarts the cap
        s.boosted = true;
        s.up(ms(t, 12500));
        s.down(ms(t, 20000), true, &c);
        assert_eq!(s.tick(ms(t, 23000), &c).0, Want::Boost);
    }
}
