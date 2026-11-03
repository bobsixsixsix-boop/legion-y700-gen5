//! System-call wrappers (poll, signalfd, inotify, a CLOCK_REALTIME timerfd, flock, adjtimex) and the file-reading
//! idioms of flightrec/main.rs and overlay/sampler.rs: a file read at every snapshot stays open and is re-read with
//! pread from offset 0 (procfs, sysfs and cgroupfs regenerate it there). Nothing here panics: every failure is an
//! Option/Result for the caller to log once and skip.
use std::collections::HashSet;
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileExt, OpenOptionsExt};
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::Path;

fn clock(id: libc::clockid_t) -> f64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: ts is a valid, writable timespec for the kernel to fill
    unsafe { libc::clock_gettime(id, &mut ts) };
    ts.tv_sec as f64 + ts.tv_nsec as f64 / 1e9
}

/// CLOCK_MONOTONIC s: the clock of flightrec's t=, of the energy and edge files and of journal's __MONOTONIC_TIMESTAMP
pub fn mono() -> f64 {
    clock(libc::CLOCK_MONOTONIC)
}

/// CLOCK_REALTIME s, as it is (the RTC starts at 1970 here until chrony steps the clock)
pub fn wall() -> f64 {
    clock(libc::CLOCK_REALTIME)
}

/// this thread's CPU time, s (--bench)
pub fn cpu() -> f64 {
    clock(libc::CLOCK_THREAD_CPUTIME_ID)
}

/// the whole content of an open file, read with pread from offset 0 into buf (cleared first)
pub fn pread_all(f: &File, buf: &mut Vec<u8>) -> io::Result<usize> {
    buf.clear();
    let mut off: usize = 0;
    loop {
        if buf.len() < off + 16384 {
            buf.resize(off + 16384, 0);
        }
        let n = match buf.get_mut(off..) {
            Some(dst) => f.read_at(dst, off as u64)?,
            None => 0,
        };
        if n == 0 {
            break;
        }
        off += n;
        if off > 4 << 20 {
            break; // never: /proc/stat is a few KiB
        }
    }
    buf.truncate(off);
    Ok(off)
}

/// one-off read (files that come and go: thread status, fdinfo, cgroup membership): open, read, close
pub fn read_into(path: &Path, buf: &mut Vec<u8>) -> io::Result<usize> {
    buf.clear();
    let mut f = File::open(path)?;
    f.read_to_end(buf)
}

/// one-off read as trimmed text
pub fn read_text(path: &Path) -> Option<String> {
    fs::read(path).ok().map(|b| String::from_utf8_lossy(&b).trim().to_string())
}

/// the pids in /proc (no threads: /proc lists thread-group leaders only)
pub fn list_pids() -> Vec<i32> {
    let Ok(rd) = fs::read_dir("/proc") else { return vec![] };
    rd.flatten()
        .filter_map(|e| {
            let n = e.file_name();
            let b = n.as_bytes();
            if !b.is_empty() && b.iter().all(u8::is_ascii_digit) {
                std::str::from_utf8(b).ok()?.parse::<i32>().ok()
            } else {
                None
            }
        })
        .collect()
}

/// the pid in a pid file, if that process is alive and its comm starts with `name` (a stale pid file after a kill -9
/// can name an unrelated process)
pub fn pid_running(pidfile: &Path, name: &str) -> Option<i32> {
    let pid = read_text(pidfile)?.parse::<i32>().ok().filter(|&p| p > 1)?;
    read_text(Path::new(&format!("/proc/{pid}/comm"))).filter(|c| c.starts_with(name)).map(|_| pid)
}

/// one line to stderr (the journal), behind the elog! macro in main.rs. writeln! rather than eprintln!: that one
/// panics when the write fails (EPIPE once the journal's stream is gone), and nothing on the daemon's paths may panic
pub fn log_args(a: std::fmt::Arguments) {
    let _ = writeln!(io::stderr(), "{a}");
}

/// "only log once": a message key prints the first time; clear() lets a recovered condition log again
#[derive(Default)]
pub struct LogOnce {
    seen: HashSet<String>,
}

impl LogOnce {
    pub fn log(&mut self, key: &str, msg: &str) {
        if self.seen.insert(key.to_string()) {
            elog!("{msg}");
        }
    }

    pub fn clear(&mut self, key: &str) {
        self.seen.remove(key);
    }
}

fn u32_at(b: &[u8], i: usize) -> Option<u32> {
    b.get(i..i + 4).and_then(|s| <[u8; 4]>::try_from(s).ok()).map(u32::from_ne_bytes)
}

// ---- signals
/// TERM/INT/USR1 taken synchronously through a signalfd
pub struct SigFd {
    fd: OwnedFd,
}

impl SigFd {
    /// blocks `sigs` for the process, then opens a signalfd for them: from here on none of them takes its default
    /// action (USR1's would terminate us), so this comes before the pid file the page reads
    pub fn new(sigs: &[libc::c_int]) -> io::Result<SigFd> {
        // SAFETY: an all-zero sigset_t is valid storage for sigemptyset to initialise
        let mut set: libc::sigset_t = unsafe { std::mem::zeroed() };
        // SAFETY: set is a valid sigset_t; the signal numbers are libc constants
        let rc = unsafe {
            libc::sigemptyset(&mut set);
            for &s in sigs {
                libc::sigaddset(&mut set, s);
            }
            libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut())
        };
        if rc != 0 {
            return Err(io::Error::from_raw_os_error(rc));
        }
        // SAFETY: set holds the blocked signals; -1 asks for a new descriptor
        let fd = unsafe { libc::signalfd(-1, &set, libc::O_NONBLOCK | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: fd is a fresh descriptor nobody else owns
        Ok(SigFd { fd: unsafe { OwnedFd::from_raw_fd(fd) } })
    }

    pub fn raw(&self) -> RawFd {
        self.fd.as_raw_fd()
    }

    /// the signals that arrived: ssi_signo, the first field of each 128-byte signalfd_siginfo
    pub fn read(&self) -> Vec<u32> {
        let mut out = vec![];
        let mut buf = [0u8; 128 * 8];
        loop {
            // SAFETY: buf is writable for its whole length
            let n = unsafe { libc::read(self.raw(), buf.as_mut_ptr().cast(), buf.len()) };
            if n <= 0 {
                break;
            }
            for rec in buf.get(..n as usize).unwrap_or(&[]).chunks_exact(128) {
                if let Some(s) = u32_at(rec, 0) {
                    out.push(s);
                }
            }
        }
        out
    }
}

// ---- inotify
pub const IN_MOVED_TO: u32 = 0x80;
pub const IN_IGNORED: u32 = 0x8000;

/// one watch on a directory for renames onto a name (flightrec's edge.tmp -> edge), re-added when it is missing
pub struct Inotify {
    fd: OwnedFd,
    wd: i32,
    dir: CString,
}

impl Inotify {
    pub fn new(dir: &Path) -> io::Result<Inotify> {
        let dir = CString::new(dir.as_os_str().as_bytes()).map_err(|_| io::Error::from_raw_os_error(libc::EINVAL))?;
        // SAFETY: plain system call without pointer arguments
        let fd = unsafe { libc::inotify_init1(libc::O_NONBLOCK | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: fd is a fresh descriptor nobody else owns
        Ok(Inotify { fd: unsafe { OwnedFd::from_raw_fd(fd) }, wd: -1, dir })
    }

    pub fn raw(&self) -> RawFd {
        self.fd.as_raw_fd()
    }

    /// true while the watch is in place; adds it when missing. The directory is made by flightrec's first start
    /// (no RuntimeDirectory= in its unit), which an autologin session can beat (ENOENT), and may go and come back.
    pub fn ensure(&mut self) -> bool {
        if self.wd >= 0 {
            return true;
        }
        // SAFETY: dir is a NUL-terminated path that outlives the call
        let wd = unsafe { libc::inotify_add_watch(self.fd.as_raw_fd(), self.dir.as_ptr(), IN_MOVED_TO) };
        self.wd = if wd >= 0 { wd } else { -1 };
        self.wd >= 0
    }

    /// reads every queued event: true if one was a rename onto `name`; an IN_IGNORED (the directory was removed)
    /// drops the watch, ensure() adds it again later
    pub fn drain(&mut self, name: &[u8]) -> bool {
        let mut hit = false;
        let mut buf = [0u8; 4096];
        loop {
            // SAFETY: buf is writable for its whole length
            let n = unsafe { libc::read(self.fd.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
            if n <= 0 {
                break;
            }
            let (h, ign) = parse_events(buf.get(..n as usize).unwrap_or(&[]), name);
            hit |= h;
            if ign {
                self.wd = -1;
            }
        }
        hit
    }
}

/// (an IN_MOVED_TO onto `name` seen, an IN_IGNORED seen) in a buffer of struct inotify_event records:
/// wd i32, mask u32, cookie u32, len u32, then len bytes of NUL-padded name
pub fn parse_events(buf: &[u8], name: &[u8]) -> (bool, bool) {
    let (mut hit, mut ign) = (false, false);
    let mut off = 0usize;
    while let Some(hdr) = buf.get(off..off + 16) {
        let mask = u32_at(hdr, 4).unwrap_or(0);
        let len = u32_at(hdr, 12).unwrap_or(0) as usize;
        let raw = buf.get(off + 16..off + 16 + len).unwrap_or(&[]);
        let nm = raw.split(|&b| b == 0).next().unwrap_or(&[]);
        if mask & IN_MOVED_TO != 0 && nm == name {
            hit = true;
        }
        if mask & IN_IGNORED != 0 {
            ign = true;
        }
        off += 16 + len;
    }
    (hit, ign)
}

// ---- clock steps
const TFD_TIMER_ABSTIME: libc::c_int = 1;
const TFD_TIMER_CANCEL_ON_SET: libc::c_int = 2;
const Y2100: libc::time_t = 4_102_444_800;

/// a CLOCK_REALTIME timerfd armed for the year 2100 with TFD_TIMER_CANCEL_ON_SET: it only becomes readable when the
/// wall clock is set (chrony's makestep, a manual date), never by expiring
pub struct ClockWatch {
    fd: OwnedFd,
}

impl ClockWatch {
    pub fn new() -> io::Result<ClockWatch> {
        // SAFETY: plain system call without pointer arguments
        let fd = unsafe { libc::timerfd_create(libc::CLOCK_REALTIME, libc::O_NONBLOCK | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: fd is a fresh descriptor nobody else owns
        let w = ClockWatch { fd: unsafe { OwnedFd::from_raw_fd(fd) } };
        w.arm()?;
        Ok(w)
    }

    fn arm(&self) -> io::Result<()> {
        let its = libc::itimerspec {
            it_interval: libc::timespec { tv_sec: 0, tv_nsec: 0 },
            it_value: libc::timespec { tv_sec: Y2100, tv_nsec: 0 },
        };
        let flags = TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET;
        // SAFETY: its is a valid itimerspec for the call; the old value is not wanted (null)
        let rc = unsafe { libc::timerfd_settime(self.fd.as_raw_fd(), flags, &its, std::ptr::null_mut()) };
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    pub fn raw(&self) -> RawFd {
        self.fd.as_raw_fd()
    }

    /// true if the wall clock was set since the last call (the read fails with ECANCELED); armed again either way
    pub fn stepped(&self) -> bool {
        let mut b = [0u8; 8];
        // SAFETY: b is writable for the 8 bytes a timerfd read returns
        let n = unsafe { libc::read(self.fd.as_raw_fd(), b.as_mut_ptr().cast(), b.len()) };
        if n < 0 {
            let canceled = io::Error::last_os_error().raw_os_error() == Some(libc::ECANCELED);
            if canceled {
                let _ = self.arm();
            }
            return canceled;
        }
        if n == 8 {
            let _ = self.arm(); // the year 2100 came: arm again
        }
        false
    }
}

// ---- poll
/// waits until one of fds has input (a negative fd is ignored) or timeout_ms passed; which ones are readable
pub fn poll_in(fds: &[RawFd], timeout_ms: i32) -> Vec<bool> {
    let mut p: Vec<libc::pollfd> = fds.iter().map(|&fd| libc::pollfd { fd, events: libc::POLLIN, revents: 0 }).collect();
    // SAFETY: p is a valid array of p.len() pollfd structs for the duration of the call
    let n = unsafe { libc::poll(p.as_mut_ptr(), p.len() as libc::nfds_t, timeout_ms) };
    if n <= 0 {
        return vec![false; fds.len()];
    }
    p.iter().map(|x| x.revents & (libc::POLLIN | libc::POLLERR | libc::POLLHUP) != 0).collect()
}

// ---- single instance
pub enum Lock {
    Held(File),
    Busy,
    Failed(io::Error),
}

/// flock(LOCK_EX|LOCK_NB) on path; the lock lives as long as the returned File
pub fn try_lock(path: &Path) -> Lock {
    let f = match OpenOptions::new().create(true).truncate(false).write(true).mode(0o644).open(path) {
        Ok(f) => f,
        Err(e) => return Lock::Failed(e),
    };
    // SAFETY: f is an open descriptor for the duration of the call
    if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Lock::Held(f);
    }
    let e = io::Error::last_os_error();
    if e.raw_os_error() == Some(libc::EWOULDBLOCK) {
        Lock::Busy
    } else {
        Lock::Failed(e)
    }
}

// ---- the kernel's synchronisation flag
extern "C" {
    fn adjtimex(buf: *mut libc::c_void) -> libc::c_int;
}
const TIME_ERROR: libc::c_int = 5;

/// adjtimex with modes 0 (read-only): synchronised unless the clock state is TIME_ERROR (STA_UNSYNC set). Only the
/// fallback when chronyc gives no answer (chrony clears STA_UNSYNC only with rtcsync on).
pub fn kernel_synced() -> bool {
    let mut buf = [0u64; 64];
    // SAFETY: 512 zeroed, 8-aligned bytes, more than struct timex (208 bytes on aarch64); modes = 0 only reads
    let rc = unsafe { adjtimex(buf.as_mut_ptr().cast()) };
    rc >= 0 && rc != TIME_ERROR
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(mask: u32, name: &str) -> Vec<u8> {
        let mut nm = name.as_bytes().to_vec();
        if !nm.is_empty() {
            nm.resize((nm.len() / 16 + 1) * 16, 0); // NUL-padded like the kernel's
        }
        let mut b = vec![];
        b.extend_from_slice(&1i32.to_ne_bytes());
        b.extend_from_slice(&mask.to_ne_bytes());
        b.extend_from_slice(&0u32.to_ne_bytes());
        b.extend_from_slice(&(nm.len() as u32).to_ne_bytes());
        b.extend_from_slice(&nm);
        b
    }

    #[test]
    fn inotify_name_filter() {
        assert_eq!(parse_events(&ev(IN_MOVED_TO, "edge"), b"edge"), (true, false));
        assert_eq!(parse_events(&ev(IN_MOVED_TO, "edge.tmp"), b"edge"), (false, false));
        assert_eq!(parse_events(&ev(IN_MOVED_TO, "energy"), b"edge"), (false, false));
        assert_eq!(parse_events(&ev(0x100, "edge"), b"edge"), (false, false)); // IN_CREATE: not subscribed anyway
        let mut b = ev(IN_MOVED_TO, "x");
        b.extend(ev(IN_MOVED_TO, "edge"));
        b.extend(ev(IN_IGNORED, ""));
        assert_eq!(parse_events(&b, b"edge"), (true, true));
        // a truncated record is not read past the buffer
        assert_eq!(parse_events(&b[..20], b"edge"), (false, false));
        assert_eq!(parse_events(&[], b"edge"), (false, false));
    }

    fn tmpdir(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("y700-batteryd-test-{}-{tag}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn watch_dir_appears_later_and_comes_back() {
        let d = tmpdir("watch");
        let mut w = Inotify::new(&d).unwrap();
        assert!(!w.ensure(), "no directory yet: ENOENT");
        fs::create_dir_all(&d).unwrap();
        assert!(w.ensure());
        fs::write(d.join("edge.tmp"), "v1 t=1.0 dpms=On pw=dis\n").unwrap();
        fs::rename(d.join("edge.tmp"), d.join("edge")).unwrap();
        assert!(w.drain(b"edge"));
        assert!(!w.drain(b"edge"), "drained");
        fs::remove_dir_all(&d).unwrap();
        let _ = w.drain(b"edge"); // IN_IGNORED
        assert!(!w.ensure(), "gone: the watch is dropped and cannot be added");
        fs::create_dir_all(&d).unwrap();
        assert!(w.ensure(), "made again: watched again");
        fs::write(d.join("edge.tmp"), "x").unwrap();
        fs::rename(d.join("edge.tmp"), d.join("edge")).unwrap();
        assert!(w.drain(b"edge"));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn second_lock_is_busy() {
        let d = tmpdir("lock");
        fs::create_dir_all(&d).unwrap();
        let p = d.join("lock");
        let first = try_lock(&p);
        assert!(matches!(first, Lock::Held(_)));
        // flock belongs to the open file description: a second open in the same process conflicts like a second daemon
        assert!(matches!(try_lock(&p), Lock::Busy));
        drop(first);
        assert!(matches!(try_lock(&p), Lock::Held(_)));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn pread_reads_everything() {
        let d = tmpdir("pread");
        fs::create_dir_all(&d).unwrap();
        let p = d.join("f");
        let data: Vec<u8> = (0..40000u32).map(|i| (i % 251) as u8).collect();
        fs::write(&p, &data).unwrap();
        let f = File::open(&p).unwrap();
        let mut buf = vec![];
        assert_eq!(pread_all(&f, &mut buf).unwrap(), data.len());
        assert_eq!(buf, data);
        let _ = fs::remove_dir_all(&d);
    }
}
