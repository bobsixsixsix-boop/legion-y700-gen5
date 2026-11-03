//! The sync flag of every line (DESIGN.md section 2 "时钟"): `chronyc -n -c tracking`'s Leap status, "Normal" =
//! synchronised. The kernel's flag (adjtimex) is only the fallback when chronyc gives no answer - not installed, or
//! chronyd not running ("506 Cannot talk to daemon", empty stdout): chrony clears STA_UNSYNC only with rtcsync on, and
//! the repo plans to turn rtcsync off. A wall time > 1.7e9 proves nothing (fake-hwclock loads an old one).
//! Asked at start, after every clock step and at every snapshot while not synchronised except the TERM one (which must
//! end within TimeoutStopSec); once synchronised, never again until the next step. chronyc's stdout is read to its end
//! under poll, not waited for in a sleep loop: TimerSlackNSec=10s in the unit may stretch every sleep by up to 10 s,
//! while a poll returns as soon as chronyc writes or exits. A chronyc that hangs is killed after 3 s (the slack can
//! stretch only that last timeout). std's Command resets the child's signal mask, so the TERM/INT/USR1 blocked here do
//! not stay blocked in it.
use std::io::{self, Read};
use std::os::unix::io::AsRawFd;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::fds;

pub enum Chrony {
    Missing,
    Failed,
    Out(String),
}

/// the Leap status of `chronyc -c tracking`'s CSV line (its last field): Some(true) for "Normal", Some(false) for
/// "Not synchronised"/"Insert second"/..., None when the output is not a tracking line
pub fn parse_tracking(out: &str) -> Option<bool> {
    let line = out.lines().map(str::trim).find(|l| !l.is_empty())?;
    if !line.contains(',') {
        return None;
    }
    let last = line.rsplit(',').next()?.trim();
    if last.is_empty() {
        return None;
    }
    Some(last == "Normal")
}

/// (synchronised, which source said so)
pub fn decide(c: &Chrony, kernel: bool) -> (bool, &'static str) {
    if let Chrony::Out(o) = c {
        if let Some(s) = parse_tracking(o) {
            return (s, "chrony");
        }
    }
    (kernel, "adjtimex")
}

pub fn run_chronyc() -> Chrony {
    let spawned = Command::new("chronyc")
        .args(["-n", "-c", "tracking"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let mut child = match spawned {
        Ok(c) => c,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Chrony::Missing,
        Err(_) => return Chrony::Failed,
    };
    let t0 = Instant::now();
    let mut out: Vec<u8> = Vec::with_capacity(512);
    let mut eof = false;
    if let Some(mut so) = child.stdout.take() {
        let fd = so.as_raw_fd();
        let mut chunk = [0u8; 1024];
        loop {
            let left = Duration::from_secs(3).saturating_sub(t0.elapsed());
            if left.is_zero() || out.len() > 64 << 10 {
                break; // hung (or, never, a flood: a tracking line is ~200 bytes)
            }
            let ms = (left.as_millis() as i32).max(1);
            if fds::poll_in(&[fd], ms).first() != Some(&true) {
                continue;
            }
            // readable or hung up: a read returns at once
            match so.read(&mut chunk) {
                Ok(0) => {
                    eof = true;
                    break;
                }
                Ok(n) => out.extend_from_slice(chunk.get(..n).unwrap_or(&[])),
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
    }
    if !eof {
        let _ = child.kill();
        let _ = child.wait();
        return Chrony::Failed;
    }
    // stdout closes as chronyc exits: this wait only reaps it
    let _ = child.wait();
    Chrony::Out(String::from_utf8_lossy(&out).into_owned())
}

pub struct Clock {
    pub sync: bool,
    pub src: &'static str,
    missing: bool, // chronyc not installed: not looked for again
}

impl Clock {
    pub fn new() -> Clock {
        let mut c = Clock { sync: false, src: "adjtimex", missing: false };
        c.refresh();
        c
    }

    #[cfg(test)]
    pub fn fixed(sync: bool) -> Clock {
        Clock { sync, src: "chrony", missing: true }
    }

    pub fn refresh(&mut self) {
        let c = if self.missing { Chrony::Missing } else { run_chronyc() };
        if matches!(c, Chrony::Missing) {
            self.missing = true;
        }
        let (s, src) = decide(&c, fds::kernel_synced());
        self.sync = s;
        self.src = src;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tracking() {
        let ok = "A9FEA97B,169.254.169.123,4,1761803001.412345678,-0.000001234,0.000000512,0.000004321,-12.345,\
                  -0.001,0.050,0.000512345,0.000123456,64.2,Normal\n";
        assert_eq!(parse_tracking(ok), Some(true));
        let un = "7F7F0101,,10,0.000000000,0.000000000,0.000000000,0.000000000,0.000,0.000,0.000,0.000000000,\
                  0.000000000,0.0,Not synchronised\n";
        assert_eq!(parse_tracking(un), Some(false));
        assert_eq!(parse_tracking("\n506 Cannot talk to daemon\n"), None);
        assert_eq!(parse_tracking(""), None);
        assert_eq!(parse_tracking("a,b,\n"), None);
    }

    #[test]
    fn fallback() {
        let ok = Chrony::Out("x,y,Normal\n".into());
        assert_eq!(decide(&ok, false), (true, "chrony"));
        assert_eq!(decide(&Chrony::Out("x,y,Not synchronised".into()), true), (false, "chrony"));
        assert_eq!(decide(&Chrony::Out(String::new()), true), (true, "adjtimex"));
        assert_eq!(decide(&Chrony::Missing, false), (false, "adjtimex"));
        assert_eq!(decide(&Chrony::Failed, true), (true, "adjtimex"));
    }
}
