//! The sinks, the pstore archive, MARK lines, the cadence and the daemon loop (see main.rs for the overview).
use super::*;
use std::os::unix::io::AsRawFd;

pub struct Paths {
    pub log_dir: String,
    pub run_dir: String,
    pub pmsg: bool,
}

fn boot8() -> String {
    rd("/proc/sys/kernel/random/boot_id")
        .map(|b| b.chars().take(8).collect::<String>())
        .filter(|b| !b.is_empty())
        .unwrap_or_else(|| "noboot".into())
}

struct Sinks {
    pmsg: Option<File>,
    live: Option<File>,
    ufs: Option<File>,
    live_path: String,
    n: u64,
    boot: String,
}

impl Sinks {
    fn new(p: &Paths) -> Self {
        let boot = boot8();
        let _ = fs::create_dir_all(&p.run_dir);
        let _ = fs::create_dir_all(&p.log_dir);
        let pmsg = if p.pmsg {
            OpenOptions::new().write(true).open(PMSG).map_err(|e| eprintln!("pmsg: {e} (continuing without)")).ok()
        } else {
            None
        };
        let ufs_path = format!("{}/flightrec-{boot}.log", p.log_dir);
        let ufs = OpenOptions::new().append(true).create(true).mode(0o600).open(&ufs_path).ok();
        let live_path = format!("{}/live.log", p.run_dir);
        let live = OpenOptions::new().append(true).create(true).mode(0o644).open(&live_path).ok();
        let link = format!("{}/current.log", p.log_dir);
        let _ = fs::remove_file(&link);
        let _ = std::os::unix::fs::symlink(format!("flightrec-{boot}.log"), &link);
        Sinks { pmsg, live, ufs, live_path, n: 0, boot }
    }

    fn write(&mut self, line: &str, sync_every: u64, sync: bool) {
        let b = format!("{line}\n");
        for f in [&mut self.pmsg, &mut self.live, &mut self.ufs].into_iter().flatten() {
            let _ = f.write_all(b.as_bytes());
        }
        self.n += 1;
        if sync || self.n % sync_every.max(1) == 0 {
            if let Some(f) = &self.ufs {
                let _ = f.sync_data();
            }
        }
        if self.n % 60 == 0 {
            self.trim_live();
        }
    }

    fn trim_live(&self) {
        let Ok(m) = fs::metadata(&self.live_path) else { return };
        if m.len() <= LIVE_MAX {
            return;
        }
        let Ok(mut f) = File::open(&self.live_path) else { return };
        if f.seek(SeekFrom::End(-((LIVE_MAX / 4) as i64))).is_err() {
            return;
        }
        let mut tail = vec![];
        if f.read_to_end(&mut tail).is_err() {
            return;
        }
        let start = tail.iter().position(|&b| b == b'\n').map_or(0, |i| i + 1);
        let _ = fs::write(&self.live_path, &tail[start..]); // the daemon's O_APPEND fd keeps appending at the new end
    }
}

/// copy what systemd-pstore archived (and anything still in /sys/fs/pstore) to <log_dir>/pstore/<boot>/
fn archive_pstore(p: &Paths, boot: &str) -> usize {
    let dst = format!("{}/pstore/{boot}", p.log_dir);
    let mut copied = 0;
    for (src, prefix) in [("/var/lib/systemd/pstore", ""), ("/sys/fs/pstore", "sysfs-")] {
        for e in fs::read_dir(src).into_iter().flatten().flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || !e.path().is_file() {
                continue; // Python: glob("*") (no hidden files), os.path.isfile
            }
            let to = format!("{dst}/{prefix}{name}");
            if fs::create_dir_all(&dst).is_ok() && fs::copy(e.path(), &to).is_ok() {
                // shutil.copy2 kept the modification time: so do we
                if let (Ok(m), Ok(f)) = (fs::metadata(e.path()), OpenOptions::new().write(true).open(&to)) {
                    if let Ok(t) = m.modified() {
                        let _ = f.set_modified(t);
                    }
                }
                copied += 1;
            }
        }
    }
    copied
}

/// the boots in the order they started, oldest first: <log_dir>/boots.txt, this boot appended (once) at every start.
/// File times cannot order the logs: the RTC starts at 1970-01-14 here, so a fresh log - and the whole log of a boot
/// that died before NTP set the clock, the one worth most - carries a 1970 mtime. 2026-10-23: prune_logs sorted by
/// mtime, took this boot's new log for the oldest of 13 and deleted it; the recorder wrote on into the unlinked
/// file for the whole boot (y700-checklist: "flightrec-<boot>.log 不存在"), and would have on every boot after.
fn boot_order(p: &Paths, boot: &str) -> Vec<String> {
    let path = format!("{}/boots.txt", p.log_dir);
    let mut order: Vec<String> =
        fs::read_to_string(&path).unwrap_or_default().split_whitespace().map(str::to_string).collect();
    if order.last().map(String::as_str) == Some(boot) {
        return order; // restarted within this boot
    }
    order.push(boot.to_string());
    if order.len() > 4 * KEEP_LOGS {
        // keep the newest 2 * KEEP_LOGS (a log of a boot dropped here would count as older than all known ones)
        order.drain(..order.len() - 2 * KEEP_LOGS);
        let tmp = format!("{path}.tmp");
        let done = File::create(&tmp).and_then(|mut f| {
            f.write_all(format!("{}\n", order.join("\n")).as_bytes())?;
            f.sync_all()
        });
        if done.and_then(|_| fs::rename(&tmp, &path)).is_err() {
            eprintln!("{path}: not rewritten");
        }
    } else {
        let done = OpenOptions::new().append(true).create(true).mode(0o644).open(&path).and_then(|mut f| {
            f.write_all(format!("{boot}\n").as_bytes())?;
            f.sync_data()
        });
        if let Err(e) = done {
            eprintln!("{path}: {e}");
        }
    }
    order
}

/// keep this boot's log and the newest KEEP_LOGS - 1 others, newest by boot_order(); a log it does not know (from
/// before boots.txt existed) counts as older than every one it knows, by mtime among themselves. pstore/<boot>
/// (archive_pstore) goes by the same list: every start copies all of systemd-pstore's flat archive again (~240 KB a
/// boot, more with every dmesg-ramoops-N it never deletes) and nothing removed the copies (10-31 audit A2); a
/// directory there whose boot has no log left - the ones from before this - goes too
fn prune_logs(p: &Paths, boot: &str, order: &[String]) {
    let mut logs: Vec<((bool, i64), PathBuf, String)> = fs::read_dir(&p.log_dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let n = e.file_name().to_string_lossy().into_owned();
            let b = n.strip_prefix("flightrec-")?.strip_suffix(".log")?.to_string();
            if b == boot {
                return None;
            }
            let key = match order.iter().rposition(|o| *o == b) {
                Some(i) => (true, i as i64),
                None => (false, fs::metadata(e.path()).ok()?.mtime()),
            };
            Some((key, e.path(), b))
        })
        .collect();
    logs.sort();
    let gone = logs.len().saturating_sub(KEEP_LOGS - 1);
    for (_, f, _) in &logs[..gone] {
        let _ = fs::remove_file(f);
    }
    for e in fs::read_dir(format!("{}/pstore", p.log_dir)).into_iter().flatten().flatten() {
        let n = e.file_name().to_string_lossy().into_owned();
        let kept = n == boot || logs[gone..].iter().any(|(_, _, b)| *b == n);
        if !kept && e.file_type().map_or(false, |t| t.is_dir()) {
            let _ = fs::remove_dir_all(e.path()); // does not follow symlinks; file_type() is the entry's own
        }
    }
}

/// the experiment flag: <run_dir>/fast holds the CLOCK_MONOTONIC second it expires at (not the wall clock: an NTP
/// step - the RTC starts at 1970 here - would end or stretch it; /run is per boot and the tablet never suspends)
fn fast_flag(p: &Paths) -> bool {
    rd(&format!("{}/fast", p.run_dir)).and_then(|s| s.parse::<f64>().ok()).map_or(false, |exp| exp > mono())
}

fn knobs_on(f: &mut Files) -> Option<&'static str> {
    for (k, path) in [("aco", PARAMS[1].1), ("aso", PARAMS[2].1)] {
        if matches!(f.read(path).as_deref(), Some("Y") | Some("1")) {
            return Some(k);
        }
    }
    None
}

/// why the cadence is fast (an experiment is on), or None. Knobs set by y700-cx-auto (daily use: the tested E3a
/// level while the screen is off on battery, /run/y700-cx-auto.armed) are not an experiment: a 1 s cadence there
/// would eat a good part of what it saves.
fn experiment(r: &mut Recorder, p: &Paths) -> Option<String> {
    if fast_flag(p) {
        return Some("experiment-mark".to_string());
    }
    if Path::new("/run/y700-cx-auto.armed").exists() {
        return None;
    }
    knobs_on(&mut r.f).map(|k| format!("{k}=Y"))
}

/// MARK line to pmsg, live.log and this boot's UFS log (own invocation, never waits on the daemon); a
/// "<STEP> start [<N>min]" mark raises the experiment flag, "<STEP> end" drops it; the daemon is woken (SIGUSR1)
/// so its cadence follows at once
pub fn mark(p: &Paths, text: &str) -> i32 {
    let boot = boot8();
    let line = format!("MARK t={:.1} at={} {text}\n", mono(), strftime("%H:%M:%S"));
    let targets = [
        (PMSG.to_string(), false, p.pmsg),
        (format!("{}/live.log", p.run_dir), false, true),
        (format!("{}/flightrec-{boot}.log", p.log_dir), true, true),
    ];
    for (path, sync, enabled) in targets {
        if !enabled {
            continue;
        }
        if let Some(dir) = Path::new(&path).parent() {
            let _ = fs::create_dir_all(dir);
        }
        let r = if path == PMSG {
            OpenOptions::new().write(true).open(&path)
        } else {
            OpenOptions::new().append(true).create(true).mode(0o600).open(&path)
        };
        let done = r.and_then(|mut f| {
            f.write_all(line.as_bytes())?;
            if sync {
                f.sync_data()?;
            }
            Ok(())
        });
        if let Err(e) = done {
            eprintln!("{path}: {e}");
        }
    }
    print!("{line}");
    let w: Vec<&str> = text.split_whitespace().collect();
    let flag = format!("{}/fast", p.run_dir);
    match w.get(1).copied() {
        Some("start") => {
            let mins = w.get(2).and_then(|m| m.strip_suffix("min")).and_then(|m| m.parse::<f64>().ok());
            let until = mono() + mins.map_or(FAST_DEFAULT_S, |m| m * 60.0 + FAST_MARGIN_S);
            let _ = fs::create_dir_all(&p.run_dir);
            let _ = fs::write(&flag, format!("{until:.0}\n"));
        }
        Some("end") => {
            let _ = fs::remove_file(&flag);
        }
        _ => {}
    }
    // wake the daemon - only if that pid really is the recorder (a stale pid file after a kill -9 could name an
    // unrelated process, and SIGUSR1's default action is to terminate it)
    let pidf = format!("{}/daemon.pid", p.run_dir);
    match rd(&pidf).and_then(|s| s.parse::<i32>().ok()).filter(|&pid| pid > 1) {
        Some(pid) if rd(&format!("/proc/{pid}/comm")).map_or(false, |c| c.starts_with("y700-flightrec")) => {
            if unsafe { libc::kill(pid, libc::SIGUSR1) } != 0 {
                eprintln!("wake {pid}: {}", std::io::Error::last_os_error());
            }
        }
        _ => eprintln!("{pidf}: no running recorder to wake (the cadence follows at its next line)"),
    }
    0
}

/// this thread's CPU time, ns
fn cpu_ns() -> i64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts) };
    ts.tv_sec as i64 * 1_000_000_000 + ts.tv_nsec as i64
}

fn usage() -> i32 {
    eprintln!("usage: y700-flightrec [--interval S] [--sync N] [--idle-interval S] [--idle-sync N] [--iface IF]");
    eprintln!("       y700-flightrec --mark TEXT... | --once      (test: --log-dir D --run-dir D --no-pmsg)");
    1
}

fn mode_line(fast: &Option<String>, why_slow: &str) -> String {
    format!(
        "MODE {} t={:.1} at={} reason={}",
        if fast.is_some() { "fast" } else { "slow" },
        mono(),
        strftime("%H:%M:%S"),
        fast.as_deref().unwrap_or(why_slow)
    )
}

pub fn run() -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (mut interval, mut sync_every, mut idle_interval, mut idle_sync) = (1.0f64, 1u64, 10.0f64, 6u64);
    let mut iface = "wlp1s0".to_string();
    let mut p = Paths { log_dir: "/var/log/y700-flightrec".into(), run_dir: "/run/y700-flightrec".into(), pmsg: true };
    let mut once = false;
    let mut bench: Option<u64> = None;
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--bench" => {
                bench = args.get(i + 1).and_then(|v| v.parse().ok());
                if bench.is_none() {
                    return usage();
                }
                i += 1;
            }
            "--mark" => {
                let t = args[i + 1..].join(" ");
                return mark(&p, if t.is_empty() { "mark" } else { &t });
            }
            "--once" => once = true,
            "--no-pmsg" => p.pmsg = false,
            "--interval" | "--sync" | "--idle-interval" | "--idle-sync" | "--iface" | "--log-dir" | "--run-dir" => {
                let Some(v) = args.get(i + 1).cloned() else { return usage() };
                let ok = match a {
                    "--interval" => v.parse().map(|x| interval = x).is_ok() && interval > 0.0,
                    "--sync" => v.parse().map(|x| sync_every = x).is_ok(),
                    "--idle-interval" => v.parse().map(|x| idle_interval = x).is_ok() && idle_interval > 0.0,
                    "--idle-sync" => v.parse().map(|x| idle_sync = x).is_ok(),
                    "--iface" => {
                        iface = v;
                        true
                    }
                    "--log-dir" => {
                        p.log_dir = v;
                        true
                    }
                    _ => {
                        p.run_dir = v;
                        true
                    }
                };
                if !ok {
                    return usage();
                }
                i += 1;
            }
            _ => return usage(),
        }
        i += 1;
    }
    let mut r = Recorder::new();
    if let Some(n) = bench {
        // sample + fmt in a tight loop, no writes (compare with the same loop over the Python functions)
        let (mut pv, mut wp) = (r.sample(), r.wifi(&iface));
        let t0 = cpu_ns();
        for _ in 0..n {
            let (cv, wc) = (r.sample(), r.wifi(&iface));
            let _ = r.fmt(&pv, &cv, &wp, &wc);
            pv = cv;
            wp = wc;
        }
        println!("{n} samples, {:.3} ms CPU each", (cpu_ns() - t0) as f64 / n as f64 / 1e6);
        return 0;
    }
    if once {
        let (pv, wp) = (r.sample(), r.wifi(&iface));
        std::thread::sleep(std::time::Duration::from_secs(1));
        let (cv, wc) = (r.sample(), r.wifi(&iface));
        println!("{}", r.fmt(&pv, &cv, &wp, &wc));
        return 0;
    }

    // one daemon per run_dir (10-31 audit A1): a second one started by hand without --run-dir rewrote the energy
    // line under the service's, overwrote daemon.pid and, stopped with Ctrl-C, deleted it - y700-batteryd then took
    // the recorder for gone and kept the battery page degraded (cov:0) for the rest of the boot. Taken before
    // Sinks::new and archive_pstore touch anything; held until exit (the File lives to the end of run()).
    let _ = fs::create_dir_all(&p.run_dir);
    let lockf = format!("{}/lock", p.run_dir);
    let _lock = match OpenOptions::new().create(true).truncate(false).write(true).mode(0o600).open(&lockf) {
        Ok(f) if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 => f,
        Ok(_) => {
            let e = std::io::Error::last_os_error(); // flock's
            eprintln!("{lockf}: {e} - another y700-flightrec runs there (a test instance needs its own --run-dir)");
            return 1;
        }
        Err(e) => {
            eprintln!("{lockf}: {e}");
            return 1;
        }
    };

    // signals are taken synchronously (sigtimedwait is the sleep): TERM/INT stop, USR1 = a mark changed the cadence
    let mut set: libc::sigset_t = unsafe { std::mem::zeroed() };
    unsafe {
        libc::sigemptyset(&mut set);
        for s in [libc::SIGTERM, libc::SIGINT, libc::SIGUSR1] {
            libc::sigaddset(&mut set, s);
        }
        libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
    }
    let mut sinks = Sinks::new(&p);
    let copied = archive_pstore(&p, &sinks.boot);
    let order = boot_order(&p, &sinks.boot);
    prune_logs(&p, &sinks.boot, &order);
    let pidf = format!("{}/daemon.pid", p.run_dir);
    let _ = fs::write(&pidf, format!("{}\n", std::process::id()));
    let params = r.params();
    let header = format!(
        "HEADER boot={} at={} kernel={} interval={interval:?} sync={sync_every} idle_interval={idle_interval:?} idle_sync={idle_sync} iface={iface} pstore_archived={copied} {params} cmdline={}",
        sinks.boot,
        strftime("%F %T"),
        rd("/proc/sys/kernel/osrelease").unwrap_or_default(),
        rd("/proc/cmdline").unwrap_or_default()
    );
    sinks.write(&header, sync_every, true);
    let mut fast = experiment(&mut r, &p);
    sinks.write(&mode_line(&fast, "no-experiment"), sync_every, false);
    let ivl = |fast: &Option<String>| if fast.is_some() { interval } else { idle_interval };
    let (mut prev, mut wprev) = (r.sample(), r.wifi(&iface));
    // the battery page's counters: this boot's resumed from <run_dir>/energy or zeroed, edge written now (acc.rs)
    let mut energy = super::acc::Acc::open(&p.run_dir, &sinks.boot, &prev);
    let mut next = mono() + ivl(&fast);
    loop {
        let now = mono();
        if next > now {
            let w = (next - now).min(ivl(&fast));
            let ts = libc::timespec { tv_sec: w as libc::time_t, tv_nsec: (w.fract() * 1e9) as libc::c_long };
            let sig = unsafe { libc::sigtimedwait(&set, std::ptr::null_mut(), &ts) };
            if sig == libc::SIGTERM || sig == libc::SIGINT {
                break;
            }
            if sig == libc::SIGUSR1 {
                let m = experiment(&mut r, &p);
                if m.is_some() != fast.is_some() {
                    sinks.write(&mode_line(&m, "experiment-ended"), sync_every, false);
                    if m.as_deref() == Some("experiment-mark") {
                        // a start MARK with the knobs still off (cx-exp.sh marks first): a fresh baseline, so the
                        // first line after the MARK covers ~1 s after it, as the 1 Hz Python recorder's did - not up
                        // to idle_interval s of pre-knob time, which exp-collect.sh would add to the step's sums
                        // (review 2026-10-17: ~300 extra cl0 "rej" against E1's 360 in three hours)
                        prev = r.sample();
                        wprev = r.wifi(&iface);
                        next = mono() + interval;
                    } else if m.is_some() {
                        next = mono(); // a knob is already on: the slow window holds knob-on time, write it now
                    }
                    fast = m;
                }
            }
            continue;
        }
        let (cur, wcur) = (r.sample(), r.wifi(&iface));
        let line = r.fmt(&prev, &cur, &wprev, &wcur);
        sinks.write(&line, if fast.is_some() { sync_every } else { idle_sync }, false);
        energy.line(&cur); // data lines only: HEADER/MODE/MARK/STOP carry no reading
        prev = cur;
        wprev = wcur;
        // the knobs are read with every line: an experiment switched on without a mark is caught too
        let m = experiment(&mut r, &p);
        if m.is_some() != fast.is_some() {
            sinks.write(&mode_line(&m, "no-experiment"), sync_every, false);
            fast = m;
        }
        next += ivl(&fast);
        if next < mono() - 5.0 * ivl(&fast) {
            next = mono() + ivl(&fast); // fell far behind (a stall): resync
        }
    }
    sinks.write(&format!("STOP t={:.1} at={}", mono(), strftime("%H:%M:%S")), sync_every, true);
    // only if it still names us: batteryd reads "flightrec runs" from it (a recorder that is not ours - an older
    // build without the lock above - may have written its pid since)
    if rd(&pidf) == Some(std::process::id().to_string()) {
        let _ = fs::remove_file(&pidf);
    }
    0
}
