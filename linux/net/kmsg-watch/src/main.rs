// y700-kmsg-watch: start the y700 Wi-Fi / display watchdogs when the kernel logs their error line.
//
// Replaces y700-wifi-watchdog.timer and y700-display-watchdog.timer, which ran both oneshot scripts every ~65 s (a
// systemd job, a cgroup, /bin/sh and journalctl each time) although nothing is wrong 99.99 % of the time. This process
// sleeps in poll() on /dev/kmsg and does nothing until the kernel stores a log record. Then:
//
//   - a KERNEL record (facility 0) containing one of WATCHES -> `systemctl start --no-block <watchdog>.service`, SETTLE s
//     after the first match (a burst is looked at as a whole: even a healthy boot logs isolated vblank timeouts in
//     pairs ~60 ms apart, 10 lines in 70 min in kernel-y8/inventory/dmesg) and never sooner than DEBOUNCE s after the
//     previous start of that watchdog. Every match is therefore followed by a start within DEBOUNCE s, and a storm
//     costs one start per DEBOUNCE s per watchdog. Userspace writes to /dev/kmsg are forced to facility >= 1 by the
//     kernel (devkmsg_write), so journald, systemd and tb323fu-emergency-key's "<1>tb323fu: ..." lines can never
//     trigger a watchdog;
//   - a lost-records error (-EPIPE: the ring buffer overtook us) counts as a match for both, to be safe;
//   - "<15>y700-kmsg-watch: selftest <token>" written to /dev/kmsg by `y700-kmsg-watch --selftest` (root; the daily
//     y700-checklist) -> both watchdogs are started now and the result goes to RESULT for the caller.
//
// The watchdog scripts still decide everything themselves (count the lines in journalctl -k, cool-down, Wi-Fi radio
// switch, recovery, notification). Starting a unit whose start job is still running is merged into that job by systemd
// (job.c job_install -> jobs_may_late_merge), so it never runs twice at once.
//
// Zero wakeups while the kernel log is quiet: with nothing armed the loop calls poll(-1); glibc turns that into
// ppoll(fds, 1, NULL) on arm64, and the kernel's do_poll() sleeps in schedule() with no hrtimer, on the log_wait queue
// that only a new record (wake_up_klogd) wakes -- or a signal. A timeout exists only while a start is armed, i.e. only
// within DEBOUNCE s after a matching line. No threads, no sd_notify watchdog (that would be a periodic wakeup).
// Design, proof with file:line, install / verify / roll back: y700/linux/net/KMSG-WATCH.md.
//
//   y700-kmsg-watch               the daemon (y700-kmsg-watch.service: root, sandboxed, SCHED_IDLE)
//   y700-kmsg-watch --selftest    root, from outside: ping the daemon through /dev/kmsg, print its answer,
//                                 exit 0 = it read the ping and both `systemctl start` calls returned 0
//
// Rust port (2026-11-03) of the Python daemon (last Python version: git 1814212 linux/net/y700-kmsg-watch, with its
// tests y700-kmsg-watch-selftest.py and y700-kmsg-watch-realtest.py). Decisions, journal lines, the --selftest
// protocol, its output and exit codes are the same; deliberate differences are marked RUST:. The Python loop already
// slept in poll(-1) with no wakeups; what the port buys is memory (python3.14: VmRSS 16.4 MB, its cgroup 6.9 MB on
// 11-03) and the interpreter's work on each record and at start-up. A record costs one read() and a few byte
// comparisons; nothing is allocated unless it matches.
// RUST: realtest.py builds a copy with another systemctl, RESULT and selftest tag put in at compile time (option_env!
// below; Python's realtest patched the module's globals). A normal build has none of them, so the installed binary
// cannot be pointed anywhere else.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const KMSG: &str = "/dev/kmsg";
const SYSTEMCTL: &str = match option_env!("Y700KW_RT_SYSTEMCTL") {
    Some(p) => p,
    None => "/usr/bin/systemctl",
};
const RESULT: &str = match option_env!("Y700KW_RT_RESULT") {
    Some(p) => p,
    None => "/run/y700-kmsg-watch/selftest", // RuntimeDirectory= of the unit
};
const TAG: &str = match option_env!("Y700KW_RT_TAG") {
    Some(t) => t,
    None => "y700-kmsg-watch: selftest ",
};
const DEBOUNCE: f64 = 20.0; // s: at most one start per watchdog per this long (the scripts look back 3 min / 1 min)
const SETTLE: f64 = 5.0; // s from the first matching line to the start (lets a burst arrive before the script counts)
const READ_MAX: usize = 8192; // one record per read(); smaller than the record -> EINVAL (kernel: PRINTK_MESSAGE_MAX 2048)
const DRAIN_MAX: usize = 256; // records handled per wakeup before the armed deadlines are looked at again (log storms)
const SELFTEST_WAIT: f64 = 10.0; // s the --selftest client waits for the answer
// (substring, unit): the SAME strings the scripts count with `journalctl -k ... | grep -c`; change both together.
// v7.3-rc4: ath12k mac.c ath12k_mac_flush() "failed to flush transmit queue, data pkts pending %d";
//           dpu_encoder_phys_vid.c DPU_ERROR("vblank timeout: %x") -> "[drm:...] [dpu error]vblank timeout: 400000"
const WATCHES: [(&str, &str); 2] = [
    ("failed to flush transmit queue", "y700-wifi-watchdog.service"),
    ("vblank timeout", "y700-display-watchdog.service"),
];
const N: usize = WATCHES.len();
const EPIPE_TEXT: &[u8] = b"kernel log records lost before they were read (EPIPE)";

fn log(msg: &str) {
    // stdout = the journal (y700-kmsg-watch.service); a write error is ignored, as Python's print did
    #[cfg(not(test))]
    let _ = writeln!(io::stdout(), "{msg}");
    #[cfg(test)]
    tests::LOGGED.with(|l| l.borrow_mut().push(msg.to_string()));
}

fn short(unit: &str) -> &str {
    // y700-wifi-watchdog.service -> wifi
    if unit.matches('-').count() >= 2 {
        unit.split('-').nth(1).unwrap_or(unit)
    } else {
        unit
    }
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w[0] == needle[0] && w == needle)
}

/// Python's bytes.decode("ascii", "replace"): one U+FFFD per byte >= 0x80 (the kernel escapes those anyway)
fn ascii(b: &[u8]) -> String {
    b.iter().map(|&c| if c < 0x80 { c as char } else { '\u{fffd}' }).collect()
}

/// Python's repr() of bytes, for the journal line about an unparsable record
fn py_repr(b: &[u8]) -> String {
    let q = if b.contains(&b'\'') && !b.contains(&b'"') { b'"' } else { b'\'' };
    let mut s = format!("b{}", q as char);
    for &c in b {
        match c {
            b'\\' => s.push_str("\\\\"),
            b'\t' => s.push_str("\\t"),
            b'\n' => s.push_str("\\n"),
            b'\r' => s.push_str("\\r"),
            _ if c == q => {
                s.push('\\');
                s.push(c as char)
            }
            0x20..=0x7e => s.push(c as char),
            _ => s.push_str(&format!("\\x{c:02x}")),
        }
    }
    s.push(q as char);
    s
}

/// One /dev/kmsg record -> (facility, seq, text) or None.
/// kernel/printk/printk.c info_print_ext_header() + msg_print_ext_body():
///   b"<prio>,<seq>,<usec>,<flag>[,caller=T123];<text>\n[ SUBSYSTEM=...\n DEVICE=...\n]"
/// prio = facility << 3 | level; the text's bytes < 0x20, >= 0x7f and backslashes are escaped as \xNN, so the text is
/// ASCII and never contains a newline: everything after the first newline is the device dictionary.
fn parse(rec: &[u8]) -> Option<(u64, u64, &[u8])> {
    // RUST: the two numbers as the kernel prints them (%u, %llu); Python's int() also took spaces, underscores and a
    // minus sign, which no kernel record has
    fn num(f: &[u8]) -> Option<u64> {
        std::str::from_utf8(f).ok()?.parse().ok()
    }
    let semi = rec.iter().position(|&b| b == b';')?;
    let mut fields = rec[..semi].split(|&b| b == b',');
    let prio = num(fields.next()?)?;
    let seq = num(fields.next()?)?;
    let body = &rec[semi + 1..];
    let text = &body[..body.iter().position(|&b| b == b'\n').unwrap_or(body.len())];
    Some((prio >> 3, seq, text))
}

/// The decisions, free of I/O: start(unit) -> exit code; times are CLOCK_MONOTONIC seconds.
struct Watcher {
    start: Box<dyn FnMut(&str) -> i32>,
    result: String,
    last: [Option<f64>; N],  // time of the last start (None: never)
    due: Vec<(usize, f64)>,  // armed starts, in the order they were armed (Python's dict order)
    unanswered: [u64; N],    // matches since the last start
    first: [Option<String>; N], // text of the first of those (200 characters are logged)
    matches: [u64; N],
    starts: [u64; N],
    failed: [u64; N],
    records: u64,
    lost: u64,
    overruns: u64,
    bad: u64,
    seq: Option<u64>,
    t0: Option<f64>,
}

impl Watcher {
    fn new(start: Box<dyn FnMut(&str) -> i32>, result: String) -> Watcher {
        Watcher {
            start,
            result,
            last: [None; N],
            due: Vec::new(),
            unanswered: [0; N],
            first: Default::default(),
            matches: [0; N],
            starts: [0; N],
            failed: [0; N],
            records: 0,
            lost: 0,
            overruns: 0,
            bad: 0,
            seq: None,
            t0: None,
        }
    }

    /// Once at start-up: let each script look back over whatever was logged before we were reading.
    fn begin(&mut self, now: f64) {
        self.t0 = Some(now);
        for i in 0..N {
            self.fire(i, now, Some("watcher start-up (catch-up for lines logged before it was reading)"));
        }
    }

    fn record(&mut self, rec: &[u8], now: f64) {
        let Some((facility, seq, text)) = parse(rec) else {
            self.bad += 1;
            if self.bad <= 3 {
                log(&format!("unparsable /dev/kmsg record ignored: {}", py_repr(&rec[..rec.len().min(80)])));
            }
            return;
        };
        if let Some(prev) = self.seq {
            if seq > prev.saturating_add(1) {
                self.lost += seq - prev - 1;
            }
        }
        self.seq = Some(seq);
        self.records += 1;
        if facility == 0 {
            for (i, (needle, _)) in WATCHES.iter().enumerate() {
                if find(text, needle.as_bytes()).is_some() {
                    self.hit(i, now, text);
                }
            }
        } else if let Some(at) = find(text, TAG.as_bytes()) {
            self.selftest(ascii(&text[at + TAG.len()..]).trim(), now);
        }
    }

    /// read() returned -EPIPE: records were overwritten before we read them (the kernel has moved us to the oldest one
    /// left). One of them may have matched, so treat it as a match for every watchdog.
    fn overrun(&mut self, now: f64) {
        self.overruns += 1;
        for i in 0..N {
            self.hit(i, now, EPIPE_TEXT);
        }
    }

    fn hit(&mut self, i: usize, now: f64, text: &[u8]) {
        self.matches[i] += 1;
        self.unanswered[i] += 1;
        if self.first[i].is_none() {
            self.first[i] = Some(ascii(&text[..text.len().min(200)]));
        }
        if !self.due.iter().any(|&(u, _)| u == i) {
            let at = match self.last[i] {
                None => now + SETTLE,
                Some(last) => (now + SETTLE).max(last + DEBOUNCE),
            };
            self.due.push((i, at));
        }
    }

    fn fire(&mut self, i: usize, now: f64, reason: Option<&str>) -> i32 {
        self.due.retain(|&(u, _)| u != i);
        let n = std::mem::take(&mut self.unanswered[i]);
        let first = self.first[i].take().unwrap_or_default();
        let unit = WATCHES[i].1;
        let rc = (self.start)(unit);
        self.last[i] = Some(now);
        self.starts[i] += 1;
        if rc != 0 {
            self.failed[i] += 1;
        }
        let lines = format!("{n} matching line{} since the last start, first: {first}", if n != 1 { "s" } else { "" });
        let why = match reason {
            Some(r) if n > 0 => format!("{r} (also answers {lines})"),
            Some(r) => r.to_string(),
            None => lines,
        };
        let failed = if rc == 0 { String::new() } else { format!(" -- systemctl FAILED (exit {rc})") };
        log(&format!("start {unit}: {why}{failed}"));
        rc
    }

    /// Seconds until the earliest armed start; None = nothing armed = poll(-1), no timer.
    fn timeout(&self, now: f64) -> Option<f64> {
        self.due.iter().map(|&(_, t)| t).reduce(f64::min).map(|t| (t - now).max(0.0))
    }

    fn expire(&mut self, now: f64) {
        for (i, t) in self.due.clone() {
            if t <= now + 0.001 {
                self.fire(i, now, None);
            }
        }
    }

    fn stats(&self, now: f64) -> String {
        let per = |d: &[u64; N]| {
            WATCHES.iter().zip(d).map(|((_, u), v)| format!("{}={v}", short(u))).collect::<Vec<_>>().join(" ")
        };
        let up = self.t0.map_or(0.0, |t0| now - t0);
        format!(
            "up {up:.0} s, records {}, lost {}, overruns {}, matches {}, starts {}, failed starts {}",
            self.records,
            self.lost,
            self.overruns,
            per(&self.matches),
            per(&self.starts),
            per(&self.failed)
        )
    }

    fn selftest(&mut self, token: &str, now: f64) {
        let ok = |c: u8| c.is_ascii_alphanumeric() || b"-_.".contains(&c);
        if !(0 < token.len() && token.len() <= 40 && token.bytes().all(ok)) {
            log("selftest record with a malformed token ignored");
            return;
        }
        let reason = format!("selftest {token}");
        let rcs: Vec<i32> = (0..N).map(|i| self.fire(i, now, Some(&reason))).collect();
        let verdict = if rcs.iter().all(|&rc| rc == 0) { "ok" } else { "FAIL" };
        let each = WATCHES.iter().zip(&rcs).map(|((_, u), rc)| format!("{}={rc}", short(u))).collect::<Vec<_>>();
        let line = format!("selftest {token} {verdict} {}; {}", each.join(" "), self.stats(now));
        if let Err(e) = write_result(&self.result, &line) {
            // RUST: io::Error's text ("Permission denied (os error 13)"); Python's OSError read "[Errno 13] ...: '<path>'"
            log(&format!("cannot write {}: {e}", self.result));
        }
        log(&line);
    }
}

fn write_result(path: &str, line: &str) -> io::Result<()> {
    if let Some(dir) = Path::new(path).parent() {
        fs::create_dir_all(dir)?;
    }
    let tmp = format!("{path}.tmp");
    fs::write(&tmp, format!("{line}\n"))?;
    fs::rename(&tmp, path)
}

/// What the loop needs from /dev/kmsg and the clock (the tests replay recorded kernel logs on a fake clock).
trait Source {
    fn now(&mut self) -> f64;
    /// timeout in s (None: forever) -> true when there is something to read
    fn wait(&mut self, timeout: Option<f64>) -> io::Result<bool>;
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize>;
}

struct Kmsg(File);

fn monotonic() -> f64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as f64 + ts.tv_nsec as f64 * 1e-9
}

fn poll_ms(timeout: Option<f64>) -> i32 {
    timeout.map_or(-1, |t| (t * 1000.0) as i32 + 1) // round up: never wake before the deadline
}

impl Source for Kmsg {
    fn now(&mut self) -> f64 {
        monotonic()
    }

    fn wait(&mut self, timeout: Option<f64>) -> io::Result<bool> {
        let mut p = libc::pollfd { fd: self.0.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        if unsafe { libc::poll(&mut p, 1, poll_ms(timeout)) } < 0 {
            let e = io::Error::last_os_error();
            // RUST: a signal ends this wait and the loop works out the timeout again; CPython retried with the time left
            return if e.kind() == io::ErrorKind::Interrupted { Ok(false) } else { Err(e) };
        }
        if p.revents & (libc::POLLNVAL | libc::POLLHUP) != 0 {
            let msg = format!("{KMSG}: poll returned {:#x}, giving up (systemd restarts us)", p.revents);
            return Err(io::Error::other(msg));
        }
        Ok(p.revents != 0)
    }

    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            match self.0.read(buf) {
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue, // as os.read() (PEP 475)
                r => return r,
            }
        }
    }
}

/// Read what is there (the fd is O_NONBLOCK), at most DRAIN_MAX records, so that an endless storm still gets back to
/// expire() in the loop.
fn drain(src: &mut impl Source, w: &mut Watcher, now: f64, buf: &mut [u8]) -> io::Result<()> {
    for _ in 0..DRAIN_MAX {
        match src.read(buf) {
            Ok(0) => return Ok(()),
            Ok(n) => w.record(&buf[..n], now),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(()), // -EAGAIN: nothing left
            // -EPIPE: overrun, the kernel reset our position to the oldest record
            Err(e) if e.kind() == io::ErrorKind::BrokenPipe => w.overrun(now),
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

/// The daemon's loop. Returns only with an error it cannot go on from (systemd restarts us).
fn run(src: &mut impl Source, w: &mut Watcher) -> io::Error {
    let mut buf = vec![0u8; READ_MAX];
    loop {
        let t = src.now();
        let readable = match src.wait(w.timeout(t)) {
            Ok(r) => r,
            Err(e) => return e,
        };
        let now = src.now();
        if readable {
            if let Err(e) = drain(src, w, now, &mut buf) {
                return e;
            }
        }
        let t = src.now();
        w.expire(t);
    }
}

fn spawn_status(prog: &str, args: &[&str]) -> i32 {
    // std's spawn gives the child SIGPIPE back at its default; SIGXFSZ is never ignored in a Rust program (CPython
    // ignored both, hence Python's setsigdef)
    match Command::new(prog).args(args).status() {
        Ok(st) => st.code().unwrap_or_else(|| -st.signal().unwrap_or(0)), // as os.waitstatus_to_exitcode
        Err(e) => {
            log(&format!("cannot run {prog}: {e}")); // RUST: io::Error's text, see selftest()
            255
        }
    }
}

fn systemctl_start(unit: &str) -> i32 {
    spawn_status(SYSTEMCTL, &["start", "--no-block", "--no-ask-password", "--quiet", unit])
}

fn banner() -> String {
    let units: Vec<&str> = WATCHES.iter().map(|w| w.1).collect();
    let needles: Vec<String> = WATCHES.iter().map(|w| format!("'{}'", w.0)).collect();
    format!(
        "reading {KMSG} from its end; starts {} on {} (kernel lines only), {SETTLE} s after the first line, at most once \
         per {DEBOUNCE} s each",
        units.join(", "),
        needles.join(", ")
    )
}

fn daemon() -> io::Error {
    // std opens with O_CLOEXEC
    let file = match OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK).open(KMSG) {
        Ok(f) => f,
        Err(e) => return io::Error::new(e.kind(), format!("{KMSG}: {e}")),
    };
    // devkmsg_llseek(SEEK_END): our seq = prb_next_seq(), only new records
    if let Err(e) = (&file).seek(SeekFrom::End(0)) {
        return io::Error::new(e.kind(), format!("{KMSG}: lseek: {e}"));
    }
    let mut w = Watcher::new(Box::new(systemctl_start), RESULT.to_string());
    log(&banner());
    let mut k = Kmsg(file);
    w.begin(k.now());
    run(&mut k, &mut w)
}

/// --selftest: Ok((exit code, the line to print)); Err: /dev/kmsg could not be written (nothing on stdout).
fn client_selftest(kmsg: &str, result: &str, timeout: f64) -> io::Result<(i32, String)> {
    let ms = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis();
    let token = format!("{}-{ms}", std::process::id());
    // one write() = one record. <15> = user.debug: the kernel keeps facility 1 (it never lets userspace write facility
    // 0) and level 7 is below the console loglevel, so the line is not printed on tty1 / ramoops
    OpenOptions::new().write(true).open(kmsg)?.write(format!("<15>{TAG}{token}\n").as_bytes())?;
    let end = monotonic() + timeout;
    let want = format!("selftest {token} ");
    loop {
        let line = fs::read_to_string(result).map(|s| s.trim().to_string()).unwrap_or_default();
        if line.starts_with(&want) {
            let code = if line.split_whitespace().nth(2) == Some("ok") { 0 } else { 1 };
            return Ok((code, line));
        }
        if monotonic() >= end {
            let line = format!(
                "selftest {token} NOANSWER: y700-kmsg-watch did not answer within {timeout} s (systemctl status \
                 y700-kmsg-watch)"
            );
            return Ok((1, line));
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let code = if args.is_empty() {
        // RUST: one line on stderr and exit 1 where Python printed a traceback (exit 1); SIGINT kills it like SIGTERM
        // (Python exited 0 on KeyboardInterrupt; systemd never sends SIGINT here)
        eprintln!("{}", daemon());
        1
    } else if args.len() == 1 && args[0] == "--selftest" {
        match client_selftest(KMSG, RESULT, SELFTEST_WAIT) {
            Ok((code, line)) => {
                println!("{line}");
                code
            }
            Err(e) => {
                eprintln!("{KMSG}: {e}"); // RUST: Python raised (traceback, exit 1)
                1
            }
        }
    } else {
        // RUST: points at the design doc; the Python text said "see the header of this file"
        eprintln!("usage: y700-kmsg-watch [--selftest]   (see y700/linux/net/KMSG-WATCH.md)");
        2
    };
    std::process::exit(code);
}

#[cfg(test)]
mod tests {
    // Port of y700-kmsg-watch-selftest.py (T1-T14, same scenarios and numbers): a simulator replays /dev/kmsg records on
    // a fake clock and answers for systemctl; the real Kmsg source runs on a SOCK_SEQPACKET socketpair (one read = one
    // record, O_NONBLOCK, POLLHUP when the peer goes). Real kernel text: linux/kernel-y8/inventory/dmesg (a healthy
    // 70-minute boot of this tablet: 3070 records, 10 isolated vblank timeouts) and
    // linux/power/cx-collapse/crash-0341-lastkmsg.log (36 vblank timeouts before the 03:41 hang). The scripts' look-back
    // windows and thresholds are read from linux/net/y700-*-watchdog themselves. The dmesg is kept local
    // (inventory/.gitignore): without it T2/T3 print SKIP instead of failing.
    use super::*;
    use std::cell::{Cell, RefCell};
    use std::collections::VecDeque;
    use std::os::fd::FromRawFd;
    use std::rc::Rc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    thread_local! {
        pub static LOGGED: RefCell<Vec<String>> = RefCell::new(Vec::new());
        static SEQ: Cell<u64> = Cell::new(100000);
    }

    const WIFI: &str = WATCHES[0].1;
    const DPU: &str = WATCHES[1].1;
    const WIFI_LINE: &str = "ath12k_wifi7_pci 0000:01:00.0: failed to flush transmit queue, data pkts pending 7";
    fn dmesg() -> Option<Vec<u8>> {
        fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../kernel-y8/inventory/dmesg")).ok()
    }
    const CRASH: &[u8] = include_bytes!("../../../power/cx-collapse/crash-0341-lastkmsg.log");
    const SCRIPTS: [(&str, &str); N] = [
        ("y700-wifi-watchdog", include_str!("../../y700-wifi-watchdog")),
        ("y700-display-watchdog", include_str!("../../y700-display-watchdog")),
    ];
    const SERVICE: &str = include_str!("../../y700-kmsg-watch.service");
    const SAFETY: &str = include_str!("../../y700-watchdog-safety.conf");
    const WIFI_TIMER: &str = include_str!("../../y700-wifi-watchdog.timer");

    fn logged(part: &str) -> bool {
        LOGGED.with(|l| l.borrow().iter().any(|m| m.contains(part)))
    }

    fn scratch(name: &str) -> String {
        static N: AtomicUsize = AtomicUsize::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        format!("{}/y700kw-test-{}-{name}-{n}", std::env::temp_dir().display(), std::process::id())
    }

    // ---- /dev/kmsg records as the kernel formats them (printk.c info_print_ext_header + msg_print_ext_body)
    fn esc(text: &str) -> String {
        text.bytes()
            .map(|b| if b < 0x20 || b >= 0x7f || b == b'\\' { format!("\\x{b:02x}") } else { (b as char).to_string() })
            .collect()
    }

    #[derive(Clone, Copy)]
    struct R {
        fac: u64,
        level: u64,
        dev: Option<(&'static str, &'static str)>,
        flag: &'static str,
        caller: Option<&'static str>,
        seq: Option<u64>,
    }
    const K: R = R { fac: 0, level: 3, dev: None, flag: "-", caller: None, seq: None };

    fn rec(text: &str, t: f64, r: R) -> Vec<u8> {
        let s = r.seq.unwrap_or_else(|| SEQ.with(|c| c.replace(c.get() + 1)));
        let caller = r.caller.map(|c| format!(",caller={c}")).unwrap_or_default();
        let dev = r.dev.map(|(a, b)| format!(" SUBSYSTEM={a}\n DEVICE={b}\n")).unwrap_or_default();
        format!("{},{s},{},{}{caller};{}\n{dev}", r.fac << 3 | r.level, (t * 1e6) as u64, r.flag, esc(text)).into_bytes()
    }

    fn dmesg_lines(raw: &[u8]) -> Vec<(f64, String)> {
        String::from_utf8_lossy(raw)
            .lines()
            .filter_map(|l| {
                let (ts, text) = l.strip_prefix('[')?.split_once("] ")?;
                Some((ts.trim_start().parse().ok()?, text.to_string()))
            })
            .collect()
    }

    fn matches_any(text: &str) -> bool {
        WATCHES.iter().any(|(n, _)| text.contains(n))
    }

    // ---- /dev/kmsg + the monotonic clock. events: (t, record | EPIPE) in ring-buffer (seq) order; a time earlier than
    // the one before is clamped (printk timestamps from different CPUs are not strictly ordered, the seq is). wait()
    // jumps the clock to the next arrival or to the timeout, whichever comes first; with no timeout and nothing left to
    // arrive the real process would sleep forever -> the error "done" ends run().
    enum Ev {
        Rec(Vec<u8>),
        Epipe,
    }

    struct Sim {
        t: Rc<Cell<f64>>,
        events: VecDeque<(f64, Ev)>,
        ready: VecDeque<Ev>,
        waits: Vec<(f64, Option<f64>)>,
        read_cost: f64,
    }

    impl Sim {
        fn arrive(&mut self) {
            while self.events.front().is_some_and(|e| e.0 <= self.t.get()) {
                self.ready.push_back(self.events.pop_front().unwrap().1);
            }
        }
    }

    impl Source for Sim {
        fn now(&mut self) -> f64 {
            self.t.get()
        }

        fn wait(&mut self, timeout: Option<f64>) -> io::Result<bool> {
            assert!(self.waits.len() <= 200_000, "runaway loop");
            let t = self.t.get();
            self.waits.push((t, timeout));
            self.arrive();
            if !self.ready.is_empty() {
                return Ok(true);
            }
            match (self.events.front().map(|e| e.0), timeout) {
                (None, None) => Err(io::Error::other("done")),
                (Some(next), to) if to.map_or(true, |to| next <= t + to) => {
                    self.t.set(next);
                    self.arrive();
                    Ok(true)
                }
                (_, to) => {
                    self.t.set(t + to.unwrap());
                    Ok(false)
                }
            }
        }

        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            if self.read_cost > 0.0 {
                self.t.set(self.t.get() + self.read_cost);
                self.arrive();
            }
            match self.ready.pop_front() {
                None => Err(io::Error::from_raw_os_error(libc::EAGAIN)),
                Some(Ev::Epipe) => Err(io::Error::from_raw_os_error(libc::EPIPE)),
                Some(Ev::Rec(r)) => {
                    buf[..r.len()].copy_from_slice(&r);
                    Ok(r.len())
                }
            }
        }
    }

    struct Played {
        sim: Sim,
        w: Watcher,
        starts: Rc<RefCell<Vec<(f64, String)>>>,
    }

    impl Played {
        fn starts_of(&self, unit: &str, after: f64) -> Vec<f64> {
            self.starts.borrow().iter().filter(|(t, u)| u == unit && *t > after).map(|s| s.0).collect()
        }
        fn all_starts(&self) -> Vec<(f64, String)> {
            self.starts.borrow().clone()
        }
    }

    fn play_with(events: Vec<(f64, Ev)>, t0: f64, rc: &[(&'static str, i32)], read_cost: f64, result: &str) -> Played {
        let mut prev = t0;
        let events = events
            .into_iter()
            .map(|(t, e)| {
                prev = prev.max(t);
                (prev, e)
            })
            .collect();
        let mut sim = Sim { t: Rc::new(Cell::new(t0)), events, ready: VecDeque::new(), waits: vec![], read_cost };
        let starts = Rc::new(RefCell::new(Vec::new()));
        let (clock, log, rc) = (sim.t.clone(), starts.clone(), rc.to_vec());
        let start = move |u: &str| {
            log.borrow_mut().push((clock.get(), u.to_string()));
            rc.iter().find(|r| r.0 == u).map_or(0, |r| r.1)
        };
        let mut w = Watcher::new(Box::new(start), result.to_string());
        w.begin(sim.now());
        let e = run(&mut sim, &mut w);
        assert_eq!(e.to_string(), "done", "the loop ended early");
        Played { sim, w, starts }
    }

    fn play(events: Vec<(f64, Ev)>) -> Played {
        play_with(events, 0.0, &[], 0.0, &(scratch("play") + "/selftest"))
    }

    fn recs(lines: &[(f64, &str)], r: R) -> Vec<(f64, Ev)> {
        lines.iter().map(|&(t, x)| (t, Ev::Rec(rec(x, t, r)))).collect()
    }

    /// the script's own look-back window (s) and threshold, so "would the script act at this start?" tracks them
    fn rule(unit: &str) -> (f64, usize) {
        let (name, text) = SCRIPTS.iter().find(|s| format!("{}.service", s.0) == unit).unwrap();
        let needle = WATCHES.iter().find(|w| w.1 == unit).unwrap().0;
        let grep = format!("grep -c \"{needle}\"");
        let line = text.lines().find(|l| l.contains("journalctl -k --since \"-") && l.contains("min\"") && l.contains(&grep));
        let min: f64 = line.expect(name).split("--since \"-").nth(1).unwrap().split("min\"").next().unwrap().parse().unwrap();
        let thr = text.split("[ \"$n\" -ge ").nth(1).expect(name).split(' ').next().unwrap().parse().unwrap();
        (min * 60.0, thr)
    }

    fn would_act(unit: &str, start: f64, matches: &[f64]) -> bool {
        let (window, threshold) = rule(unit);
        matches.iter().filter(|&&t| start - window <= t && t <= start).count() >= threshold
    }

    fn gaps(ts: &[f64]) -> Vec<f64> {
        ts.windows(2).map(|w| w[1] - w[0]).collect()
    }

    fn min(v: &[f64]) -> f64 {
        v.iter().copied().fold(f64::INFINITY, f64::min)
    }

    #[test]
    fn rules_parsed_from_both_scripts() {
        assert_eq!(rule(WIFI), (180.0, 2));
        assert_eq!(rule(DPU), (60.0, 15));
    }

    // ---- T1 parse: the record format
    #[test]
    fn t1_parse() {
        let r = rec(WIFI_LINE, 12.5, R { level: 4, dev: Some(("pci", "+pci:0000:01:00.0")), ..K });
        assert_eq!(parse(&r).map(|p| (p.0, p.2)), Some((0, WIFI_LINE.as_bytes())), "kernel record with device dictionary");
        let r = rec("hello", 0.0, R { caller: Some("T123"), flag: "c", ..K });
        assert_eq!(parse(&r).unwrap().2, b"hello", "caller field and continuation flag");
        assert_eq!(parse(&rec("x", 0.0, R { fac: 1, level: 4, ..K })).unwrap().0, 1, "userspace record is facility 1");
        let r = rec("a\\b\nc é vblank timeout: 1", 0.0, K);
        assert_eq!(parse(&r).unwrap().2, b"a\\x5cb\\x0ac \\xc3\\xa9 vblank timeout: 1", "escaped text stays on one line");
        for bad in [&b"garbage"[..], b"x,y;z", b"6;no seq"] {
            assert!(parse(bad).is_none(), "malformed record {bad:?}");
        }
    }

    // ---- T2 a healthy boot's real kernel log, matching lines removed: no start besides start-up, never a timer
    #[test]
    fn t2_quiet_boot_never_a_timer() {
        let Some(raw) = dmesg() else { eprintln!("SKIP t2: no linux/kernel-y8/inventory/dmesg (the author's boot log, kept local)"); return; };
        let boot = dmesg_lines(&raw);
        let quiet: Vec<(f64, &str)> = boot.iter().filter(|(_, x)| !matches_any(x)).map(|(t, x)| (*t, x.as_str())).collect();
        let n = quiet.len();
        let instants = quiet.iter().map(|q| q.0.to_bits()).collect::<std::collections::HashSet<_>>().len();
        let p = play(recs(&quiet, R { level: 6, ..K }));
        let wakeups = p.sim.waits.len() - 1; // the last wait is the endless sleep
        println!("T2 {n} records over {:.0} s -> {wakeups} poll wakeups", boot.last().unwrap().0 - boot[0].0);
        assert_eq!(p.all_starts().iter().map(|s| s.1.as_str()).collect::<Vec<_>>(), [WIFI, DPU], "only the two start-up starts");
        assert!(p.sim.waits.iter().all(|w| w.1.is_none()), "every poll had no timeout (poll(-1))");
        assert!(wakeups <= instants, "one wakeup per arrival instant at most: {wakeups} > {instants}");
        assert_eq!((p.w.records, p.w.lost), (n as u64, 0), "all records counted");
    }

    // ---- T3 the same boot with its 10 real vblank timeouts (pairs ~60 ms apart): one start per cluster, none acts
    #[test]
    fn t3_healthy_boot_vblank_pairs() {
        let Some(raw) = dmesg() else { eprintln!("SKIP t3: no linux/kernel-y8/inventory/dmesg (the author's boot log, kept local)"); return; };
        let boot = dmesg_lines(&raw);
        let all: Vec<(f64, &str)> = boot.iter().map(|(t, x)| (*t, x.as_str())).collect();
        let p = play(recs(&all, K));
        let dpu_t: Vec<f64> = boot.iter().filter(|(_, x)| x.contains("vblank timeout")).map(|b| b.0).collect();
        let d = p.starts_of(DPU, 0.0);
        println!("T3 vblank lines at {dpu_t:?}\n   display starts at {d:?}");
        assert_eq!(p.w.matches[1], 10, "10 matches seen");
        assert!(d.len() == 4 && (d[0] - (dpu_t[0] + SETTLE)).abs() < 1e-6, "one start per cluster, SETTLE s after its first line: {d:?}");
        assert!(!d.iter().any(|&s| would_act(DPU, s, &dpu_t)), "no start would act (threshold not reached)");
        assert!(p.starts_of(WIFI, 0.0).is_empty(), "wifi only started at start-up");
        let idle: Vec<_> = p
            .sim
            .waits
            .iter()
            .filter(|(t, to)| to.is_some() && !dpu_t.iter().any(|&a| a <= *t && *t <= a + SETTLE + 0.01))
            .collect();
        assert!(idle.is_empty(), "timeouts only within SETTLE s after a vblank line: {idle:?}");
        assert!(p.sim.waits.last().unwrap().1.is_none(), "last poll back to no timeout");
    }

    // ---- T4 the 03:41 hang's last kernel lines as one 10-second burst: the second start sees all 36
    #[test]
    fn t4_crash_burst() {
        let crash = String::from_utf8_lossy(CRASH);
        let lines: Vec<&str> = crash.lines().collect();
        let n = lines.len() as f64;
        let burst: Vec<(f64, &str)> = lines.iter().enumerate().map(|(i, x)| (1000.0 + 10.0 * i as f64 / n, *x)).collect();
        let p = play(recs(&burst, K));
        let d = p.starts_of(DPU, 0.0);
        let mt: Vec<f64> = burst.iter().filter(|b| b.1.contains("vblank timeout")).map(|b| b.0).collect();
        println!("T4 {} vblank lines in 10 s -> display starts at {d:?}", mt.len());
        assert!(!d.is_empty() && (d[0] - mt[0] - SETTLE).abs() < 1e-6 && d.len() <= 2, "first start SETTLE s after the first line: {d:?}");
        let after = d.iter().copied().filter(|&x| x >= *mt.last().unwrap()).fold(f64::INFINITY, f64::min);
        assert!(would_act(DPU, after, &mt), "the start after the last vblank line would recover");
    }

    // ---- T5 the 2026-10-13 Wi-Fi failure: a flush failure at the end of every ~20 s association
    #[test]
    fn t5_wifi_failure_every_21s() {
        let fl: Vec<f64> = (0..6).map(|i| 2000.0 + 21.0 * i as f64).collect();
        let lines: Vec<(f64, &str)> = fl.iter().map(|&t| (t, WIFI_LINE)).collect();
        let p = play(recs(&lines, R { level: 4, dev: Some(("pci", "+pci:0000:01:00.0")), ..K }));
        let s = p.starts_of(WIFI, 0.0);
        let first_act = s.iter().copied().find(|&x| would_act(WIFI, x, &fl));
        println!("T5 wifi starts at {s:?}; first that reloads: {first_act:?}");
        assert!(s.len() == fl.len() && min(&gaps(&s)) >= DEBOUNCE - 1e-6, "a start for every failure, >= DEBOUNCE apart: {s:?}");
        assert!(first_act.is_some_and(|a| a - fl[0] <= 30.0), "reload decided <= 30 s after the first failure");
        assert!(p.starts_of(DPU, 0.0).is_empty(), "display untouched");
    }

    // ---- T6 the 2026-10-13 DPU storm: 2 timeouts/s (+ the companion line) for 120 s
    #[test]
    fn t6_dpu_storm() {
        let st: Vec<f64> = (0..240).map(|i| 3000.0 + 0.5 * i as f64).collect();
        let mut ev = Vec::new();
        for &t in &st {
            let v = "[drm:dpu_encoder_phys_vid_wait_for_commit_done:583] [dpu error]vblank timeout: 80000000";
            let c = "[drm:dpu_kms_wait_for_commit_done:528] [dpu error]wait for commit done returned -110";
            ev.push((t, Ev::Rec(rec(v, t, K))));
            ev.push((t + 0.0001, Ev::Rec(rec(c, t, K))));
        }
        let p = play(ev);
        let d = p.starts_of(DPU, 0.0);
        let first_act = d.iter().copied().find(|&x| would_act(DPU, x, &st));
        println!("T6 storm 3000..3120 s -> display starts at {d:?}; first that recovers: {first_act:?}");
        assert!(min(&gaps(&d)) >= DEBOUNCE - 1e-6, "at most one start per DEBOUNCE s");
        assert_eq!(d.len(), 7, "7 starts in 125 s (not 240)");
        assert!(first_act.is_some_and(|a| a - st[0] <= 30.0), "recovery decided <= 30 s into the storm");
        assert!(p.sim.waits.last().unwrap().1.is_none() && p.w.due.is_empty(), "back to poll(-1) after the storm");
    }

    // ---- T7 userspace lines (facility forced >= 1 by devkmsg_write) never trigger, even with the exact text
    #[test]
    fn t7_userspace_never_triggers() {
        let ev = vec![
            (10.0, Ev::Rec(rec("tb323fu: vblank timeout", 10.0, R { fac: 1, level: 1, ..K }))),
            (11.0, Ev::Rec(rec(WIFI_LINE, 11.0, R { fac: 1, level: 4, ..K }))),
            (12.0, Ev::Rec(rec(WIFI_LINE, 12.0, R { fac: 3, level: 4, ..K }))),
        ];
        let p = play(ev);
        assert!(p.starts_of(WIFI, 0.0).is_empty() && p.starts_of(DPU, 0.0).is_empty(), "no start from userspace records");
        assert!(p.sim.waits.iter().all(|w| w.1.is_none()), "nothing armed");
    }

    // ---- T8 overrun: -EPIPE, then the next record 1000 seq numbers later
    #[test]
    fn t8_epipe() {
        let ev = vec![
            (50.0, Ev::Rec(rec("before", 50.0, R { seq: Some(5000), ..K }))),
            (60.0, Ev::Epipe),
            (60.0, Ev::Rec(rec("after", 60.0, R { seq: Some(6001), ..K }))),
        ];
        let p = play(ev);
        assert_eq!((p.w.overruns, p.w.lost), (1, 1000), "overrun counted, gap counted as lost");
        assert_eq!(p.starts_of(WIFI, 0.0), [60.0 + SETTLE], "wifi started SETTLE s later");
        assert_eq!(p.starts_of(DPU, 0.0), [60.0 + SETTLE], "display started SETTLE s later");
        assert!(logged("start y700-wifi-watchdog.service: 1 matching line since the last start, first: kernel log records lost"));
    }

    // ---- T9 selftest through /dev/kmsg: both started at once, result file written; FAIL when systemctl fails
    #[test]
    fn t9_selftest_record() {
        let dir = scratch("t9");
        let result = format!("{dir}/run/selftest");
        let u = R { fac: 1, level: 4, ..K };
        let ev = vec![
            (70.0, Ev::Rec(rec(&format!("{TAG}123-456"), 70.0, u))),
            (80.0, Ev::Rec(rec(&format!("{TAG}bad token!"), 80.0, u))),
        ];
        let p = play_with(ev, 0.0, &[], 0.0, &result);
        let res = fs::read_to_string(&result).unwrap();
        println!("T9 result: {}", res.trim());
        let at70: Vec<String> = p.all_starts().into_iter().filter(|s| s.0 == 70.0).map(|s| s.1).collect();
        assert_eq!(at70, [WIFI, DPU], "both started at the selftest instant");
        assert!(res.starts_with("selftest 123-456 ok wifi=0 display=0; up 70 s, records 1"), "result line: {res}");
        assert_eq!(
            res,
            "selftest 123-456 ok wifi=0 display=0; up 70 s, records 1, lost 0, overruns 0, matches wifi=0 display=0, \
             starts wifi=2 display=2, failed starts wifi=0 display=0\n"
        );
        assert!(p.all_starts().iter().all(|s| s.0 != 80.0) && logged("malformed"), "malformed token ignored");
        let p = play_with(vec![(70.0, Ev::Rec(rec(&format!("{TAG}9-9"), 70.0, u)))], 0.0, &[(DPU, 1)], 0.0, &result);
        assert!(fs::read_to_string(&result).unwrap().starts_with("selftest 9-9 FAIL wifi=0 display=1"), "FAIL reported");
        assert!(logged("start y700-display-watchdog.service: selftest 9-9 -- systemctl FAILED (exit 1)"));
        drop(p);
        let p = play(vec![(70.0, Ev::Rec(rec(&format!("{TAG}1-1"), 70.0, K)))]);
        assert_eq!(p.all_starts(), [(0.0, WIFI.to_string()), (0.0, DPU.to_string())], "a kernel line with the tag is not a selftest");
        fs::remove_dir_all(&dir).unwrap();
    }

    // ---- T10 systemctl failing on a real match: logged, counted, the loop goes on and retries on the next match
    #[test]
    fn t10_systemctl_failing() {
        let lines = [(100.0, WIFI_LINE), (150.0, WIFI_LINE)];
        let p = play_with(recs(&lines, R { level: 4, ..K }), 0.0, &[(WIFI, 1)], 0.0, &(scratch("t10") + "/selftest"));
        assert!(logged("FAILED (exit 1)"), "failure logged");
        assert_eq!((p.starts_of(WIFI, 0.0), p.w.failed[0]), (vec![105.0, 155.0], 3), "retried on the next match");
    }

    // ---- T11 an endless storm (the reader never sees EAGAIN): the armed start still fires on time
    #[test]
    fn t11_endless_storm() {
        let ev: Vec<(f64, Ev)> =
            (0..20000).map(|i| (500.0 + 0.001 * i as f64, Ev::Rec(rec("[dpu error]vblank timeout: 1", 500.0, K)))).collect();
        let p = play_with(ev, 0.0, &[], 0.01, &(scratch("t11") + "/selftest"));
        let d = p.starts_of(DPU, 0.0);
        let bound = 500.0 + SETTLE + DRAIN_MAX as f64 * 0.01 + 0.02;
        println!("T11 20000 records, 10 ms per read -> display starts at {d:?}");
        assert!(!d.is_empty() && d[0] <= bound, "first start no later than SETTLE + one drain round: {d:?} > {bound}");
        assert!(min(&gaps(&d)) >= DEBOUNCE - 1e-6, "still >= DEBOUNCE apart");
    }

    // ---- T12 the I/O side: poll timeouts as the daemon passes them, the real Kmsg source on a socketpair, the starter
    #[test]
    fn t12_poll_timeouts() {
        // the match comes right after the start-up starts, so the armed start waits for DEBOUNCE, not SETTLE
        let p = play_with(recs(&[(100.0, "[dpu error]vblank timeout: 1")], K), 100.0, &[], 0.0, &(scratch("t12") + "/s"));
        let ms: Vec<i32> = p.sim.waits.iter().map(|w| poll_ms(w.1)).collect();
        assert_eq!(ms, [-1, (DEBOUNCE * 1000.0) as i32 + 1, -1], "-1 (idle), 20001 (armed), -1 (idle again)");
        assert_eq!(poll_ms(Some(4.9999)), 5000, "rounded up: never before the deadline");
    }

    #[test]
    fn t12_real_source_on_a_socketpair() {
        let mut fds = [0; 2];
        let rc = unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC, 0, fds.as_mut_ptr()) };
        assert_eq!(rc, 0);
        let (ours, theirs) = unsafe { (File::from_raw_fd(fds[0]), File::from_raw_fd(fds[1])) };
        assert_eq!(unsafe { libc::fcntl(fds[0], libc::F_SETFL, libc::O_NONBLOCK) }, 0); // as /dev/kmsg is opened
        let writer = std::thread::spawn(move || {
            let mut theirs = theirs;
            let user = R { fac: 1, level: 7, ..K };
            for r in [
                b"garbage".to_vec(),
                rec("tb323fu: hello", 1.0, user),
                rec(&format!("{TAG}12-34"), 1.0, user),
                rec("[dpu error]vblank timeout: 1", 1.0, K),
            ] {
                theirs.write_all(&r).unwrap();
            }
            std::thread::sleep(Duration::from_millis(300));
        }); // theirs closes here: POLLHUP for the daemon's poll
        let dir = scratch("t12s");
        let result = format!("{dir}/selftest");
        let starts = Rc::new(RefCell::new(Vec::new()));
        let s2 = starts.clone();
        let mut w = Watcher::new(Box::new(move |u: &str| { s2.borrow_mut().push(u.to_string()); 0 }), result.clone());
        let mut k = Kmsg(ours);
        w.begin(k.now());
        let e = run(&mut k, &mut w);
        writer.join().unwrap();
        let e = e.to_string();
        assert!(e.starts_with("/dev/kmsg: poll returned 0x") && e.ends_with(", giving up (systemd restarts us)"), "{e}");
        assert_eq!((w.records, w.bad, w.lost), (3, 1, 0));
        assert!(logged("unparsable /dev/kmsg record ignored: b'garbage'"));
        assert_eq!(*starts.borrow(), [WIFI, DPU, WIFI, DPU], "start-up, then the selftest");
        assert!(w.due.iter().any(|d| d.0 == 1), "the vblank line armed a display start");
        let res = fs::read_to_string(&result).unwrap();
        assert!(res.starts_with("selftest 12-34 ok wifi=0 display=0; up 0 s, records 2, lost 0"), "{res}");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn t12_starter_exit_codes() {
        assert_eq!(spawn_status("/bin/sh", &["-c", "exit 3"]), 3);
        assert_eq!(spawn_status("/bin/sh", &["-c", "kill -TERM $$"]), -libc::SIGTERM, "a signal as -signo");
        // this test process ignores SIGPIPE (std does); the child must not
        let sigign = "[ $(( 0x$(awk '/^SigIgn/ {print $2}' /proc/$$/status) & 0x1000 )) -eq 0 ]";
        assert_eq!(spawn_status("/bin/sh", &["-c", sigign]), 0, "SIGPIPE at its default in the child");
        assert_eq!(spawn_status("/nonexistent/systemctl", &["start"]), 255);
        assert!(logged("cannot run /nonexistent/systemctl: "));
    }

    #[test]
    fn t12_journal_lines() {
        assert_eq!(
            banner(),
            "reading /dev/kmsg from its end; starts y700-wifi-watchdog.service, y700-display-watchdog.service on \
             'failed to flush transmit queue', 'vblank timeout' (kernel lines only), 5 s after the first line, at most \
             once per 20 s each"
        );
        assert_eq!(py_repr(b"a'b\\\x00\xff\t"), "b\"a'b\\\\\\x00\\xff\\t\"");
        assert_eq!(py_repr(b"it's \"x\""), "b'it\\'s \"x\"'");
        assert_eq!((format!("{:.0}", 2.5), format!("{:.0}", 3.5), format!("{}", 10.0)), ("2".into(), "4".into(), "10".into()));
        let p = play(recs(&[(5.0, "[drm:x] [dpu error]vblank timeout: 1"), (5.06, "[dpu error]vblank timeout: 2")], K));
        drop(p);
        assert!(logged(
            "start y700-display-watchdog.service: 2 matching lines since the last start, first: [drm:x] [dpu error]vblank timeout: 1"
        ));
        assert!(logged("start y700-wifi-watchdog.service: watcher start-up (catch-up for lines logged before it was reading)"));
        assert_eq!(short(WIFI), "wifi");
        assert_eq!(short("x-y"), "x-y");
    }

    // ---- T13 the --selftest client: answered / FAIL / no answer
    fn run_client(rc: &'static [(&'static str, i32)], answer: bool, timeout: f64) -> ((i32, String), Vec<u8>, Vec<String>) {
        let dir = scratch("t13");
        fs::create_dir_all(&dir).unwrap();
        let (kfile, cres) = (format!("{dir}/kmsg"), format!("{dir}/run/client"));
        fs::write(&kfile, b"").unwrap();
        let starts = Arc::new(Mutex::new(Vec::new()));
        let (k2, c2, s2) = (kfile.clone(), cres.clone(), starts.clone());
        // the kernel (devkmsg_write) + the daemon, once
        let daemon = std::thread::spawn(move || {
            let end = monotonic() + 3.0;
            while answer && monotonic() < end {
                let data = fs::read_to_string(&k2).unwrap();
                if let Some((pri, text)) = data.trim_end().strip_prefix('<').and_then(|d| d.split_once('>')) {
                    let pri: u64 = pri.parse().unwrap();
                    let start = move |u: &str| {
                        s2.lock().unwrap().push(u.to_string());
                        rc.iter().find(|r| r.0 == u).map_or(0, |r| r.1)
                    };
                    let mut w = Watcher::new(Box::new(start), c2);
                    w.record(&rec(text, 0.0, R { fac: (pri >> 3).max(1), level: pri & 7, ..K }), 0.0);
                    return;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        });
        let out = client_selftest(&kfile, &cres, timeout).unwrap();
        daemon.join().unwrap();
        let written = fs::read(&kfile).unwrap();
        let starts = starts.lock().unwrap().clone();
        fs::remove_dir_all(&dir).unwrap();
        (out, written, starts)
    }

    #[test]
    fn t13_client() {
        let ((code, out), written, starts) = run_client(&[], true, 3.0);
        println!("T13 client wrote {:?}\n    printed {out:?}", String::from_utf8_lossy(&written));
        assert!(written.starts_with(format!("<15>{TAG}").as_bytes()) && written.iter().filter(|&&b| b == b'\n').count() == 1);
        assert!(code == 0 && out.contains(" ok ") && starts == [WIFI, DPU], "answered -> exit 0: {code} {out}");
        let ((code, out), _, _) = run_client(&[(WIFI, 5)], true, 3.0);
        assert!(code == 1 && out.contains("FAIL wifi=5"), "systemctl failing -> exit 1: {code} {out}");
        let ((code, out), _, _) = run_client(&[], false, 0.5);
        assert!(code == 1, "no answer -> exit 1");
        assert!(
            out.starts_with("selftest ")
                && out.ends_with(" NOANSWER: y700-kmsg-watch did not answer within 0.5 s (systemctl status y700-kmsg-watch)"),
            "{out}"
        );
        assert!(client_selftest("/nonexistent/kmsg", "/nonexistent/r", 0.1).is_err(), "unwritable kmsg -> error, no line");
    }

    // ---- T14 files: what the deployer gets
    #[test]
    fn t14_files() {
        for (name, text) in [("main.rs", include_str!("main.rs")), ("install.sh", include_str!("../install.sh")), ("unit", SERVICE)] {
            assert!(!text.contains('\r'), "{name}: LF line endings");
        }
        let here = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
        for ((needle, unit), (name, script)) in WATCHES.iter().zip(SCRIPTS) {
            assert_eq!(format!("{name}.service"), *unit);
            assert!(script.contains(&format!("grep -c \"{needle}\"")), "{name} greps exactly {needle:?}");
            for ext in [".service", ".timer"] {
                assert!(here.join(format!("{name}{ext}")).exists(), "{name}{ext} still in the repo");
            }
        }
        let mut settings: Vec<(&str, &str)> = Vec::new();
        for line in SERVICE.lines().filter(|l| !l.is_empty() && !l.starts_with('#') && !l.starts_with('[')) {
            settings.push(line.split_once('=').unwrap_or((line, "")));
        }
        let get = |k: &str| settings.iter().filter(|s| s.0 == k).map(|s| s.1).collect::<Vec<_>>();
        let runtime = Path::new(RESULT).parent().unwrap().file_name().unwrap().to_str().unwrap();
        for (k, v) in [
            ("ExecStart", "/usr/local/libexec/y700-kmsg-watch"),
            ("Restart", "always"),
            ("Type", "simple"),
            ("DeviceAllow", "/dev/kmsg r"),
            ("DevicePolicy", "closed"),
            ("CapabilityBoundingSet", "CAP_SYSLOG"),
            ("CPUSchedulingPolicy", "idle"),
            ("RuntimeDirectory", runtime),
            ("StartLimitIntervalSec", "0"),
            ("WantedBy", "multi-user.target"),
        ] {
            assert_eq!(get(k), [v], "unit {k}={v}");
        }
        // RUST: MemoryDenyWriteExecute= is no longer on this list: it would only have hurt CPython's JIT
        for k in ["ProtectKernelLogs", "PrivateDevices", "WatchdogSec", "User", "DynamicUser"] {
            assert!(get(k).is_empty(), "the unit must not set {k}= (it breaks the watcher)");
        }
        assert_eq!(RESULT, format!("/run/{runtime}/selftest"), "RESULT lives in the RuntimeDirectory");
        assert_eq!((SYSTEMCTL, TAG), ("/usr/bin/systemctl", "y700-kmsg-watch: selftest "), "a normal build");
        let body: Vec<&str> = SAFETY.lines().filter(|l| !l.is_empty() && !l.starts_with('#')).collect();
        assert!(!SAFETY.contains('\r'));
        assert_eq!(body, ["[Timer]", "OnBootSec=", "OnBootSec=15min", "OnUnitActiveSec=15min", "AccuracySec=1min"]);
        // systemd's own rule (load-fragment.c config_parse_timer): an empty OnXxxSec=/OnCalendar= value empties the WHOLE
        // list of the timer, any other value appends -- main unit file first, then the drop-in
        let timer_list = |files: &[&str]| {
            let mut out: Vec<(String, String)> = Vec::new();
            for line in files.iter().flat_map(|f| f.lines()) {
                if let Some((k, v)) = line.split_once('=') {
                    if k.starts_with("On") && (k.ends_with("Sec") || k == "OnCalendar") {
                        if v.is_empty() { out.clear() } else { out.push((k.into(), v.into())) }
                    }
                }
            }
            out
        };
        let pair = |k: &str, v: &str| (k.to_string(), v.to_string());
        assert_eq!(timer_list(&[WIFI_TIMER, SAFETY]), [pair("OnBootSec", "15min"), pair("OnUnitActiveSec", "15min")]);
        // the first version reset twice: OnUnitActiveSec= also dropped OnBootSec=15min, and OnUnitActiveSec alone never
        // elapses before the service's first start (timer.c TIMER_UNIT_ACTIVE, base <= 0) -- dead watcher, dead net
        let old = "[Timer]\nOnBootSec=\nOnBootSec=15min\nOnUnitActiveSec=\nOnUnitActiveSec=15min\n";
        assert_eq!(timer_list(&[WIFI_TIMER, old]), [pair("OnUnitActiveSec", "15min")]);
        // no time-based call and no thread in the daemon (the --selftest client after it may sleep)
        let core = include_str!("main.rs").split("\nfn client_selftest").next().unwrap();
        for line in core.lines().map(str::trim).filter(|l| !l.starts_with("//")) {
            for word in ["sleep", "alarm", "setitimer", "timerfd", "thread"] {
                assert!(!line.contains(word), "{word} in the daemon: {line}");
            }
        }
    }
}
