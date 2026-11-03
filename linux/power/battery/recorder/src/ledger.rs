//! The ledger directory ~/.local/state/y700-battery/ (DESIGN.md section 2 "账本"):
//!   - boots.txt: boot8 ids in the order the boots started, this boot appended once per boot (as flightrec's run.rs
//!     boot_order: the RTC starts at 1970 here, file times cannot order boots);
//!   - b-<boot8>.jsonl, then b-<boot8>.<n>.jsonl: a part is closed at 4 MiB; every part starts with H, the full U table
//!     and a full S, so one part decodes on its own;
//!   - fg-<boot8>[.<n>].log: refresh-auto's foreground log, pruned with the ledger. Its parts run the other way round:
//!     refresh-auto always writes fg-<boot8>.log and renames it to fg-<boot8>.<n>.log (n = highest + 1) when full, so
//!     the unnumbered file is the newest part and the numbered ones are older, oldest first.
//! Writes: O_APPEND, one write() per group of lines (H + U + S, or one S, or one K). A write cut short (ENOSPC) or a
//! SIGKILL at MemoryMax can leave a half line: before the next write - in this process or the next - a newline closes
//! it, and the reader skips the line that does not parse.
//! Retention, by part file (评审修订): 40 days and 16 MiB in all, oldest first by boots.txt; only the part being
//! written (and this boot's fg-<boot8>.log, which refresh-auto writes) is always kept - the older parts of this boot
//! take part, or a 60-day boot would grow past the cap.
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

pub const PART_MAX: u64 = 4 << 20;
pub const KEEP_BYTES: u64 = 16 << 20;
pub const KEEP_S: f64 = 40.0 * 86400.0;
pub const LINE_MAX: usize = 64 << 10;
const BOOTS_MAX: usize = 512; // boots.txt rewritten with the newest half beyond this
const SANE_WALL: f64 = 1.0e9; // a wall time below this is the RTC's 1970: no age can be judged from it

pub fn part_name(boot8: &str, n: u32) -> String {
    if n == 0 {
        format!("b-{boot8}.jsonl")
    } else {
        format!("b-{boot8}.{n}.jsonl")
    }
}

/// (boot8, part, is a foreground log) of a ledger file name; None for anything else (boots.txt, lock, *.tmp)
pub fn parse_name(name: &str) -> Option<(String, u32, bool)> {
    let (fg, rest) = if let Some(r) = name.strip_prefix("b-").and_then(|r| r.strip_suffix(".jsonl")) {
        (false, r)
    } else if let Some(r) = name.strip_prefix("fg-").and_then(|r| r.strip_suffix(".log")) {
        (true, r)
    } else {
        return None;
    };
    let (boot, part) = match rest.split_once('.') {
        Some((b, n)) => (b, n.parse::<u32>().ok()?),
        None => (rest, 0),
    };
    if boot.is_empty() || !boot.bytes().all(|c| c.is_ascii_alphanumeric()) {
        return None;
    }
    Some((boot.to_string(), part, fg))
}

#[derive(Clone, Debug)]
pub struct LFile {
    pub name: String,
    pub boot: String,
    pub part: u32,
    pub fg: bool,
    pub size: u64,
    pub mtime: f64,
}

pub fn list(dir: &Path) -> Vec<LFile> {
    let Ok(rd) = fs::read_dir(dir) else { return vec![] };
    rd.flatten()
        .filter_map(|e| {
            let name = e.file_name().to_str()?.to_string();
            let (boot, part, fg) = parse_name(&name)?;
            let m = e.metadata().ok()?;
            if !m.is_file() {
                return None;
            }
            Some(LFile { name, boot, part, fg, size: m.len(), mtime: m.mtime() as f64 })
        })
        .collect()
}

/// a file's place among its boot's parts, oldest first: ledger parts count up from b-<boot8>.jsonl (0); of the fg
/// parts the unnumbered one is the newest (refresh-auto renames it away when full and goes on in a new one)
fn seq(f: &LFile) -> u32 {
    if f.fg && f.part == 0 {
        u32::MAX
    } else {
        f.part
    }
}

/// the files to delete. now_wall: the wall clock when it is synchronised (None: no age rule this time). A file's age
/// is judged only when its mtime is a real date too (a part last written before chrony set the clock carries 1970).
/// Order for the size rule: boots by boots.txt, boots it does not know before all it knows (by mtime among
/// themselves), this boot always newest; within a boot by seq().
pub fn plan_prune(files: &[LFile], order: &[String], cur_boot: &str, cur_part: u32, now_wall: Option<f64>) -> Vec<String> {
    let protected = |f: &LFile| f.boot == cur_boot && ((f.fg && f.part == 0) || (!f.fg && f.part == cur_part));
    let mut del: Vec<String> = vec![];
    let mut keep: Vec<&LFile> = vec![];
    for f in files {
        let old = match now_wall {
            Some(w) if w > SANE_WALL && f.mtime > SANE_WALL => w - f.mtime > KEEP_S,
            _ => false,
        };
        if old && !protected(f) {
            del.push(f.name.clone());
        } else {
            keep.push(f);
        }
    }
    let rank = |f: &LFile| -> (bool, usize, i64, u32, bool) {
        if f.boot == cur_boot {
            return (true, usize::MAX, 0, seq(f), f.fg);
        }
        match order.iter().position(|b| *b == f.boot) {
            Some(i) => (true, i, 0, seq(f), f.fg),
            None => (false, 0, f.mtime as i64, seq(f), f.fg),
        }
    };
    keep.sort_by_key(|f: &&LFile| rank(*f));
    let mut total: u64 = keep.iter().map(|f| f.size).fold(0u64, |a, b| a.saturating_add(b));
    for f in keep {
        if total <= KEEP_BYTES {
            break;
        }
        if protected(f) {
            continue;
        }
        total = total.saturating_sub(f.size);
        del.push(f.name.clone());
    }
    del
}

#[derive(Debug, PartialEq)]
pub enum BootsWrite {
    Keep,
    Append,
    Rewrite,
}

pub fn boots_update(mut order: Vec<String>, boot: &str) -> (Vec<String>, BootsWrite) {
    if order.last().map(String::as_str) == Some(boot) {
        return (order, BootsWrite::Keep); // restarted within this boot
    }
    order.push(boot.to_string());
    if order.len() > BOOTS_MAX {
        let cut = order.len() - BOOTS_MAX / 2;
        order.drain(..cut);
        return (order, BootsWrite::Rewrite);
    }
    (order, BootsWrite::Append)
}

/// boots.txt read, this boot added; the order, oldest first
pub fn boot_order(dir: &Path, boot: &str) -> Vec<String> {
    let path = dir.join("boots.txt");
    let old: Vec<String> =
        fs::read_to_string(&path).unwrap_or_default().split_whitespace().map(str::to_string).collect();
    let (order, how) = boots_update(old, boot);
    let done = match how {
        BootsWrite::Keep => Ok(()),
        BootsWrite::Append => OpenOptions::new().append(true).create(true).mode(0o644).open(&path).and_then(|mut f| {
            f.write_all(format!("{boot}\n").as_bytes())?;
            f.sync_data()
        }),
        BootsWrite::Rewrite => {
            let tmp = dir.join("boots.txt.tmp");
            File::create(&tmp)
                .and_then(|mut f| {
                    f.write_all(format!("{}\n", order.join("\n")).as_bytes())?;
                    f.sync_all()
                })
                .and_then(|_| fs::rename(&tmp, &path))
        }
    };
    if let Err(e) = done {
        elog!("{}: {e}", path.display());
    }
    order
}

/// a group of `len` bytes no longer fits the current part
pub fn rotation_due(size: u64, len: usize) -> bool {
    size > 0 && size.saturating_add(len as u64) > PART_MAX
}

pub struct Ledger {
    dir: PathBuf,
    boot8: String,
    pub part: u32,
    file: Option<File>,
    size: u64,
    dirty: bool, // the last write failed: the file may end in a half line
    // the part has no complete head yet: set when it is begun (rotate) or found empty (made, made again), cleared
    // only by a write that went through - a head cut short (ENOSPC after k bytes) leaves k + 1 bytes after the
    // repair, and the size alone would let the retry go without H, the full U table and a full S
    headless: bool,
}

impl Ledger {
    /// the newest part of this boot (a restart within the boot writes on in it, after a newline if it ends in a half
    /// line), or a new part when that one is full; a file that cannot be opened now is tried again at every write
    pub fn open(dir: &Path, boot8: &str) -> Ledger {
        let part = list(dir).iter().filter(|f| !f.fg && f.boot == boot8).map(|f| f.part).max().unwrap_or(0);
        let mut l = Ledger {
            dir: dir.to_path_buf(),
            boot8: boot8.to_string(),
            part,
            file: None,
            size: 0,
            dirty: false,
            headless: false,
        };
        if l.ensure_open().is_ok() && l.size >= PART_MAX {
            let _ = l.rotate();
        }
        l
    }

    #[cfg(test)]
    pub fn with_file(f: File) -> Ledger {
        Ledger {
            dir: PathBuf::from("/nonexistent"),
            boot8: "test".into(),
            part: 0,
            file: Some(f),
            size: 0,
            dirty: false,
            headless: false,
        }
    }

    pub fn name(&self) -> String {
        part_name(&self.boot8, self.part)
    }

    pub fn size(&self) -> u64 {
        self.size
    }

    fn ensure_open(&mut self) -> io::Result<()> {
        if self.file.is_some() {
            return Ok(());
        }
        let f = OpenOptions::new().read(true).append(true).create(true).mode(0o644).open(self.dir.join(self.name()))?;
        self.size = f.metadata()?.len();
        if self.size == 0 {
            self.headless = true;
        }
        self.file = Some(f);
        self.repair()
    }

    /// a file that does not end in a newline gets one
    fn repair(&mut self) -> io::Result<()> {
        let Some(f) = &self.file else { return Ok(()) };
        let len = f.metadata()?.len();
        self.size = len;
        if len > 0 {
            let mut b = [0u8; 1];
            f.read_exact_at(&mut b, len - 1)?;
            if b != [b'\n'] {
                let mut w: &File = f;
                w.write_all(b"\n")?;
                self.size = len + 1;
            }
        }
        self.dirty = false;
        Ok(())
    }

    /// before a write: the part open (a part deleted under us is let go and made again), a cut-off line closed. True
    /// while the part has no complete head (empty, or its head's write cut short): the write must start with H and the
    /// full table.
    pub fn prepare(&mut self) -> io::Result<bool> {
        let unlinked = match &self.file {
            Some(f) => f.metadata().map(|m| m.nlink() == 0).unwrap_or(true),
            None => false,
        };
        if unlinked {
            self.file = None;
        }
        self.ensure_open()?;
        if self.dirty {
            self.repair()?;
        }
        Ok(self.headless)
    }

    /// one write() of a group of whole lines
    pub fn append(&mut self, data: &[u8]) -> io::Result<()> {
        let Some(f) = &self.file else { return Err(io::Error::from_raw_os_error(libc::EBADF)) };
        let mut w: &File = f;
        match w.write_all(data) {
            Ok(()) => {
                self.size = self.size.saturating_add(data.len() as u64);
                self.headless = false;
                Ok(())
            }
            Err(e) => {
                self.dirty = true;
                Err(e)
            }
        }
    }

    /// the full part synced and closed, the next one started
    pub fn rotate(&mut self) -> io::Result<()> {
        if let Some(f) = self.file.take() {
            let _ = f.sync_data();
        }
        self.part = self.part.saturating_add(1);
        self.size = 0;
        self.dirty = false;
        self.headless = true;
        self.ensure_open()
    }

    pub fn sync(&self) -> io::Result<()> {
        match &self.file {
            Some(f) => f.sync_data(),
            None => Ok(()),
        }
    }

    /// (files deleted, bytes freed)
    pub fn prune(&self, order: &[String], now_wall: Option<f64>) -> (usize, u64) {
        let files = list(&self.dir);
        let (mut n, mut bytes) = (0usize, 0u64);
        for name in plan_prune(&files, order, &self.boot8, self.part, now_wall) {
            let sz = files.iter().find(|f| f.name == name).map_or(0, |f| f.size);
            match fs::remove_file(self.dir.join(&name)) {
                Ok(()) => {
                    n += 1;
                    bytes = bytes.saturating_add(sz);
                }
                Err(e) => elog!("prune {name}: {e}"),
            }
        }
        (n, bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("y700-batteryd-test-{}-{tag}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn names() {
        assert_eq!(part_name("3f2a9c1e", 0), "b-3f2a9c1e.jsonl");
        assert_eq!(part_name("3f2a9c1e", 3), "b-3f2a9c1e.3.jsonl");
        assert_eq!(parse_name("b-3f2a9c1e.jsonl"), Some(("3f2a9c1e".into(), 0, false)));
        assert_eq!(parse_name("b-3f2a9c1e.3.jsonl"), Some(("3f2a9c1e".into(), 3, false)));
        assert_eq!(parse_name("fg-3f2a9c1e.log"), Some(("3f2a9c1e".into(), 0, true)));
        assert_eq!(parse_name("fg-3f2a9c1e.2.log"), Some(("3f2a9c1e".into(), 2, true)));
        for bad in ["boots.txt", "lock", "boots.txt.tmp", "b-.jsonl", "b-x.y.jsonl", "b-3f2a9c1e.jsonl.tmp", "fg-a/b.log"] {
            assert_eq!(parse_name(bad), None, "{bad}");
        }
    }

    fn lf(name: &str, size: u64, mtime: f64) -> LFile {
        let (boot, part, fg) = parse_name(name).unwrap();
        LFile { name: name.into(), boot, part, fg, size, mtime }
    }

    const MB: u64 = 1 << 20;
    const NOW: f64 = 1_761_810_000.0;
    const DAY: f64 = 86400.0;

    #[test]
    fn prune_age_and_size() {
        let order: Vec<String> = ["aaaa0001", "bbbb0002", "cccc0003"].iter().map(|s| s.to_string()).collect();
        let files = vec![
            lf("b-aaaa0001.jsonl", MB, NOW - 50.0 * DAY),    // 50 days: too old
            lf("fg-aaaa0001.log", MB, 5_000_000.0),          // a 1970 mtime: no age, size rule only
            lf("b-bbbb0002.jsonl", 4 * MB, NOW - 10.0 * DAY),
            lf("b-bbbb0002.1.jsonl", 4 * MB, NOW - 9.0 * DAY),
            lf("b-cccc0003.jsonl", 4 * MB, NOW - 50.0 * DAY), // this boot's old part: takes part
            lf("b-cccc0003.1.jsonl", 4 * MB, NOW),            // being written
            lf("fg-cccc0003.log", MB, NOW - 45.0 * DAY),      // this boot's live fg part: kept
        ];
        let d = plan_prune(&files, &order, "cccc0003", 1, Some(NOW));
        // age: b-aaaa0001.jsonl, b-cccc0003.jsonl; left 4+4+4+1+1 = 14 MiB <= 16: the size rule deletes nothing
        assert_eq!(d, vec!["b-aaaa0001.jsonl".to_string(), "b-cccc0003.jsonl".to_string()]);
        // the clock not synchronised: no age rule; 19 MiB -> oldest first down to 16
        let d = plan_prune(&files, &order, "cccc0003", 1, None);
        assert_eq!(d, vec!["b-aaaa0001.jsonl".to_string(), "fg-aaaa0001.log".to_string(), "b-bbbb0002.jsonl".to_string()]);
        // a boot boots.txt does not know counts oldest; this boot is never "unknown"
        let mut f2 = files.clone();
        f2.push(lf("b-dddd0004.jsonl", 2 * MB, NOW));
        let d = plan_prune(&f2, &order, "cccc0003", 1, None);
        assert_eq!(d.first().map(String::as_str), Some("b-dddd0004.jsonl"));
        // only the part being written survives everything
        let big = vec![lf("b-cccc0003.jsonl", 20 * MB, 1.0), lf("b-cccc0003.1.jsonl", 20 * MB, 1.0)];
        assert_eq!(plan_prune(&big, &order, "cccc0003", 1, Some(NOW)), vec!["b-cccc0003.jsonl".to_string()]);
        // refresh-auto writes on in fg-<boot8>.log and renames a full one to fg-<boot8>.<n>.log: the numbered parts are
        // the older ones, oldest first, and the unnumbered one is never deleted
        let fgs = vec![
            lf("b-cccc0003.jsonl", 2 * MB, NOW),
            lf("fg-cccc0003.log", 10 * MB, NOW),
            lf("fg-cccc0003.1.log", 5 * MB, NOW),
            lf("fg-cccc0003.2.log", 5 * MB, NOW),
        ];
        assert_eq!(
            plan_prune(&fgs, &order, "cccc0003", 0, None),
            vec!["fg-cccc0003.1.log".to_string(), "fg-cccc0003.2.log".to_string()]
        );
        let old = vec![lf("fg-cccc0003.log", MB, NOW - 50.0 * DAY), lf("fg-cccc0003.1.log", MB, NOW - 50.0 * DAY)];
        assert_eq!(plan_prune(&old, &order, "cccc0003", 0, Some(NOW)), vec!["fg-cccc0003.1.log".to_string()]);
    }

    #[test]
    fn boots() {
        let (o, w) = boots_update(vec!["a".into()], "a");
        assert_eq!((o.len(), w), (1, BootsWrite::Keep));
        let (o, w) = boots_update(vec!["a".into()], "b");
        assert_eq!((o, w), (vec!["a".to_string(), "b".to_string()], BootsWrite::Append));
        let many: Vec<String> = (0..BOOTS_MAX).map(|i| format!("{i:08x}")).collect();
        let (o, w) = boots_update(many, "ffffffff");
        assert_eq!(w, BootsWrite::Rewrite);
        assert_eq!(o.len(), BOOTS_MAX / 2);
        assert_eq!(o.last().map(String::as_str), Some("ffffffff"));
    }

    #[test]
    fn half_line_and_parts() {
        let d = tmpdir("ledger");
        fs::write(d.join("b-t0000001.jsonl"), "{\"k\":\"S\"}\n{\"k\":\"S\",\"wh").unwrap();
        fs::write(d.join("b-t0000001.2.jsonl"), "{\"k\":\"H\"}\n{\"k\":\"S\",\"c").unwrap();
        let mut l = Ledger::open(&d, "t0000001");
        assert_eq!(l.part, 2, "the newest part of this boot");
        assert_eq!(l.prepare().unwrap(), false);
        l.append(b"{\"k\":\"S\"}\n").unwrap();
        assert_eq!(fs::read_to_string(d.join("b-t0000001.2.jsonl")).unwrap(), "{\"k\":\"H\"}\n{\"k\":\"S\",\"c\n{\"k\":\"S\"}\n");
        assert_eq!(l.size(), fs::metadata(d.join("b-t0000001.2.jsonl")).unwrap().len());
        // the part deleted under us: made again, empty (the caller writes a head)
        fs::remove_file(d.join("b-t0000001.2.jsonl")).unwrap();
        assert_eq!(l.prepare().unwrap(), true);
        assert!(d.join("b-t0000001.2.jsonl").exists());
        // rotation
        assert!(!rotation_due(0, 10 << 20), "an empty part takes any group");
        assert!(rotation_due(PART_MAX - 10, 11));
        assert!(!rotation_due(PART_MAX - 10, 10));
        l.rotate().unwrap();
        assert_eq!(l.name(), "b-t0000001.3.jsonl");
        assert_eq!(l.prepare().unwrap(), true);
        // a full part found at start: a new part is begun
        let full = vec![b'\n'; PART_MAX as usize];
        fs::write(d.join("b-t0000002.jsonl"), &full).unwrap();
        let l2 = Ledger::open(&d, "t0000002");
        assert_eq!((l2.part, l2.size()), (1, 0));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn head_cut_short_is_written_again() {
        let d = tmpdir("cuthead");
        let p = d.join("b-t0000003.jsonl");
        let mut l = Ledger::open(&d, "t0000003");
        assert_eq!(l.prepare().unwrap(), true, "a new part: the write starts with a head");
        // the head's write cut short (ENOSPC after 12 bytes): a half line on disk, the size not advanced
        OpenOptions::new().append(true).open(&p).unwrap().write_all(b"{\"k\":\"H\",\"v\"").unwrap();
        l.dirty = true;
        assert_eq!(l.prepare().unwrap(), true, "closed by a newline, still without a head");
        assert_eq!(fs::read_to_string(&p).unwrap(), "{\"k\":\"H\",\"v\"\n");
        assert_eq!(l.size(), 13);
        l.append(b"{\"k\":\"H\"}\n").unwrap();
        assert_eq!(l.prepare().unwrap(), false, "headed");
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn disk_full_is_an_error_not_a_panic() {
        let Ok(f) = OpenOptions::new().append(true).open("/dev/full") else { return };
        let mut l = Ledger::with_file(f);
        let e = l.append(b"{\"k\":\"S\"}\n").unwrap_err();
        assert_eq!(e.raw_os_error(), Some(libc::ENOSPC));
        assert!(l.dirty);
        assert_eq!(l.size(), 0);
    }
}
