//! y700-gpu-floor (2026-10-18, ROOT): while Chrome plays a full-screen video, hold the Adreno's devfreq range at
//! [FLOOR_MHZ, CEIL_MHZ], and give it back afterwards. Why a floor: extension 1.4 hides the page behind a full-screen
//! Chrome video, which leaves only KWin's composite and the video on the GPU; with the simple_ondemand threshold at 80
//! the GPU can then sit at 160 MHz where that work is close to a frame long, so KWin sometimes misses vblanks (803
//! dropped frames in 45 s in one window, README "视频播放功耗" 结论 4). A modest floor keeps the headroom.
//! Why a ceiling: in the owner's real Chrome session Chrome's GPU process waits on DRM syncobj timelines with a deadline
//! ~140 times a second (drm_syncobj_timeline_wait_ioctl -> dma_fence_set_deadline -> msm_fence_set_deadline), msm turns
//! that into wait-boost requests that hold the GPU at 1200 MHz (5 W instead of 3.5 W at 500 MHz, measured on the live
//! session, README 结论 6); a boost can never go above max_freq. The ceiling is only the fallback for a Chrome that was
//! started without linux/gpu/y700-no-waitboost.so (the LD_PRELOAD shim that drops the deadline flag, which removes the
//! storm at its source: 3.6 W instead of 5.0 W in a same-video A/B, README 结论 7): when that shim is mapped in the
//! browser process and its switch file `y700-no-waitboost.ctl` (next to the video directory) does not say "Y0", the
//! ceiling is not set and the GPU keeps its full range. Nothing else changes: other players (mpv, wiliwili)
//! and everything outside a Chrome video keep the helper's profile limits.
//!
//! Condition: a state file `chrome-<pid>` in the user's y700-video directory (written by the Y700 Chrome extension +
//! native host, see linux/display/refresh-auto/chrome) says playing=1, that browser process is alive, and the panel is
//! on. With fullscreen=1 too (Level::Full) floor and ceiling are both set; with a video playing in the page
//! (Level::Playing) only the ceiling is (CEIL_WHEN=playing, the default; CEIL_WHEN=fullscreen restricts it to full
//! screen). Both are dropped RELEASE_S seconds after the condition ends (seeks, a short stall); a change between the two
//! levels re-applies at once.
//! Event-driven: one inotify watch on the state directory. The panel state and the shim's switch file are not watched, so
//! while a state file says a video plays (or limits are held) the daemon also looks every 10 s (panel back on, switch
//! flipped, someone else resetting the floor). Nothing runs when no video plays.
//! The state and switch files belong to the user: they are read with O_NONBLOCK and only when fstat says regular file,
//! at most 4 KiB (a FIFO or a symlink to /dev/zero in their place cannot hang or flood this root daemon).
//!
//! The floor is only ever RAISED and the ceiling only LOWERED: if the helper's profile floor is already >= FLOOR_MHZ
//! (performance profile, 461) the daemon does nothing. Giving them back goes through tb323fu-helperd (`tb323fu-ctl gpu limits <profile> <lo> <hi>`
//! with the values it already has re-applies the effective profile) because devfreq's `min_freq` reads back the
//! effective minimum including msm's wait-boost QoS requests, so the old value cannot be read reliably; without the
//! helper the floor goes back to the lowest OPP.
//! Config /etc/default/y700-gpu-floor: FLOOR_MHZ=, CEIL_MHZ= (default 500, 0 = off), RELEASE_S=, USER_UID=. `--release` (ExecStopPost) gives the floor
//! back if this daemon died holding it. Paths can be overridden for the fake-sysfs test (test-gpu-floor.sh):
//! Y700_GPU_DIR, Y700_VIDEO_DIR, Y700_DPMS, Y700_STATE, Y700_CTL, Y700_CONF.
use std::collections::HashMap;
use std::ffi::CString;
use std::fs;
use std::io::Read;
use std::os::raw::{c_char, c_int, c_ulong, c_void};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

extern "C" {
    fn inotify_init1(flags: c_int) -> c_int;
    fn inotify_add_watch(fd: c_int, path: *const c_char, mask: u32) -> c_int;
    fn poll(fds: *mut PollFd, nfds: c_ulong, timeout: c_int) -> c_int;
    fn read(fd: c_int, buf: *mut c_void, n: usize) -> isize;
}
#[repr(C)]
struct PollFd {
    fd: c_int,
    events: i16,
    revents: i16,
}
const POLLIN: i16 = 1;
const IN_NONBLOCK: c_int = 0o4000;
const IN_CLOEXEC: c_int = 0o2000000;
// CLOSE_WRITE | MOVED_FROM | MOVED_TO | CREATE | DELETE | DELETE_SELF | MOVE_SELF
const WATCH_MASK: u32 = 0x8 | 0x40 | 0x80 | 0x100 | 0x200 | 0x400 | 0x800;
const IN_IGNORED: u32 = 0x8000;
const O_NONBLOCK: c_int = 0o4000;
const O_NOCTTY: c_int = 0o400;
const OPP_MIN_FALLBACK_HZ: u64 = 160_000_000;

struct Cfg {
    floor_mhz: u64,
    /// GPU ceiling while held (0 = leave the helper's max alone), see the module doc.
    ceil_mhz: u64,
    /// the ceiling also applies to a playing video that is not full screen (CEIL_WHEN=playing, the default)
    ceil_playing: bool,
    release: Duration,
    uid: u32,
}

/// What the Chrome extension's state files say, highest wins.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
enum Level {
    Idle,
    Playing,
    Full,
}

/// What is held on the GPU: the floor raised (Full only), the ceiling lowered.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Target {
    floor: bool,
    ceil: bool,
}

/// `shim`: the wait-boost shim is active in that Chrome, so there is no storm to cap.
fn target(cfg: &Cfg, level: Level, shim: bool) -> Option<Target> {
    let ceil = !shim && cfg.ceil_mhz > 0 && (level == Level::Full || (level == Level::Playing && cfg.ceil_playing));
    let t = Target { floor: level == Level::Full, ceil };
    if t.floor || t.ceil { Some(t) } else { None }
}

/// Held limits, Hz: the floor (0 = not raised) and the ceiling (0 = not lowered).
#[derive(Clone, Copy)]
struct Held {
    lo: u64,
    hi: u64,
    tgt: Target,
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn log(msg: &str) {
    eprintln!("y700-gpu-floor: {msg}");
}

/// `KEY=VALUE` lines (shell style: optional quotes, # comments).
fn parse_conf(text: &str) -> HashMap<String, String> {
    let mut m = HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            m.insert(k.trim().to_string(), v.trim().trim_matches(|c| c == '"' || c == '\'').to_string());
        }
    }
    m
}

fn load_cfg() -> Cfg {
    let conf = parse_conf(&fs::read_to_string(env_or("Y700_CONF", "/etc/default/y700-gpu-floor")).unwrap_or_default());
    let num = |k: &str, d: u64| conf.get(k).and_then(|v| v.parse::<u64>().ok()).unwrap_or(d);
    let floor_mhz = num("FLOOR_MHZ", 282);
    let floor_mhz = if (100..=1200).contains(&floor_mhz) { floor_mhz } else { 282 };
    let ceil_mhz = num("CEIL_MHZ", 500);
    Cfg {
        floor_mhz,
        // 0 = off; a ceiling below the floor (or past the top OPP) makes no sense: off
        ceil_mhz: if ceil_mhz >= floor_mhz && ceil_mhz <= 1200 { ceil_mhz } else { 0 },
        ceil_playing: conf.get("CEIL_WHEN").map(|v| v != "fullscreen").unwrap_or(true),
        release: Duration::from_secs(num("RELEASE_S", 3).min(60)),
        uid: num("USER_UID", 1000) as u32,
    }
}

fn gpu_dir() -> PathBuf {
    PathBuf::from(env_or("Y700_GPU_DIR", "/sys/class/devfreq/3d00000.gpu"))
}

fn state_path() -> PathBuf {
    PathBuf::from(env_or("Y700_STATE", "/run/y700-gpu-floor.state"))
}

fn video_dir(cfg: &Cfg) -> PathBuf {
    match std::env::var("Y700_VIDEO_DIR") {
        Ok(d) => PathBuf::from(d),
        Err(_) => PathBuf::from(format!("/run/user/{}/y700-video", cfg.uid)),
    }
}

/// A small regular file the user can write (state files, the shim's switch): see the module doc.
fn read_user_file(p: &Path) -> Option<Vec<u8>> {
    if !fs::symlink_metadata(p).ok()?.is_file() {
        return None;
    }
    let f = fs::OpenOptions::new().read(true).custom_flags(O_NONBLOCK | O_NOCTTY).open(p).ok()?;
    if !f.metadata().ok()?.is_file() {
        return None; // swapped after the check above
    }
    let mut v = Vec::new();
    f.take(4096).read_to_end(&mut v).ok()?;
    Some(v)
}

fn read_u64(p: &Path) -> Option<u64> {
    fs::read_to_string(p).ok()?.trim().parse().ok()
}

/// Available OPPs in Hz, ascending.
fn opps(gd: &Path) -> Vec<u64> {
    let mut v: Vec<u64> = fs::read_to_string(gd.join("available_frequencies"))
        .unwrap_or_default()
        .split_whitespace()
        .filter_map(|x| x.parse().ok())
        .collect();
    v.sort_unstable();
    v
}

/// The smallest OPP >= mhz (the largest one when none is), in Hz.
fn opp_at_least(opps: &[u64], mhz: u64) -> u64 {
    let want = mhz * 1_000_000;
    opps.iter().copied().find(|&o| o >= want).or_else(|| opps.last().copied()).unwrap_or(want)
}

/// The largest OPP <= mhz (the smallest one when none is), in Hz.
fn opp_at_most(opps: &[u64], mhz: u64) -> u64 {
    let want = mhz * 1_000_000;
    opps.iter().copied().rev().find(|&o| o <= want).or_else(|| opps.first().copied()).unwrap_or(want)
}

fn screen_on() -> bool {
    if let Ok(p) = std::env::var("Y700_DPMS") {
        return fs::read_to_string(p).map(|s| s.trim() != "Off").unwrap_or(true);
    }
    let Ok(rd) = fs::read_dir("/sys/class/drm") else { return true };
    for e in rd.flatten() {
        let n = e.file_name().to_string_lossy().to_string();
        if n.starts_with("card") && n.ends_with("-DSI-1") {
            return fs::read_to_string(e.path().join("dpms")).map(|s| s.trim() != "Off").unwrap_or(true);
        }
    }
    true
}

/// (browser pid, level) from a state file: playing=1 is Playing, plus fullscreen=1 is Full.
fn parse_state(content: &str) -> Option<(u32, Level)> {
    let kv: HashMap<&str, &str> = content.lines().filter_map(|l| l.split_once('=')).collect();
    if kv.get("playing") != Some(&"1") {
        return None;
    }
    let level = if kv.get("fullscreen") == Some(&"1") { Level::Full } else { Level::Playing };
    Some((kv.get("pid")?.parse().ok()?, level))
}

fn chrome_alive(pid: u32) -> bool {
    fs::read_to_string(format!("/proc/{pid}/comm")).map(|c| c.trim().starts_with("chrome")).unwrap_or(false)
}

/// y700-no-waitboost.so is mapped in that browser process and its switch (`ctl`) is not "Y0" (a missing switch file counts
/// as on: the shim creates it, with "Y1", when it starts).
fn shim_active(pid: u32, ctl: &Path) -> bool {
    shim_on(&fs::read_to_string(format!("/proc/{pid}/maps")).unwrap_or_default(), read_user_file(ctl).as_deref())
}

/// shim_active() on what it read: the process's maps and the switch file's content (None = no such file).
fn shim_on(maps: &str, ctl: Option<&[u8]>) -> bool {
    maps.contains("y700-no-waitboost") && ctl.map(|c| c.get(..2) != Some(b"Y0".as_slice())).unwrap_or(true)
}

/// The highest level over the live browsers' state files, and the browser that has it (0 = none).
fn level(dir: &Path) -> (Level, u32) {
    let mut best = (Level::Idle, 0);
    let Ok(rd) = fs::read_dir(dir) else { return best };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if !name.starts_with("chrome-") || name.ends_with(".tmp") {
            continue;
        }
        let text = read_user_file(&e.path()).map(|v| String::from_utf8_lossy(&v).into_owned());
        if let Some((pid, l)) = text.as_deref().and_then(parse_state) {
            if l > best.0 && chrome_alive(pid) {
                best = (l, pid);
            }
        }
    }
    best
}

/// What tb323fu-helperd has: the effective profile name and its [min, max] MHz floors.
struct Helper {
    profile: String,
    floors: Vec<(String, u64, u64)>,
}

impl Helper {
    fn limits(&self) -> Option<(&str, u64, u64)> {
        self.floors.iter().find(|f| f.0 == self.profile).map(|f| (f.0.as_str(), f.1, f.2))
    }
}

/// Parse `tb323fu-ctl gpu`: a `Profile: <name>` line and, under `Floors:`, `<name>: <min> <max>` lines.
fn parse_ctl(text: &str) -> Option<Helper> {
    let (mut profile, mut floors, mut in_floors) = (None, Vec::new(), false);
    for line in text.lines() {
        let t = line.trim();
        if t == "Floors:" {
            in_floors = true;
            continue;
        }
        if let Some(v) = t.strip_prefix("Profile:") {
            profile = Some(v.trim().to_string());
            in_floors = false;
            continue;
        }
        if in_floors {
            if let Some((name, rest)) = t.split_once(':') {
                let n: Vec<u64> = rest.split_whitespace().filter_map(|x| x.parse().ok()).collect();
                if n.len() == 2 {
                    floors.push((name.trim().to_string(), n[0], n[1]));
                    continue;
                }
            }
            in_floors = false;
        }
    }
    Some(Helper { profile: profile?, floors }).filter(|h| h.limits().is_some())
}

fn helper_state() -> Option<Helper> {
    let out = Command::new(env_or("Y700_CTL", "tb323fu-ctl")).arg("gpu").output().ok()?;
    if !out.status.success() {
        return None;
    }
    parse_ctl(&String::from_utf8_lossy(&out.stdout))
}

/// Raise the floor (tgt.floor) and lower the ceiling (tgt.ceil) as configured; Some(what is held) when anything is.
fn apply(cfg: &Cfg, gd: &Path, tgt: Target) -> Option<Held> {
    let ops = opps(gd);
    let want = opp_at_least(&ops, cfg.floor_mhz);
    let (base, base_hi) = match helper_state().as_ref().and_then(|h| h.limits()) {
        Some((_, lo, hi)) => (lo * 1_000_000, hi * 1_000_000),
        // may include boosts: only makes us do less
        None => (read_u64(&gd.join("min_freq")).unwrap_or(0), read_u64(&gd.join("max_freq")).unwrap_or(u64::MAX)),
    };
    // a profile that already holds the floor (performance, 461) wants speed: neither floor nor ceiling is touched
    if base >= want {
        log(&format!("profile floor {} MHz >= {} MHz: nothing to do", base / 1_000_000, want / 1_000_000));
        return None;
    }
    let lo = if tgt.floor { want } else { 0 };
    // the ceiling: never below the floor, and only when it lowers the helper's max
    let mut cap = if tgt.ceil { opp_at_most(&ops, cfg.ceil_mhz).max(want) } else { 0 };
    if cap >= base_hi {
        cap = 0;
    }
    if lo == 0 && cap == 0 {
        return None;
    }
    // recorded BEFORE the writes: killed in between, `--release` (ExecStopPost) still finds something to give back
    let _ = fs::write(state_path(), format!("{lo}\n{cap}\n"));
    if lo > 0 && fs::write(gd.join("min_freq"), lo.to_string()).is_err() {
        log("cannot write min_freq");
        let _ = fs::remove_file(state_path());
        return None;
    }
    if cap > 0 && fs::write(gd.join("max_freq"), cap.to_string()).is_err() {
        cap = 0;
        if lo == 0 {
            let _ = fs::remove_file(state_path());
            return None;
        }
        let _ = fs::write(state_path(), format!("{lo}\n0\n"));
    }
    let what = [
        (lo > 0).then(|| format!("GPU floor {} -> {} MHz", base / 1_000_000, lo / 1_000_000)),
        (cap > 0).then(|| format!("GPU ceiling {} -> {} MHz", base_hi.min(1_200_000_000) / 1_000_000, cap / 1_000_000)),
    ];
    let what: Vec<String> = what.into_iter().flatten().collect();
    let kind = if tgt.floor { "full-screen" } else { "playing" };
    log(&format!("{kind} Chrome video: {}", what.join(", ")));
    Some(Held { lo, hi: cap, tgt })
}

/// Give the floor (and the ceiling) back: let the helper re-apply the effective profile, or the OPP range without it.
fn release(gd: &Path, floor_hz: u64, ceil_hz: u64) {
    let via_helper = helper_state().and_then(|h| {
        let (p, lo, hi) = h.limits()?;
        Command::new(env_or("Y700_CTL", "tb323fu-ctl"))
            .args(["gpu", "limits", p, &lo.to_string(), &hi.to_string()])
            .status()
            .ok()
            .filter(|s| s.success())
            .map(|_| (lo, p.to_string()))
    });
    match via_helper {
        Some((lo, p)) => log(&format!("limits given back via helper (profile {p}, floor {lo} MHz)")),
        None => {
            let ops = opps(gd);
            let lo = ops.first().copied().unwrap_or(OPP_MIN_FALLBACK_HZ);
            let _ = fs::write(gd.join("min_freq"), lo.to_string());
            if ceil_hz > 0 {
                if let Some(hi) = ops.last() {
                    let _ = fs::write(gd.join("max_freq"), hi.to_string());
                }
            }
            log(&format!("helper unavailable: floor {} -> {} MHz (lowest OPP){}", floor_hz / 1_000_000, lo / 1_000_000,
                if ceil_hz > 0 { ", ceiling back to the highest OPP" } else { "" }));
        }
    }
    let _ = fs::remove_file(state_path());
}

/// `/run/y700-gpu-floor.state`: floor Hz, then (optionally) the ceiling Hz that was set, 0 = not touched.
fn read_state() -> Option<(u64, u64)> {
    let text = fs::read_to_string(state_path()).ok()?;
    let mut it = text.lines().filter_map(|l| l.trim().parse::<u64>().ok());
    let floor = it.next()?;
    Some((floor, it.next().unwrap_or(0)))
}

struct Watcher {
    fd: c_int,
    wd: c_int,
    dir: PathBuf,
}

impl Watcher {
    fn new(dir: PathBuf) -> Self {
        let fd = unsafe { inotify_init1(IN_NONBLOCK | IN_CLOEXEC) };
        if fd < 0 {
            log("inotify_init1 failed");
            std::process::exit(1);
        }
        Watcher { fd, wd: -1, dir }
    }

    /// true while the directory is being watched (it appears with the user's session and goes with it).
    fn ensure(&mut self) -> bool {
        if self.wd >= 0 {
            return true;
        }
        let Ok(c) = CString::new(self.dir.to_string_lossy().as_bytes()) else { return false };
        if !self.dir.is_dir() {
            return false;
        }
        self.wd = unsafe { inotify_add_watch(self.fd, c.as_ptr(), WATCH_MASK) };
        self.wd >= 0
    }

    fn wait(&mut self, timeout_ms: i64) {
        let mut p = PollFd { fd: self.fd, events: POLLIN, revents: 0 };
        let to = if timeout_ms < 0 { -1 } else { timeout_ms.min(i32::MAX as i64) as c_int };
        if unsafe { poll(&mut p, 1, to) } > 0 && p.revents & POLLIN != 0 {
            let mut buf = [0u8; 4096];
            loop {
                let n = unsafe { read(self.fd, buf.as_mut_ptr() as *mut c_void, buf.len()) };
                if n <= 0 {
                    break;
                }
                let (mut off, n) = (0usize, n as usize);
                while off + 16 <= n {
                    let mask = u32::from_ne_bytes(buf[off + 4..off + 8].try_into().unwrap());
                    let len = u32::from_ne_bytes(buf[off + 12..off + 16].try_into().unwrap()) as usize;
                    if mask & IN_IGNORED != 0 {
                        self.wd = -1; // the directory went away: watch again when it is back
                    }
                    off += 16 + len;
                }
            }
        }
    }
}

/// The helper (a profile change) moved the floor down or the ceiling up. A floor that only reads back lower because the
/// effective max is below it (thermal OPP limits; devfreq clamps min to max when reading) does not count: setting it
/// again would change nothing and repeat every 10 s.
fn reset_by_someone(gd: &Path, h: &Held) -> bool {
    let (min, max) = (read_u64(&gd.join("min_freq")), read_u64(&gd.join("max_freq")));
    let floor_down = h.lo > 0 && min.map(|m| m < h.lo).unwrap_or(false) && max.map(|m| m >= h.lo).unwrap_or(false);
    let ceil_up = h.hi > 0 && max.map(|m| m > h.hi).unwrap_or(false);
    floor_down || ceil_up
}

fn release_from_state() {
    let gd = gpu_dir();
    if let Some((floor, ceil)) = read_state() {
        release(&gd, floor, ceil);
    }
}

fn main() {
    if std::env::args().nth(1).as_deref() == Some("--release") {
        release_from_state();
        return;
    }
    let cfg = load_cfg();
    let (gd, vd) = (gpu_dir(), video_dir(&cfg));
    if !gd.join("min_freq").exists() {
        log(&format!("no devfreq at {}, nothing to do", gd.display()));
        return;
    }
    release_from_state(); // a previous run died holding the floor
    let ceil = if cfg.ceil_mhz > 0 {
        format!(", ceiling {} MHz ({})", cfg.ceil_mhz, if cfg.ceil_playing { "while a video plays" } else { "full screen only" })
    } else {
        String::new()
    };
    log(&format!("full-screen Chrome video: floor {} MHz{ceil} (no ceiling when the wait-boost shim is loaded); released {} s after it ends, watching {}",
        cfg.floor_mhz, cfg.release.as_secs(), vd.display()));
    let ctl_file = vd.parent().map(|p| p.join("y700-no-waitboost.ctl")).unwrap_or_default();
    let mut w = Watcher::new(vd.clone());
    let (mut held, mut drop_at): (Option<Held>, Option<Instant>) = (None, None);
    loop {
        let watching = w.ensure();
        let now = Instant::now();
        let (l, pid) = if watching { level(&vd) } else { (Level::Idle, 0) };
        let want = if l != Level::Idle && screen_on() { target(&cfg, l, pid > 0 && shim_active(pid, &ctl_file)) } else { None };
        match (want, held) {
            (Some(t), None) => {
                drop_at = None;
                held = apply(&cfg, &gd, t);
            }
            (Some(t), Some(h)) => {
                drop_at = None;
                if t != h.tgt {
                    // full screen <-> playing: give the old limits back, then set the new ones
                    release(&gd, h.lo, h.hi);
                    held = apply(&cfg, &gd, t);
                } else if reset_by_someone(&gd, &h) {
                    // give back first: without the helper apply() would read our own floor back as the profile's and
                    // conclude there is nothing to do, leaving it up with nobody holding it
                    log("limits were reset by someone else, applying them again");
                    release(&gd, h.lo, h.hi);
                    held = apply(&cfg, &gd, t);
                }
            }
            (None, Some(h)) => match drop_at {
                None => drop_at = Some(now + cfg.release),
                Some(d) if now >= d => {
                    release(&gd, h.lo, h.hi);
                    held = None;
                    drop_at = None;
                }
                _ => {}
            },
            (None, None) => {}
        }
        // a video plays: look again every 10 s for what is not watched (panel back on, the shim's switch)
        let mut timeout: i64 = if !watching { 5000 } else if l != Level::Idle { 10_000 } else { -1 };
        if held.is_some() {
            let t = match drop_at {
                Some(d) => d.saturating_duration_since(Instant::now()).as_millis() as i64 + 20,
                None => 10_000,
            };
            timeout = if timeout < 0 { t } else { timeout.min(t) };
        }
        w.wait(timeout);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_file() {
        assert_eq!(parse_state("pid=42\nplaying=1\nfullscreen=1\nosd=0\n"), Some((42, Level::Full)));
        assert_eq!(parse_state("pid=42\nplaying=1\nfullscreen=0\n"), Some((42, Level::Playing)));
        assert_eq!(parse_state("pid=42\nplaying=0\nfullscreen=1\n"), None);
        assert_eq!(parse_state("playing=1\nfullscreen=1\n"), None);
    }

    #[test]
    fn targets() {
        let mut c = Cfg { floor_mhz: 342, ceil_mhz: 500, ceil_playing: true, release: Duration::from_secs(3), uid: 1000 };
        assert!(target(&c, Level::Idle, false).is_none());
        assert!(target(&c, Level::Playing, false) == Some(Target { floor: false, ceil: true }));
        assert!(target(&c, Level::Full, false) == Some(Target { floor: true, ceil: true }));
        // the wait-boost shim loaded: nothing to cap, the floor stays
        assert!(target(&c, Level::Playing, true).is_none());
        assert!(target(&c, Level::Full, true) == Some(Target { floor: true, ceil: false }));
        c.ceil_playing = false;
        assert!(target(&c, Level::Playing, false).is_none());
        assert!(target(&c, Level::Full, false) == Some(Target { floor: true, ceil: true }));
        c.ceil_mhz = 0;
        assert!(target(&c, Level::Full, false) == Some(Target { floor: true, ceil: false }));
    }

    #[test]
    fn shim_switch() {
        // not this process's own maps: with the shim in /etc/ld.so.preload (the tablet since 10-18) every process has it
        let with = "ffff8000-ffff9000 r-xp 00000000 103:2 1234 /usr/local/lib/y700-no-waitboost.so\n";
        let without = "ffff8000-ffff9000 r-xp 00000000 103:2 99 /usr/lib/aarch64-linux-gnu/libc.so.6\n";
        assert!(shim_on(with, None)); // no switch file yet: on (the shim creates it with Y1)
        assert!(shim_on(with, Some(b"Y1")));
        assert!(!shim_on(with, Some(b"Y0")));
        assert!(!shim_on(with, Some(b"Y0\n")));
        assert!(!shim_on(without, Some(b"Y1")));
        assert!(!shim_on(without, None));
        assert!(!shim_active(0, Path::new("/nonexistent"))); // no such process
    }

    #[test]
    fn user_files() {
        let d = std::env::temp_dir().join(format!("y700-gf-uf-{}", std::process::id()));
        fs::create_dir_all(&d).unwrap();
        let f = d.join("chrome-1");
        fs::write(&f, "pid=1\nplaying=1\n").unwrap();
        assert_eq!(read_user_file(&f).as_deref(), Some(b"pid=1\nplaying=1\n".as_slice()));
        fs::write(&f, vec![b'x'; 10000]).unwrap();
        assert_eq!(read_user_file(&f).map(|v| v.len()), Some(4096));
        let l = d.join("chrome-2");
        std::os::unix::fs::symlink("/dev/zero", &l).unwrap();
        assert!(read_user_file(&l).is_none());
        let fifo = d.join("chrome-3");
        assert!(Command::new("mkfifo").arg(&fifo).status().unwrap().success());
        assert!(read_user_file(&fifo).is_none()); // returns at once, no writer needed
        assert!(read_user_file(&d.join("missing")).is_none());
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn conf() {
        let m = parse_conf("# c\nFLOOR_MHZ=\"282\"\nRELEASE_S = 5\n\nbad line\n");
        assert_eq!(m["FLOOR_MHZ"], "282");
        assert_eq!(m["RELEASE_S"], "5");
    }

    #[test]
    fn opp() {
        let o = [160_000_000, 191_000_000, 282_000_000, 1_200_000_000];
        assert_eq!(opp_at_least(&o, 200), 282_000_000);
        assert_eq!(opp_at_least(&o, 282), 282_000_000);
        assert_eq!(opp_at_least(&o, 5000), 1_200_000_000);
        assert_eq!(opp_at_most(&o, 500), 282_000_000);
        assert_eq!(opp_at_most(&o, 282), 282_000_000);
        assert_eq!(opp_at_most(&o, 100), 160_000_000);
    }

    #[test]
    fn ctl_output() {
        let t = "Gpu:\n  CpuBoost: true\n  CpuLimits: \n      balanced: 384 3628 768 4396\n  Floors: \n      balanced: 160 1200\n      performance: 461 1200\n      power-saver: 160 726\n  FollowPowerProfiles: false\n  Profile: balanced\n  WifiAvailable: true\n";
        let h = parse_ctl(t).unwrap();
        assert_eq!(h.limits(), Some(("balanced", 160, 1200)));
        assert_eq!(h.floors.len(), 3);
        assert!(parse_ctl("Gpu:\n  Profile: balanced\n").is_none());
        let t2 = t.replace("Profile: balanced", "Profile: performance");
        assert_eq!(parse_ctl(&t2).unwrap().limits(), Some(("performance", 461, 1200)));
    }
}
