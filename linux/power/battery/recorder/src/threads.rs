//! Wake-ups per unit, for the screen-off model (DESIGN.md section 2 "wk", section 5): the sum over a unit's threads of
//! voluntary_ctxt_switches + nonvoluntary_ctxt_switches (/proc/<pid>/task/<tid>/status) since the last scan. A thread
//! that sleeps and is woken switches out voluntarily once per wake-up, so the growth is a wake-up count.
//!   - Only at the screen-off edge, the screen-off checkpoints and the screen-on edge: a scan opens one status file per
//!     thread (about 1100 threads here, DESIGN.md section 11b), 20-45 us each; status files cannot be kept open.
//!   - A thread new since the last scan (or a tid reused with a lower count) counts whole: it was born in the interval.
//!     A thread that exited takes its last interval with it (no exit hook without root): wk is a lower bound.
//!   - Kernel threads (cgroup "/", where only kthreadd's children live) are summed under "-k"; every other process
//!     counts for its cgroup unit (units.resolve). Other users' threads are readable too (status is world-readable).
use std::collections::HashMap;
use std::fs;
use std::path::Path;

use crate::fds;
use crate::units::{self, Units};

/// the unit code of kernel threads in a scan ("-k" in the ledger); unit ids start at 1
pub const KERNEL: u32 = 0;

/// voluntary + nonvoluntary context switches of a status text
pub fn parse_ctxt(b: &[u8]) -> Option<u64> {
    let t = String::from_utf8_lossy(b);
    let (mut v, mut n) = (None, None);
    for l in t.lines() {
        if let Some(r) = l.strip_prefix("voluntary_ctxt_switches:") {
            v = r.trim().parse::<u64>().ok();
        } else if let Some(r) = l.strip_prefix("nonvoluntary_ctxt_switches:") {
            n = r.trim().parse::<u64>().ok();
        }
    }
    Some(v?.saturating_add(n?))
}

/// per unit code, the switches since `prev` (tid -> count) of the threads in `cur` (tid -> (count, unit code)),
/// sorted by unit id with "-k" last
pub fn deltas(prev: &HashMap<i32, u64>, cur: &HashMap<i32, (u64, u32)>) -> Vec<(String, u64)> {
    let mut sum: HashMap<u32, u64> = HashMap::new();
    for (tid, &(n, k)) in cur {
        let d = match prev.get(tid) {
            Some(&p) if n >= p => n - p,
            _ => n,
        };
        if d > 0 {
            let e = sum.entry(k).or_insert(0);
            *e = e.saturating_add(d);
        }
    }
    let mut v: Vec<(u32, u64)> = sum.into_iter().collect();
    v.sort_by_key(|&(k, _)| (k == KERNEL, k));
    v.into_iter().map(|(k, n)| (if k == KERNEL { "-k".to_string() } else { k.to_string() }, n)).collect()
}

pub struct Threads {
    prev: HashMap<i32, u64>,
    primed: bool,
    buf: Vec<u8>,
    pub count: usize, // threads read by the last scan
}

impl Threads {
    pub fn new() -> Threads {
        Threads { prev: HashMap::new(), primed: false, buf: Vec::with_capacity(2048), count: 0 }
    }

    /// one scan of every thread; None the first time (the baseline), else the switches per unit since the last scan
    pub fn scan(&mut self, units: &Units) -> Option<Vec<(String, u64)>> {
        let mut cur: HashMap<i32, (u64, u32)> = HashMap::with_capacity(self.prev.len().max(1024));
        for pid in fds::list_pids() {
            if fds::read_into(Path::new(&format!("/proc/{pid}/cgroup")), &mut self.buf).is_err() {
                continue; // exited
            }
            let code = match units::cg_path(&String::from_utf8_lossy(&self.buf)) {
                Some(cg) if cg == "/" => KERNEL,
                Some(cg) => match units.resolve(&cg) {
                    Some(id) => id,
                    None => continue,
                },
                None => continue,
            };
            let Ok(rd) = fs::read_dir(format!("/proc/{pid}/task")) else { continue };
            for e in rd.flatten() {
                let Some(tid) = e.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) else { continue };
                if fds::read_into(&e.path().join("status"), &mut self.buf).is_err() {
                    continue;
                }
                if let Some(n) = parse_ctxt(&self.buf) {
                    cur.insert(tid, (n, code));
                }
            }
        }
        self.count = cur.len();
        let out = if self.primed { Some(deltas(&self.prev, &cur)) } else { None };
        self.prev = cur.into_iter().map(|(t, (n, _))| (t, n)).collect();
        self.primed = true;
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status() {
        let s = b"Name:\tkworker/u16:3\nState:\tI (idle)\nTgid:\t812\nThreads:\t1\nvoluntary_ctxt_switches:\t28130\n\
                  nonvoluntary_ctxt_switches:\t17\n";
        assert_eq!(parse_ctxt(s), Some(28147));
        assert_eq!(parse_ctxt(b"Name:\tx\nvoluntary_ctxt_switches:\t5\n"), None);
        assert_eq!(parse_ctxt(b""), None);
    }

    #[test]
    fn per_unit() {
        let prev: HashMap<i32, u64> = [(10, 100), (11, 50), (12, 900), (13, 7)].into_iter().collect();
        let cur: HashMap<i32, (u64, u32)> = [
            (10, (130, 17)), // +30
            (11, (50, 17)),  // +0
            (12, (40, 2)),   // tid reused (count went down): whole 40
            (14, (5, 17)),   // new thread: whole 5
            (20, (1000, KERNEL)),
            (21, (4, 1)),
        ]
        .into_iter()
        .collect(); // 13 exited: lost
        assert_eq!(
            deltas(&prev, &cur),
            vec![("1".to_string(), 4), ("2".to_string(), 40), ("17".to_string(), 35), ("-k".to_string(), 1000)]
        );
        assert!(deltas(&prev, &HashMap::new()).is_empty());
    }
}
