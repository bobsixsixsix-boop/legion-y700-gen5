// y700-refresh-auto: the panel's refresh rate follows the video (owner, 2026-10-16: "全自动根据视频源来切换 30 60 120
// 三个档，游戏/触摸操作的时候默认 120"). README "刷新率跟随视频" has the whole design; in short: the base rate (default
// 120 Hz, or whatever the owner last picked) for touch, games and everything else, and 30 / 60 Hz only while the active
// window is a fullscreen player (KWin script) whose state file ($XDG_RUNTIME_DIR/y700-video/*, mpv script / wiliwili
// patch / Chrome host) says it plays 30 / 60 fps video, with no touch for 3 s, the screen on and the session unlocked.
// The flicker guard (0065: a full modeset at 60/30 Hz flickers): power key, lock screen and PrepareForSleep go back to
// the base at once; the video rate is never set with the screen off; SIGTERM and ExecStopPost --restore put the base
// back. Each window report also goes to the battery page's foreground log (linux/power/battery/DESIGN.md section 3).
// Status: gdbus call --session -d fyi.y700.RefreshAuto -o /RefreshAuto -m fyi.y700.RefreshAuto.status
//
// Rust port (2026-11-03) of the Python + Gio daemon (last Python version: git 669f79f
// linux/display/refresh-auto/y700-refresh-auto, with test-retry-offline.py, test-log-fg.py and the two shell tests).
// Decision, timings, log lines, config file, state files, the fg log and the D-Bus interface are the same - the logic
// is ported method for method in src/logic.rs; deliberate differences are marked RUST:. Where Python's cost went
// (11-03, 20.8 h up): 0.33 s of CPU, RSS 40.4 MB in 4 threads. Its GLib file monitor on ~/.config woke the gmain
// thread for every write of every KDE config file (909 context switches), GDBus ran its own worker thread, and while
// the panel was below its base a 1 s timer read the DSI dpms node - about 1700 wakeups in a 28-minute video session,
// which is where the screen-on boots with video (0.022-0.026 % of a core, against 0.002-0.0045 % without) spent it.
// Here the screen state comes as KWin's DPMS events (src/wl.rs), ~/.config is watched for finished writes only, the
// buses are read in this one thread, and every timer is an exact deadline: nothing runs between events.
//
// RUST: the deliberate differences, in one place
//   - the screen-off guard waits for KWin's DPMS events; the 1 s dpms tick runs only without them, or while the screen
//     is off and the panel still below the base (src/logic.rs on_screen / on_dpms_tick);
//   - kwinoutputconfig.json: only finished writes (IN_CLOSE_WRITE, IN_MOVED_TO) start the 100 ms re-read, not every
//     modify or attribute change - check_kwin ignores those anyway;
//   - KWin's Scripting object is called directly: GDBus's proxy also fetched its properties and subscribed to its
//     signals, for nothing;
//   - errors are one line ("<D-Bus error name>: <text>", Python's OSError text) where Python logged a traceback;
//   - a bus that closes logs "<bus> bus lost" and then stops as SIGTERM does (GDBus raised SIGTERM, silently);
//   - a power key that fails to read is dropped with a line (Python logged a traceback on every wakeup);
//   - the state directory, if removed, is made again and watched at once (GLib looked for it every 4 s);
//   - GLib's timeout_add_seconds slack (timers fired up to 1 s late, batched with others) is gone;
//   - the config refuses Infinity, which Python took and then failed on in int().
// Run by y700-refresh-auto.service (user); install and rollback: install.sh.

mod dbus;
mod fg;
mod json;
mod logic;
mod obj;
mod wl;

use dbus::{first_u32, strings, string_body, Arg, Bus, Msg, METHOD_CALL, SIGNAL};
use fg::{py_isspace, Fg};
use json::py_str_repr;
use logic::{pick_hz, restore, Cfg, Num, Out, Ra};
use obj::Route;
use std::collections::HashMap;
use std::ffi::CString;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{exit, Child, Command, Stdio};
use wl::Wl;

const NAME: &str = "fyi.y700.RefreshAuto";
const KWIN_NAME: &str = "y700-refresh-auto";
/// touch, pen, volume keys: read only while a video wants a lower rate
const TOUCHISH: [&str; 4] = ["NVTCapacitiveTouchScreen", "NVTCapacitivePen", "pmic_resin", "gpio-keys"];
const POWER_KEY: &str = "pmic_pwrkey";
const EV_SIZE: usize = 24; // struct input_event on arm64
const EV_KEY: u16 = 1;
const KEY_POWER: u16 = 116;
const SCREENSAVER: &str = "org.freedesktop.ScreenSaver";
const LOGIN1: &str = "org.freedesktop.login1";
const LOGIN1_PATH: &str = "/org/freedesktop/login1";
const LOGIN1_MANAGER: &str = "org.freedesktop.login1.Manager";
const LOCK_MATCH: &str = "type='signal',interface='org.freedesktop.ScreenSaver',member='ActiveChanged'";
const SLEEP_MATCH: &str = "type='signal',sender='org.freedesktop.login1',interface='org.freedesktop.login1.Manager',\
    member='PrepareForSleep',path='/org/freedesktop/login1'";
const LOGIN1_MATCH: &str = "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',\
    member='NameOwnerChanged',arg0='org.freedesktop.login1'";
const STATE_MASK: u32 = libc::IN_CREATE | libc::IN_CLOSE_WRITE | libc::IN_MOVED_TO | libc::IN_MOVED_FROM | libc::IN_DELETE | libc::IN_ONLYDIR;
const CONF_MASK: u32 = libc::IN_CLOSE_WRITE | libc::IN_MOVED_TO | libc::IN_ONLYDIR;
const KWINCONF_NAME: &str = "kwinoutputconfig.json";
/// how often a lost KWin connection is tried again (the dpms tick covers the screen-off guard meanwhile)
const KWIN_RETRY_S: f64 = 5.0;
/// --decide-test's table: fps -> the rate it must get at a 120 Hz base
const DECIDE: [(f64, i64); 18] = [(29.97, 30), (30.0, 30), (59.94, 60), (60.0, 60), (23.976, 120), (24.0, 120), (25.0, 120), (50.0, 120),
    (48.0, 120), (45.0, 120), (120.0, 120), (90.0, 120), (0.0, 120), (15.0, 30), (20.0, 60), (10.0, 30), (144.0, 120), (37.5, 120)];

pub fn say(msg: &str) {
    // RUST: a stdout that is gone (journald restarting) loses the line; println! would panic
    let _ = writeln!(io::stdout().lock(), "{msg}");
    #[cfg(test)]
    tests::LOGGED.with(|l| l.borrow_mut().push(msg.to_string()));
}

/// CLOCK_MONOTONIC in s (time.monotonic(): the fg log's clock too)
fn mono() -> f64 {
    let mut t = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut t) };
    t.tv_sec as f64 + t.tv_nsec as f64 / 1e9
}

fn strerror(e: &io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_string())
}

/// Python's OSError text: [Errno 2] No such file or directory: '/dev/input/event3'
fn oserr(e: &io::Error, path: &Path) -> String {
    match e.raw_os_error() {
        Some(n) => format!("[Errno {n}] {}: {}", strerror(e), py_str_repr(&path.to_string_lossy())),
        None => e.to_string(),
    }
}

/// GLib's text for a child that did not start (GLib.spawn_sync and Gio.Subprocess alike, checked on the tablet 11-03)
fn spawn_error(e: &io::Error, prog: &str) -> String {
    let Some(n) = e.raw_os_error() else { return e.to_string() };
    let code = match n {
        libc::EACCES => 3,
        libc::EPERM => 4,
        libc::E2BIG => 5,
        libc::ENOEXEC => 6,
        libc::ENAMETOOLONG => 7,
        libc::ENOENT => 8,
        libc::ENOMEM => 9,
        libc::ENOTDIR => 10,
        libc::ELOOP => 11,
        libc::ETXTBSY => 12,
        libc::EIO => 13,
        libc::ENFILE => 14,
        libc::EMFILE => 15,
        libc::EINVAL => 16,
        libc::EISDIR => 17,
        libc::ELIBBAD => 18,
        _ => 19,
    };
    format!("g-exec-error-quark: Failed to execute child process “{prog}” ({}) ({code})", strerror(e))
}

fn read_text(p: &Path) -> Option<String> {
    String::from_utf8(fs::read(p).ok()?).ok()
}

fn kwin_hz(kwinconf: &Path) -> Option<i64> {
    logic::kwin_hz_of(&read_text(kwinconf)?)
}

/// save_cfg(): json.dump(cfg, indent=1) through <conf>.tmp
fn save_cfg(conf: &Path, cfg: &Cfg) -> Result<(), String> {
    let dir = conf.parent().unwrap_or(Path::new("."));
    fs::create_dir_all(dir).map_err(|e| oserr(&e, dir))?;
    let mut tmp = conf.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    fs::write(&tmp, cfg.to_json()).map_err(|e| oserr(&e, &tmp))?;
    fs::rename(&tmp, conf).map_err(|e| format!("{} -> {}", oserr(&e, &tmp), py_str_repr(&conf.to_string_lossy())))
}

/// /proc/bus/input/devices: name -> /dev/input/eventN (input_devices())
fn parse_devices(text: &str) -> HashMap<String, String> {
    let (mut out, mut name) = (HashMap::new(), String::new());
    for line in text.lines() {
        if let Some(v) = line.strip_prefix("N: Name=") {
            name = v.trim_matches(py_isspace).trim_matches('"').to_string();
        } else if let Some(v) = line.strip_prefix("H: Handlers=") {
            for h in v.split(py_isspace).filter(|h| h.starts_with("event") && !name.is_empty()) {
                out.insert(name.clone(), format!("/dev/input/{h}"));
            }
        }
    }
    out
}

/// The DSI connectors' dpms nodes (glob /sys/class/drm/card*-DSI-1/dpms)
fn dpms_paths() -> Vec<PathBuf> {
    let Ok(dir) = fs::read_dir("/sys/class/drm") else { return Vec::new() };
    let mut v: Vec<PathBuf> = dir
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("card") && n.ends_with("-DSI-1"))
        .map(|n| Path::new("/sys/class/drm").join(n).join("dpms"))
        .filter(|p| p.exists())
        .collect();
    v.sort();
    v
}

/// screen_on(): the first readable node decides; none readable is on
fn sysfs_on(paths: &[PathBuf]) -> bool {
    paths.iter().find_map(|p| fs::read_to_string(p).ok()).map_or(true, |s| s.starts_with("On"))
}

fn open_input(p: &str) -> io::Result<File> {
    fs::OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK).open(p)
}

/// A power key press among the events read (whole input_events only).
fn presses(buf: &[u8]) -> bool {
    buf.chunks_exact(EV_SIZE).any(|e| {
        let u16_at = |i: usize| u16::from_ne_bytes([e[i], e[i + 1]]);
        u16_at(16) == EV_KEY && u16_at(18) == KEY_POWER && i32::from_ne_bytes(e[20..24].try_into().unwrap()) == 1
    })
}

/// Reads an evdev fd until it is empty: Ok(whether the power key went down), Err when the device is gone.
fn drain(mut f: &File) -> io::Result<bool> {
    let mut buf = [0u8; EV_SIZE * 64];
    let mut press = false;
    loop {
        match f.read(&mut buf) {
            Ok(0) => return Ok(press),
            Ok(n) => press |= presses(&buf[..n]),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(press),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
}

/// unlink_if(): removes a state file only if it still says pid=<pid> (a newer player may have taken the name)
fn unlink_if(path: &Path, pid: i64) {
    let want = format!("pid={pid}");
    if fs::read_to_string(path).is_ok_and(|t| t.split(py_isspace).any(|w| w == want)) {
        let _ = fs::remove_file(path);
    }
}

fn pidfd(pid: i64) -> io::Result<OwnedFd> {
    let pid = libc::pid_t::try_from(pid).map_err(|_| io::Error::from_raw_os_error(libc::EINVAL))?;
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(fd as RawFd) })
}

/// restore()'s kscreen-doctor: bounded by timeout(1), waited for
fn restore_cmd(mode: &str) -> Result<(), String> {
    Command::new("timeout")
        .args(["8", "kscreen-doctor", &format!("output.DSI-1.mode.{mode}")])
        .output()
        .map(drop)
        .map_err(|e| spawn_error(&e, "timeout"))
}

#[derive(Debug, PartialEq)]
struct Ev {
    wd: i32,
    mask: u32,
    cookie: u32,
    name: String,
}

fn inotify_events(b: &[u8]) -> Vec<Ev> {
    let mut out = Vec::new();
    let mut at = 0;
    while at + 16 <= b.len() {
        let u = |i: usize| u32::from_ne_bytes(b[at + i..at + i + 4].try_into().unwrap());
        let len = u(12) as usize;
        let Some(raw) = b.get(at + 16..at + 16 + len) else { break }; // the kernel hands out whole events only
        let name = String::from_utf8_lossy(raw.split(|&c| c == 0).next().unwrap_or(&[])).into_owned();
        out.push(Ev { wd: u(0) as i32, mask: u(4), cookie: u(8), name });
        at += 16 + len;
    }
    out
}

/// The state directory's changes as on_statedir() took GLib's events: (name, gone). A rename inside the directory
/// (MOVED_FROM and MOVED_TO with one cookie - the writers' foo.tmp -> foo) counts for the new name only, as RENAMED did.
fn dir_changes(evs: &[Ev], wd: i32) -> Vec<(String, bool)> {
    let mine: Vec<&Ev> = evs.iter().filter(|e| e.wd == wd).collect();
    let renamed = |c: u32| mine.iter().any(|e| e.mask & libc::IN_MOVED_TO != 0 && e.cookie == c);
    mine.iter()
        .filter_map(|e| {
            if e.mask & (libc::IN_CREATE | libc::IN_CLOSE_WRITE | libc::IN_MOVED_TO) != 0 {
                Some((e.name.clone(), false))
            } else if e.mask & libc::IN_DELETE != 0 || (e.mask & libc::IN_MOVED_FROM != 0 && !renamed(e.cookie)) {
                Some((e.name.clone(), true))
            } else {
                None
            }
        })
        .collect()
}

/// Everything there is to read (the fd is non-blocking): a rename's two events stay together.
fn read_all(fd: RawFd) -> Vec<u8> {
    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
        if n <= 0 {
            return out; // EAGAIN: all read
        }
        out.extend_from_slice(&buf[..n as usize]);
    }
}

fn inotify() -> io::Result<OwnedFd> {
    let fd = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn add_watch(ino: &OwnedFd, dir: &Path, mask: u32) -> io::Result<i32> {
    let c = CString::new(dir.as_os_str().as_bytes())?;
    let wd = unsafe { libc::inotify_add_watch(ino.as_raw_fd(), c.as_ptr(), mask) };
    if wd < 0 {
        return Err(io::Error::other(oserr(&io::Error::last_os_error(), dir)));
    }
    Ok(wd)
}

fn make_statedir(dir: &Path) -> io::Result<()> {
    fs::DirBuilder::new().recursive(true).mode(0o700).create(dir).map_err(|e| io::Error::other(oserr(&e, dir)))
}

/// SIGTERM / SIGINT as an fd, from the main loop on (Python's signal_add came after its start too: before, they kill
/// the process and ExecStopPost restores).
fn signalfd() -> io::Result<OwnedFd> {
    unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGTERM);
        libc::sigaddset(&mut set, libc::SIGINT);
        // Command resets the mask in its children: kscreen-doctor and timeout(1) get these signals as usual
        if libc::sigprocmask(libc::SIG_BLOCK, &set, std::ptr::null_mut()) != 0 {
            return Err(io::Error::last_os_error());
        }
        let fd = libc::signalfd(-1, &set, libc::SFD_NONBLOCK | libc::SFD_CLOEXEC);
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(OwnedFd::from_raw_fd(fd))
    }
}

enum Screen {
    Kwin(Wl),
    /// RUST: only without KWin's events: the logic's 1 s tick reads the dpms node, as Python always did. `retry`: try
    /// KWin again now and then (not when it lacks the protocol)
    Sysfs { retry: bool, next: f64 },
}

fn without_kwin(e: &io::Error) -> Screen {
    say(&format!("no KWin screen events ({e}); checking the screen every second while below the base"));
    Screen::Sysfs { retry: e.kind() != io::ErrorKind::Unsupported, next: mono() + KWIN_RETRY_S }
}

/// The world as the decision sees it (logic::Out).
struct Real {
    ses: Bus,
    sys: Bus,
    conf: PathBuf,
    kwinconf: PathBuf,
    statedir: PathBuf,
    dpms: Vec<PathBuf>,
    screen: Screen,
    /// the running kscreen-doctor and its pidfd
    child: Option<(Child, OwnedFd)>,
    touch_paths: Vec<String>,
    /// open only while a video wants a lower rate
    touch_fds: Vec<File>,
    pidfds: Vec<(i64, OwnedFd)>,
    sleep_fd: Option<OwnedFd>,
}

impl Out for Real {
    fn now(&self) -> f64 {
        mono()
    }
    fn kwin_hz(&mut self) -> Option<i64> {
        kwin_hz(&self.kwinconf)
    }
    fn kscreen_json(&mut self) -> Result<Vec<u8>, String> {
        // shortcut: waited for without a timeout, as Python's spawn_sync was (a hung kscreen-doctor -j hangs the daemon)
        Command::new("kscreen-doctor").arg("-j").output().map(|o| o.stdout).map_err(|e| spawn_error(&e, "kscreen-doctor"))
    }
    fn switch(&mut self, output: &str, mode: &str) -> Result<(), String> {
        let mut child = Command::new("kscreen-doctor")
            .arg(format!("output.{output}.mode.{mode}"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| spawn_error(&e, "kscreen-doctor"))?;
        match pidfd(child.id() as i64) {
            Ok(fd) => {
                self.child = Some((child, fd));
                Ok(())
            }
            Err(e) => {
                // RUST: its end could not be waited for in the loop: killed, and counted as not started
                let _ = child.kill();
                let _ = child.wait();
                Err(format!("pidfd_open: {e}"))
            }
        }
    }
    fn kill_switch(&mut self) {
        if let Some((c, _)) = &mut self.child {
            let _ = c.kill();
        }
    }
    fn stop_switch(&mut self) {
        if let Some((mut c, _)) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
    fn restore_mode(&mut self, mode: &str) -> Result<(), String> {
        restore_cmd(mode)
    }
    fn screen_on(&mut self) -> bool {
        // KWin's word and the node's, as Python read it: off if either says so
        let kwin = match &self.screen {
            Screen::Kwin(w) => w.screen_on(),
            Screen::Sysfs { .. } => true,
        };
        kwin && sysfs_on(&self.dpms)
    }
    fn screen_events(&self) -> bool {
        matches!(self.screen, Screen::Kwin(_))
    }
    fn save_cfg(&mut self, cfg: &Cfg) -> Result<(), String> {
        save_cfg(&self.conf, cfg)
    }
    fn touch(&mut self, on: bool) {
        if on && self.touch_fds.is_empty() {
            for p in &self.touch_paths {
                match open_input(p) {
                    Ok(f) => self.touch_fds.push(f),
                    Err(e) => say(&format!("cannot open {p}: {}", oserr(&e, Path::new(p)))),
                }
            }
        } else if !on {
            self.touch_fds.clear();
        }
    }
    fn touch_attached(&self) -> bool {
        !self.touch_fds.is_empty()
    }
    fn read_state(&mut self, name: &str) -> Option<Vec<u8>> {
        fs::read(self.statedir.join(name)).ok()
    }
    fn pid_exists(&self, pid: i64) -> bool {
        Path::new(&format!("/proc/{pid}")).exists()
    }
    fn unlink_if(&mut self, name: &str, pid: i64) {
        unlink_if(&self.statedir.join(name), pid);
    }
    fn watch_pid(&mut self, pid: i64) {
        if !self.pidfds.iter().any(|p| p.0 == pid) {
            if let Ok(fd) = pidfd(pid) {
                self.pidfds.push((pid, fd));
            }
        }
    }
    fn unwatch_pid(&mut self, pid: i64) {
        self.pidfds.retain(|p| p.0 != pid);
    }
    fn take_sleep_lock(&mut self) {
        if self.sleep_fd.is_some() {
            return;
        }
        let args = [Arg::Str("sleep"), Arg::Str("y700-refresh-auto"), Arg::Str("panel back to its base refresh rate"), Arg::Str("delay")];
        match self.sys.call(LOGIN1, LOGIN1_PATH, LOGIN1_MANAGER, "Inhibit", &args) {
            Ok(mut m) => match first_u32(&m, 'h').map(|i| i as usize) {
                Some(i) if i < m.fds.len() => self.sleep_fd = Some(m.fds.swap_remove(i)),
                _ => say("no sleep delay inhibitor: no fd in logind's reply"),
            },
            Err(e) => say(&format!("no sleep delay inhibitor: {e}")),
        }
    }
    fn release_sleep_lock(&mut self) {
        self.sleep_fd = None;
    }
}

/// Runs the KWin script now, so that it reports the current active window. The script must stay ENABLED (metadata
/// EnabledByDefault: true): Scripting.start() unloads a disabled script at once. If this fails, KWin's own load at
/// login still reports. Do not switch to /Scripting/Script<id>.run: ids are reused after an unload.
fn reload_kwin_script(ses: &mut Bus, script: &Path) {
    if !script.exists() {
        say(&format!("KWin script missing: {}", script.display()));
        return;
    }
    let mut call = |m: &str, a: &[Arg]| ses.call_t(2000, "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", m, a);
    let path = script.to_string_lossy();
    let r = (|| -> io::Result<()> {
        call("unloadScript", &[Arg::Str(KWIN_NAME)])?;
        let sid = call("loadScript", &[Arg::Str(&path), Arg::Str(KWIN_NAME)])?;
        if (first_u32(&sid, 'i').ok_or_else(|| io::Error::other("loadScript: no id in the reply"))? as i32) < 0 {
            say("KWin refused to load the script (already loaded?)");
        }
        call("start", &[])?;
        if first_u32(&call("isScriptLoaded", &[Arg::Str(KWIN_NAME)])?, 'b') == Some(0) {
            say("the KWin script is not loaded after start(): disabled in System Settings? (no window reports)");
        }
        Ok(())
    })();
    if let Err(e) = r {
        say(&format!("could not (re)load the KWin script: {e}"));
    }
}

struct Daemon {
    ra: Ra<Real>,
    ino: OwnedFd,
    wd_state: i32,
    wd_conf: i32,
    power: Option<File>,
    /// logind's unique name: PrepareForSleep counts only from it
    login1: Option<String>,
}

fn start(home: &str) -> io::Result<Daemon> {
    let h = PathBuf::from(home);
    let run = std::env::var_os("XDG_RUNTIME_DIR").map_or_else(|| PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() })), PathBuf::from);
    let statedir = run.join("y700-video");
    let conf = h.join(".config/y700-refresh-auto.json");
    let mut ses = Bus::session()?;
    let sys = Bus::system()?;
    let r = ses.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", &[Arg::Str(NAME), Arg::U32(4)])?; // 4 = DO_NOT_QUEUE
    if !matches!(first_u32(&r, 'u'), Some(1 | 4)) {
        say("another y700-refresh-auto owns the name: exiting");
        exit(0);
    }
    let cfg = Cfg::load(read_text(&conf).as_deref());
    save_cfg(&conf, &cfg).map_err(io::Error::other)?;
    let real = Real {
        ses,
        sys,
        conf,
        kwinconf: h.join(".config").join(KWINCONF_NAME),
        statedir: statedir.clone(),
        dpms: dpms_paths(),
        screen: Screen::Sysfs { retry: false, next: 0.0 },
        child: None,
        touch_paths: Vec::new(),
        touch_fds: Vec::new(),
        pidfds: Vec::new(),
        sleep_fd: None,
    };
    let mut ra = Ra::new(real, cfg, Fg::new(home));
    ra.read_modes();
    ra.cur_hz = ra.current_hz();
    ra.dpms = !ra.out.dpms.is_empty();
    if !ra.dpms {
        say("no DSI dpms node: the screen-off guard cannot work, video rates disabled");
    }
    // RUST: one of these two lines at every start (y700-checklist reads the last one)
    ra.out.screen = match Wl::open() {
        Ok(w) => {
            say("watching KWin screen events");
            Screen::Kwin(w)
        }
        Err(e) => without_kwin(&e),
    };
    ra.out.ses.add_match(LOCK_MATCH)?;
    if let Ok(m) = ra.out.ses.call_t(1000, SCREENSAVER, "/ScreenSaver", SCREENSAVER, "GetActive", &[]) {
        if let Some(b) = first_u32(&m, 'b') {
            ra.locked = b != 0;
        }
    }
    ra.out.sys.add_match(SLEEP_MATCH)?;
    ra.out.sys.add_match(LOGIN1_MATCH)?;
    let login1 = ra.out.sys.name_owner(LOGIN1)?;
    ra.out.take_sleep_lock();
    make_statedir(&statedir)?;
    let ino = inotify()?;
    let wd_state = add_watch(&ino, &statedir, STATE_MASK)?;
    let wd_conf = add_watch(&ino, &h.join(".config"), CONF_MASK)?;
    for e in fs::read_dir(&statedir)?.flatten() {
        let n = e.file_name().to_string_lossy().into_owned();
        if !n.ends_with(".tmp") {
            ra.read_player(&n);
        }
    }
    let devs = parse_devices(&fs::read_to_string("/proc/bus/input/devices").unwrap_or_default());
    ra.out.touch_paths = TOUCHISH.iter().filter_map(|n| devs.get(*n).cloned()).collect();
    let power = devs.get(POWER_KEY).and_then(|p| {
        open_input(p).map_err(|e| say(&format!("cannot open the power key: {}", oserr(&e, Path::new(p))))).ok()
    });
    say(&ra.start_line(ra.out.touch_paths.len()));
    ra.fg.mark(mono(), "START"); // before the reload: the script's report of the current window comes after it
    reload_kwin_script(&mut ra.out.ses, &h.join(".local/share/kwin/scripts/y700-refresh-auto/contents/code/main.js"));
    ra.evaluate("start");
    Ok(Daemon { ra, ino, wd_state, wd_conf, power, login1 })
}

/// RUST: a bus that closes logs a line, then stops as SIGTERM does (GDBus's exit-on-close raised SIGTERM, silently).
fn lost(ra: &mut Ra<Real>, bus: &str, e: io::Error) -> ! {
    say(&format!("{bus} bus lost: {e}"));
    ra.stop();
    exit(0)
}

/// A method call to us, on either connection (the object is only on the session's).
fn on_call(ra: &mut Ra<Real>, m: &Msg, session: bool) {
    let bus = if session { &mut ra.out.ses } else { &mut ra.out.sys };
    let sent = match obj::route(m, session) {
        Route::Reply(sig, body) => bus.reply(m, sig, &body),
        Route::Error(name, text) => bus.error(m, name, &text),
        Route::ActiveWindow(cls, covers, pid) => match bus.reply(m, "", &[]) {
            Ok(()) => {
                ra.on_active_window(&cls, covers, pid as i64);
                Ok(())
            }
            Err(e) => Err(e),
        },
        Route::Status => {
            let s = ra.status();
            ra.out.ses.reply(m, "s", &string_body(&s))
        }
    };
    if let Err(e) = sent {
        lost(ra, if session { "session" } else { "system" }, e);
    }
}

impl Daemon {
    /// Everything the buses brought: signals, calls to us, and whatever came while a call of ours waited.
    fn dispatch(&mut self) {
        loop {
            if let Some(m) = self.ra.out.ses.pending.pop_front() {
                match m.kind {
                    METHOD_CALL => on_call(&mut self.ra, &m, true),
                    SIGNAL if m.member == "ActiveChanged" && m.iface.as_deref() == Some(SCREENSAVER) => {
                        if let Some(b) = first_u32(&m, 'b') {
                            self.ra.on_lock(b != 0);
                        }
                    }
                    _ => {}
                }
            } else if let Some(m) = self.ra.out.sys.pending.pop_front() {
                match m.kind {
                    METHOD_CALL => on_call(&mut self.ra, &m, false),
                    SIGNAL if m.member == "NameOwnerChanged" && m.sender == "org.freedesktop.DBus" => {
                        if let [name, _, new] = &strings(&m)[..] {
                            if name == LOGIN1 {
                                self.login1 = (!new.is_empty()).then(|| new.clone());
                            }
                        }
                    }
                    SIGNAL if m.member == "PrepareForSleep"
                        && m.path == LOGIN1_PATH
                        && m.iface.as_deref() == Some(LOGIN1_MANAGER)
                        && self.login1.as_deref() == Some(m.sender.as_str()) =>
                    {
                        if let Some(b) = first_u32(&m, 'b') {
                            self.ra.on_sleep(b != 0);
                        }
                    }
                    _ => {}
                }
            } else {
                return;
            }
        }
    }

    fn on_touch_fd(&mut self, fd: RawFd) {
        let Some(i) = self.ra.out.touch_fds.iter().position(|f| f.as_raw_fd() == fd) else { return };
        if drain(&self.ra.out.touch_fds[i]).is_err() {
            self.ra.out.touch_fds.remove(i); // device gone (driver re-probe): dropped, reopened on the next attach
            return;
        }
        self.ra.on_touch();
    }

    fn on_power_fd(&mut self) {
        let Some(f) = &self.power else { return };
        match drain(f) {
            Ok(true) => self.ra.on_power(),
            Ok(false) => {}
            Err(e) => {
                say(&format!("cannot read the power key: {e}: no longer watched")); // RUST: see the header
                self.power = None;
            }
        }
    }

    fn on_inotify(&mut self) {
        // shortcut: an IN_Q_OVERFLOW (16384 events queued) loses changes until the next one; the writers write rarely
        let evs = inotify_events(&read_all(self.ino.as_raw_fd()));
        for (name, gone) in dir_changes(&evs, self.wd_state) {
            self.ra.on_statedir(&name, gone);
        }
        let conf = libc::IN_CLOSE_WRITE | libc::IN_MOVED_TO;
        if evs.iter().any(|e| e.wd == self.wd_conf && e.mask & conf != 0 && e.name == KWINCONF_NAME) {
            self.ra.on_kwinconf();
        }
        if evs.iter().any(|e| e.wd == self.wd_state && e.mask & libc::IN_IGNORED != 0) {
            // RUST: the directory was removed: made again and watched at once (GLib looked for it every 4 s)
            let dir = self.ra.out.statedir.clone();
            match make_statedir(&dir).and_then(|()| add_watch(&self.ino, &dir, STATE_MASK)) {
                Ok(wd) => self.wd_state = wd,
                Err(e) => say(&format!("cannot watch {}: {e}", dir.display())),
            }
        }
    }

    fn run(mut self) -> ! {
        let sig = match signalfd() {
            Ok(fd) => fd,
            Err(e) => {
                say(&format!("signalfd: {e}"));
                self.ra.stop();
                exit(1)
            }
        };
        loop {
            self.dispatch();
            let now = mono();
            let retry = match &self.ra.out.screen {
                Screen::Sysfs { retry: true, next } => Some(*next),
                _ => None,
            };
            let deadline = self.ra.next_deadline().into_iter().chain(retry).min_by(f64::total_cmp);
            let timeout = deadline.map_or(-1, |d| ((d - now) * 1000.0).ceil().clamp(0.0, 3.6e6) as i32);
            let touch: Vec<RawFd> = self.ra.out.touch_fds.iter().map(|f| f.as_raw_fd()).collect();
            let pids: Vec<(i64, RawFd)> = self.ra.out.pidfds.iter().map(|(p, fd)| (*p, fd.as_raw_fd())).collect();
            let wl_fd = match &self.ra.out.screen {
                Screen::Kwin(w) => w.fd(),
                Screen::Sysfs { .. } => -1,
            };
            // touch first: nothing handled before them can have closed (or reused) their fds
            let mut fds = vec![sig.as_raw_fd()];
            fds.extend(&touch);
            let base = fds.len();
            fds.extend([
                self.ra.out.ses.fd(),
                self.ra.out.sys.fd(),
                wl_fd,
                self.ino.as_raw_fd(),
                self.power.as_ref().map_or(-1, |f| f.as_raw_fd()),
                self.ra.out.child.as_ref().map_or(-1, |c| c.1.as_raw_fd()),
            ]);
            fds.extend(pids.iter().map(|p| p.1));
            let mut pfd: Vec<libc::pollfd> = fds.iter().map(|&fd| libc::pollfd { fd, events: libc::POLLIN, revents: 0 }).collect();
            if unsafe { libc::poll(pfd.as_mut_ptr(), pfd.len() as libc::nfds_t, timeout) } < 0 {
                let e = io::Error::last_os_error();
                if e.kind() != io::ErrorKind::Interrupted {
                    say(&format!("poll: {e}"));
                    self.ra.stop();
                    exit(1);
                }
                continue;
            }
            let ready = |i: usize| pfd[i].revents != 0;
            if ready(0) {
                let mut info = [0u8; 128]; // signalfd_siginfo: which signal does not matter
                let _ = unsafe { libc::read(sig.as_raw_fd(), info.as_mut_ptr().cast(), info.len()) };
                self.ra.stop();
                exit(0);
            }
            for (i, fd) in touch.iter().enumerate() {
                if ready(1 + i) {
                    self.on_touch_fd(*fd);
                }
            }
            if ready(base) {
                if let Err(e) = self.ra.out.ses.fill() {
                    lost(&mut self.ra, "session", e);
                }
            }
            if ready(base + 1) {
                if let Err(e) = self.ra.out.sys.fill() {
                    lost(&mut self.ra, "system", e);
                }
            }
            if ready(base + 2) {
                if let Screen::Kwin(w) = &mut self.ra.out.screen {
                    match w.read() {
                        Ok(()) => self.ra.on_screen(),
                        Err(e) => {
                            self.ra.out.screen = without_kwin(&e); // KWin restarted or crashed: the tick until it is back
                            self.ra.on_events_lost();
                        }
                    }
                }
            }
            if ready(base + 3) {
                self.on_inotify();
            }
            if ready(base + 4) {
                self.on_power_fd();
            }
            if ready(base + 5) {
                if let Some((mut c, _)) = self.ra.out.child.take() {
                    let ok = c.wait().is_ok_and(|s| s.success());
                    self.ra.on_mode_done(ok);
                }
            }
            let exited: Vec<i64> = pids.iter().enumerate().filter(|(i, _)| ready(base + 6 + i)).map(|(_, p)| p.0).collect();
            for pid in exited {
                if self.ra.out.pidfds.iter().any(|p| p.0 == pid) {
                    self.ra.on_player_exit(pid);
                }
            }
            let now = mono();
            if matches!(&self.ra.out.screen, Screen::Sysfs { retry: true, next } if now >= *next) {
                self.ra.out.screen = match Wl::open() {
                    Ok(w) => {
                        say("KWin screen events back");
                        Screen::Kwin(w)
                    }
                    Err(e) => Screen::Sysfs { retry: e.kind() != io::ErrorKind::Unsupported, next: now + KWIN_RETRY_S },
                };
            }
            self.ra.on_timer();
        }
    }
}

fn decide_lines() -> Vec<String> {
    let cfg = Cfg::default();
    DECIDE
        .iter()
        .map(|&(fps, want)| {
            let got = pick_hz(fps, &cfg, Num::I(120));
            let verdict = if got == Num::I(want) { "ok".to_string() } else { format!("WRONG (want {want})") };
            format!("{fps:7.3} fps -> {got} Hz {verdict}")
        })
        .collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--decide-test") {
        for l in decide_lines() {
            say(&l);
        }
        return;
    }
    let home = std::env::var("HOME").unwrap_or_default();
    if args.iter().any(|a| a == "--restore") {
        let h = Path::new(&home);
        let base = Cfg::load(read_text(&h.join(".config/y700-refresh-auto.json")).as_deref()).base_hz;
        restore(kwin_hz(&h.join(".config").join(KWINCONF_NAME)), base, "restore", restore_cmd);
        return;
    }
    match start(&home) {
        Ok(d) => d.run(),
        Err(e) => {
            say(&format!("cannot start: {e}"));
            exit(1)
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::cell::RefCell;

    thread_local! {
        pub static LOGGED: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
    }

    pub fn logged_count() -> usize {
        LOGGED.with(|l| l.borrow().len())
    }

    pub fn logged_since(n: usize) -> Vec<String> {
        LOGGED.with(|l| l.borrow()[n..].to_vec())
    }

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("ra-main-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn decide_table() {
        let lines = decide_lines();
        assert_eq!(lines.len(), 18);
        assert!(lines.iter().all(|l| l.ends_with(" Hz ok")), "{lines:?}");
        assert_eq!(lines[0], " 29.970 fps -> 30 Hz ok");
        assert_eq!(lines[12], "  0.000 fps -> 120 Hz ok");
    }

    #[test]
    fn error_texts() {
        let e = File::open("/nonexistent-ra/x").unwrap_err();
        assert_eq!(oserr(&e, Path::new("/nonexistent-ra/x")), "[Errno 2] No such file or directory: '/nonexistent-ra/x'");
        assert_eq!(oserr(&e, Path::new("it's")), "[Errno 2] No such file or directory: \"it's\"");
        // GLib's words, recorded on the tablet (11-03) for these two
        let e = Command::new("nonexistent-x").spawn().unwrap_err();
        assert_eq!(spawn_error(&e, "nonexistent-x"), "g-exec-error-quark: Failed to execute child process “nonexistent-x” (No such file or directory) (8)");
        let e = Command::new("/etc").spawn().unwrap_err();
        assert_eq!(spawn_error(&e, "/etc"), "g-exec-error-quark: Failed to execute child process “/etc” (Permission denied) (3)");
    }

    #[test]
    fn config_file() {
        let d = tmp("conf");
        let conf = d.join("sub/y700-refresh-auto.json");
        save_cfg(&conf, &Cfg::default()).unwrap();
        assert_eq!(read_text(&conf).unwrap(), Cfg::default().to_json());
        assert!(!d.join("sub/y700-refresh-auto.json.tmp").exists());
        // a directory where the file goes: the rename's text names both paths
        let blocked = d.join("blocked.json");
        fs::create_dir_all(blocked.join("x")).unwrap();
        let e = save_cfg(&blocked, &Cfg::default()).unwrap_err();
        let (a, b) = (d.join("blocked.json.tmp"), d.join("blocked.json"));
        assert_eq!(e, format!("[Errno 21] Is a directory: '{}' -> '{}'", a.display(), b.display()));
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn devices() {
        // the tablet's /proc/bus/input/devices, shortened
        let text = "I: Bus=0000 Vendor=0000 Product=0000 Version=0000\nN: Name=\"pmic_pwrkey\"\nP: Phys=pmic_pwrkey/input0\n\
            H: Handlers=kbd event0 \nB: EV=3\n\nN: Name=\"NVTCapacitiveTouchScreen\"\nH: Handlers=mouse0 event3\n\n\
            N: Name=\"gpio-keys\"\r\nH: Handlers=kbd event1 event9\n\nN: Name=\"\"\nH: Handlers=event7\n";
        let d = parse_devices(text);
        assert_eq!(d.get("pmic_pwrkey").map(String::as_str), Some("/dev/input/event0"));
        assert_eq!(d.get("NVTCapacitiveTouchScreen").map(String::as_str), Some("/dev/input/event3"));
        assert_eq!(d.get("gpio-keys").map(String::as_str), Some("/dev/input/event9")); // the last one wins
        assert_eq!(d.len(), 3); // no name, no entry
    }

    fn ev(typ: u16, code: u16, value: i32) -> Vec<u8> {
        let mut e = vec![0u8; 16];
        e.extend(typ.to_ne_bytes());
        e.extend(code.to_ne_bytes());
        e.extend(value.to_ne_bytes());
        e
    }

    #[test]
    fn power_key_events() {
        let down = ev(EV_KEY, KEY_POWER, 1);
        assert!(presses(&[ev(0, 0, 0), down.clone(), ev(0, 0, 0)].concat()));
        assert!(!presses(&[ev(EV_KEY, KEY_POWER, 0), ev(EV_KEY, KEY_POWER, 2), ev(EV_KEY, 115, 1), ev(4, KEY_POWER, 1)].concat()));
        assert!(!presses(&down[..20])); // not a whole event
        // read until empty, from a pipe standing in for the device
        let mut p = [0; 2];
        assert_eq!(unsafe { libc::pipe2(p.as_mut_ptr(), libc::O_NONBLOCK) }, 0);
        let (r, mut w) = unsafe { (File::from_raw_fd(p[0]), File::from_raw_fd(p[1])) };
        w.write_all(&[ev(0, 0, 0), down].concat().repeat(100)).unwrap();
        assert!(drain(&r).unwrap());
        assert!(!drain(&r).unwrap());
    }

    #[test]
    fn screen_nodes() {
        let d = tmp("dpms");
        let (off, on) = (d.join("off"), d.join("on"));
        fs::write(&off, "Off\n").unwrap();
        fs::write(&on, "On\n").unwrap();
        let none = d.join("missing");
        assert!(sysfs_on(&[]));
        assert!(sysfs_on(&[none.clone()]));
        assert!(!sysfs_on(&[none.clone(), off.clone(), on.clone()])); // the first readable one decides
        assert!(sysfs_on(&[on, off]));
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn state_file_unlink() {
        let d = tmp("unlink");
        let f = d.join("mpv");
        fs::write(&f, "pid=4242\nplaying=1\n").unwrap();
        unlink_if(&f, 424);
        unlink_if(&f, 42420);
        assert!(f.exists());
        unlink_if(&f, 4242);
        assert!(!f.exists());
        unlink_if(&f, 4242); // gone already: nothing
        fs::remove_dir_all(&d).unwrap();
    }

    fn raw(wd: i32, mask: u32, cookie: u32, name: &str) -> Vec<u8> {
        let mut n = name.as_bytes().to_vec();
        n.resize((name.len() / 16 + 1) * 16, 0); // the kernel pads names with NULs
        let mut b = Vec::new();
        for v in [wd as u32, mask, cookie, n.len() as u32] {
            b.extend(v.to_ne_bytes());
        }
        b.extend(n);
        b
    }

    #[test]
    fn statedir_events() {
        use libc::{IN_CLOSE_WRITE, IN_CREATE, IN_DELETE, IN_IGNORED, IN_MOVED_FROM, IN_MOVED_TO};
        let buf = [
            raw(1, IN_CREATE, 0, "wiliwili"),
            raw(1, IN_CLOSE_WRITE, 0, "wiliwili"),
            raw(1, IN_MOVED_FROM, 7, "mpv.tmp"), // the writers' rename: the new name only
            raw(1, IN_MOVED_TO, 7, "mpv"),
            raw(2, IN_CLOSE_WRITE, 0, KWINCONF_NAME), // another watch
            raw(1, IN_MOVED_FROM, 8, "chrome"),       // moved out
            raw(1, IN_MOVED_TO, 9, "other"),          // moved in
            raw(1, IN_DELETE, 0, "wiliwili"),
            raw(1, IN_IGNORED, 0, ""),
        ]
        .concat();
        let evs = inotify_events(&buf);
        assert_eq!(evs.len(), 9);
        assert_eq!(evs[4], Ev { wd: 2, mask: IN_CLOSE_WRITE, cookie: 0, name: KWINCONF_NAME.into() });
        let got = dir_changes(&evs, 1);
        let want = [("wiliwili", false), ("wiliwili", false), ("mpv", false), ("chrome", true), ("other", false), ("wiliwili", true)];
        assert_eq!(got, want.map(|(n, g)| (n.to_string(), g)));
        assert_eq!(inotify_events(&buf[..buf.len() - 8]).len(), 8); // a cut event is not read
    }

    /// The statedir watch as the kernel reports it: a writer's tmp + rename, a delete, the directory removed.
    #[test]
    fn statedir_watch() {
        let d = tmp("watch");
        let ino = inotify().unwrap();
        let wd = add_watch(&ino, &d, STATE_MASK).unwrap();
        fs::write(d.join("mpv.tmp"), "pid=1\n").unwrap();
        fs::rename(d.join("mpv.tmp"), d.join("mpv")).unwrap();
        fs::remove_file(d.join("mpv")).unwrap();
        let got = dir_changes(&inotify_events(&read_all(ino.as_raw_fd())), wd);
        // the rename counts for the new name only. mpv.tmp's create and close-write come too, but the close can come
        // late (after the delete, or not yet) when a parallel test forks while the file is open: not compared
        assert!(!got.contains(&("mpv.tmp".into(), true)), "{got:?}");
        let at = |c: (&str, bool)| got.iter().position(|g| (g.0.as_str(), g.1) == c);
        assert!(at(("mpv", false)).unwrap() < at(("mpv", true)).unwrap(), "{got:?}");
        fs::remove_dir(&d).unwrap();
        // IN_IGNORED comes with the directory's last reference: a parallel test's child that inherited mpv.tmp's fd
        // holds it (through mpv's dentry) until it execs
        let ignored = |evs: &[Ev]| evs.iter().any(|e| e.wd == wd && e.mask & libc::IN_IGNORED != 0);
        let mut evs = Vec::new();
        for _ in 0..50 {
            evs.extend(inotify_events(&read_all(ino.as_raw_fd())));
            if ignored(&evs) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert!(ignored(&evs), "{evs:?}");
        assert_eq!(add_watch(&ino, &d, STATE_MASK).unwrap_err().to_string(), format!("[Errno 2] No such file or directory: '{}'", d.display()));
    }

    /// On the tablet, as the session user, next to the running daemon - read only: no name requested, no mode set, no
    /// activeWindow report, no inhibitor taken. Every D-Bus probe goes to the running daemon and to this crate's object
    /// (served from a thread on a connection that has only its unique name) and the answers must match byte for byte.
    ///   runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    ///     WAYLAND_DISPLAY=wayland-0 target/release/deps/y700_refresh_auto-* --ignored --nocapture live
    #[test]
    #[ignore]
    fn live() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;
        use std::time::Duration;
        let mut ses = Bus::session().unwrap();
        let real = ses.name_owner(NAME).unwrap().expect("the running daemon owns the name");
        let mut srv = Bus::session().unwrap();
        let ours = srv.name.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let st = stop.clone();
        let server = std::thread::spawn(move || {
            while !st.load(Ordering::Relaxed) {
                if dbus::wait_readable(srv.fd(), Duration::from_millis(50)).unwrap() {
                    srv.fill().unwrap();
                }
                while let Some(m) = srv.pending.pop_front() {
                    if m.kind != METHOD_CALL {
                        continue;
                    }
                    match obj::route(&m, true) {
                        Route::Reply(sig, body) => srv.reply(&m, sig, &body).unwrap(),
                        Route::Error(name, text) => srv.error(&m, name, &text).unwrap(),
                        Route::ActiveWindow(..) => srv.reply(&m, "", &[]).unwrap(),
                        Route::Status => srv.reply(&m, "s", &string_body("{}")).unwrap(),
                    }
                }
            }
        });
        const I: &str = "org.freedesktop.DBus.Introspectable";
        const P: &str = "org.freedesktop.DBus.Properties";
        const PEER: &str = "org.freedesktop.DBus.Peer";
        use obj::{IFACE, PATH};
        use Arg::Str;
        let probes: [(&str, &str, &str, &[Arg]); 20] = [
            ("/", I, "Introspect", &[]),
            (PATH, I, "Introspect", &[]),
            ("/Nope", I, "Introspect", &[]),
            ("/RefreshAuto/x", I, "Introspect", &[]),
            (PATH, I, "Introspect", &[Str("x")]),
            (PATH, PEER, "Ping", &[]),
            ("/", PEER, "Ping", &[]),
            ("/Nope", PEER, "GetMachineId", &[]),
            (PATH, P, "GetAll", &[Str(IFACE)]),
            (PATH, P, "GetAll", &[Str("a.b")]),
            ("/", P, "GetAll", &[Str(IFACE)]),
            (PATH, P, "Get", &[Str(IFACE), Str("x")]),
            (PATH, P, "Get", &[Str("a.b"), Str("x")]),
            (PATH, P, "Get", &[Str(IFACE)]),
            (PATH, IFACE, "nope", &[]),
            (PATH, "a.b", "status", &[]),
            ("/Nope", IFACE, "status", &[]),
            (PATH, IFACE, "status", &[Str("x")]),
            (PATH, "", "status", &[]),
            (PATH, IFACE, "activeWindow", &[Str("x")]), // refused for its signature before any handler runs
        ];
        // (exact, readable)
        let show = |r: io::Result<Msg>| match r {
            Ok(m) => (format!("({}) {:?}", m.signature, m.body), format!("({}) {}", m.signature, String::from_utf8_lossy(&m.body))),
            Err(e) => (e.to_string(), e.to_string()),
        };
        for (path, iface, member, args) in probes {
            let a = show(ses.call_t(3000, &real, path, iface, member, args));
            let b = show(ses.call_t(3000, &ours, path, iface, member, args));
            println!("{path} {iface}.{member}{args:?}: {}", a.1.chars().take(110).collect::<String>().replace('\n', " "));
            assert_eq!(a.0, b.0, "{path} {iface}.{member}: real {} / ours {}", a.1, b.1);
        }
        stop.store(true, Ordering::Relaxed);
        server.join().unwrap();
        // the real status: the keys, in order, and its mode against kwinoutputconfig.json's
        let st = ses.call_t(3000, &real, PATH, IFACE, "status", &[]).unwrap();
        let text = dbus::R::new(&st.body).string().unwrap();
        println!("status {text}");
        let json::J::Obj(kv) = json::parse(&text).unwrap() else { panic!("{text}") };
        let keys: Vec<&str> = kv.iter().map(|k| k.0.as_str()).collect();
        assert_eq!(keys, ["base_hz", "cur_hz", "expected_hz", "video_target", "active", "players", "manual", "locked", "touch_age_s",
            "touch_attached", "shielded_touches", "backoff", "fg_log_errors"]);
        let home = std::env::var("HOME").unwrap();
        let kwin = kwin_hz(&Path::new(&home).join(".config").join(KWINCONF_NAME));
        println!("kwinoutputconfig.json: {kwin:?} Hz");
        assert_eq!(kwin.map(json::J::Int), kv.iter().find(|k| k.0 == "cur_hz").map(|k| k.1.clone()));
        // the screen: KWin's DPMS state and the node agree
        let wl = Wl::open().unwrap();
        let nodes = dpms_paths();
        println!("outputs {:?}, KWin on {}, {nodes:?} on {}", wl.outputs(), wl.screen_on(), sysfs_on(&nodes));
        assert!(wl.outputs().iter().any(|o| o.0.as_deref().is_some_and(|n| n.starts_with("DSI"))));
        assert_eq!(wl.screen_on(), sysfs_on(&nodes));
        // the KWin script reports to this interface; KWin has it loaded
        let script = Path::new(&home).join(".local/share/kwin/scripts/y700-refresh-auto/contents/code/main.js");
        assert!(read_text(&script).unwrap().contains(r#"callDBus("fyi.y700.RefreshAuto", "/RefreshAuto", "fyi.y700.RefreshAuto", "activeWindow""#));
        let loaded = ses.call_t(2000, "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "isScriptLoaded", &[Str(KWIN_NAME)]).unwrap();
        assert_eq!(first_u32(&loaded, 'b'), Some(1));
        let locked = ses.call_t(1000, SCREENSAVER, "/ScreenSaver", SCREENSAVER, "GetActive", &[]).map(|m| first_u32(&m, 'b'));
        println!("screen saver active: {locked:?}");
        // the inputs: names as the daemon looks for them, the power key readable
        let devs = parse_devices(&fs::read_to_string("/proc/bus/input/devices").unwrap());
        let touch: Vec<_> = TOUCHISH.iter().filter_map(|n| devs.get(*n)).collect();
        println!("power key {:?}, touchish {touch:?}", devs.get(POWER_KEY));
        assert_eq!(touch.len(), 4);
        assert!(drain(&open_input(&devs[POWER_KEY]).unwrap()).is_ok());
        // our match rules parse; logind is there to inhibit sleep
        ses.add_match(LOCK_MATCH).unwrap();
        let mut sys = Bus::system().unwrap();
        sys.add_match(SLEEP_MATCH).unwrap();
        sys.add_match(LOGIN1_MATCH).unwrap();
        assert!(sys.name_owner(LOGIN1).unwrap().is_some());
    }
}
