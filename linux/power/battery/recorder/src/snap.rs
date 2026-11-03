//! What a snapshot reads besides the unit table, and how the ledger lines are written.
//!
//! Light counters (every snapshot, all absolute):
//!   cl  per CPU cluster (cpufreq policy): [busy ms, sum f*t in MHz*ms, sum t in ms] - busy from the policy's CPUs'
//!       /proc/stat lines (user+nice+system+irq+softirq+steal), f*t and t from stats/time_in_state; the mean
//!       frequency of an interval is d(f*t)/d(t)
//!   ctx /proc/stat ctxt;  pkt wlp1s0 [rx_packets, tx_packets];  x Xwayland [pid, utime+stime ticks] (Xwayland runs
//!       in KWin's cgroup, so it is found through that unit's cgroup.procs)
//!   fr  flightrec's energy totals: every numeric field of /run/y700-flightrec/energy as it is (t, n, ton, toff,
//!       don, doff, dton, dtoff, chg, tchg, tz, tzero, gap, bl, lb, lbt - units in DESIGN.md section 2), only when
//!       the file is of this boot; read twice and taken only when both reads agree (flightrec pwrites it in place)
//!
//! Lines (JSON, one per write; numbers plain, m/w seconds with 2 decimals):
//!   {"k":"H","v":1,"boot":"<boot id>","part":N,"m":..,"w":..,"sync":0|1,"why":"start"|"part"}
//!   {"k":"U","id":N,"p":"<key>","ino":N}
//!   {"k":"S","why":..,"m":..,"w":..,"sync":0|1[,"dpms":0|1][,"pw":"dis"|"chg"],"cov":0|1[,"edge":T][,"fr":{..}],
//!    "cg":{"<id>":usage_usec,..}[,"new":[..]][,"gone":[..]],"cl":[[..],..][,"ctx":N][,"pkt":[rx,tx]][,"x":[pid,ticks]]
//!    [,"gpu":{"<id>":[engine_ns,cycles],..}][,"wk":{"<id>"|"-k":N,..}][,"st":".."][,"cap":N]}
//!   {"k":"K","m":..,"w":..,"sync":0|1,"src":"chrony"|"adjtimex","step":S}
use std::collections::HashMap;
use std::fs::{self, File};
use std::path::{Path, PathBuf};

use crate::fds;

// ---- JSON
pub fn jstr(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for ch in s.chars() {
        match ch {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

/// a float with d decimals; never NaN/inf in the ledger
pub fn fnum(v: f64, d: usize) -> String {
    if v.is_finite() {
        format!("{:.*}", d, v)
    } else {
        "0".to_string()
    }
}

fn b01(b: bool) -> u8 {
    if b {
        1
    } else {
        0
    }
}

/// one S line's content; the recorder fills cg/new/gone/gpu with what changed since the last line written
#[derive(Clone, Debug, Default)]
pub struct SLine {
    pub why: &'static str,
    pub m: f64,
    pub w: f64,
    pub sync: bool,
    pub dpms: Option<bool>,
    pub pw: Option<&'static str>,
    pub cov: bool,
    pub edge: Option<f64>,
    pub fr: Option<Vec<(String, i64)>>,
    pub cg: Vec<(u32, u64)>,
    pub new: Vec<u32>,
    pub gone: Vec<u32>,
    pub cl: Vec<[u64; 3]>,
    pub ctx: Option<u64>,
    pub pkt: Option<(u64, u64)>,
    pub x: Option<(i32, u64)>,
    pub gpu: Vec<(u32, (u64, u64))>,
    pub wk: Option<Vec<(String, u64)>>,
    pub st: Option<String>,
    pub cap: Option<i64>,
}

fn ids(v: &[u32]) -> String {
    v.iter().map(|i| i.to_string()).collect::<Vec<_>>().join(",")
}

pub fn render_s(s: &SLine) -> String {
    let mut o = String::with_capacity(4096);
    o.push_str(&format!(
        "{{\"k\":\"S\",\"why\":{},\"m\":{},\"w\":{},\"sync\":{}",
        jstr(s.why),
        fnum(s.m, 2),
        fnum(s.w, 2),
        b01(s.sync)
    ));
    if let Some(d) = s.dpms {
        o.push_str(&format!(",\"dpms\":{}", b01(d)));
    }
    if let Some(p) = s.pw {
        o.push_str(&format!(",\"pw\":{}", jstr(p)));
    }
    o.push_str(&format!(",\"cov\":{}", b01(s.cov)));
    if let Some(e) = s.edge {
        o.push_str(&format!(",\"edge\":{}", fnum(e, 1)));
    }
    if let Some(fr) = &s.fr {
        let f: Vec<String> = fr.iter().map(|(k, v)| format!("{}:{v}", jstr(k))).collect();
        o.push_str(&format!(",\"fr\":{{{}}}", f.join(",")));
    }
    let cg: Vec<String> = s.cg.iter().map(|(id, v)| format!("\"{id}\":{v}")).collect();
    o.push_str(&format!(",\"cg\":{{{}}}", cg.join(",")));
    if !s.new.is_empty() {
        o.push_str(&format!(",\"new\":[{}]", ids(&s.new)));
    }
    if !s.gone.is_empty() {
        o.push_str(&format!(",\"gone\":[{}]", ids(&s.gone)));
    }
    let cl: Vec<String> = s.cl.iter().map(|c| format!("[{},{},{}]", c[0], c[1], c[2])).collect();
    o.push_str(&format!(",\"cl\":[{}]", cl.join(",")));
    if let Some(c) = s.ctx {
        o.push_str(&format!(",\"ctx\":{c}"));
    }
    if let Some((rx, tx)) = s.pkt {
        o.push_str(&format!(",\"pkt\":[{rx},{tx}]"));
    }
    if let Some((pid, t)) = s.x {
        o.push_str(&format!(",\"x\":[{pid},{t}]"));
    }
    if !s.gpu.is_empty() {
        let g: Vec<String> = s.gpu.iter().map(|(id, (e, c))| format!("\"{id}\":[{e},{c}]")).collect();
        o.push_str(&format!(",\"gpu\":{{{}}}", g.join(",")));
    }
    if let Some(wk) = &s.wk {
        let w: Vec<String> = wk.iter().map(|(k, n)| format!("{}:{n}", jstr(k))).collect();
        o.push_str(&format!(",\"wk\":{{{}}}", w.join(",")));
    }
    if let Some(st) = &s.st {
        o.push_str(&format!(",\"st\":{}", jstr(st)));
    }
    if let Some(c) = s.cap {
        o.push_str(&format!(",\"cap\":{c}"));
    }
    o.push('}');
    o
}

pub fn render_h(boot: &str, part: u32, m: f64, w: f64, sync: bool, why: &str) -> String {
    format!(
        "{{\"k\":\"H\",\"v\":1,\"boot\":{},\"part\":{part},\"m\":{},\"w\":{},\"sync\":{},\"why\":{}}}",
        jstr(boot),
        fnum(m, 2),
        fnum(w, 2),
        b01(sync),
        jstr(why)
    )
}

pub fn render_u(id: u32, key: &str, ino: u64) -> String {
    format!("{{\"k\":\"U\",\"id\":{id},\"p\":{},\"ino\":{ino}}}", jstr(key))
}

/// a clock step: step = the change of (w - m) against the recorder's last look before it, s
pub fn render_k(m: f64, w: f64, sync: bool, src: &str, step: f64) -> String {
    format!(
        "{{\"k\":\"K\",\"m\":{},\"w\":{},\"sync\":{},\"src\":{},\"step\":{}}}",
        fnum(m, 2),
        fnum(w, 2),
        b01(sync),
        jstr(src),
        fnum(step, 3)
    )
}

// ---- flightrec's files
pub fn parse_dpms(v: &str) -> Option<bool> {
    match v {
        "On" => Some(true),
        "Off" => Some(false),
        _ => None,
    }
}

pub fn parse_pw(v: &str) -> Option<&'static str> {
    match v {
        "dis" => Some("dis"),
        "chg" => Some("chg"),
        _ => None,
    }
}

/// /run/y700-flightrec/energy: "v1 boot=<boot8> t=<ms> n=.. ... lb=+000000000412 lbt=.. dpms=Off pw=dis"
#[derive(Clone, Debug, PartialEq)]
pub struct Energy {
    pub boot: String,
    pub t: i64,
    pub fields: Vec<(String, i64)>,
}

pub fn parse_energy(text: &str) -> Option<Energy> {
    let line = text.lines().next()?;
    let mut it = line.split_whitespace();
    if it.next()? != "v1" {
        return None;
    }
    let (mut boot, mut t, mut fields) = (None, None, vec![]);
    for tok in it {
        let Some((k, v)) = tok.split_once('=') else { continue };
        if k == "boot" {
            boot = Some(v.to_string());
            continue;
        }
        if k.is_empty() || !k.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
            continue;
        }
        if let Ok(n) = v.parse::<i64>() {
            // fixed-width digits with leading zeros, lb with a sign: i64's parser takes both
            if k == "t" {
                t = Some(n);
            }
            fields.push((k.to_string(), n));
        }
    }
    Some(Energy { boot: boot?, t: t?, fields })
}

/// /run/y700-flightrec/edge: "v1 t=7341.9 dpms=Off pw=dis"
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Edge {
    pub t: f64,
    pub dpms: Option<bool>,
    pub pw: Option<&'static str>,
}

pub fn parse_edge(text: &str) -> Option<Edge> {
    let line = text.lines().next()?;
    let mut it = line.split_whitespace();
    if it.next()? != "v1" {
        return None;
    }
    let (mut t, mut dpms, mut pw) = (None, None, None);
    for tok in it {
        match tok.split_once('=') {
            Some(("t", v)) => t = v.parse::<f64>().ok().filter(|x| x.is_finite()),
            Some(("dpms", v)) => dpms = parse_dpms(v),
            Some(("pw", v)) => pw = parse_pw(v),
            _ => {}
        }
    }
    Some(Edge { t: t?, dpms, pw })
}

/// a file rewritten in place by someone else (pwrite at offset 0): read twice through one fd, taken only when both
/// reads agree (up to three tries)
pub fn read_stable(path: &Path) -> Option<String> {
    let f = File::open(path).ok()?;
    let (mut a, mut b) = (Vec::with_capacity(512), Vec::with_capacity(512));
    for _ in 0..3 {
        if fds::pread_all(&f, &mut a).is_err() || fds::pread_all(&f, &mut b).is_err() {
            return None;
        }
        if a == b {
            return Some(String::from_utf8_lossy(&a).into_owned());
        }
    }
    None
}

/// the battery's status and capacity: each is a firmware round trip, so only at start and at power edges
pub fn battery(dir: &Path) -> (Option<String>, Option<i64>) {
    let st = fds::read_text(&dir.join("status")).filter(|s| !s.is_empty());
    let cap = fds::read_text(&dir.join("capacity")).and_then(|s| s.parse::<i64>().ok());
    (st, cap)
}

// ---- CPU, network, Xwayland
/// (per-cpu busy ticks = user+nice+system+irq+softirq+steal, the ctxt total) of /proc/stat
pub fn parse_stat(t: &str) -> (HashMap<usize, u64>, Option<u64>) {
    let mut busy = HashMap::new();
    let mut ctx = None;
    for l in t.lines() {
        if let Some(r) = l.strip_prefix("cpu") {
            if !r.starts_with(|c: char| c.is_ascii_digit()) {
                continue; // the "cpu " total line
            }
            let mut it = r.split_whitespace();
            let Some(id) = it.next().and_then(|s| s.parse::<usize>().ok()) else { continue };
            let v: Vec<u64> = it.map(|x| x.parse::<u64>().unwrap_or(0)).collect();
            let g = |i: usize| v.get(i).copied().unwrap_or(0);
            busy.insert(id, g(0).saturating_add(g(1)).saturating_add(g(2)).saturating_add(g(5)).saturating_add(g(6)).saturating_add(g(7)));
        } else if let Some(r) = l.strip_prefix("ctxt ") {
            ctx = r.trim().parse::<u64>().ok();
        }
    }
    (busy, ctx)
}

/// (sum of kHz * ticks, sum of ticks) of a cpufreq stats/time_in_state ("<kHz> <ticks>" lines)
pub fn parse_tis(t: &str) -> (u128, u64) {
    let (mut ft, mut tt) = (0u128, 0u64);
    for l in t.lines() {
        let mut it = l.split_whitespace();
        if let (Some(Ok(f)), Some(Ok(n))) = (it.next().map(str::parse::<u64>), it.next().map(str::parse::<u64>)) {
            ft = ft.saturating_add(f as u128 * n as u128);
            tt = tt.saturating_add(n);
        }
    }
    (ft, tt)
}

/// one cluster's cl entry from its CPUs' busy ticks and its time_in_state sums
pub fn cl_entry(busy_ticks: u64, tis: Option<(u128, u64)>, ms_tick: u64) -> [u64; 3] {
    let (ft, tt) = tis.unwrap_or((0, 0));
    let mhz_ms = ft.saturating_mul(ms_tick as u128) / 1000; // kHz*ticks * ms/tick / 1000 = MHz*ms
    [busy_ticks.saturating_mul(ms_tick), u64::try_from(mhz_ms).unwrap_or(u64::MAX), tt.saturating_mul(ms_tick)]
}

/// a list like "0 1 2 3 4 5" or "0-5" (cpufreq related_cpus)
pub fn parse_cpus(t: &str) -> Vec<usize> {
    let mut v = vec![];
    for part in t.split(|c: char| c.is_whitespace() || c == ',').filter(|s| !s.is_empty()) {
        match part.split_once('-') {
            Some((a, b)) => {
                if let (Ok(a), Ok(b)) = (a.parse::<usize>(), b.parse::<usize>()) {
                    if b >= a && b - a < 1024 {
                        v.extend(a..=b);
                    }
                }
            }
            None => {
                if let Ok(a) = part.parse::<usize>() {
                    v.push(a);
                }
            }
        }
    }
    v
}

/// (comm, utime + stime ticks) of a /proc/<pid>/stat (the comm can hold spaces and parentheses: cut at the last ')')
pub fn parse_stat_times(b: &[u8]) -> Option<(String, u64)> {
    let open = b.iter().position(|&c| c == b'(')?;
    let close = b.iter().rposition(|&c| c == b')')?;
    if close <= open {
        return None;
    }
    let comm = String::from_utf8_lossy(b.get(open + 1..close)?).into_owned();
    let rest = std::str::from_utf8(b.get(close + 1..)?).ok()?;
    let f: Vec<&str> = rest.split_whitespace().collect();
    let u = f.get(11)?.parse::<u64>().ok()?; // field 14 (utime); index 0 is field 3 (state)
    let s = f.get(12)?.parse::<u64>().ok()?; // field 15 (stime)
    Some((comm, u.saturating_add(s)))
}

struct Kept {
    path: PathBuf,
    f: Option<File>,
}

impl Kept {
    fn new(path: PathBuf) -> Kept {
        Kept { path, f: None }
    }

    /// the content through the kept fd (opened on first use, closed after an error and opened again next time)
    fn read(&mut self, buf: &mut Vec<u8>) -> bool {
        if self.f.is_none() {
            self.f = File::open(&self.path).ok();
        }
        let ok = match &self.f {
            Some(f) => fds::pread_all(f, buf).is_ok(),
            None => false,
        };
        if !ok {
            self.f = None;
        }
        ok
    }
}

pub struct LightData {
    pub cl: Vec<[u64; 3]>,
    pub ctx: Option<u64>,
    pub pkt: Option<(u64, u64)>,
    pub x: Option<(i32, u64)>,
}

pub struct Light {
    stat: Kept,
    pol: Vec<(Kept, Vec<usize>)>, // time_in_state, the policy's CPUs
    rx: Kept,
    tx: Kept,
    ms_tick: u64,
    buf: Vec<u8>,
    x_pid: Option<i32>,
}

impl Light {
    pub fn new(iface: &str) -> Light {
        // SAFETY: sysconf takes no pointers
        let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
        let ms_tick = if hz > 0 && hz <= 1000 { (1000 / hz) as u64 } else { 10 };
        let base = Path::new("/sys/devices/system/cpu/cpufreq");
        let mut pols: Vec<(usize, PathBuf)> = fs::read_dir(base)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| {
                let n = e.file_name().to_string_lossy().into_owned();
                n.strip_prefix("policy").and_then(|x| x.parse::<usize>().ok()).map(|i| (i, e.path()))
            })
            .collect();
        pols.sort();
        let pol = pols
            .into_iter()
            .map(|(_, p)| {
                let cpus = fds::read_text(&p.join("related_cpus")).map(|t| parse_cpus(&t)).unwrap_or_default();
                (Kept::new(p.join("stats/time_in_state")), cpus)
            })
            .collect();
        let net = Path::new("/sys/class/net").join(iface).join("statistics");
        Light {
            stat: Kept::new(PathBuf::from("/proc/stat")),
            pol,
            rx: Kept::new(net.join("rx_packets")),
            tx: Kept::new(net.join("tx_packets")),
            ms_tick,
            buf: Vec::with_capacity(8192),
            x_pid: None,
        }
    }

    fn num(&mut self, which: bool) -> Option<u64> {
        let k = if which { &mut self.rx } else { &mut self.tx };
        if !k.read(&mut self.buf) {
            return None;
        }
        String::from_utf8_lossy(&self.buf).trim().parse::<u64>().ok()
    }

    /// kwin: KWin's cgroup directory, where Xwayland runs
    pub fn read(&mut self, kwin: Option<&Path>) -> LightData {
        let (busy, ctx) = if self.stat.read(&mut self.buf) {
            parse_stat(&String::from_utf8_lossy(&self.buf))
        } else {
            (HashMap::new(), None)
        };
        let mut cl = Vec::with_capacity(self.pol.len());
        for (k, cpus) in self.pol.iter_mut() {
            let b: u64 = cpus.iter().map(|c| busy.get(c).copied().unwrap_or(0)).fold(0u64, |a, x| a.saturating_add(x));
            let tis = if k.read(&mut self.buf) { Some(parse_tis(&String::from_utf8_lossy(&self.buf))) } else { None };
            cl.push(cl_entry(b, tis, self.ms_tick));
        }
        let pkt = match (self.num(true), self.num(false)) {
            (Some(r), Some(t)) => Some((r, t)),
            _ => None,
        };
        let x = self.xwayland(kwin);
        LightData { cl, ctx, pkt, x }
    }

    fn x_times(&mut self, pid: i32) -> Option<u64> {
        fds::read_into(Path::new(&format!("/proc/{pid}/stat")), &mut self.buf).ok()?;
        let (comm, t) = parse_stat_times(&self.buf)?;
        (comm == "Xwayland").then_some(t)
    }

    fn xwayland(&mut self, kwin: Option<&Path>) -> Option<(i32, u64)> {
        if let Some(pid) = self.x_pid {
            if let Some(t) = self.x_times(pid) {
                return Some((pid, t));
            }
            self.x_pid = None;
        }
        let procs = fs::read_to_string(kwin?.join("cgroup.procs")).ok()?;
        for p in procs.split_whitespace().filter_map(|s| s.parse::<i32>().ok()) {
            if let Some(t) = self.x_times(p) {
                self.x_pid = Some(p);
                return Some((p, t));
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ENERGY: &str = "v1 boot=3f2a9c1e t=0000031540012 n=0000000003154 ton=0000004120000 toff=0000027420000 don=0000004120333 doff=0000003311870 dton=0000004100000 dtoff=0000027000000 chg=0000000412004 tchg=0000000420000 tz=0000000180000 tzero=0000000000000 gap=0000000000000 bl=0001352000000 lb=+000000000412 lbt=0000031540012 dpms=Off pw=dis\n";

    #[test]
    fn energy_file() {
        let e = parse_energy(ENERGY).unwrap();
        assert_eq!(e.boot, "3f2a9c1e");
        assert_eq!(e.t, 31540012);
        let get = |k: &str| e.fields.iter().find(|f| f.0 == k).map(|f| f.1);
        assert_eq!(get("don"), Some(4120333));
        assert_eq!(get("lb"), Some(412));
        assert_eq!(get("tzero"), Some(0));
        assert_eq!(get("dpms"), None);
        assert_eq!(e.fields.first().map(|f| f.0.as_str()), Some("t"));
        assert_eq!(parse_energy("v1 boot=x lb=-000000000012 t=5"), Some(Energy {
            boot: "x".into(), t: 5, fields: vec![("lb".into(), -12), ("t".into(), 5)] }));
        assert_eq!(parse_energy("v2 boot=x t=1"), None);
        assert_eq!(parse_energy("v1 t=1"), None);
        assert_eq!(parse_energy(""), None);
    }

    #[test]
    fn edge_file() {
        assert_eq!(parse_edge("v1 t=7341.9 dpms=Off pw=dis\n"), Some(Edge { t: 7341.9, dpms: Some(false), pw: Some("dis") }));
        assert_eq!(parse_edge("v1 t=12.0 dpms=On pw=chg"), Some(Edge { t: 12.0, dpms: Some(true), pw: Some("chg") }));
        assert_eq!(parse_edge("v1 t=12.0 dpms=? pw=-"), Some(Edge { t: 12.0, dpms: None, pw: None }));
        assert_eq!(parse_edge("v1 dpms=On"), None);
        assert_eq!(parse_edge("garbage"), None);
    }

    #[test]
    fn proc_stat_and_time_in_state() {
        let st = "cpu  100 0 50 9000 10 5 5 0 0 0\ncpu0 10 1 2 900 9 3 4 5 7 7\ncpu6 1 0 0 10 0 0 0 0\nintr 1 2 3\nctxt 81234567\nbtime 1\n";
        let (b, c) = parse_stat(st);
        assert_eq!(b.get(&0), Some(&(10 + 1 + 2 + 3 + 4 + 5)));
        assert_eq!(b.get(&6), Some(&1));
        assert_eq!(b.len(), 2, "the total line is not a cpu");
        assert_eq!(c, Some(81234567));
        let tis = "300000 100\n1171200 50\n";
        let (ft, tt) = parse_tis(tis);
        assert_eq!(tt, 150);
        assert_eq!(ft, 300000 * 100 + 1171200 * 50);
        // 10 ms ticks: busy 37 ticks = 370 ms; 1.5 s at (300 MHz * 1 s + 1171.2 MHz * 0.5 s) = 885600 MHz*ms
        assert_eq!(cl_entry(37, Some((ft, tt)), 10), [370, 885600, 1500]);
        assert_eq!(cl_entry(37, None, 10), [370, 0, 0]);
        assert_eq!(parse_cpus("0 1 2 3 4 5\n"), vec![0, 1, 2, 3, 4, 5]);
        assert_eq!(parse_cpus("6-7"), vec![6, 7]);
    }

    #[test]
    fn pid_stat() {
        let s = b"3315 (Xwayland) S 3100 3100 3100 0 -1 4194560 100 0 0 0 2500 815 0 0 20 0 3 0 1000 0\n";
        assert_eq!(parse_stat_times(s), Some(("Xwayland".to_string(), 3315)));
        let s = b"42 (a) b (c)) R 1 1 1 0 -1 0 0 0 0 0 7 8 0 0 20 0 1 0 5 0\n";
        assert_eq!(parse_stat_times(s), Some(("a) b (c)".to_string(), 15)));
        assert_eq!(parse_stat_times(b"42 (short) R 1"), None);
    }

    #[test]
    fn json_lines() {
        assert_eq!(jstr("app-geoclue\\x2ddemo\"q\"\n"), "\"app-geoclue\\\\x2ddemo\\\"q\\\"\\u000a\"");
        let s = SLine {
            why: "off",
            m: 7342.2,
            w: 1761810342.6,
            sync: true,
            dpms: Some(false),
            pw: Some("dis"),
            cov: true,
            edge: Some(7341.9),
            fr: Some(vec![("t".into(), 7342000), ("lb".into(), -3)]),
            cg: vec![(1, 61231000), (17, 1290331)],
            new: vec![23],
            gone: vec![19],
            cl: vec![[812345, 95123456, 912340], [20311, 31234567, 912340]],
            ctx: Some(81234567),
            pkt: Some((1203, 988)),
            x: Some((3315, 812)),
            gpu: vec![(17, (1830000000, 512000000))],
            wk: Some(vec![("17".into(), 28130), ("-k".into(), 22148)]),
            st: Some("Discharging".into()),
            cap: Some(64),
        };
        assert_eq!(
            render_s(&s),
            "{\"k\":\"S\",\"why\":\"off\",\"m\":7342.20,\"w\":1761810342.60,\"sync\":1,\"dpms\":0,\"pw\":\"dis\",\"cov\":1,\
             \"edge\":7341.9,\"fr\":{\"t\":7342000,\"lb\":-3},\"cg\":{\"1\":61231000,\"17\":1290331},\"new\":[23],\
             \"gone\":[19],\"cl\":[[812345,95123456,912340],[20311,31234567,912340]],\"ctx\":81234567,\"pkt\":[1203,988],\
             \"x\":[3315,812],\"gpu\":{\"17\":[1830000000,512000000]},\"wk\":{\"17\":28130,\"-k\":22148},\
             \"st\":\"Discharging\",\"cap\":64}"
        );
        let bare = SLine { why: "ck", ..Default::default() };
        assert_eq!(render_s(&bare), "{\"k\":\"S\",\"why\":\"ck\",\"m\":0.00,\"w\":0.00,\"sync\":0,\"cov\":0,\"cg\":{},\"cl\":[]}");
        assert_eq!(
            render_h("3f2a9c1e-77d0", 0, 18.42, 40213.7, false, "start"),
            "{\"k\":\"H\",\"v\":1,\"boot\":\"3f2a9c1e-77d0\",\"part\":0,\"m\":18.42,\"w\":40213.70,\"sync\":0,\"why\":\"start\"}"
        );
        assert_eq!(render_u(2, "u/session.slice/plasma-kwin_wayland.service", 48213),
            "{\"k\":\"U\",\"id\":2,\"p\":\"u/session.slice/plasma-kwin_wayland.service\",\"ino\":48213}");
        assert_eq!(render_k(41.2, 1761803001.4, true, "chrony", f64::NAN),
            "{\"k\":\"K\",\"m\":41.20,\"w\":1761803001.40,\"sync\":1,\"src\":\"chrony\",\"step\":0}");
    }
}
