//! y700-kwin-uclamp (2026-10-20, ROOT): keep a utilization floor (uclamp.min, default 512) on every thread of the
//! user's kwin_wayland, so schedutil raises the CPU clock while KWin composites instead of starting it at 768 MHz.
//!
//! Why: at 120 fps on the 120 Hz panel a Moonlight frame has no slack; with the CPU idling low, Moonlight's threads and
//! KWin wake up too slowly for some frames and the panel shows the previous frame again (runs/streaming/c120-*, README
//! "120 fps 掉帧还没调完美"). Moonlight gets its own floor from linux/streaming/y700-moonlight (no privilege needed).
//! KWin's cannot be set by the user: kwin_wayland carries the file capability cap_sys_nice, and the kernel
//! (cap_safe_nice) refuses to change the scheduling of a task with more capabilities than the caller. Measured: with
//! KWin floored too, 0.21-0.90 % repeated frames over 6 runs (mean 0.54 %) against 0.73-2.66 % (mean 1.37 %) without.
//! The owner chose a permanent floor (local games benefit too) over a sudo hook that only holds it while streaming.
//! uclamp.min does not pin the clock: it only counts while KWin's threads run (schedutil ~1.25 x max x min / 1024).
//!
//! How: find kwin_wayland of USER_UID in /proc (exact comm, not kwin_wayland_wrapper, and not a headless test KWin:
//! 10-21 a leftover `kwin_wayland --virtual` of the task-switcher test bed had the lower pid, so the floor went to it
//! and the session KWin had none until it exited), sched_setattr every thread in
//! /proc/<pid>/task with SCHED_FLAG_KEEP_ALL | SCHED_FLAG_UTIL_CLAMP_MIN (policy, priority and uclamp.max untouched).
//! New threads do NOT keep the floor: KWin's main thread (and DSI-1, libinput-connec) runs SCHED_RR|SCHED_RESET_ON_FORK,
//! so every thread it creates starts at uclamp.min 0. Seen 10-20: 22 h after login KWin had grown a new GPU submit
//! thread (kwin_way:ir3q3), kwin_wa:disk$1 and Qt "Thread (pooled)" workers, all at 0, because the first version only
//! re-applied 10 s and 60 s after KWin started and then slept on the pidfd. Now, besides those two passes, it rescans
//! from the start every RESCAN_SEC (default 5 s, 0 = never) and floors only the threads that are below MIN; 0.2 wakeups/s against
//! the ~20/s the screen-off check expects. What it floored is logged at most once per 10 minutes (pool threads churn).
//! It still waits on a pidfd, so KWin's exit is seen at once. Without a KWin (before login, after a crash) it looks
//! every 3 s. `--release` (ExecStopPost) sets the user's KWin back to 0; `--status` prints each thread's uclamp.min.
//! A second thread does the touch boost (GPU clock up while an edge gesture runs, BOOST_* keys): see touchboost.rs.
//! Config /etc/default/y700-kwin-uclamp: UCLAMP_MIN= (0..1024), USER_UID=, RESCAN_SEC= (0..3600). Y700_PROC
//! overrides /proc for the tests.
use std::fs;
use std::os::raw::{c_int, c_long, c_ulong};
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::{Duration, Instant};

mod touchboost;

extern "C" {
    fn syscall(n: c_long, ...) -> c_long;
    fn poll(fds: *mut PollFd, nfds: c_ulong, timeout: c_int) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn __errno_location() -> *mut c_int;
}
#[repr(C)]
struct PollFd {
    fd: c_int,
    events: i16,
    revents: i16,
}
const POLLIN: i16 = 1;
const EINTR: c_int = 4;
// aarch64 (asm-generic) syscall numbers
const SYS_SCHED_SETATTR: c_long = 274;
const SYS_SCHED_GETATTR: c_long = 275;
const SYS_PIDFD_OPEN: c_long = 434;
const SCHED_FLAG_KEEP_ALL: u64 = 0x08 | 0x10;
const SCHED_FLAG_UTIL_CLAMP_MIN: u64 = 0x20;
const CONF: &str = "/etc/default/y700-kwin-uclamp";
const KWIN: &str = "kwin_wayland";

/// struct sched_attr, SCHED_ATTR_SIZE_VER1 (56 bytes, with the uclamp fields)
#[repr(C)]
#[derive(Default)]
struct SchedAttr {
    size: u32,
    sched_policy: u32,
    sched_flags: u64,
    sched_nice: i32,
    sched_priority: u32,
    sched_runtime: u64,
    sched_deadline: u64,
    sched_period: u64,
    sched_util_min: u32,
    sched_util_max: u32,
}

#[derive(Debug, PartialEq)]
struct Cfg {
    min: u32,
    uid: u32,
    rescan: u32,
}

fn parse_cfg(text: &str) -> Cfg {
    let mut c = Cfg { min: 512, uid: 1000, rescan: 5 };
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else { continue };
        let v = v.trim().trim_matches('"');
        match (k.trim(), v.parse::<u32>()) {
            ("UCLAMP_MIN", Ok(n)) if n <= 1024 => c.min = n,
            ("USER_UID", Ok(n)) => c.uid = n,
            ("RESCAN_SEC", Ok(n)) if n <= 3600 => c.rescan = n,
            (k @ ("UCLAMP_MIN" | "USER_UID" | "RESCAN_SEC"), _) => eprintln!("{CONF}: bad {k}={v:?}, keeping the default"),
            _ => {}
        }
    }
    c
}

fn proc_root() -> PathBuf {
    PathBuf::from(std::env::var("Y700_PROC").unwrap_or_else(|_| "/proc".into()))
}

/// the real uid of /proc/<pid>/status
fn proc_uid(dir: &Path) -> Option<u32> {
    let s = fs::read_to_string(dir.join("status")).ok()?;
    let line = s.lines().find(|l| l.starts_with("Uid:"))?;
    line.split_whitespace().nth(1)?.parse().ok()
}

/// a headless test KWin (`kwin_wayland --virtual`, as linux/gesture/tests/ts-bed.sh and taskswitcher/smoke.sh start
/// as the same user): not the session's compositor. Unreadable cmdline = not a test one.
fn is_virtual(dir: &Path) -> bool {
    fs::read(dir.join("cmdline")).map(|c| c.split(|&b| b == 0).any(|a| a == b"--virtual")).unwrap_or(false)
}

/// pid of the user's session kwin_wayland (exact comm, not `--virtual`; the lowest pid if there were several)
fn find_kwin(root: &Path, uid: u32) -> Option<u32> {
    let mut found: Option<u32> = None;
    for e in fs::read_dir(root).ok()?.flatten() {
        let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<u32>().ok()) else { continue };
        let dir = e.path();
        if fs::read_to_string(dir.join("comm")).map(|c| c.trim_end() == KWIN).unwrap_or(false)
            && proc_uid(&dir) == Some(uid)
            && !is_virtual(&dir)
        {
            found = Some(found.map_or(pid, |f| f.min(pid)));
        }
    }
    found
}

fn tids(root: &Path, pid: u32) -> Vec<u32> {
    let mut v: Vec<u32> = fs::read_dir(root.join(pid.to_string()).join("task"))
        .map(|d| d.flatten().filter_map(|e| e.file_name().to_str()?.parse().ok()).collect())
        .unwrap_or_default();
    v.sort_unstable();
    v
}

fn errno() -> c_int {
    unsafe { *__errno_location() }
}

fn set_min(tid: u32, min: u32) -> Result<(), c_int> {
    let a = SchedAttr {
        size: std::mem::size_of::<SchedAttr>() as u32,
        sched_flags: SCHED_FLAG_KEEP_ALL | SCHED_FLAG_UTIL_CLAMP_MIN,
        sched_util_min: min,
        ..Default::default()
    };
    let r = unsafe { syscall(SYS_SCHED_SETATTR, tid as c_long, &a as *const SchedAttr, 0 as c_ulong) };
    if r == 0 { Ok(()) } else { Err(errno()) }
}

fn get_min(tid: u32) -> Option<u32> {
    let mut a = SchedAttr::default();
    let size = std::mem::size_of::<SchedAttr>() as u32;
    let r = unsafe { syscall(SYS_SCHED_GETATTR, tid as c_long, &mut a as *mut SchedAttr, size as c_ulong, 0 as c_ulong) };
    (r == 0).then_some(a.sched_util_min)
}

/// one pass over the threads: (set, failed, first errno)
fn apply(root: &Path, pid: u32, min: u32) -> (usize, usize, c_int) {
    let (mut ok, mut bad, mut first) = (0, 0, 0);
    for t in tids(root, pid) {
        match set_min(t, min) {
            Ok(()) => ok += 1,
            Err(3) => {} // ESRCH: the thread ended meanwhile
            Err(e) => {
                bad += 1;
                if first == 0 {
                    first = e;
                }
            }
        }
    }
    (ok, bad, first)
}

/// floor only the threads below min: (floored, their comms)
fn top_up(root: &Path, pid: u32, min: u32) -> (usize, Vec<String>) {
    let (mut n, mut names) = (0, Vec::new());
    for t in tids(root, pid) {
        if get_min(t).map_or(false, |m| m < min) && set_min(t, min).is_ok() {
            n += 1;
            let c = fs::read_to_string(root.join(pid.to_string()).join("task").join(t.to_string()).join("comm"));
            let c = c.map(|c| c.trim_end().to_string()).unwrap_or_default();
            if !names.contains(&c) {
                names.push(c);
            }
        }
    }
    (n, names)
}

fn log_apply(pid: u32, min: u32, (ok, bad, e): (usize, usize, c_int), what: &str) {
    if bad > 0 {
        eprintln!("{KWIN} {pid}: uclamp.min {min} on {ok} threads, {bad} failed (errno {e}) [{what}]");
    } else {
        eprintln!("{KWIN} {pid}: uclamp.min {min} on {ok} threads [{what}]");
    }
}

/// block until pid exits or timeout_ms passes (-1 = no timeout). true = it exited (or cannot be watched)
fn wait_exit(pidfd: c_int, timeout_ms: c_int) -> bool {
    let mut p = PollFd { fd: pidfd, events: POLLIN, revents: 0 };
    loop {
        let r = unsafe { poll(&mut p, 1, timeout_ms) };
        if r > 0 {
            return true;
        }
        if r == 0 {
            return false;
        }
        if errno() != EINTR {
            return true;
        }
    }
}

fn run(cfg: &Cfg) -> ! {
    let root = proc_root();
    eprintln!("y700-kwin-uclamp: uclamp.min {} for uid {}'s {KWIN}", cfg.min, cfg.uid);
    let mut missing_said = false;
    loop {
        let Some(pid) = find_kwin(&root, cfg.uid) else {
            if !missing_said {
                eprintln!("no {KWIN} for uid {} yet, looking every 3 s", cfg.uid);
                missing_said = true;
            }
            sleep(Duration::from_secs(3));
            continue;
        };
        missing_said = false;
        // pidfd first, then the threads: an exit between the two shows up on the pidfd
        let pidfd = unsafe { syscall(SYS_PIDFD_OPEN, pid as c_long, 0 as c_ulong) } as c_int;
        log_apply(pid, cfg.min, apply(&root, pid, cfg.min), "found");
        if pidfd < 0 {
            // no pidfd (should not happen on this kernel): fall back to looking every 10 s
            eprintln!("pidfd_open({pid}) failed (errno {}), polling instead", errno());
            while root.join(pid.to_string()).exists() {
                sleep(Duration::from_secs(10));
            }
            continue;
        }
        // full passes 10 s and 60 s after finding it, top-ups every RESCAN_SEC from the start (10-21: with the top-ups
        // only after the 60 s pass, a KWin that had just started grew 3 threads at 0 and the checklist warned)
        let start = Instant::now();
        let mut passes = [(10u64, "10 s later"), (60, "60 s later")].into_iter().peekable();
        let (mut n, mut names, mut since) = (0usize, Vec::<String>::new(), Instant::now());
        loop {
            let to_pass = passes.peek().map(|&(s, _)| Duration::from_secs(s).saturating_sub(start.elapsed()).as_millis() as c_int);
            let tick = (cfg.rescan > 0).then_some((cfg.rescan * 1000) as c_int);
            let ms = match (to_pass, tick) {
                (Some(p), Some(t)) => p.min(t),
                (Some(p), None) => p,
                (None, Some(t)) => t,
                (None, None) => -1,
            };
            if wait_exit(pidfd, ms) {
                break;
            }
            if let Some(&(s, what)) = passes.peek() {
                if start.elapsed() >= Duration::from_secs(s) {
                    log_apply(pid, cfg.min, apply(&root, pid, cfg.min), what);
                    passes.next();
                    continue;
                }
            }
            let (k, ks) = top_up(&root, pid, cfg.min);
            n += k;
            for c in ks {
                if !names.contains(&c) {
                    names.push(c);
                }
            }
            if n > 0 && since.elapsed() >= Duration::from_secs(600) {
                eprintln!("{KWIN} {pid}: floored {n} new threads ({})", names.join(", "));
                (n, since) = (0, Instant::now());
                names.clear();
            }
        }
        if n > 0 {
            eprintln!("{KWIN} {pid}: floored {n} new threads ({})", names.join(", "));
        }
        unsafe { close(pidfd) };
        eprintln!("{KWIN} {pid} exited");
    }
}

fn main() {
    let text = fs::read_to_string(std::env::var("Y700_CONF").unwrap_or_else(|_| CONF.into())).unwrap_or_default();
    let cfg = parse_cfg(&text);
    let boost = touchboost::parse_boost(&text);
    let root = proc_root();
    match std::env::args().nth(1).as_deref() {
        None => {
            if boost.mhz > 0 {
                std::thread::spawn(move || touchboost::run(boost));
            } else {
                touchboost::release(&touchboost::parse_boost(""));
            }
            run(&cfg)
        }
        Some("--release") => {
            touchboost::release(&if boost.mhz > 0 { boost } else { touchboost::parse_boost("") });
            match find_kwin(&root, cfg.uid) {
                Some(pid) => log_apply(pid, 0, apply(&root, pid, 0), "release"),
                None => eprintln!("no {KWIN} for uid {}: nothing to release", cfg.uid),
            }
        }
        Some("--status") => match find_kwin(&root, cfg.uid) {
            Some(pid) => {
                let mins: Vec<String> = tids(&root, pid)
                    .into_iter()
                    .map(|t| get_min(t).map_or("?".into(), |m| m.to_string()))
                    .collect();
                let low = mins.iter().filter(|m| m.parse::<u32>().map_or(true, |m| m < cfg.min)).count();
                println!("{KWIN} {pid}: {} threads, {low} below {}: uclamp.min {}", mins.len(), cfg.min, mins.join(" "));
                std::process::exit(if low == 0 { 0 } else { 3 });
            }
            None => {
                println!("no {KWIN} for uid {}", cfg.uid);
                std::process::exit(4);
            }
        },
        Some(a) => {
            eprintln!("usage: y700-kwin-uclamp [--release|--status]  (unknown {a:?})");
            std::process::exit(2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cfg_defaults_and_overrides() {
        assert_eq!(parse_cfg(""), Cfg { min: 512, uid: 1000, rescan: 5 });
        assert_eq!(parse_cfg("# x\nUCLAMP_MIN=384\nUSER_UID=\"1001\"\nRESCAN_SEC=0\n"), Cfg { min: 384, uid: 1001, rescan: 0 });
        assert_eq!(parse_cfg("UCLAMP_MIN=2000\nUSER_UID=x\nRESCAN_SEC=9999"), Cfg { min: 512, uid: 1000, rescan: 5 });
    }

    fn fake(root: &Path, pid: u32, comm: &str, uid: u32, tasks: &[u32]) {
        fake_cmd(root, pid, comm, uid, tasks, &[comm]);
    }

    fn fake_cmd(root: &Path, pid: u32, comm: &str, uid: u32, tasks: &[u32], args: &[&str]) {
        let d = root.join(pid.to_string());
        fs::create_dir_all(d.join("task")).unwrap();
        fs::write(d.join("comm"), format!("{comm}\n")).unwrap();
        fs::write(d.join("cmdline"), args.iter().map(|a| format!("{a}\0")).collect::<String>()).unwrap();
        fs::write(d.join("status"), format!("Name:\t{comm}\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n")).unwrap();
        for t in tasks {
            fs::create_dir_all(d.join("task").join(t.to_string())).unwrap();
        }
    }

    #[test]
    fn finds_the_users_kwin_only() {
        let root = std::env::temp_dir().join(format!("y700-kwin-uclamp-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fake(&root, 50, "kwin_wayland_wr", 1000, &[50]);
        fake(&root, 60, "kwin_wayland", 0, &[60]);
        // the test bed's KWin, a lower pid than the session's (10-21)
        fake_cmd(&root, 65, "kwin_wayland", 1000, &[65], &["kwin_wayland", "--virtual", "--socket", "y700-tsbed-1"]);
        fake(&root, 70, "kwin_wayland", 1000, &[72, 70, 71]);
        fs::create_dir_all(root.join("self")).unwrap();
        assert_eq!(find_kwin(&root, 1000), Some(70));
        assert_eq!(find_kwin(&root, 1001), None);
        assert_eq!(tids(&root, 70), vec![70, 71, 72]);
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn sets_and_reads_back_on_itself() {
        // lowering one's own uclamp.min to 0 needs no privilege
        let me = std::process::id();
        let root = PathBuf::from("/proc");
        let (ok, bad, _) = apply(&root, me, 0);
        assert!(ok >= 1 && bad == 0);
        assert_eq!(get_min(me), Some(0));
        // nothing is below 0, so a top-up to 0 touches nothing
        assert_eq!(top_up(&root, me, 0).0, 0);
    }
}
