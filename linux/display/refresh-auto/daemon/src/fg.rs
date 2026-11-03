//! Foreground log for the battery page (linux/power/battery/DESIGN.md section 3). Lines, appended to
//! FG_DIR/fg-<boot8>.log (boot8 = the first 8 hex chars of the boot id), one write() each:
//!   <mono> <pid> <covers> <new_usage> <prev_usage> <cgroup> <class>   one per window report (KWin script)
//!   <mono> START                                                       the daemon started (before the first report)
//!   <mono> STOP                                                        SIGTERM / SIGINT (or a bus gone)
//! mono = CLOCK_MONOTONIC in s, 2 decimals (the clock of flightrec's t= and the journal's __MONOTONIC_TIMESTAMP);
//! covers 1/0; new_usage = usage_usec of the new foreground unit's cpu.stat, prev_usage = that of the previous foreground
//! unit at this moment; cgroup = the new unit's cgroup path; '-' for whatever could not be read (window closed, process
//! gone: cgroup and new_usage; no previous unit after START, or it is gone: prev_usage). class comes last and may contain
//! spaces or be empty (the line then ends in a space): readers split each \n-terminated line with split(" ", 6).
//! A crash or SIGKILL leaves no STOP: the report cuts at the end of the y700-refresh-auto.service unit instead.
//! A line cut short (SIGKILL between two pages of a write; a short write whose fragment could not be cut off again) is
//! ended with a \n by the next append, batteryd's rule for its ledger (DESIGN.md section 2): readers drop lines that do
//! not parse (one cut inside its class still does, the class truncated) and a last line without its \n (the live part
//! while a write is in flight; a numbered part when the file was rotated right after the cut).
//! Parts: fg-<boot8>.log is always the live, newest part. Before it would pass FG_MAX it is renamed to fg-<boot8>.<n>.log
//! with n = the highest there + 1, so numbered parts run oldest first: a boot reads .1, .2, ..., then the unnumbered file
//! (prev_usage pairs across a part boundary as within a file). Cleanup goes in that order, never the current boot's
//! unnumbered file.
//! Ported line for line from the Python daemon (its test bed test-log-fg.py is the tests below).

use std::fs;
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;

pub const FG_MAX: u64 = 1 << 20;
/// Everything Python's str.splitlines() splits on: never inside a field.
const FG_BREAKS: [char; 10] = ['\n', '\r', '\u{b}', '\u{c}', '\u{1c}', '\u{1d}', '\u{1e}', '\u{85}', '\u{2028}', '\u{2029}'];

pub struct Fg {
    pub dir: PathBuf,
    pub proc: String,
    pub cgroup: String,
    /// cgroup of the last foreground unit (the next line's prev_usage)
    unit: Option<String>,
    /// boot8, read once
    boot: Option<String>,
    /// failures; only the first is logged, the status shows the count
    pub errors: u64,
}

impl Fg {
    /// The state dir is ~/.local/state unless XDG_STATE_HOME (absolute) says otherwise; y700-batteryd and the report
    /// resolve it alike.
    pub fn new(home: &str) -> Fg {
        let xdg = std::env::var("XDG_STATE_HOME").unwrap_or_default();
        let state = if xdg.starts_with('/') { PathBuf::from(xdg) } else { PathBuf::from(home).join(".local/state") };
        Fg::at(state.join("y700-battery"), "/proc", "/sys/fs/cgroup")
    }

    pub fn at(dir: PathBuf, proc: &str, cgroup: &str) -> Fg {
        Fg { dir, proc: proc.into(), cgroup: cgroup.into(), unit: None, boot: None, errors: 0 }
    }

    /// One line per window report. Never fails: it runs after the decision and a failure must not leak into the
    /// refresh-rate side. No directory: nothing is read or written at all.
    pub fn log(&mut self, mono: f64, cls: &str, covers: bool, pid: i64) {
        // unit is that of the line written last, so prev_usage always belongs to the line before it in the file: it is
        // cleared first and set again only once this line is written (a failed write leaves no stale pairing).
        let prev_unit = self.unit.take();
        if !self.dir.is_dir() {
            return;
        }
        let unit = unit_of(&self.proc, pid);
        let new = usage_of(&self.cgroup, unit.as_deref());
        let prev = if unit.is_some() && unit == prev_unit { new } else { usage_of(&self.cgroup, prev_unit.as_deref()) };
        match self.write(&fg_line(mono, pid, covers, unit.as_deref(), new, prev, cls)) {
            Ok(true) => self.unit = unit,
            Ok(false) => {}
            Err(e) => self.failed(e),
        }
    }

    /// "<mono> START" / "<mono> STOP": the report cuts the foreground time at the daemon's start and stop.
    pub fn mark(&mut self, mono: f64, what: &str) {
        self.unit = None; // no previous foreground across a start or stop
        if !self.dir.is_dir() {
            return;
        }
        if let Err(e) = self.write(&format!("{mono:.2} {what}\n")) {
            self.failed(e);
        }
    }

    /// Ok(true) once the line is in the file.
    fn write(&mut self, line: &str) -> io::Result<bool> {
        if self.boot.is_none() {
            self.boot = boot8(&self.proc);
            if self.boot.is_none() {
                return Err(io::Error::other(format!("no boot id in {}/sys/kernel/random/boot_id", self.proc)));
            }
        }
        fg_append(&self.dir, self.boot.as_deref().unwrap(), line.as_bytes())
    }

    fn failed(&mut self, e: io::Error) {
        self.errors += 1;
        if self.errors == 1 {
            // RUST: the error's text where Python logged its traceback
            crate::say(&format!("foreground log failed (only the first failure is logged, status fg_log_errors counts them):\n{e}"));
        }
    }
}

/// One read() of a small kernel file from offset 0 (open, read, close: no buffering, no fd kept open that would pin a
/// dying cgroup).
fn read_small(path: &str) -> io::Result<String> {
    let mut f = fs::File::open(path)?;
    let mut b = vec![0u8; 4096];
    let n = f.read(&mut b)?;
    Ok(String::from_utf8_lossy(&b[..n]).into_owned())
}

/// First 8 hex chars of the boot id (the log's name), None if unreadable.
fn boot8(proc: &str) -> Option<String> {
    let b: String = read_small(&format!("{proc}/sys/kernel/random/boot_id")).ok()?.trim().chars().take(8).collect();
    (b.len() == 8 && b.bytes().all(|c| matches!(c, b'0'..=b'9' | b'a'..=b'f'))).then_some(b)
}

/// Python's str.splitlines(): the lines without their breaks (\r\n counts as one).
fn splitlines(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut it = s.char_indices().peekable();
    while let Some((i, c)) = it.next() {
        if FG_BREAKS.contains(&c) {
            out.push(&s[start..i]);
            start = i + c.len_utf8();
            if c == '\r' && it.peek().map(|p| p.1) == Some('\n') {
                it.next();
                start += 1;
            }
        }
    }
    if start < s.len() {
        out.push(&s[start..]);
    }
    out
}

/// The cgroup path of pid's unit: the 0:: line of /proc/<pid>/cgroup walked up from the leaf to the first .scope or
/// .service (a process in a nested cgroup belongs to the unit above it); None if unreadable (window closed, process
/// gone) or pid is 0 (no window).
fn unit_of(proc: &str, pid: i64) -> Option<String> {
    if pid <= 0 {
        return None;
    }
    let text = read_small(&format!("{proc}/{pid}/cgroup")).ok()?;
    let line = splitlines(&text).into_iter().find(|l| l.starts_with("0::"))?; // v1 hierarchies on a hybrid system first
    let path = &line[3..];
    let path = path.strip_suffix(" (deleted)").unwrap_or(path); // the process outlived its cgroup: the name still says whose
    let parts: Vec<&str> = path.split('/').collect();
    for i in (1..parts.len()).rev() {
        if parts[i].ends_with(".scope") || parts[i].ends_with(".service") {
            return Some(parts[..=i].join("/"));
        }
    }
    (!path.is_empty()).then(|| path.to_string()) // no unit above (the root, a bare slice): the leaf itself
}

/// usage_usec of the unit's cpu.stat, None if there is no unit or it is gone (ENOENT / ENODEV).
fn usage_of(cgroup: &str, unit: Option<&str>) -> Option<i64> {
    let unit = unit.filter(|u| !u.is_empty())?;
    let text = read_small(&format!("{cgroup}{}/cpu.stat", unit.trim_end_matches('/'))).ok()?;
    for line in splitlines(&text) {
        let (k, v) = line.split_once(' ').unwrap_or((line, ""));
        if k == "usage_usec" {
            return v.trim().parse().ok();
        }
    }
    None
}

/// Python's str.isspace(), which also counts the separators \x1c-\x1f.
pub(crate) fn py_isspace(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// A cgroup path as one field: whitespace as \xNN per UTF-8 byte (systemd's own escaping, so the report's unit-name
/// unescape covers it), '-' if unknown. Unit names never contain any; a hand-made nested cgroup might.
pub fn fg_esc(path: Option<&str>) -> String {
    let Some(path) = path.filter(|p| !p.is_empty()) else { return "-".into() };
    let mut out = String::new();
    for c in path.chars() {
        if py_isspace(c) || FG_BREAKS.contains(&c) {
            for b in c.to_string().bytes() {
                out.push_str(&format!("\\x{b:02x}"));
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// One report line (format above); a line break in the class would split the record, so it becomes a space.
pub fn fg_line(mono: f64, pid: i64, covers: bool, unit: Option<&str>, new: Option<i64>, prev: Option<i64>, cls: &str) -> String {
    let cls: String = cls.chars().map(|c| if FG_BREAKS.contains(&c) { ' ' } else { c }).collect();
    let n = |v: Option<i64>| v.map_or("-".to_string(), |v| v.to_string());
    format!("{mono:.2} {pid} {} {} {} {} {cls}\n", covers as u8, n(new), n(prev), fg_esc(unit))
}

/// n for the next fg-<boot>.<n>.log: one more than the highest there (parts count up from 1, oldest first; the
/// unnumbered file is always the newest part).
fn fg_next_part(dir: &PathBuf, boot: &str) -> io::Result<u64> {
    let pre = format!("fg-{boot}.");
    let mut n = 0;
    for e in fs::read_dir(dir)? {
        let name = e?.file_name();
        let Some(f) = name.to_str() else { continue };
        if f.starts_with(&pre) && f.ends_with(".log") && f.len() >= pre.len() + 4 {
            let mid = &f[pre.len()..f.len() - 4];
            if !mid.is_empty() && mid.bytes().all(|b| b.is_ascii_digit()) {
                n = n.max(mid.parse::<u64>().unwrap_or(u64::MAX - 1)); // shortcut: a part number past u64 counts as the last
            }
        }
    }
    Ok(n + 1)
}

/// (size, head) of the open log: head is a newline when the file ends in a line cut short, written before the next line
/// so that the two never run together.
fn fg_tail(f: &fs::File) -> io::Result<(u64, &'static [u8])> {
    let size = f.metadata()?.len();
    if size == 0 {
        return Ok((0, b""));
    }
    let mut last = [0u8; 1];
    let n = unsafe { libc::pread(f.as_raw_fd(), last.as_mut_ptr().cast(), 1, (size - 1) as libc::off_t) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((size, if n == 1 && last[0] == b'\n' { b"" } else { b"\n" }))
}

fn open_log(path: &PathBuf) -> io::Result<fs::File> {
    // read: fg_tail reads the last byte back
    fs::OpenOptions::new().read(true).append(true).create(true).mode(0o600).open(path)
}

/// Append data (whole lines) to fg-<boot>.log with one write(): open, append, close; no fsync, the page cache writes it
/// back. Before the file would pass FG_MAX it is renamed to the next numbered part. A short write (ENOSPC partway
/// through a line) is cut off again and returned as an error; should that fail too, the next append ends the fragment.
/// The directory vanishing after the caller's check (the feature turned off) is not an error: Ok(false), nothing
/// written.
pub fn fg_append(dir: &PathBuf, boot: &str, data: &[u8]) -> io::Result<bool> {
    let path = dir.join(format!("fg-{boot}.log"));
    let mut f = match open_log(&path) {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(e),
    };
    let (mut size, mut head) = fg_tail(&f)?;
    if size > 0 && size + (head.len() + data.len()) as u64 > FG_MAX {
        drop(f);
        fs::rename(&path, dir.join(format!("fg-{boot}.{}.log", fg_next_part(dir, boot)?)))?;
        f = open_log(&path)?;
        (size, head) = fg_tail(&f)?; // empty: a cut line stays the old part's last line, without its \n
    }
    let all = [head, data].concat();
    let n = write_once(&f, &all)?;
    if n != all.len() {
        truncate(&f, size)?; // one writer (the bus name) and O_APPEND: this write began at size
        return Err(io::Error::other(format!("short write to {}: {n} of {} bytes, cut off again", path.display(), all.len())));
    }
    Ok(true)
}

fn write_once(f: &fs::File, b: &[u8]) -> io::Result<usize> {
    #[cfg(test)]
    if let Some(n) = tests::SHORT.with(|s| s.get()) {
        let n = if n == 0 { b.len() / 2 } else { n };
        return write_once_real(f, &b[..n]);
    }
    write_once_real(f, b)
}

fn write_once_real(f: &fs::File, b: &[u8]) -> io::Result<usize> {
    let n = unsafe { libc::write(f.as_raw_fd(), b.as_ptr().cast(), b.len()) };
    if n < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(n as usize)
    }
}

fn truncate(f: &fs::File, size: u64) -> io::Result<()> {
    #[cfg(test)]
    if tests::TRUNC_EIO.with(|t| t.get()) {
        return Err(io::Error::from_raw_os_error(libc::EIO));
    }
    f.set_len(size)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::cell::Cell;

    thread_local! {
        /// write() lands only this many bytes (0: half), like ENOSPC partway through a line
        pub static SHORT: Cell<Option<usize>> = const { Cell::new(None) };
        pub static TRUNC_EIO: Cell<bool> = const { Cell::new(false) };
    }

    pub const B8: &str = "3f2a9c1e";
    pub const U: &str = "/user.slice/user-1000.slice/user@1000.service";

    pub fn claude() -> String {
        format!("{U}/app.slice/app-com.anthropic.Claude-16803.scope")
    }
    pub fn shell() -> String {
        format!("{U}/session.slice/plasma-plasmashell.service")
    }
    fn tg() -> String {
        format!("{U}/app.slice/app-flatpak-org.telegram.desktop-4120.scope")
    }

    /// A temp dir holding a fake /proc and cgroup tree and the log's directory, as test-log-fg.py's setUp.
    pub struct Tree {
        pub root: PathBuf,
    }

    impl Tree {
        pub fn new(name: &str) -> Tree {
            let root = std::env::temp_dir().join(format!("ra-fg-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            let t = Tree { root };
            t.put("proc/sys/kernel/random/boot_id", "3f2a9c1e-77d0-4b1e-9a51-0c2d6e1f8a90\n");
            fs::create_dir_all(t.fg_dir()).unwrap();
            t
        }
        pub fn put(&self, rel: &str, text: &str) {
            let p = self.root.join(rel);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(p, text).unwrap();
        }
        pub fn fg_dir(&self) -> PathBuf {
            self.root.join("state/y700-battery")
        }
        pub fn fg(&self) -> Fg {
            Fg::at(self.fg_dir(), &self.s("proc"), &self.s("cgroup"))
        }
        fn s(&self, rel: &str) -> String {
            self.root.join(rel).to_str().unwrap().to_string()
        }
        pub fn pid(&self, pid: i64, text: &str) {
            self.put(&format!("proc/{pid}/cgroup"), text);
        }
        pub fn cpu(&self, unit: &str, usec: i64) {
            self.put(&format!("cgroup{unit}/cpu.stat"), &format!("usage_usec {usec}\nuser_usec {}\nsystem_usec {}\nnr_periods 0\nnr_throttled 0\nthrottled_usec 0\n", usec / 3, usec - usec / 3));
        }
        pub fn path(&self, name: Option<&str>) -> PathBuf {
            self.fg_dir().join(name.map_or(format!("fg-{B8}.log"), String::from))
        }
        pub fn raw(&self, name: Option<&str>) -> Vec<u8> {
            fs::read(self.path(name)).unwrap()
        }
        pub fn lines(&self) -> Vec<String> {
            let s = String::from_utf8(self.raw(None)).unwrap();
            assert!(!s.contains('\r'));
            s.split_inclusive('\n').map(String::from).collect()
        }
        pub fn names(&self) -> Vec<String> {
            let mut v: Vec<String> = fs::read_dir(self.fg_dir()).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
            v.sort();
            v
        }
        fn fill(&self, size: usize, name: Option<&str>) {
            fs::write(self.path(name), [vec![b'x'; size - 1], vec![b'\n']].concat()).unwrap();
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
            SHORT.with(|s| s.set(None));
            TRUNC_EIO.with(|t| t.set(false));
        }
    }

    /// How the report reads a line: split(" ", 6) of a \n-terminated line.
    pub fn fields(line: &str) -> Vec<String> {
        assert!(line.ends_with('\n') && !line[..line.len() - 1].contains('\n'), "{line:?}");
        line[..line.len() - 1].splitn(7, ' ').map(String::from).collect()
    }

    #[test]
    fn design_example() {
        let t = Tree::new("design");
        let mut fg = t.fg();
        t.pid(3315, &format!("0::{}\n", shell()));
        t.cpu(&shell(), 900000000);
        t.pid(16803, &format!("0::{}\n", claude()));
        t.cpu(&claude(), 812345);
        fg.log(7000.0, "plasmashell", true, 3315);
        t.cpu(&shell(), 912345678);
        fg.log(7342.61, "Claude", true, 16803);
        let got = t.lines();
        assert_eq!(got, [format!("7000.00 3315 1 900000000 - {} plasmashell\n", shell()),
            "7342.61 16803 1 812345 912345678 /user.slice/user-1000.slice/user@1000.service/app.slice/app-com.anthropic.Claude-16803.scope Claude\n".to_string()]);
        assert_eq!(fields(&got[1]), ["7342.61", "16803", "1", "812345", "912345678", &claude(), "Claude"]);
    }

    #[test]
    fn cgroup_walk() {
        let t = Tree::new("walk");
        let mut fg = t.fg();
        // nested under the scope; a v1 line first; the leaf has its own cpu.stat, the unit's is the one read
        t.pid(4120, &format!("12:pids:{U}/x\n1:name=systemd:{U}/y\n0::{}/sub/leaf\n", tg()));
        t.cpu(&tg(), 405000);
        t.cpu(&format!("{}/sub/leaf", tg()), 1);
        fg.log(1000.0, "org.telegram.desktop", true, 4120);
        // the process outlived its cgroup; nothing to read
        t.pid(77, &format!("0::{U}/app.slice/app-gone-77.scope (deleted)\n"));
        fg.log(1001.0, "gone", true, 77);
        // no .scope / .service above the leaf: the leaf itself, whitespace escaped the way systemd does
        t.pid(78, "0::/user.slice/odd dir\n");
        t.cpu("/user.slice/odd dir", 5);
        fg.log(1002.0, "odd", false, 78);
        assert_eq!(t.lines(), [format!("1000.00 4120 1 405000 - {} org.telegram.desktop\n", tg()),
            format!("1001.00 77 1 - 405000 {U}/app.slice/app-gone-77.scope gone\n"),
            "1002.00 78 0 5 - /user.slice/odd\\x20dir odd\n".to_string()]);
    }

    #[test]
    fn class_field() {
        let t = Tree::new("class");
        let mut fg = t.fg();
        let steam = format!("{U}/app.slice/app-steam-arm64-5000.service");
        t.pid(5000, &format!("0::{steam}\n"));
        t.cpu(&steam, 10);
        fg.log(1000.0, "Steam Big Picture Mode", true, 5000);
        fg.log(1001.0, "", false, 0); // desktop: pid 0, empty class
        fg.log(1002.0, "evil\nclass\u{2028}x", true, 0); // U+2028 LINE SEPARATOR: splitlines() splits there
        let got = t.lines();
        assert_eq!(got.len(), 3);
        assert_eq!(fields(&got[0])[6], "Steam Big Picture Mode");
        assert_eq!(got[1], "1001.00 0 0 - 10 - \n");
        assert_eq!(fields(&got[1]), ["1001.00", "0", "0", "-", "10", "-", ""]);
        assert_eq!(fields(&got[2])[6], "evil class x");
    }

    #[test]
    fn same_unit_and_gone_prev() {
        let t = Tree::new("same");
        let mut fg = t.fg();
        t.pid(16803, &format!("0::{}\n", claude()));
        t.pid(16900, &format!("0::{}\n", claude()));
        t.cpu(&claude(), 100);
        fg.log(1000.0, "Claude", true, 16803);
        t.cpu(&claude(), 250);
        fg.log(1001.0, "Claude", false, 16900); // another window of the same app: prev == new
        fs::remove_dir_all(t.root.join(format!("cgroup{}", claude()))).unwrap(); // the app quit
        t.pid(3315, &format!("0::{}\n", shell()));
        t.cpu(&shell(), 7);
        fg.log(1002.0, "plasmashell", true, 3315);
        assert_eq!(t.lines(), [format!("1000.00 16803 1 100 - {} Claude\n", claude()), format!("1001.00 16900 0 250 250 {} Claude\n", claude()),
            format!("1002.00 3315 1 7 - {} plasmashell\n", shell())]);
    }

    #[test]
    fn failed_write_leaves_no_stale_pairing() {
        let t = Tree::new("stale");
        let mut fg = t.fg();
        t.pid(16803, &format!("0::{}\n", claude()));
        t.cpu(&claude(), 100);
        t.pid(3315, &format!("0::{}\n", shell()));
        t.cpu(&shell(), 7);
        fg.log(1000.0, "Claude", true, 16803);
        SHORT.with(|s| s.set(Some(0))); // lost: the next line must not claim the shell's usage as prev
        fg.log(1001.0, "plasmashell", true, 3315);
        SHORT.with(|s| s.set(None));
        fg.log(1002.0, "Claude", true, 16803);
        assert_eq!(t.lines(), [format!("1000.00 16803 1 100 - {} Claude\n", claude()), format!("1002.00 16803 1 100 - {} Claude\n", claude())]);
        assert_eq!(fg.errors, 1);
    }

    #[test]
    fn boot_id() {
        let t = Tree::new("boot");
        let mut fg = t.fg();
        t.put("proc/sys/kernel/random/boot_id", "not-a-boot-id\n");
        let before = crate::tests::logged_count();
        fg.mark(1000.0, "START");
        fg.mark(1000.0, "STOP");
        assert!(t.names().is_empty());
        assert_eq!(fg.errors, 2);
        let logs = crate::tests::logged_since(before);
        assert_eq!(logs.len(), 1);
        assert!(logs[0].contains("no boot id"), "{logs:?}");
        t.put("proc/sys/kernel/random/boot_id", "0a1b2c3d-0000-4000-8000-000000000000\n");
        fg.mark(1000.0, "START");
        assert_eq!(t.names(), ["fg-0a1b2c3d.log"]);
    }

    #[test]
    fn escape() {
        assert_eq!(fg_esc(None), "-");
        assert_eq!(fg_esc(Some("")), "-");
        assert_eq!(fg_esc(Some("/a b\tc\nd")), "/a\\x20b\\x09c\\x0ad");
        assert_eq!(fg_esc(Some("/x\u{3000}y")), "/x\\xe3\\x80\\x80y"); // ideographic space, per byte
        assert_eq!(fg_esc(Some("/x\u{1f}y")), "/x\\x1fy"); // a separator Python's isspace() counts
        let name = format!("{U}/app.slice/app-geoclue\\x2ddemo\\x2dagent@autostart.service");
        assert_eq!(fg_esc(Some(&name)), name); // systemd's own escapes pass through untouched
    }

    #[test]
    fn missing_directory() {
        let t = Tree::new("missing");
        let mut fg = t.fg();
        fs::remove_dir_all(t.root.join("state")).unwrap();
        // nothing read: a pid whose cgroup file is a directory would fail a read
        fs::create_dir_all(t.root.join("proc/16803/cgroup")).unwrap();
        fg.mark(1000.0, "START");
        fg.log(1000.0, "Claude", true, 16803);
        fg.mark(1000.0, "STOP");
        assert_eq!(fg.errors, 0);
        assert!(!t.root.join("state").exists());
        assert!(fg.boot.is_none()); // the boot id was not even read
    }

    #[test]
    fn comes_and_goes() {
        let t = Tree::new("comes");
        let mut fg = t.fg();
        t.pid(16803, &format!("0::{}\n", claude()));
        t.cpu(&claude(), 100);
        t.pid(3315, &format!("0::{}\n", shell()));
        t.cpu(&shell(), 7);
        fg.log(1000.0, "Claude", true, 16803);
        fs::remove_dir_all(t.fg_dir()).unwrap(); // turned off
        fg.log(1001.0, "plasmashell", true, 3315);
        fs::create_dir_all(t.fg_dir()).unwrap(); // on again: the first line has no prev (the file is new)
        fg.log(1002.0, "Claude", true, 16803);
        assert_eq!(t.lines(), [format!("1002.00 16803 1 100 - {} Claude\n", claude())]);
        assert_eq!(fg.errors, 0);
    }

    #[test]
    fn vanishes_between_check_and_open() {
        let t = Tree::new("vanish");
        assert!(fg_append(&t.fg_dir(), B8, b"x\n").unwrap());
        fs::remove_dir_all(t.fg_dir()).unwrap();
        assert!(!fg_append(&t.fg_dir(), B8, b"x\n").unwrap());
    }

    #[test]
    fn unwritable_log_is_counted() {
        let t = Tree::new("unwritable");
        let mut fg = t.fg();
        fs::create_dir(t.path(None)).unwrap(); // the log's name is taken by a directory: open() fails
        let before = crate::tests::logged_count();
        fg.log(1000.0, "x", true, 7);
        fg.log(1000.0, "y", true, 8);
        assert_eq!((fg.errors, crate::tests::logged_since(before).len()), (2, 1));
    }

    #[test]
    fn rotation() {
        let t = Tree::new("rotation");
        let mut fg = t.fg();
        let stop = b"1000.00 STOP\n";
        t.fill(FG_MAX as usize - stop.len(), None);
        fg.mark(1000.0, "STOP"); // lands exactly on 1 MiB: no rotation
        assert_eq!(fs::metadata(t.path(None)).unwrap().len(), FG_MAX);
        assert_eq!(t.names(), [format!("fg-{B8}.log")]);
        fg.mark(1001.0, "START"); // would pass it: the full file becomes part 1
        assert_eq!(t.names(), [format!("fg-{B8}.1.log"), format!("fg-{B8}.log")]);
        let p1 = format!("fg-{B8}.1.log");
        assert_eq!(fs::metadata(t.path(Some(&p1))).unwrap().len(), FG_MAX);
        assert!(t.raw(Some(&p1)).ends_with(&[&b"x\n"[..], stop].concat()));
        assert_eq!(t.raw(None), b"1001.00 START\n");
        // numbering: highest + 1, other boots and stray names ignored
        for n in [format!("fg-{B8}.7.log"), format!("fg-{B8}.x.log"), format!("fg-{B8}..log"), format!("fg-{B8}.\u{b2}.log"),
            "fg-00000000.9.log".into(), format!("b-{B8}.12.jsonl")]
        {
            fs::write(t.path(Some(&n)), b"").unwrap();
        }
        t.fill(FG_MAX as usize, None);
        fg.mark(1002.0, "START");
        let p8 = format!("fg-{B8}.8.log");
        assert_eq!(fs::metadata(t.path(Some(&p8))).unwrap().len(), FG_MAX);
        assert_eq!(t.raw(None), b"1002.00 START\n");
        for n in t.names() {
            assert!(fs::metadata(t.path(Some(&n))).unwrap().len() <= FG_MAX, "{n}");
        }
        assert_eq!(fg.errors, 0);
    }

    #[test]
    fn never_rotates_an_empty_file() {
        let t = Tree::new("empty");
        let big = [vec![b'y'; FG_MAX as usize + 10], vec![b'\n']].concat();
        assert!(fg_append(&t.fg_dir(), B8, &big).unwrap());
        assert_eq!(t.names(), [format!("fg-{B8}.log")]);
        assert!(fg_append(&t.fg_dir(), B8, b"z\n").unwrap());
        assert_eq!(t.names(), [format!("fg-{B8}.1.log"), format!("fg-{B8}.log")]);
        assert_eq!(t.raw(None), b"z\n");
    }

    #[test]
    fn short_write_is_cut_off() {
        let t = Tree::new("short");
        let mut fg = t.fg();
        t.pid(16803, &format!("0::{}\n", claude()));
        t.cpu(&claude(), 812345);
        t.pid(3315, &format!("0::{}\n", shell()));
        t.cpu(&shell(), 7);
        fg.mark(1000.0, "START");
        let before = crate::tests::logged_count();
        SHORT.with(|s| s.set(Some(0)));
        fg.log(1001.0, "Claude", true, 16803);
        SHORT.with(|s| s.set(None));
        assert_eq!(t.raw(None), b"1000.00 START\n"); // the fragment is gone again
        fg.log(1002.0, "plasmashell", true, 3315); // intact, and no prev_usage from the lost line
        assert_eq!(t.lines(), ["1000.00 START\n".to_string(), format!("1002.00 3315 1 7 - {} plasmashell\n", shell())]);
        let logs = crate::tests::logged_since(before);
        assert_eq!((fg.errors, logs.len()), (1, 1));
        assert!(logs[0].contains("short write"), "{logs:?}");
    }

    #[test]
    fn short_write_after_rotation() {
        let t = Tree::new("shortrot");
        let mut fg = t.fg();
        t.fill(FG_MAX as usize, None);
        SHORT.with(|s| s.set(Some(0)));
        fg.mark(1000.0, "START");
        SHORT.with(|s| s.set(None));
        assert_eq!(fs::metadata(t.path(Some(&format!("fg-{B8}.1.log")))).unwrap().len(), FG_MAX);
        assert_eq!(t.raw(None), b""); // cut to the new part's size, not grown to the old one's
        fg.mark(1001.0, "START");
        assert_eq!(t.raw(None), b"1001.00 START\n");
        assert_eq!(t.names(), [format!("fg-{B8}.1.log"), format!("fg-{B8}.log")]);
        assert_eq!(fg.errors, 1);
    }

    #[test]
    fn cut_line_is_ended_first() {
        let t = Tree::new("cut");
        let mut fg = t.fg();
        fs::write(t.path(None), b"1000.00 START\n1001.00 16803 1 8123").unwrap(); // SIGKILL between two pages of a write
        fg.mark(1002.0, "START");
        let got = t.lines();
        assert_eq!(got, ["1000.00 START\n", "1001.00 16803 1 8123\n", "1002.00 START\n"]);
        assert_eq!(fields(&got[2]), ["1002.00", "START"]);
        assert_eq!(fg.errors, 0);
    }

    #[test]
    fn cut_off_fails_too() {
        let t = Tree::new("cutfail");
        let mut fg = t.fg();
        fg.mark(1000.0, "START");
        SHORT.with(|s| s.set(Some(5)));
        TRUNC_EIO.with(|x| x.set(true));
        fg.mark(1001.0, "STOP");
        SHORT.with(|s| s.set(None));
        TRUNC_EIO.with(|x| x.set(false));
        assert_eq!(t.raw(None), b"1000.00 START\n1001.");
        fg.mark(1002.0, "START");
        assert_eq!(t.lines(), ["1000.00 START\n", "1001.\n", "1002.00 START\n"]);
        assert_eq!(fg.errors, 1);
    }

    #[test]
    fn cut_line_and_rotation() {
        let t = Tree::new("cutrot");
        let mut fg = t.fg();
        let (cut, start) = (&b"1001.00 16803"[..], &b"1002.00 START\n"[..]);
        fs::write(t.path(None), [vec![b'x'; FG_MAX as usize - start.len() - cut.len() - 1], b"\n".to_vec(), cut.to_vec()].concat()).unwrap();
        fg.mark(1002.0, "START"); // exactly 1 MiB, but for the \n that ends the cut line: rotated
        assert_eq!(t.names(), [format!("fg-{B8}.1.log"), format!("fg-{B8}.log")]);
        assert!(t.raw(Some(&format!("fg-{B8}.1.log"))).ends_with(&[&b"x\n"[..], cut].concat())); // its last line, without a \n
        assert_eq!(t.raw(None), start); // no empty first line in the new part
        for n in t.names() {
            assert!(fs::metadata(t.path(Some(&n))).unwrap().len() <= FG_MAX, "{n}");
        }
        assert_eq!(fg.errors, 0);
    }
}
