//! The unit table: which cgroups are tracked, their ledger keys and ids, and their CPU time (cpu.stat usage_usec)
//! through one kept-open fd each.
//!
//! Tracked (DESIGN.md section 2 "单元表"): the root cgroup (id 1); the top-level /system.slice, /user.slice and
//! /init.scope (root minus these three = kernel threads and interrupts, the report's "内核与中断"); every .service and
//! .scope under system.slice (through its sub-slices); our uid's login sessions; under user@<uid>.service the three
//! slices app/session/background (app.slice minus its known children = "已关闭的程序") and every .service/.scope
//! below them, plus the manager's own init.scope. A unit's cpu.stat already contains its sub-cgroups (rstat), so
//! nothing below a .service/.scope is tracked: a process in a nested cgroup counts for the outermost unit above it.
//!
//! Keys (the "p" of a U line): "/" root, "/system.slice", "/user.slice", "/init.scope" (raw top-level paths);
//! "s/<path below system.slice>", "u/<path below user@<uid>.service>", "l/session-N.scope". KWin
//! (u/session.slice/plasma-kwin_wayland.service) gets id 2 the first time it is seen, everything else 3, 4, ... in
//! order of discovery. A unit is (key, inode of its cgroup directory = the cgroup id): the same name made again (an
//! app restarted, a service restarted) has a new inode and gets a new id, so a delta never spans two instances.
//! A unit that is gone - or whose cpu.stat read fails with ENODEV (the cgroup is being destroyed) - is dropped with
//! its fd at once, so the recorder never pins a dying cgroup.
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io;
use std::os::unix::fs::{DirEntryExt, MetadataExt};
use std::path::{Path, PathBuf};

use crate::fds;

pub const ROOT_ID: u32 = 1;
pub const KWIN_ID: u32 = 2;
pub const KWIN_KEY: &str = "u/session.slice/plasma-kwin_wayland.service";
pub const USER_SLICES: [&str; 3] = ["app.slice", "session.slice", "background.slice"];
const TOP: [&str; 3] = ["system.slice", "user.slice", "init.scope"];
const MAX_DEPTH: usize = 6; // slices in slices; systemd nests two or three deep

pub fn is_unit(name: &str) -> bool {
    name.ends_with(".service") || name.ends_with(".scope")
}

/// the path of the "0::" line of /proc/<pid>/cgroup (cgroup v2)
pub fn cg_path(text: &str) -> Option<String> {
    text.lines().find_map(|l| l.strip_prefix("0::")).map(|p| p.trim().to_string())
}

fn tail<'a>(c: &'a [&'a str], i: usize) -> &'a [&'a str] {
    c.get(i..).unwrap_or(&[])
}

/// "a/b.service/c" -> "a/b.service": up to the first .service/.scope component
fn outer(rest: &[&str]) -> Option<String> {
    let i = rest.iter().position(|c| is_unit(c))?;
    rest.get(..=i).map(|v| v.join("/"))
}

/// the key of the tracked unit a cgroup (a /proc/<pid>/cgroup path, or a directory below the cgroup root) belongs to
pub fn cgroup_key(path: &str, uid: u32) -> String {
    let c: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    match c.first().copied() {
        None => "/".to_string(),
        Some("system.slice") => match outer(tail(&c, 1)) {
            Some(u) => format!("s/{u}"),
            None => "/system.slice".to_string(),
        },
        Some("init.scope") => "/init.scope".to_string(),
        Some("user.slice") => {
            let us = format!("user-{uid}.slice");
            let mgr = format!("user@{uid}.service");
            if c.get(1).copied() != Some(us.as_str()) {
                return "/user.slice".to_string(); // another user's sessions: only in the slice total
            }
            match c.get(2).copied() {
                Some(m) if m == mgr => {
                    let r = tail(&c, 3);
                    if let Some(u) = outer(r) {
                        format!("u/{u}")
                    } else if let Some(s) = r.first().copied().filter(|s| USER_SLICES.contains(s)) {
                        format!("u/{s}")
                    } else {
                        "/user.slice".to_string()
                    }
                }
                Some(s) if s.starts_with("session-") && s.ends_with(".scope") => format!("l/{s}"),
                _ => "/user.slice".to_string(),
            }
        }
        Some(_) => "/".to_string(),
    }
}

/// coarser keys to try, in order, when a cgroup's own unit is not in the table (it appeared after the last scan):
/// its user slice, the top-level slice, the root
pub fn fallbacks(key: &str) -> Vec<String> {
    let mut v = vec![];
    if let Some(r) = key.strip_prefix("u/") {
        if let Some(s) = r.split('/').next() {
            if r != s && USER_SLICES.contains(&s) {
                v.push(format!("u/{s}"));
            }
        }
        v.push("/user.slice".to_string());
    } else if key.starts_with("l/") {
        v.push("/user.slice".to_string());
    } else if key.starts_with("s/") {
        v.push("/system.slice".to_string());
    }
    if key != "/" {
        v.push("/".to_string());
    }
    v
}

/// usage_usec of a cpu.stat text
pub fn parse_usage(b: &[u8]) -> Option<u64> {
    let t = std::str::from_utf8(b).ok()?;
    t.lines().find_map(|l| l.strip_prefix("usage_usec ").and_then(|v| v.trim().parse::<u64>().ok()))
}

pub struct Unit {
    pub id: u32,
    pub ino: u64,
    dir: PathBuf,
    fd: Option<File>,
    pub usage: Option<u64>, // usage_usec at the last read, None when it could not be read
    pub announced: bool,    // a U line for it was written (this process); before that it is not in the ledger
}

/// one row of the table for writing it out, sorted by id
pub struct Row {
    pub id: u32,
    pub key: String,
    pub ino: u64,
    pub usage: Option<u64>,
    pub announced: bool,
}

pub struct Found {
    pub key: String,
    pub ino: u64,
    pub dir: PathBuf,
}

pub struct Units {
    root: PathBuf,
    uid: u32,
    pub live: HashMap<String, Unit>,
    next_id: u32,
    reserved: HashSet<u32>, // ROOT_ID / KWIN_ID once handed out
    pub gone: Vec<u32>,     // announced units gone since the last S written
    buf: Vec<u8>,
}

impl Units {
    pub fn new(root: &Path, uid: u32) -> Units {
        Units {
            root: root.to_path_buf(),
            uid,
            live: HashMap::new(),
            next_id: 3,
            reserved: HashSet::new(),
            gone: vec![],
            buf: Vec::with_capacity(4096),
        }
    }

    /// list the cgroups, update the table, read every live unit's cpu.stat
    pub fn refresh(&mut self) {
        let f = self.scan();
        self.apply(f);
        self.read_all();
    }

    pub fn scan(&self) -> Vec<Found> {
        let mut out = vec![];
        if let Ok(m) = fs::metadata(&self.root) {
            out.push(Found { key: "/".to_string(), ino: m.ino(), dir: self.root.clone() });
        }
        for t in TOP {
            let d = self.root.join(t);
            if let Ok(m) = fs::metadata(&d) {
                if m.is_dir() {
                    out.push(Found { key: format!("/{t}"), ino: m.ino(), dir: d });
                }
            }
        }
        walk(&self.root.join("system.slice"), "s/", 0, &mut out);
        let us = self.root.join("user.slice").join(format!("user-{}.slice", self.uid));
        if let Ok(rd) = fs::read_dir(&us) {
            for e in rd.flatten() {
                let n = e.file_name().to_string_lossy().into_owned();
                if n.starts_with("session-") && n.ends_with(".scope") && e.file_type().map_or(false, |t| t.is_dir()) {
                    out.push(Found { key: format!("l/{n}"), ino: e.ino(), dir: e.path() });
                }
            }
        }
        let mgr = us.join(format!("user@{}.service", self.uid));
        for s in USER_SLICES {
            let d = mgr.join(s);
            if let Ok(m) = fs::metadata(&d) {
                out.push(Found { key: format!("u/{s}"), ino: m.ino(), dir: d });
            }
        }
        walk(&mgr, "u/", 0, &mut out);
        out
    }

    /// a scan's result against the table: same key and inode = the same unit; a new inode under a known key = the old
    /// one is gone and a new one starts; keys not found any more are gone
    pub fn apply(&mut self, found: Vec<Found>) {
        let mut seen: HashSet<String> = HashSet::with_capacity(found.len());
        for f in found {
            if !seen.insert(f.key.clone()) {
                continue; // the same key twice cannot happen; the first wins
            }
            match self.live.get(&f.key).map(|u| u.ino == f.ino) {
                Some(true) => continue,
                Some(false) => self.retire(&f.key),
                None => {}
            }
            let id = self.take_id(&f.key);
            self.live.insert(f.key, Unit { id, ino: f.ino, dir: f.dir, fd: None, usage: None, announced: false });
        }
        let gone: Vec<String> = self.live.keys().filter(|k| !seen.contains(*k)).cloned().collect();
        for k in gone {
            self.retire(&k);
        }
    }

    fn take_id(&mut self, key: &str) -> u32 {
        let reserved = if key == "/" {
            Some(ROOT_ID)
        } else if key == KWIN_KEY {
            Some(KWIN_ID)
        } else {
            None
        };
        if let Some(r) = reserved {
            if self.reserved.insert(r) {
                return r;
            }
        }
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);
        id
    }

    /// drop a unit and its fd; one the ledger never heard of (no U line yet) leaves no trace
    fn retire(&mut self, key: &str) {
        if let Some(u) = self.live.remove(key) {
            if u.announced {
                self.gone.push(u.id);
            }
        }
    }

    /// a failed open/read of a unit's cpu.stat: the fd is closed (opened again next time); ENODEV/ENOENT mean the
    /// cgroup is going or gone, and the unit goes with it
    pub fn failed(&mut self, key: &str, e: &io::Error) {
        if let Some(u) = self.live.get_mut(key) {
            u.fd = None;
            u.usage = None;
        }
        if matches!(e.raw_os_error(), Some(libc::ENODEV) | Some(libc::ENOENT)) {
            self.retire(key);
        }
    }

    pub fn read_all(&mut self) {
        let mut errs: Vec<(String, io::Error)> = vec![];
        for (k, u) in self.live.iter_mut() {
            if u.fd.is_none() {
                match File::open(u.dir.join("cpu.stat")) {
                    Ok(f) => u.fd = Some(f),
                    Err(e) => {
                        errs.push((k.clone(), e));
                        continue;
                    }
                }
            }
            let r = match &u.fd {
                Some(f) => fds::pread_all(f, &mut self.buf),
                None => continue,
            };
            match r {
                Ok(_) => u.usage = parse_usage(&self.buf),
                Err(e) => errs.push((k.clone(), e)),
            }
        }
        for (k, e) in errs {
            self.failed(&k, &e);
        }
    }

    pub fn id_of(&self, key: &str) -> Option<u32> {
        self.live.get(key).map(|u| u.id)
    }

    /// the id a process in this cgroup counts for: its unit, else the nearest coarser tracked one
    pub fn resolve(&self, cgroup: &str) -> Option<u32> {
        let k = cgroup_key(cgroup, self.uid);
        if let Some(id) = self.id_of(&k) {
            return Some(id);
        }
        fallbacks(&k).iter().find_map(|f| self.id_of(f))
    }

    pub fn dir_of(&self, key: &str) -> Option<&Path> {
        self.live.get(key).map(|u| u.dir.as_path())
    }

    pub fn rows(&self) -> Vec<Row> {
        let mut v: Vec<Row> = self
            .live
            .iter()
            .map(|(k, u)| Row { id: u.id, key: k.clone(), ino: u.ino, usage: u.usage, announced: u.announced })
            .collect();
        v.sort_by_key(|r| r.id);
        v
    }

    /// after an S was written: every live unit is in the ledger now
    pub fn mark_announced(&mut self) {
        for u in self.live.values_mut() {
            u.announced = true;
        }
        self.gone.clear();
    }

    pub fn live_ids(&self) -> HashSet<u32> {
        self.live.values().map(|u| u.id).collect()
    }
}

/// the .service/.scope cgroups below dir, through .slice cgroups only
fn walk(dir: &Path, prefix: &str, depth: usize, out: &mut Vec<Found>) {
    if depth > MAX_DEPTH {
        return;
    }
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        if !e.file_type().map_or(false, |t| t.is_dir()) {
            continue;
        }
        let n = e.file_name().to_string_lossy().into_owned();
        if is_unit(&n) {
            // d_ino of a cgroupfs (kernfs) entry is the cgroup's inode: no stat() per unit
            out.push(Found { key: format!("{prefix}{n}"), ino: e.ino(), dir: e.path() });
        } else if n.ends_with(".slice") {
            walk(&e.path(), &format!("{prefix}{n}/"), depth + 1, out);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const UU: &str = "/user.slice/user-1000.slice/user@1000.service";

    #[test]
    fn keys() {
        let k = |p: &str| cgroup_key(p, 1000);
        assert_eq!(k("/"), "/");
        assert_eq!(k(""), "/");
        assert_eq!(k("/init.scope"), "/init.scope");
        assert_eq!(k("/system.slice"), "/system.slice");
        assert_eq!(k("/system.slice/y700-flightrec.service"), "s/y700-flightrec.service");
        assert_eq!(k("/system.slice/system-getty.slice/getty@tty1.service"), "s/system-getty.slice/getty@tty1.service");
        assert_eq!(k("/system.slice/system-getty.slice"), "/system.slice");
        assert_eq!(k("/user.slice/user-1000.slice/session-3.scope"), "l/session-3.scope");
        assert_eq!(k("/user.slice/user-0.slice/session-9.scope"), "/user.slice");
        assert_eq!(k("/user.slice/user-1000.slice"), "/user.slice");
        assert_eq!(k(&format!("{UU}/session.slice/plasma-kwin_wayland.service")), KWIN_KEY);
        assert_eq!(k(&format!("{UU}/init.scope")), "u/init.scope");
        assert_eq!(k(&format!("{UU}/app.slice")), "u/app.slice");
        assert_eq!(
            k(&format!("{UU}/app.slice/app-com.anthropic.Claude-16803.scope")),
            "u/app.slice/app-com.anthropic.Claude-16803.scope"
        );
        // nested sub-cgroups count for the outermost .scope/.service above them
        assert_eq!(k(&format!("{UU}/app.slice/app-steam-arm64.service/sub/deeper")), "u/app.slice/app-steam-arm64.service");
        assert_eq!(
            k(&format!("{UU}/app.slice/app-flatpak-org.telegram.desktop-4120.scope/tray.scope")),
            "u/app.slice/app-flatpak-org.telegram.desktop-4120.scope"
        );
        assert_eq!(k(&format!("{UU}/app.slice/app-geoclue\\x2ddemo\\x2dagent@autostart.service")),
            "u/app.slice/app-geoclue\\x2ddemo\\x2dagent@autostart.service");
        assert_eq!(k("/machine.slice/x.scope"), "/");
        assert_eq!(cg_path("0::/user.slice/user-1000.slice/session-3.scope\n"), Some("/user.slice/user-1000.slice/session-3.scope".into()));
        assert_eq!(cg_path("0::/\n"), Some("/".into()));
        assert_eq!(cg_path("1:name=x:/\n"), None);
    }

    #[test]
    fn fallback_chain() {
        assert_eq!(fallbacks("u/app.slice/app-x.scope"), vec!["u/app.slice", "/user.slice", "/"]);
        assert_eq!(fallbacks("u/init.scope"), vec!["/user.slice", "/"]);
        assert_eq!(fallbacks("u/app.slice"), vec!["/user.slice", "/"]);
        assert_eq!(fallbacks("l/session-3.scope"), vec!["/user.slice", "/"]);
        assert_eq!(fallbacks("s/foo.service"), vec!["/system.slice", "/"]);
        assert_eq!(fallbacks("/"), Vec::<String>::new());
    }

    #[test]
    fn cpu_stat() {
        let t = b"usage_usec 61231000\nuser_usec 40000000\nsystem_usec 21231000\nnr_periods 0\n";
        assert_eq!(parse_usage(t), Some(61231000));
        assert_eq!(parse_usage(b"user_usec 5\n"), None);
        assert_eq!(parse_usage(b"usage_usec x\n"), None);
    }

    fn found(key: &str, ino: u64) -> Found {
        Found { key: key.to_string(), ino, dir: PathBuf::from("/nonexistent") }
    }

    #[test]
    fn ids_and_inodes() {
        let mut u = Units::new(Path::new("/nonexistent"), 1000);
        u.apply(vec![found("/", 1), found("u/app.slice/a.scope", 100), found(KWIN_KEY, 50)]);
        assert_eq!(u.id_of("/"), Some(ROOT_ID));
        assert_eq!(u.id_of(KWIN_KEY), Some(KWIN_ID));
        assert_eq!(u.id_of("u/app.slice/a.scope"), Some(3));
        u.mark_announced();
        // a.scope made again (new inode): a new id, the old one gone; KWin restarted: a new id too (2 is used up)
        u.apply(vec![found("/", 1), found("u/app.slice/a.scope", 101), found(KWIN_KEY, 51)]);
        assert_eq!(u.id_of("u/app.slice/a.scope"), Some(4));
        assert_eq!(u.id_of(KWIN_KEY), Some(5));
        let mut g = u.gone.clone();
        g.sort();
        assert_eq!(g, vec![KWIN_ID, 3]);
        u.mark_announced();
        // the same inode again: nothing changes
        u.apply(vec![found("/", 1), found("u/app.slice/a.scope", 101), found(KWIN_KEY, 51)]);
        assert!(u.gone.is_empty());
        assert_eq!(u.id_of("u/app.slice/a.scope"), Some(4));
        // a unit seen once and gone before it was ever written leaves no "gone"
        u.apply(vec![found("/", 1), found("u/app.slice/a.scope", 101), found(KWIN_KEY, 51), found("s/b.service", 7)]);
        u.apply(vec![found("/", 1), found("u/app.slice/a.scope", 101), found(KWIN_KEY, 51)]);
        assert!(u.gone.is_empty());
        // a unit not found any more is gone
        u.apply(vec![found("/", 1), found(KWIN_KEY, 51)]);
        assert_eq!(u.gone, vec![4]);
        assert_eq!(u.resolve("/user.slice/user-1000.slice/user@1000.service/app.slice/a.scope"), Some(ROOT_ID));
    }

    #[test]
    fn enodev_closes_and_drops() {
        let mut u = Units::new(Path::new("/nonexistent"), 1000);
        u.apply(vec![found("/", 1), found("s/x.service", 9), found("s/y.service", 10)]);
        u.mark_announced();
        for k in ["s/x.service", "s/y.service"] {
            if let Some(un) = u.live.get_mut(k) {
                un.fd = File::open("/dev/null").ok();
                un.usage = Some(5);
            }
        }
        // EACCES: the fd is closed, the unit stays
        u.failed("s/y.service", &io::Error::from_raw_os_error(libc::EACCES));
        assert!(u.live.get("s/y.service").map_or(false, |x| x.fd.is_none() && x.usage.is_none()));
        // ENODEV: the cgroup is being destroyed - fd closed with the unit, which is gone
        let id = u.id_of("s/x.service");
        u.failed("s/x.service", &io::Error::from_raw_os_error(libc::ENODEV));
        assert!(u.live.get("s/x.service").is_none());
        assert_eq!(u.gone, vec![id.unwrap_or(0)]);
        // a missing cgroup directory: read_all drops it (ENOENT on open)
        u.read_all();
        assert!(u.live.get("s/y.service").is_none());
    }

    #[test]
    fn resolve_falls_back() {
        let mut u = Units::new(Path::new("/nonexistent"), 1000);
        u.apply(vec![found("/", 1), found("/user.slice", 2), found("u/app.slice", 3), found("/system.slice", 4)]);
        let app = u.id_of("u/app.slice");
        assert_eq!(u.resolve(&format!("{UU}/app.slice/new-app.scope")), app);
        assert_eq!(u.resolve("/system.slice/new.service"), u.id_of("/system.slice"));
        assert_eq!(u.resolve("/user.slice/user-1000.slice/session-4.scope"), u.id_of("/user.slice"));
        assert_eq!(u.resolve("/"), Some(ROOT_ID));
    }
}
