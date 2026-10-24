//! y700-flightrec: flight recorder for the Y700 CX-collapse experiments (PROTOCOL.md section 2). Rust since
//! 2026-10-17 (the owner: power-sensitive device, resident programs in Rust); before that y700-flightrec.py (git
//! history), whose line format, sinks and command line this keeps exactly - cx-exp.sh, exp-collect.sh and
//! y700-checklist read them.
//!
//! One line (~290 B) about the SoC's idle/power state per sample, appended to three places:
//!   1. /dev/pmsg0 - the pstore pmsg ring (256 KiB here). The ramoops region survives a warm reset, so after a
//!      silent SoC reset the previous boot's tail shows up as /sys/fs/pstore/pmsg-ramoops-0 and systemd-pstore
//!      moves it to /var/lib/systemd/pstore/. A cold cut (long press) loses it.
//!   2. /run/y700-flightrec/live.log - tmpfs, for `tail -f` while an experiment runs (trimmed at 2 MiB).
//!   3. /var/log/y700-flightrec/flightrec-<bootid>.log - UFS, fdatasync'ed every N lines: the copy that survives
//!      anything. One file per boot, the last 12 kept, current.log -> this boot's. "Last" is by boots.txt there
//!      (each boot's id appended at start), not by file time: the RTC starts at 1970, see boot_order() in run.rs.
//! At start it copies whatever systemd-pstore archived (and anything still in /sys/fs/pstore) into
//! /var/log/y700-flightrec/pstore/<bootid>/, because systemd-pstore overwrites same-named files next boot.
//!
//! Cadence (new 2026-10-17): a line every --interval s (1) and fdatasync every --sync lines (5) only while an
//! experiment is on - a CX knob (allow_cluster_off / allow_system_off) is set, or `--mark "<STEP> start ..."` was
//! called and its "<STEP> end" not yet (cx-exp.sh marks start before it sets the knobs; the flag expires on its own
//! if a script dies); otherwise every --idle-interval s (10) with fdatasync every --idle-sync lines (6, ~1 min).
//! The Python recorder sampled every second around the clock: 0.57 % of a core with the screen off (6 h of
//! systemd CPU accounting, low clocks - 3/5 of it Python user time parsing ~190 /proc/interrupts lines and ~60
//! open/read/close a second) plus a UFS write every second and a flush every 5 s. MODE lines mark the switches.
//!
//! Line format - space separated key=value; every count is the delta since the previous line:
//!   t=<CLOCK_MONOTONIC s> at=<HH:MM:SS> up=<uptime s> bat=<mW, + = drawn from the battery> dpms=<On|Off>
//!   wifi=<operstate>/+<rx+tx packets> gov=<cpuidle governor> aco=<allow_cluster_off> aso=<allow_system_off|->
//!   dl=<download_mode> busy=<cpu busy %> ctxt=<context switches> irqt=<interrupts>
//!   irq=<top-3 "name:count"> c0=wfi:N,ret:N,rej:N (cpu0-5)  c1=... (cpu6-7)
//!   pd=cl0:<usage>/<rejected>,cl1:...,sys:...   (pm_genpd idle_states S0 of the three PSCI domains)
//!   qs=apss:<count>/+<ms>,cxsd:...,aosd:...,ddr:...   (qcom_stats; ticks / 19200 = ms)
//! Other lines: HEADER (start), MARK (--mark), MODE fast|slow (cadence switch), STOP (SIGTERM).
//!
//! Usage:  y700-flightrec [--interval S] [--sync N] [--idle-interval S] [--idle-sync N] [--iface wlp1s0]   daemon
//!         y700-flightrec --mark "E1 start 30min"   append a MARK line to all three sinks (and flag the experiment)
//!         y700-flightrec --once                    one sample line over a 1 s window to stdout (self-test)
//!   test only: --log-dir D --run-dir D --no-pmsg   (a second instance next to the running one)
//! Read-only apart from its own files and /dev/pmsg0. Every file read each sample stays open and is re-read with
//! pread at offset 0 (sysfs/procfs/debugfs regenerate it there). Root (debugfs).
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

const PMSG: &str = "/dev/pmsg0";
const QS_DIR: &str = "/sys/kernel/debug/qcom_stats";
const GENPD: &str = "/sys/kernel/debug/pm_genpd";
const BAT: &str = "/sys/class/power_supply/qcom-battmgr-bat";
const PARAMS: [(&str, &str); 4] = [
    ("gov", "/sys/devices/system/cpu/cpuidle/current_governor"),
    ("aco", "/sys/module/cpuidle_psci_domain/parameters/allow_cluster_off"),
    ("aso", "/sys/module/cpuidle_psci_domain/parameters/allow_system_off"), // y10 knob; "-" until it exists
    ("dl", "/sys/module/qcom_scm/parameters/download_mode"),
];
const PD_NAMES: [(&str, &str); 3] =
    [("cl0", "power-domain-cluster"), ("cl1", "power-domain-cluster1"), ("sys", "power-domain-system")];
const QS_NAMES: [&str; 4] = ["apss", "cxsd", "aosd", "ddr"];
const TICKS_PER_MS: i64 = 19200; // qcom_stats durations are 19.2 MHz arch-timer ticks
const KEEP_LOGS: usize = 12;
const LIVE_MAX: u64 = 2 * 1024 * 1024;
const FAST_DEFAULT_S: f64 = 3.0 * 3600.0; // a "start" mark without minutes keeps the fast cadence this long
const FAST_MARGIN_S: f64 = 30.0 * 60.0; // added to "<N>min" (the restore and settle after a step)

fn mono() -> f64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as f64 + ts.tv_nsec as f64 / 1e9
}

/// local time with an strftime format (Python's time.strftime)
fn strftime(fmt: &str) -> String {
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        let mut buf = [0u8; 64];
        let f = std::ffi::CString::new(fmt).unwrap_or_default();
        let n = libc::strftime(buf.as_mut_ptr().cast(), buf.len(), f.as_ptr(), &tm);
        String::from_utf8_lossy(&buf[..n]).into_owned()
    }
}

/// one-off read, stripped (Python rd)
fn rd(path: &str) -> Option<String> {
    fs::read(path).ok().map(|b| String::from_utf8_lossy(&b).trim().to_string())
}

/// files read every sample: kept open, re-read with pread from offset 0
struct Files {
    h: HashMap<String, File>,
    buf: Vec<u8>,
}

impl Files {
    fn new() -> Self {
        Files { h: HashMap::new(), buf: vec![0u8; 65536] }
    }

    /// the whole content (stripped), or None (the file is then closed and opened again next time)
    fn read(&mut self, path: &str) -> Option<String> {
        if !self.h.contains_key(path) {
            let f = File::open(path).ok()?;
            self.h.insert(path.to_string(), f);
        }
        let f = &self.h[path];
        let mut out: Vec<u8> = Vec::new();
        let mut off = 0u64;
        loop {
            match f.read_at(&mut self.buf, off) {
                Ok(0) => break,
                Ok(n) => {
                    out.extend_from_slice(&self.buf[..n]);
                    off += n as u64;
                    if out.len() > 4 * 1024 * 1024 {
                        break; // never: /proc/interrupts is ~25 KiB
                    }
                }
                Err(_) => {
                    self.h.remove(path);
                    return None;
                }
            }
        }
        Some(String::from_utf8_lossy(&out).trim().to_string())
    }

    fn num(&mut self, path: &str) -> i64 {
        self.read(path).and_then(|s| s.split_whitespace().next().and_then(|t| t.parse().ok())).unwrap_or(0)
    }
}

#[derive(Default, Clone)]
struct Sample {
    t: f64,
    at: String,
    up: String,
    idle: [[i64; 3]; 2], // per cluster: state0 (wfi), state1 (ret) usage, rejected summed over all states
    pd: Vec<(&'static str, (i64, i64))>,
    qs: Vec<(&'static str, (i64, i64))>,
    irq: HashMap<String, (i64, String)>,
    cpu_total: i64,
    cpu_idle: i64,
    ctxt: i64,
    bat_mw: f64,
    dpms: String,
}

struct Recorder {
    f: Files,
    idle_files: Vec<(usize, usize, String, String)>, // (cluster, state index, usage path, rejected path)
    dpms_path: Option<String>,
    bat: (f64, f64, f64), // (last read monotonic, voltage uV, current uA)
}

impl Recorder {
    fn new() -> Self {
        let mut cpus: Vec<(usize, usize, Vec<usize>)> = vec![];
        for e in fs::read_dir("/sys/devices/system/cpu").into_iter().flatten().flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            let Some(id) = n.strip_prefix("cpu").and_then(|s| s.parse::<usize>().ok()) else { continue };
            // cpu0-5 = power-domain-cluster, cpu6-7 = power-domain-cluster1 (kaanapali.dtsi + patch 0031)
            let cl = rd(&format!("/sys/devices/system/cpu/cpu{id}/topology/cluster_id"))
                .and_then(|s| s.parse::<usize>().ok())
                .filter(|c| *c <= 1)
                .unwrap_or(if id < 6 { 0 } else { 1 });
            let mut states: Vec<usize> = fs::read_dir(format!("/sys/devices/system/cpu/cpu{id}/cpuidle"))
                .into_iter()
                .flatten()
                .flatten()
                .filter_map(|s| s.file_name().to_string_lossy().strip_prefix("state").and_then(|x| x.parse().ok()))
                .collect();
            states.sort();
            cpus.push((id, cl, states));
        }
        cpus.sort();
        let mut idle_files = vec![];
        for (id, cl, states) in &cpus {
            for idx in states {
                let base = format!("/sys/devices/system/cpu/cpu{id}/cpuidle/state{idx}");
                idle_files.push((*cl, *idx, format!("{base}/usage"), format!("{base}/rejected")));
            }
        }
        let dpms_path = fs::read_dir("/sys/class/drm").into_iter().flatten().flatten().find_map(|e| {
            let n = e.file_name().to_string_lossy().into_owned();
            (n.starts_with("card") && n.contains("-DSI-") && e.path().join("dpms").exists())
                .then(|| e.path().join("dpms").to_string_lossy().into_owned())
        });
        Recorder { f: Files::new(), idle_files, dpms_path, bat: (-1e9, 0.0, 0.0) }
    }

    fn sample(&mut self) -> Sample {
        let mut s = Sample { t: mono(), at: strftime("%H:%M:%S"), ..Default::default() };
        // cpuidle: per cluster, entries per state index (0 = WFI, 1 = retention / domain trigger) and rejections
        let files = std::mem::take(&mut self.idle_files);
        for (cl, idx, usage, rej) in &files {
            let (u, r) = (self.f.num(usage), self.f.num(rej));
            if *idx < 2 {
                s.idle[*cl][*idx] += u;
            }
            s.idle[*cl][2] += r;
        }
        self.idle_files = files;
        // genpd idle_states: "S0  time  usage  rejected  above  below  s2idle"
        for (key, name) in PD_NAMES {
            if let Some(txt) = self.f.read(&format!("{GENPD}/{name}/idle_states")) {
                if let Some(l) = txt.lines().nth(1) {
                    let f: Vec<&str> = l.split_whitespace().collect();
                    if f.len() >= 4 {
                        if let (Ok(u), Ok(r)) = (f[2].parse(), f[3].parse()) {
                            s.pd.push((key, (u, r)));
                        }
                    }
                }
            }
        }
        // qcom_stats: Count / Accumulated Duration
        for name in QS_NAMES {
            if let Some(txt) = self.f.read(&format!("{QS_DIR}/{name}")) {
                let (mut cnt, mut dur) = (None, None);
                for l in txt.lines() {
                    if let Some(v) = l.strip_prefix("Count:") {
                        cnt = v.trim().parse::<i64>().ok();
                    } else if let Some(v) = l.strip_prefix("Accumulated Duration:") {
                        dur = v.trim().parse::<i64>().ok();
                    }
                }
                if let (Some(c), Some(d)) = (cnt, dur) {
                    s.qs.push((name, (c, d)));
                }
            }
        }
        // interrupts: number -> (count, name); IPIs included
        if let Some(txt) = self.f.read("/proc/interrupts") {
            for l in txt.lines().skip(1) {
                let f: Vec<&str> = l.split_whitespace().collect();
                let Some(k) = f.first().and_then(|x| x.strip_suffix(':')) else { continue };
                let (mut n, mut i) = (0i64, 1usize);
                while i < f.len() && !f[i].is_empty() && f[i].bytes().all(|b| b.is_ascii_digit()) {
                    n += f[i].parse::<i64>().unwrap_or(0);
                    i += 1;
                }
                let rest = &f[i..];
                // "GICv3 30 Level arch_timer" / "pdc 1 Level pmk8850_pwrkey" / IPI lines "Rescheduling interrupts"
                let name = if rest.len() >= 4 && (rest[2] == "Level" || rest[2] == "Edge") { rest[3..].join(" ") } else { rest.join(" ") };
                let name = if name.is_empty() { k.to_string() } else { name };
                s.irq.insert(k.to_string(), (n, name.chars().take(22).collect()));
            }
        }
        if let Some(st) = self.f.read("/proc/stat") {
            let mut lines = st.lines();
            if let Some(first) = lines.next() {
                let v: Vec<i64> = first.split_whitespace().skip(1).filter_map(|x| x.parse().ok()).collect();
                s.cpu_total = v.iter().sum();
                s.cpu_idle = if v.len() > 4 { v[3] + v[4] } else { 0 };
            }
            for l in st.lines() {
                if let Some(v) = l.strip_prefix("ctxt ") {
                    s.ctxt = v.trim().parse().unwrap_or(0);
                }
            }
        }
        // the battery gauge is a glink round trip to the ADSP and changes every 5-8 s: read it at most every ~5 s
        if s.t - self.bat.0 >= 4.5 {
            self.bat = (s.t, self.f.num(&format!("{BAT}/voltage_now")) as f64, self.f.num(&format!("{BAT}/current_now")) as f64);
        }
        s.bat_mw = -(self.bat.1 / 1e6) * (self.bat.2 / 1e6) * 1000.0; // + = drawn from the battery
        s.dpms = match self.dpms_path.clone() {
            Some(p) => self.f.read(&p).unwrap_or_else(|| "?".into()),
            None => "?".into(),
        };
        s.up = self.f.read("/proc/uptime").and_then(|u| u.split_whitespace().next().map(str::to_string)).unwrap_or_else(|| "0".into());
        s
    }

    fn wifi(&mut self, iface: &str) -> (String, i64) {
        let base = format!("/sys/class/net/{iface}");
        let rx = self.f.num(&format!("{base}/statistics/rx_packets"));
        let tx = self.f.num(&format!("{base}/statistics/tx_packets"));
        (self.f.read(&format!("{base}/operstate")).unwrap_or_else(|| "?".into()), rx + tx)
    }

    fn params(&mut self) -> String {
        PARAMS
            .iter()
            .map(|(k, p)| format!("{k}={}", self.f.read(p).filter(|v| !v.is_empty()).unwrap_or_else(|| "-".into())))
            .collect::<Vec<_>>()
            .join(" ")
    }

    fn fmt(&mut self, prev: &Sample, cur: &Sample, wprev: &(String, i64), wcur: &(String, i64)) -> String {
        let tot = (cur.cpu_total - prev.cpu_total).max(1);
        let busy = 100.0 * (1.0 - (cur.cpu_idle - prev.cpu_idle) as f64 / tot as f64);
        let mut irqd: Vec<(i64, String)> = cur
            .irq
            .iter()
            .filter_map(|(k, (n, name))| {
                let pn = prev.irq.get(k).map_or(*n, |p| p.0);
                (n - pn > 0).then(|| (n - pn, name.clone()))
            })
            .collect();
        irqd.sort_by(|a, b| b.cmp(a)); // Python: list of (count, name) sorted reverse
        let irqt: i64 = irqd.iter().map(|x| x.0).sum();
        let top = irqd.iter().take(3).map(|(n, name)| format!("{name}:{n}")).collect::<Vec<_>>().join(",");
        let top = if top.is_empty() { "-".to_string() } else { top };
        let cl = |c: usize| {
            format!("wfi:{},ret:{},rej:{}", cur.idle[c][0] - prev.idle[c][0], cur.idle[c][1] - prev.idle[c][1], cur.idle[c][2] - prev.idle[c][2])
        };
        let get = |v: &Vec<(&'static str, (i64, i64))>, k: &str| v.iter().find(|x| x.0 == k).map(|x| x.1);
        let pd: Vec<String> = cur
            .pd
            .iter()
            .map(|(k, (u, r))| {
                let (pu, pr) = get(&prev.pd, k).unwrap_or((*u, *r));
                format!("{k}:{}/{}", u - pu, r - pr)
            })
            .collect();
        let qs: Vec<String> = cur
            .qs
            .iter()
            .map(|(k, (c, d))| {
                let (pc, pdur) = get(&prev.qs, k).unwrap_or((*c, *d));
                format!("{k}:{}/+{}", c - pc, (d - pdur).div_euclid(TICKS_PER_MS))
            })
            .collect();
        let or_dash = |v: Vec<String>| if v.is_empty() { "-".to_string() } else { v.join(",") };
        let params = self.params();
        format!(
            "t={:.1} at={} up={} bat={:+.0}mW dpms={} wifi={}/+{} {} busy={:.1} ctxt={} irqt={} irq={} c0={} c1={} pd={} qs={}",
            cur.t, cur.at, cur.up, cur.bat_mw, cur.dpms, wcur.0, wcur.1 - wprev.1, params, busy, cur.ctxt - prev.ctxt, irqt, top,
            cl(0), cl(1), or_dash(pd), or_dash(qs)
        )
    }
}

mod run;

fn main() {
    std::process::exit(run::run());
}
