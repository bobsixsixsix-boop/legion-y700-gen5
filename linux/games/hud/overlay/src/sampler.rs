//! The game overlay's sampler, in the overlay's own process (the only implementation since 2026-10-17; it began as
//! a line-by-line port of y700_hud_sampler.py, which replaced the y700-hudinfo shell sampler - both in git history).
//! "RUST:" marks where it deliberately differs from that Python module.
//!
//! Cost history (measured on the tablet, `tools/y700-hud-cost.sh`): the shell sampler forked ~30 processes per sample
//! (find/sed/xargs/awk/date...) and walked every fd of every process twice to find the GPU clients - 52 ms of CPU per
//! sample, the bar took 2.4 % of a core and ~330 forks/min on an idle desktop, 9.7 % and ~1290 forks/min in a game.
//! The in-process Python sampler: 1.3-1.5 ms per sample, the bar 0.2 % idle / 0.8 % in a game. This Rust one: 1.0-1.2
//! ms per sample (0.8-1.0 ms of it in the kernel reading sysfs/procfs, the same for any language; user time 0.15-0.23
//! ms vs Python's 0.42-0.50), the bar 0.6 % in a game, RSS 77 MB vs 104 MB. How the sampler gets there:
//!   - every file read each sample stays open and is re-read with pread(fd, n, 0) - sysfs/procfs regenerate the
//!     content at offset 0 - 2.5-11 us instead of 20-45 us for open+read+close (~40 files per sample);
//!   - the GPU clients are found incrementally: /proc is listed only when /proc/loadavg's last-pid field moved (a new
//!     process or thread since the last sample: 0.7 us, vs 0.5 ms for listing /proc - an idle desktop forks about
//!     once a minute), only the new pids' fds are looked at; every RESCAN_S the running processes are checked for a
//!     GPU opened later, but only those whose fd count changed are walked (stat() of /proc/<pid>/fd gives the count
//!     since Linux 6.2: 1.4 ms for all ~360 processes, vs ~20 ms for readlink on all ~4900 fds - on an idle desktop
//!     no count changed in 30 s), with a walk of everything every DEEP_S; a process younger than YOUNG_S has its fd
//!     count compared every sample (a game opens the GPU seconds after it starts: DXVK/Turnip device creation under
//!     FEX, y700-gl-hud exec'ing into the game); one fdinfo per DRM client is read (fdinfo repeats a client's
//!     counters for each of its fds), the next holder at once when it fails;
//!   - skin-thermal costs ~250 us CPU per read (the others ~10 us, probably an ADC busy-wait): read every SLOW_S;
//!   - the charger's current/voltage/type are only read while it is online (each is a 3-5 ms round trip to the
//!     battery firmware - little CPU, but wall time and a firmware wake-up; all three read 0 when offline);
//!   - the battery percentage (capacity) is read every CAP_S: another firmware round trip, and it moves slowly;
//!   - the game's FPS log is remembered per process instead of searched for every sample;
//!   - the thermal zones / cooling devices / cpufreq policies are listed once.
//!
//! What it measures:
//!   - GPU busy per DRM client from fdinfo drm-engine-gpu. fdinfo repeats one client's counters for every fd that
//!     refers to it (dup/fork; Proton's wine processes inherit the render fd), so the unit is the drm-client-id,
//!     counted once whoever holds it and attributed to the lowest pid holding it (docs.kernel.org/gpu/drm-usage-stats);
//!     a client only contributes when it was in both samples (one that appeared in between would add its whole
//!     lifetime, a 100 % spike). Only /dev/dri/renderD128: KWin holds card1, so the compositor's own GPU time is not
//!     in the figure (kept that way on purpose, the numbers stay comparable with the old ones).
//!     /proc/<pid>/fdinfo/<n> follows the fd NUMBER, not the file: a number closed and reused for another client would
//!     read as this client's delta, so every read checks the client id.
//!   - CPU busy from /proc/stat (idle + iowait as idle).
//!   - FPS from the log of the busiest GPU process that has one (the FPS_CANDIDATES busiest of this window, any
//!     share - the log is the proof, a desktop app has none), its own or a parent's up to 4 levels (a Proton game's
//!     drawing process is a child of the exe): the MangoHud CSV named after its comm (MANGOHUD=1 from steam-arm64;
//!     prefix match, the kernel cuts comm at 15 bytes - possibly inside a character, that partial character is
//!     dropped), else its Gallium HUD dump (OpenGL games through y700-gl-hud, found via GALLIUM_HUD_DUMP_DIR in its
//!     environ); only logs written in the last 3 s count. No log that provably belongs to such a process: no FPS.
//!     (The shell sampler's "top process >= 2 %" only ever passed because it summed GPU time over all samples.)
//!   - temperatures: max of cpu-* zones, max of gpuss-* zones, skin-thermal; THR = a cpufreq/devfreq cooling device
//!     with cur_state > 0.
//!   - battery power = current_now x voltage_now (NOT power_now: the firmware once reported a constant bogus
//!     100121690 uW after a boot at 100 %); whole-device power = USB input - battery charge; on the charger with
//!     the battery charging the input is shown as input (it contains the charger's conversion loss).
//!     On PPS the firmware charges through two charge pumps and the main charger idles (2026-10-18, its own log:
//!     IBUS 1485 + 1445 mA from the pumps, main charger iin_adc=0): USB current_now then reads 0 and the pumps'
//!     current is not exposed to Linux at all. Charging with zero input current = pump mode: input and
//!     whole-device power are left empty (unknown) and the battery's charge rate is shown instead - the input is
//!     at least that. Before this the bar showed "IN 0.0W" there.
//!   - busy values are averaged over the time since the previous sample (1 s in games, 6 s idle), so a sample needs
//!     no sleep; a failed battery/charger/GPU-clock/skin read shows its last good value.
//!   - the cache files $XDG_RUNTIME_DIR/y700-hud.txt(.kv) are written for `y700-hudinfo` on the command line and,
//!     since 2026-10-22, for the status bar (y700-shellbar watches the directory and shows the .kv pairs; the
//!     service runs `--sampler`, main.rs). The rate column is then the majority of 200 ms polls (`hz_vote`).
use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const RENDER: &[u8] = b"/dev/dri/renderD128";
const RESCAN_S: f64 = 30.0; // running processes whose fd count changed are walked again
const DEEP_S: f64 = 300.0; // every process's fds are walked again
const SLOW_S: f64 = 5.0; // skin temperature
const CAP_S: f64 = 30.0; // battery percentage: a firmware round trip per read, and it moves ~1 % in 5 min at 10 W
const FPS_MISS_S: f64 = 3.0; // a GPU process without a log is searched again after this
const FPS_CANDIDATES: usize = 3; // the busiest GPU processes looked at for a log
const YOUNG_S: f64 = 60.0; // a new process's fd count is checked every sample this long
const B: &str = "/sys/class/power_supply/qcom-battmgr-bat";
const U: &str = "/sys/class/power_supply/qcom-battmgr-usb";
const GPUF: &str = "/sys/class/devfreq/3d00000.gpu/cur_freq";
pub const RS: &str = "/sys/module/msm/parameters/idle_refresh_state";

/// One sample, in the order of the .kv cache file.
#[derive(Clone, Default, Debug)]
pub struct Kv {
    pub fps: String,
    pub hz: String,
    pub cpu: String,
    pub cpu_mhz: String,
    pub cpu_c: String,
    pub gpu: String,
    pub gpu_mhz: String,
    pub gpu_c: String,
    pub skin_c: String,
    pub thr: String,
    pub sys_w: String,
    pub bat_w: String,
    pub on: String,
    pub in_w: String,
    pub in_v: String,
    pub in_a: String,
    pub adapter: String,
    pub bat_pct: String, // battery percentage, "" until the first good read
}

impl Kv {
    pub fn pairs(&self) -> [(&'static str, &str); 18] {
        [
            ("fps", &self.fps), ("hz", &self.hz), ("cpu", &self.cpu), ("cpu_mhz", &self.cpu_mhz),
            ("cpu_c", &self.cpu_c), ("gpu", &self.gpu), ("gpu_mhz", &self.gpu_mhz), ("gpu_c", &self.gpu_c),
            ("skin_c", &self.skin_c), ("thr", &self.thr), ("sys_w", &self.sys_w), ("bat_w", &self.bat_w),
            ("on", &self.on), ("in_w", &self.in_w), ("in_v", &self.in_v), ("in_a", &self.in_a),
            ("adapter", &self.adapter), ("bat_pct", &self.bat_pct),
        ]
    }
}

fn now_wall() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn mtime(path: &Path) -> Option<f64> {
    let m = fs::metadata(path).ok()?.modified().ok()?;
    Some(m.duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0))
}

fn fresh(path: &Path, now: f64) -> bool {
    mtime(path).map_or(false, |t| now - t <= 3.0)
}

/// the last line of a file (its last 512 bytes), "" if none - like the Python _last_line (splitlines)
fn last_line(path: &Path) -> String {
    let Ok(mut f) = File::open(path) else { return String::new() };
    let Ok(n) = f.seek(SeekFrom::End(0)) else { return String::new() };
    if f.seek(SeekFrom::Start(n.saturating_sub(512))).is_err() {
        return String::new();
    }
    let mut b = Vec::with_capacity(512);
    if f.read_to_end(&mut b).is_err() {
        return String::new();
    }
    String::from_utf8_lossy(&b).lines().last().unwrap_or("").to_string()
}

/// the FPS in the last line of a MangoHud CSV ("fps,frametime,...") or a Gallium HUD dump ("fps"), "" if none
fn log_fps(csv: bool, path: &Path) -> String {
    let line = last_line(path);
    let n = line.bytes().take_while(|c| c.is_ascii_digit() || *c == b'.').count();
    if n == 0 {
        return String::new();
    }
    let rest = &line[n..];
    if (csv && !rest.starts_with(',')) || (!csv && !rest.is_empty()) {
        return String::new();
    }
    // RUST: a malformed number ("1.2.3") is "no FPS"; Python's float() raised (caught as an fps error)
    line[..n].parse::<f64>().map(|v| format!("{}", v.trunc() as i64)).unwrap_or_default()
}

/// the first whitespace-separated token after `key` in an fdinfo text
fn field(txt: &str, key: &str) -> Option<String> {
    let i = txt.find(key)?;
    txt[i + key.len()..].split_whitespace().next().map(str::to_string)
}

/// comm bytes without the partial character the kernel's 15-byte cut can leave (Python: trailing surrogates)
fn strip_invalid_tail(b: &[u8]) -> &[u8] {
    let (mut pos, mut end) = (0, 0);
    for ch in b.utf8_chunks() {
        pos += ch.valid().len();
        if !ch.valid().is_empty() {
            end = pos;
        }
        pos += ch.invalid().len();
    }
    &b[..end]
}

/// ppid: the 2nd field after the ")" that closes the comm (a comm can contain spaces and parentheses)
fn ppid(stat: &[u8]) -> Option<i32> {
    let i = stat.iter().rposition(|&b| b == b')')?;
    let rest = std::str::from_utf8(&stat[i + 1..]).ok()?;
    rest.split_whitespace().nth(1)?.parse().ok()
}

/// the newest "<base>*.csv" in dir (Python: glob + max by mtime; first one listed wins a tie)
fn newest_csv(dir: &Path, base: &[u8]) -> Option<PathBuf> {
    let mut best: Option<(f64, PathBuf)> = None;
    for e in fs::read_dir(dir).ok()?.flatten() {
        let name = e.file_name();
        let nb = name.as_bytes();
        if nb.len() >= base.len() + 4 && nb.starts_with(base) && nb.ends_with(b".csv") {
            let p = e.path();
            let t = mtime(&p).unwrap_or(0.0);
            if best.as_ref().map_or(true, |(bt, _)| t > *bt) {
                best = Some((t, p));
            }
        }
    }
    best.map(|(_, p)| p)
}

/// Python's "%.6g"
fn fmt_g6(v: f64) -> String {
    if v == 0.0 {
        return if v.is_sign_negative() { "-0".into() } else { "0".into() };
    }
    if !v.is_finite() {
        return format!("{v}");
    }
    let strip = |s: String| if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.').to_string() } else { s };
    let s = format!("{:.5e}", v); // the exponent after rounding to 6 significant digits
    let (mant, e) = s.split_once('e').unwrap_or((&s, "0"));
    let e: i32 = e.parse().unwrap_or(0);
    if !(-4..6).contains(&e) {
        format!("{}e{}{:02}", strip(mant.to_string()), if e < 0 { '-' } else { '+' }, e.abs())
    } else {
        strip(format!("{:.*}", (5 - e).max(0) as usize, v))
    }
}

/// max of the values, 0 for none (Python: max([...] or [0]))
fn fmax(v: impl Iterator<Item = f64>) -> f64 {
    v.fold(None, |m: Option<f64>, x| Some(m.map_or(x, |m| m.max(x)))).unwrap_or(0.0)
}

enum Src {
    Found(bool, PathBuf), // (csv?, log path)
    Miss(f64),            // searched at this monotonic time, nothing
}

pub struct Sampler {
    t0: Instant,
    known: HashSet<i32>,                          // pids already looked at
    fds: HashMap<(i32, String), (String, String)>, // (pid, fd) -> (fdinfo path, drm-client-id)
    last_full: f64,
    last_deep: f64,
    nfd: HashMap<i32, u64>,  // pid -> its fd count when its fds were last walked
    born: HashMap<i32, f64>, // pid -> when it was first listed, while younger than YOUNG_S
    reps: Option<HashMap<String, Vec<(i32, String, String)>>>, // client -> holders, lowest pid first
    ok: HashMap<String, i64>, // path -> last good value (held reads)
    ok_usb_type: String,
    last_pid: Option<String>, // /proc/loadavg's last-pid field at the last /proc listing
    prev: Option<(f64, u64, u64, HashMap<String, (i32, u64)>)>, // (mono, cpu_total, cpu_idle, {client: (pid, ns)})
    h: HashMap<String, File>, // path -> kept-open file
    skin: (f64, f64),         // (value, monotonic time read)
    cap: (i64, f64),          // (battery %, -1 = never read; monotonic time read)
    fps_src: HashMap<i32, Src>,
    cpu_z: Vec<String>,
    gpu_z: Vec<String>,
    skin_z: Vec<String>,
    cool: Vec<String>,
    pol: Vec<String>,
    logs: PathBuf,
    cache: Option<PathBuf>, // None: the command-line modes, which only print
    /// the status line of the last sample (what the cache file gets)
    pub line: String,
    /// the panel rate for the next sample (--sampler: the rate most 200 ms polls saw since the last sample; a
    /// single read at sample time often catches the panel just after a repaint kicked it to 120); taken by it
    pub hz_vote: Option<String>,
}

impl Sampler {
    /// write_cache: the overlay (the cache files are for `y700-hudinfo`); the command-line modes only print
    pub fn new(write_cache: bool) -> Self {
        let rt = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| "/tmp".into());
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| "/".into());
        let mut s = Sampler {
            t0: Instant::now(),
            known: HashSet::new(),
            fds: HashMap::new(),
            last_full: -1e9,
            last_deep: -1e9,
            nfd: HashMap::new(),
            born: HashMap::new(),
            reps: None,
            ok: HashMap::new(),
            ok_usb_type: String::new(),
            last_pid: None,
            prev: None,
            h: HashMap::new(),
            skin: (0.0, -1e9),
            cap: (-1, -1e9),
            fps_src: HashMap::new(),
            cpu_z: vec![],
            gpu_z: vec![],
            skin_z: vec![],
            cool: vec![],
            pol: vec![],
            logs: home.join(".cache/y700-hud"),
            cache: write_cache.then(|| rt.join("y700-hud.txt")),
            line: String::new(),
            hz_vote: None,
        };
        // static lists, read once
        let t = Path::new("/sys/class/thermal");
        for e in fs::read_dir(t).into_iter().flatten().flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            let ty = fs::read_to_string(e.path().join("type")).unwrap_or_default();
            let ty = ty.trim();
            let p = |f: &str| e.path().join(f).to_string_lossy().into_owned();
            if n.starts_with("thermal_zone") {
                if ty.starts_with("cpu-") {
                    s.cpu_z.push(p("temp"));
                } else if ty.starts_with("gpuss-") {
                    s.gpu_z.push(p("temp"));
                } else if ty == "skin-thermal" {
                    s.skin_z.push(p("temp"));
                }
            } else if n.starts_with("cooling_device") && (ty.starts_with("cpufreq") || ty.starts_with("devfreq")) {
                s.cool.push(p("cur_state"));
            }
        }
        for e in fs::read_dir("/sys/devices/system/cpu/cpufreq").into_iter().flatten().flatten() {
            let f = e.path().join("scaling_cur_freq");
            if e.file_name().to_string_lossy().starts_with("policy") && f.exists() {
                s.pol.push(f.to_string_lossy().into_owned());
            }
        }
        s.cleanup_logs();
        s
    }

    fn mono(&self) -> f64 {
        self.t0.elapsed().as_secs_f64()
    }

    /// --bench: make the next sample do the RESCAN_S pass (deep: the DEEP_S walk of every process too)
    pub fn force_rescan(&mut self, deep: bool) {
        self.last_full = -1e9;
        if deep {
            self.last_deep = -1e9;
        }
    }

    // ---- files kept open
    /// the content of path, re-read through a kept-open file with pread at offset 0; None when it cannot be read
    /// (the file is then closed and the next call opens the path again)
    pub fn pv(&mut self, path: &str, size: usize) -> Option<String> {
        if !self.h.contains_key(path) {
            let f = File::open(path).ok()?; // O_CLOEXEC, as std always does
            self.h.insert(path.to_string(), f);
        }
        let mut buf = vec![0u8; size];
        match self.h[path].read_at(&mut buf, 0) {
            Ok(n) => Some(String::from_utf8_lossy(&buf[..n]).into_owned()),
            Err(_) => {
                self.h.remove(path);
                None
            }
        }
    }

    /// the integer in path; hold: a failed read gives the last good value
    fn iv(&mut self, path: &str, default: i64, hold: bool) -> i64 {
        let v = self.pv(path, 4096).and_then(|s| s.split_whitespace().next().and_then(|t| t.parse::<i64>().ok()));
        match v {
            Some(v) => {
                if hold {
                    self.ok.insert(path.to_string(), v);
                }
                v
            }
            None if hold => *self.ok.get(path).unwrap_or(&default),
            None => default,
        }
    }

    // ---- the GPU clients
    fn scan_pid(&mut self, pid: i32, n: Option<u64>) {
        let d = format!("/proc/{pid}/fd");
        let n = match n {
            Some(n) => n,
            None => match fs::metadata(&d) {
                Ok(m) => m.len(),
                Err(_) => return, // not ours (permission) or gone
            },
        };
        self.nfd.insert(pid, n);
        let Ok(rd) = fs::read_dir(&d) else { return };
        for e in rd.flatten() {
            let fd = e.file_name().to_string_lossy().into_owned();
            let key = (pid, fd);
            if self.fds.contains_key(&key) {
                continue;
            }
            match fs::read_link(e.path()) {
                Ok(t) if t.as_os_str().as_bytes() == RENDER => {}
                _ => continue,
            }
            let path = format!("/proc/{pid}/fdinfo/{}", key.1);
            let txt = fs::read(&path).map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default();
            if let Some(c) = field(&txt, "drm-client-id:") {
                // an fd keeps its client for life: the id is read once
                self.fds.insert(key, (path, c));
                self.reps = None;
            }
        }
    }

    fn proc_fd_count(pid: i32) -> Option<u64> {
        fs::metadata(format!("/proc/{pid}/fd")).ok().map(|m| m.len())
    }

    fn refresh_fds(&mut self, now: f64) {
        // young processes: a game opens the GPU seconds after it starts
        let born: Vec<(i32, f64)> = self.born.iter().map(|(p, t)| (*p, *t)).collect();
        for (p, t) in born {
            let n = if now - t > YOUNG_S { None } else { Self::proc_fd_count(p) };
            match n {
                None => {
                    self.born.remove(&p);
                }
                Some(n) => {
                    if self.nfd.get(&p) != Some(&n) {
                        self.scan_pid(p, Some(n));
                    }
                }
            }
        }
        let full = now - self.last_full >= RESCAN_S; // a running process may have opened the GPU since
        let lp = self.pv("/proc/loadavg", 128).and_then(|s| s.split_whitespace().last().map(str::to_string));
        if !full && lp.is_some() && lp == self.last_pid {
            return; // no process or thread created since the last listing: nothing new to find
        }
        let Ok(rd) = fs::read_dir("/proc") else { return };
        let pids: HashSet<i32> = rd
            .flatten()
            .filter_map(|e| {
                let n = e.file_name();
                let b = n.as_bytes();
                if !b.is_empty() && b.iter().all(u8::is_ascii_digit) { std::str::from_utf8(b).ok()?.parse().ok() } else { None }
            })
            .collect();
        self.last_pid = lp;
        let first = self.known.is_empty(); // the first listing: everything is "new", nothing is young
        let new: Vec<i32> = pids.difference(&self.known).copied().collect();
        for p in new {
            self.scan_pid(p, None);
            if !first {
                self.born.entry(p).or_insert(now);
            }
        }
        if full {
            self.last_full = now;
            let deep = now - self.last_deep >= DEEP_S;
            if deep {
                self.last_deep = now;
            }
            let both: Vec<i32> = pids.intersection(&self.known).copied().collect();
            for p in both {
                let Some(n) = Self::proc_fd_count(p) else { continue }; // not ours or gone
                if deep || self.nfd.get(&p) != Some(&n) {
                    self.scan_pid(p, Some(n));
                }
            }
        }
        self.known = pids;
        let known = &self.known;
        self.nfd.retain(|p, _| known.contains(p));
        let gone: Vec<(i32, String)> = self.fds.keys().filter(|k| !self.known.contains(&k.0)).cloned().collect();
        for k in &gone {
            if let Some((path, _)) = self.fds.remove(k) {
                self.h.remove(&path);
            }
        }
        if !gone.is_empty() {
            self.reps = None;
        }
    }

    /// client id -> (lowest pid holding it, drm-engine-gpu ns); ONE fd per client is read
    fn gpu_ns(&mut self) -> HashMap<String, (i32, u64)> {
        let mut reps = match self.reps.take() {
            Some(r) => r,
            None => {
                let mut r: HashMap<String, Vec<(i32, String, String)>> = HashMap::new();
                for ((pid, fd), (path, c)) in &self.fds {
                    r.entry(c.clone()).or_default().push((*pid, fd.clone(), path.clone()));
                }
                for v in r.values_mut() {
                    v.sort();
                }
                r
            }
        };
        let mut out = HashMap::new();
        let clients: Vec<String> = reps.keys().cloned().collect();
        for c in clients {
            let holders = reps.get_mut(&c).unwrap();
            let mut hit = None;
            while let Some((pid, fd, path)) = holders.first().cloned() {
                if let Some(t) = self.pv(&path, 4096) {
                    if field(&t, "drm-client-id:").as_deref() == Some(c.as_str()) {
                        hit = Some((pid, t));
                        break;
                    }
                }
                // gone, closed, or the fd NUMBER now holds something else: forget it, read the next holder now
                holders.remove(0);
                self.fds.remove(&(pid, fd));
                self.h.remove(&path);
                self.known.remove(&pid);
                self.last_pid = None;
            }
            match hit {
                None => {
                    reps.remove(&c);
                }
                Some((pid, t)) => {
                    if let Some(ns) = field(&t, "drm-engine-gpu:").and_then(|s| s.parse::<u64>().ok()) {
                        out.insert(c, (pid, ns));
                    }
                }
            }
        }
        self.reps = Some(reps);
        out
    }

    // ---- FPS
    fn fps(&mut self, cands: &[i32], now: f64, mono: f64) -> String {
        let old = std::mem::take(&mut self.fps_src);
        for &pid in cands {
            match old.get(&pid) {
                Some(Src::Miss(t)) if mono - t < FPS_MISS_S => {
                    self.fps_src.insert(pid, Src::Miss(*t));
                    continue;
                }
                Some(Src::Found(csv, p)) if fresh(p, now) => {
                    let v = log_fps(*csv, p);
                    if !v.is_empty() {
                        self.fps_src.insert(pid, Src::Found(*csv, p.clone()));
                        return v;
                    }
                }
                _ => {}
            }
            match self.find_log(pid, now) {
                Some((csv, p)) => {
                    let v = log_fps(csv, &p);
                    self.fps_src.insert(pid, Src::Found(csv, p));
                    return v;
                }
                None => {
                    self.fps_src.insert(pid, Src::Miss(mono));
                }
            }
        }
        String::new()
    }

    /// (csv?, path) of the fresh FPS log of top or one of its parents (up to 4 levels)
    fn find_log(&self, top: i32, now: f64) -> Option<(bool, PathBuf)> {
        let (mut p, mut depth) = (Some(top), 0);
        while let Some(pp) = p {
            if pp == 0 || pp == 1 || depth >= 4 {
                break;
            }
            let raw = fs::read(format!("/proc/{pp}/comm")).unwrap_or_default();
            let comm = strip_invalid_tail(raw.trim_ascii());
            let base = match comm.iter().rposition(|&b| b == b'.') {
                Some(i) => &comm[..i],
                None => comm,
            };
            if !base.is_empty() {
                if let Some(f) = newest_csv(&self.logs, base) {
                    if fresh(&f, now) && !log_fps(true, &f).is_empty() {
                        return Some((true, f));
                    }
                }
            }
            if let Ok(env) = fs::read(format!("/proc/{pp}/environ")) {
                for kv in env.split(|&b| b == 0) {
                    if let Some(d) = kv.strip_prefix(b"GALLIUM_HUD_DUMP_DIR=") {
                        let f = Path::new(OsStr::from_bytes(d)).join("fps");
                        if !d.is_empty() && fresh(&f, now) && !log_fps(false, &f).is_empty() {
                            return Some((false, f));
                        }
                        break;
                    }
                }
            }
            p = fs::read(format!("/proc/{pp}/stat")).ok().and_then(|st| ppid(&st));
            depth += 1;
        }
        None
    }

    // ---- one sample
    pub fn sample(&mut self) -> Kv {
        let now = now_wall();
        let mono = self.mono();
        self.refresh_fds(mono);
        let (total, idle) = self
            .pv("/proc/stat", 256)
            .and_then(|s| {
                let v: Vec<u64> = s.split('\n').next()?.split_whitespace().skip(1).map(|x| x.parse().ok()).collect::<Option<_>>()?;
                (v.len() >= 5).then(|| (v.iter().sum::<u64>(), v[3] + v[4]))
            })
            .unwrap_or((0, 0));
        let g = self.gpu_ns();
        let (mut cpu, mut busy, mut fps) = (0i64, 0i64, String::new());
        if let Some((pw, pt, pi, pg)) = self.prev.take() {
            let dt_ns = ((mono - pw) * 1e9).max(1.0);
            let d = total as f64 - pt as f64;
            cpu = if d > 0.0 { (100.0 * (d - (idle as f64 - pi as f64)) / d) as i64 } else { 0 };
            let (mut tot, mut perpid) = (0f64, Vec::<(i32, f64)>::new());
            for (c, (pid, ns)) in &g {
                let Some((_, pns)) = pg.get(c) else { continue }; // appeared in between: no spike
                if ns <= pns {
                    continue;
                }
                let dd = (ns - pns) as f64;
                tot += dd;
                match perpid.iter_mut().find(|(p, _)| p == pid) {
                    Some(e) => e.1 += dd,
                    None => perpid.push((*pid, dd)),
                }
            }
            busy = ((tot * 100.0 / dt_ns) as i64).min(100);
            if !perpid.is_empty() {
                perpid.sort_by(|a, b| b.1.total_cmp(&a.1)); // stable: busiest first
                let cands: Vec<i32> = perpid.iter().take(FPS_CANDIDATES).map(|x| x.0).collect();
                fps = self.fps(&cands, now, mono);
            }
        }
        self.prev = Some((mono, total, idle, g));
        // sysfs, the same fields as y700-hudinfo (the lists are taken out while self is borrowed for the reads)
        let pol = std::mem::take(&mut self.pol);
        let mhz = pol.iter().map(|p| self.iv(p, 0, false) / 1000).max().unwrap_or(0);
        self.pol = pol;
        let cz = std::mem::take(&mut self.cpu_z);
        let ct = fmax(cz.iter().map(|p| self.iv(p, 0, false) as f64 / 1000.0).collect::<Vec<_>>().into_iter());
        self.cpu_z = cz;
        let gz = std::mem::take(&mut self.gpu_z);
        let gt = fmax(gz.iter().map(|p| self.iv(p, 0, false) as f64 / 1000.0).collect::<Vec<_>>().into_iter());
        self.gpu_z = gz;
        if mono - self.skin.1 >= SLOW_S {
            let sz = std::mem::take(&mut self.skin_z);
            let v = fmax(sz.iter().map(|p| self.iv(p, 0, true) as f64 / 1000.0).collect::<Vec<_>>().into_iter());
            self.skin_z = sz;
            self.skin = (v, mono);
        }
        let skin = self.skin.0;
        if mono - self.cap.1 >= CAP_S {
            let c = self.iv(&format!("{B}/capacity"), -1, true);
            self.cap = (if (0..=100).contains(&c) { c } else { self.cap.0 }, mono);
        }
        let cap = self.cap.0;
        let bat = if cap >= 0 { format!("BAT {cap}% | ") } else { String::new() };
        let cool = std::mem::take(&mut self.cool);
        let thr = cool.iter().any(|p| self.iv(p, 0, false) > 0);
        self.cool = cool;
        let gf = self.iv(GPUF, 0, true) as f64 / 1e6;
        let bi = self.iv(&format!("{B}/current_now"), 0, true) as f64;
        let bv = self.iv(&format!("{B}/voltage_now"), 0, true) as f64;
        let on = self.iv(&format!("{U}/online"), 0, true);
        let (mut ui, mut uv, mut adap) = (0f64, 0f64, String::new());
        if on == 1 {
            // offline all three read 0 / [Unknown]; each read is a firmware round trip
            ui = self.iv(&format!("{U}/current_now"), 0, true) as f64;
            uv = self.iv(&format!("{U}/voltage_now"), 0, true) as f64;
            let t = match self.pv(&format!("{U}/usb_type"), 4096) {
                Some(t) => t,
                None => self.ok_usb_type.clone(),
            };
            self.ok_usb_type = t.clone();
            adap = bracketed(&t).unwrap_or_default();
        }
        let hz = self.hz_vote.take().or_else(|| self.pv(RS, 4096).and_then(|s| hz_of(&s))).unwrap_or_default();
        let bp = (bi / 1000.0) * (bv / 1000.0); // uW, signed like the current
        // charging with no input current: the charge pumps carry it (PPS), see the header - input power unknown
        let pump = on == 1 && ui <= 0.0 && bp / 1e6 > 0.5;
        let inw = ui / 1000.0 * uv / 1000.0 / 1e6;
        let (inv, ina) = (uv / 1e6, ui / 1e6);
        let lab = adapter_label(&adap, inv, pump);
        let vin = format!(" {inv:.1}V") + &if lab.is_empty() { String::new() } else { format!(" {lab}") };
        let pwt = if pump {
            format!("chg {:.1}W{vin} (charge pump: input not measured)", bp / 1e6)
        } else if on == 1 && bp / 1e6 > 0.5 {
            format!("in {inw:.1}W{vin} (batt {:+.1}W)", bp / 1e6)
        } else if on == 1 {
            format!("{:.1}W (charger{vin})", inw - bp / 1e6)
        } else {
            format!("{:.1}W batt", -bp / 1e6)
        };
        let head = if !fps.is_empty() {
            format!("{fps} FPS | ")
        } else if !hz.is_empty() {
            format!("{hz}Hz | ")
        } else {
            String::new()
        };
        let line = format!(
            "{head}CPU {cpu}% {mhz}MHz {}C | GPU {busy}% {}MHz {}C | SKIN {}C{} | {bat}{pwt}",
            ct as i64, gf as i64, gt as i64, skin as i64, if thr { " THR" } else { "" }
        );
        let (sysw, batw) = if on == 1 {
            ((ui / 1000.0 * uv / 1000.0 - bp) / 1e6, fmt_g6(bp / 1e6))
        } else {
            (-bp / 1e6, String::new())
        };
        let on1 = on == 1;
        let unknown = |s: String| if pump { String::new() } else { s }; // empty = not measured
        let kv = Kv {
            fps,
            hz,
            cpu: cpu.to_string(),
            cpu_mhz: mhz.to_string(),
            cpu_c: (ct as i64).to_string(),
            gpu: busy.to_string(),
            gpu_mhz: (gf as i64).to_string(),
            gpu_c: (gt as i64).to_string(),
            skin_c: (skin as i64).to_string(),
            thr: if thr { "1" } else { "0" }.to_string(),
            sys_w: unknown(format!("{sysw:.1}")),
            bat_w: batw,
            on: on.to_string(),
            in_w: unknown(format!("{:.1}", if on1 { inw } else { 0.0 })),
            in_v: format!("{:.2}", if on1 { inv } else { 0.0 }),
            in_a: unknown(format!("{:.2}", if on1 { ina } else { 0.0 })),
            adapter: if on1 { lab } else { String::new() },
            bat_pct: if cap >= 0 { cap.to_string() } else { String::new() },
        };
        self.write(&line, &kv);
        self.line = line;
        kv
    }

    /// A sample that only sets the counters (busy values are averaged since the previous sample): nothing is
    /// written and the last line is kept. At start, and after the screen was off - an average over the dark time
    /// means nothing, and the status bar would show it for a second.
    pub fn prime(&mut self) {
        let (cache, line, vote) = (self.cache.take(), std::mem::take(&mut self.line), self.hz_vote.take());
        self.sample();
        (self.cache, self.line, self.hz_vote) = (cache, line, vote);
    }

    /// $XDG_RUNTIME_DIR/y700-hud.txt and .kv, for `y700-hudinfo` on the command line (written via tmp files)
    fn write(&self, line: &str, kv: &Kv) {
        let Some(cache) = &self.cache else { return };
        let c = cache.as_os_str().as_bytes();
        let with = |suffix: &str| PathBuf::from(OsStr::from_bytes(&[c, suffix.as_bytes()].concat()));
        let body: String = kv.pairs().iter().map(|(k, v)| format!("{k}={v}\n")).collect();
        let _ = fs::write(with(".rs.tmp"), format!("{line}\n"))
            .and_then(|_| fs::write(with(".kv.rs.tmp"), body))
            .and_then(|_| fs::rename(with(".rs.tmp"), cache))
            .and_then(|_| fs::rename(with(".kv.rs.tmp"), with(".kv")));
    }

    /// old game logs: CSVs not written for 3 h; gl/<pid>/ dump dirs whose game is gone and nothing inside was
    /// written for 3 h (the directory's own mtime is not the criterion)
    fn cleanup_logs(&self) {
        let now = now_wall();
        let gl = self.logs.join("gl");
        // RUST: a failure is ignored (as the shell sampler's mkdir -p); Python's os.makedirs raises out of Sampler()
        let _ = fs::create_dir_all(&gl);
        let old = |p: &Path| mtime(p).map_or(false, |t| now - t > 3.0 * 3600.0);
        for e in fs::read_dir(&self.logs).into_iter().flatten().flatten() {
            let n = e.file_name();
            let nb = n.as_bytes();
            if !nb.starts_with(b".") && nb.ends_with(b".csv") && old(&e.path()) {
                let _ = fs::remove_file(e.path());
            }
        }
        fn recent(d: &Path, now: f64) -> bool {
            for e in fs::read_dir(d).into_iter().flatten().flatten() {
                let p = e.path();
                if mtime(&p).map_or(false, |t| now - t <= 3.0 * 3600.0) {
                    return true;
                }
                if e.file_type().map_or(false, |t| t.is_dir()) && recent(&p, now) {
                    return true;
                }
            }
            false
        }
        for e in fs::read_dir(&gl).into_iter().flatten().flatten() {
            let n = e.file_name();
            let nb = n.as_bytes();
            // Python: glob("gl/*/") - directories, not hidden. RUST: a symlink is skipped (Python's glob follows
            // it and rmtree("link/") would empty its target); nothing makes one, y700-gl-hud mkdir -p's real dirs
            if nb.starts_with(b".") || !e.file_type().map_or(false, |t| t.is_dir()) {
                continue;
            }
            if !nb.is_empty() && nb.iter().all(u8::is_ascii_digit) && Path::new("/proc").join(&n).is_dir() {
                continue;
            }
            if !recent(&e.path(), now) {
                let _ = fs::remove_dir_all(e.path());
            }
        }
    }
}

/// the first "[...]" entry (Python: re.search(r"\[([^]]+)\]"))
/// the adapter type shown: the firmware's usb_type pick, except that it says SDP (a 5 V computer port) on PD
/// chargers too (2026-10-18: a fixed-PD Apple charger at 9 V and a PPS charger), so SDP above 6 V is taken as PD
/// (QC would also be above 6 V; none seen here); the charge pumps only run on PPS
fn adapter_label(t: &str, volts: f64, pump: bool) -> String {
    match t {
        _ if pump => "PPS".into(),
        "PD_PPS" => "PPS".into(),
        "PD" | "PD_DRP" => "PD".into(),
        "SDP" if volts > 6.0 => "PD".into(),
        "Unknown" => String::new(),
        a => a.into(),
    }
}

fn bracketed(t: &str) -> Option<String> {
    let mut from = 0;
    while let Some(i) = t[from..].find('[') {
        let s = from + i + 1;
        let j = t[s..].find(']')?;
        if j > 0 {
            return Some(t[s..s + j].to_string());
        }
        from = s;
    }
    None
}

/// the digits after " hz " (Python: re.search(r" hz (\d+)"))
pub fn hz_of(s: &str) -> Option<String> {
    let mut from = 0;
    while let Some(i) = s[from..].find(" hz ") {
        let st = from + i + 4;
        let n = s[st..].bytes().take_while(u8::is_ascii_digit).count();
        if n > 0 {
            return Some(s[st..st + n].to_string());
        }
        from = st;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn g6() {
        assert_eq!(fmt_g6(12.3456789), "12.3457");
        assert_eq!(fmt_g6(-0.4995), "-0.4995");
        assert_eq!(fmt_g6(0.0), "0");
        assert_eq!(fmt_g6(14.2), "14.2");
        assert_eq!(fmt_g6(1234567.0), "1.23457e+06");
        assert_eq!(fmt_g6(0.00001234), "1.234e-05");
    }
    #[test]
    fn cut_comm() {
        let b = b"Steam\xe6\xb8\xb8\xe6\x88\x8f\xe5\x90\xaf\xe5";
        assert_eq!(strip_invalid_tail(b), "Steam游戏启".as_bytes());
        assert_eq!(strip_invalid_tail(b"vkcube"), b"vkcube");
    }
    #[test]
    fn parsers() {
        assert_eq!(ppid(b"1234 (Example Game.e) S 1200 1 1"), Some(1200));
        assert_eq!(bracketed("SDP [PD_PPS] DCP"), Some("PD_PPS".into()));
        assert_eq!(bracketed("[Unknown] SDP"), Some("Unknown".into()));
        assert_eq!(adapter_label("SDP", 9.3, true), "PPS");
        assert_eq!(adapter_label("SDP", 8.7, false), "PD");
        assert_eq!(adapter_label("SDP", 5.0, false), "SDP");
        assert_eq!(adapter_label("PD_PPS", 9.0, false), "PPS");
        assert_eq!(adapter_label("Unknown", 0.0, false), "");
        assert_eq!(hz_of("policy 2 live 3400 hz 120 idle_ms 1"), Some("120".into()));
        assert_eq!(field("drm-client-id:\t237\ndrm-engine-gpu:\t5 ns\n", "drm-engine-gpu:"), Some("5".into()));
    }
}
