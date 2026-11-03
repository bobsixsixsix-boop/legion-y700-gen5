//! GPU time per unit from DRM fdinfo (docs.kernel.org/gpu/drm-usage-stats), the way overlay/sampler.rs finds it:
//!   - holders: the fds of our uid's processes whose link target is under /dev/dri/ (renderD128 and card1 both; DESIGN.md
//!     section 2). /proc is listed only when /proc/loadavg's last-pid moved (a process or thread was created since);
//!     a known process is looked at again when its fd count (st_size of /proc/<pid>/fd, Linux >= 6.2) changed.
//!     Processes whose fd directory we may not list (root's, KWin's - it is not dumpable; the stat still works) are
//!     skipped for life.
//!   - fdinfo repeats one client's counters for every fd referring to it (dup, fork), so the unit is the drm-client-id:
//!     read once per pass, through the holder with the lowest pid, and attributed to that pid's cgroup unit. An fd
//!     NUMBER can be closed and reused for something else: the client id is checked on every read, a holder that no
//!     longer names its client is dropped and its process looked at again next pass.
//!   - counters: drm-engine-gpu (ns busy) and drm-cycles-gpu (GPU cycles). acc[unit] grows by each client's growth
//!     since the last pass; a client unseen before counts whole when it was born since (client ids only grow: id above
//!     every id seen before) or at the first pass (the clients alive when the recorder starts), and from zero
//!     otherwise (an fd we had not found yet: its past is not this interval's). acc is this process's: it starts again
//!     at every recorder start (H why=start).
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use crate::fds;
use crate::units::{self, Units};

const DRI: &[u8] = b"/dev/dri/";

/// (drm-client-id, drm-engine-gpu ns, drm-cycles-gpu) of an fdinfo text; counters a driver does not report read 0
pub fn parse_fdinfo(t: &str) -> Option<(u64, u64, u64)> {
    let (mut c, mut e, mut y) = (None, 0u64, 0u64);
    for l in t.lines() {
        let Some((k, v)) = l.split_once(':') else { continue };
        let n = v.split_whitespace().next().and_then(|s| s.parse::<u64>().ok());
        match k.trim() {
            "drm-client-id" => c = n,
            "drm-engine-gpu" => e = n.unwrap_or(0),
            "drm-cycles-gpu" => y = n.unwrap_or(0),
            _ => {}
        }
    }
    c.map(|c| (c, e, y))
}

/// a client's growth since the last pass (see the module comment)
pub fn client_delta(prev: Option<(u64, u64)>, cur: (u64, u64), client: u64, max_prev: u64, primed: bool) -> (u64, u64) {
    match prev {
        Some(p) => (cur.0.saturating_sub(p.0), cur.1.saturating_sub(p.1)),
        None if !primed || client > max_prev => cur,
        None => (0, 0),
    }
}

/// the lowest-pid holder whose fdinfo still names `client`: (pid, engine ns, cycles). Holders read without it (closed,
/// gone, the fd number reused) are removed from `holders` and pushed to `stale`.
pub fn first_valid<F>(holders: &mut Vec<(i32, u32)>, client: u64, mut read: F, stale: &mut Vec<(i32, u32)>) -> Option<(i32, u64, u64)>
where
    F: FnMut(i32, u32) -> Option<(u64, u64, u64)>,
{
    holders.sort_unstable();
    while let Some(&(pid, fd)) = holders.first() {
        if let Some((c, e, y)) = read(pid, fd) {
            if c == client {
                return Some((pid, e, y));
            }
        }
        holders.remove(0);
        stale.push((pid, fd));
    }
    None
}

pub struct Gpu {
    known: HashSet<i32>,
    nfd: HashMap<i32, u64>,        // fd count at the last look
    denied: HashSet<i32>,          // fd directory not readable (another uid, not dumpable) or gone
    fds: HashMap<(i32, u32), u64>, // (pid, fd) -> drm-client-id
    last: HashMap<u64, (u64, u64)>,
    max_client: u64,
    primed: bool,
    last_pid: Option<String>,
    pub acc: HashMap<u32, (u64, u64)>, // unit id -> (engine ns, cycles), cumulative in this process
    pub clients: usize,
    buf: Vec<u8>,
}

impl Gpu {
    pub fn new() -> Gpu {
        Gpu {
            known: HashSet::new(),
            nfd: HashMap::new(),
            denied: HashSet::new(),
            fds: HashMap::new(),
            last: HashMap::new(),
            max_client: 0,
            primed: false,
            last_pid: None,
            acc: HashMap::new(),
            clients: 0,
            buf: Vec::with_capacity(4096),
        }
    }

    fn fd_count(pid: i32) -> Option<u64> {
        fs::metadata(format!("/proc/{pid}/fd")).ok().map(|m| m.len())
    }

    fn scan_pid(&mut self, pid: i32, n: u64) {
        self.nfd.insert(pid, n);
        let rd = match fs::read_dir(format!("/proc/{pid}/fd")) {
            Ok(rd) => rd,
            Err(e) => {
                // another uid's or a non-dumpable process (KWin): the stat in fd_count works (no ptrace check), the
                // listing is refused - skipped for life, or every change of its fd count would try again
                if e.kind() == io::ErrorKind::PermissionDenied {
                    self.nfd.remove(&pid);
                    self.denied.insert(pid);
                }
                return;
            }
        };
        for e in rd.flatten() {
            let Some(fd) = e.file_name().to_str().and_then(|s| s.parse::<u32>().ok()) else { continue };
            if self.fds.contains_key(&(pid, fd)) {
                continue;
            }
            match fs::read_link(e.path()) {
                Ok(t) if t.as_os_str().as_bytes().starts_with(DRI) => {}
                _ => continue,
            }
            if fds::read_into(Path::new(&format!("/proc/{pid}/fdinfo/{fd}")), &mut self.buf).is_err() {
                continue;
            }
            if let Some((c, _, _)) = parse_fdinfo(&String::from_utf8_lossy(&self.buf)) {
                self.fds.insert((pid, fd), c);
            }
        }
    }

    fn refresh(&mut self) {
        let lp = fds::read_text(Path::new("/proc/loadavg")).and_then(|s| s.split_whitespace().last().map(str::to_string));
        if !self.primed || lp.is_none() || lp != self.last_pid {
            let pids: HashSet<i32> = fds::list_pids().into_iter().collect();
            self.last_pid = lp;
            self.known = pids;
            let k = &self.known;
            self.nfd.retain(|p, _| k.contains(p));
            self.denied.retain(|p| k.contains(p));
            self.fds.retain(|(p, _), _| k.contains(p));
        }
        let look: Vec<i32> = self.known.iter().filter(|p| !self.denied.contains(*p)).copied().collect();
        for p in look {
            match Self::fd_count(p) {
                Some(n) => {
                    if self.nfd.get(&p) != Some(&n) {
                        self.scan_pid(p, n);
                    }
                }
                None => {
                    self.denied.insert(p);
                }
            }
        }
    }

    /// one pass: holders refreshed, every client read once, the growth added to its holder's unit
    pub fn pass(&mut self, units: &Units) {
        self.refresh();
        let mut by: HashMap<u64, Vec<(i32, u32)>> = HashMap::new();
        for (&(p, fd), &c) in &self.fds {
            by.entry(c).or_default().push((p, fd));
        }
        let mut stale = vec![];
        let mut cur: HashMap<u64, (u64, u64)> = HashMap::with_capacity(by.len());
        let mut owner: Vec<(u64, i32)> = Vec::with_capacity(by.len());
        let buf = &mut self.buf;
        for (c, mut holders) in by {
            let read = |p: i32, fd: u32| -> Option<(u64, u64, u64)> {
                fds::read_into(Path::new(&format!("/proc/{p}/fdinfo/{fd}")), &mut *buf).ok()?;
                parse_fdinfo(&String::from_utf8_lossy(buf.as_slice()))
            };
            if let Some((p, e, y)) = first_valid(&mut holders, c, read, &mut stale) {
                cur.insert(c, (e, y));
                owner.push((c, p));
            }
        }
        for k in stale {
            self.fds.remove(&k);
            self.nfd.remove(&k.0); // look at that process's fds again next pass
        }
        let max_prev = self.max_client;
        for (c, p) in owner {
            let Some(&now) = cur.get(&c) else { continue };
            let d = client_delta(self.last.get(&c).copied(), now, c, max_prev, self.primed);
            if d == (0, 0) {
                continue;
            }
            let cg = match fds::read_into(Path::new(&format!("/proc/{p}/cgroup")), &mut self.buf) {
                Ok(_) => units::cg_path(&String::from_utf8_lossy(&self.buf)),
                Err(_) => None,
            };
            if let Some(id) = cg.and_then(|g| units.resolve(&g)) {
                let a = self.acc.entry(id).or_insert((0, 0));
                a.0 = a.0.saturating_add(d.0);
                a.1 = a.1.saturating_add(d.1);
            }
        }
        self.max_client = cur.keys().copied().fold(self.max_client, u64::max);
        self.clients = cur.len();
        self.last = cur;
        self.primed = true;
    }

    /// units gone from the table take their totals with them
    pub fn keep(&mut self, live: &HashSet<u32>) {
        self.acc.retain(|id, _| live.contains(id));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fdinfo() {
        let t = "pos:\t0\nflags:\t02100002\nmnt_id:\t26\nino:\t1029\ndrm-driver:\tmsm\ndrm-client-id:\t237\n\
                 drm-engine-gpu:\t1830000000 ns\ndrm-cycles-gpu:\t512000000\ndrm-maxfreq-gpu:\t900000000 Hz\n\
                 drm-resident-memory:\t12 MiB\n";
        assert_eq!(parse_fdinfo(t), Some((237, 1830000000, 512000000)));
        // a KMS-only fd (card1) without engine counters still names its client
        assert_eq!(parse_fdinfo("drm-driver:\tmsm\ndrm-client-id:\t12\n"), Some((12, 0, 0)));
        assert_eq!(parse_fdinfo("pos:\t0\nflags:\t02\n"), None);
    }

    #[test]
    fn deltas() {
        // seen before: growth
        assert_eq!(client_delta(Some((100, 10)), (150, 12), 5, 9, true), (50, 2));
        // a counter going down (cannot happen): no negative growth
        assert_eq!(client_delta(Some((100, 10)), (90, 12), 5, 9, true), (0, 2));
        // born since the last pass: its whole count
        assert_eq!(client_delta(None, (70, 7), 10, 9, true), (70, 7));
        // an older client found late: from zero
        assert_eq!(client_delta(None, (70, 7), 8, 9, true), (0, 0));
        // the first pass: everything alive counts whole
        assert_eq!(client_delta(None, (70, 7), 8, 0, false), (70, 7));
    }

    #[test]
    fn reused_fd_number() {
        // client 7 held by pid 300 fd 5 (closed and reused for client 9) and pid 420 fd 12; pid 200 is gone
        let mut holders = vec![(420, 12), (300, 5), (200, 3)];
        let mut stale = vec![];
        let read = |p: i32, fd: u32| match (p, fd) {
            (300, 5) => Some((9, 1, 1)),
            (420, 12) => Some((7, 500, 40)),
            _ => None,
        };
        assert_eq!(first_valid(&mut holders, 7, read, &mut stale), Some((420, 500, 40)));
        assert_eq!(stale, vec![(200, 3), (300, 5)]);
        assert_eq!(holders, vec![(420, 12)]);
        let mut none = vec![(1, 1)];
        assert_eq!(first_valid(&mut none, 7, |_, _| None, &mut stale), None);
        assert!(none.is_empty());
    }
}
