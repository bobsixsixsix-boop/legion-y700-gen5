//! y700-cx-auto: the runtime CX-collapse level "E3a" in daily use, only where it was tested (2026-10-17:
//! the tested level now, the deeper ones keep being tested at night).
//!
//! E3a = cpuidle_psci_domain allow_cluster_off=1 + allow_system_off=1 (the cluster and APSS power down when idle)
//! with the AOP told to keep CX and DDR up (qcom_aoss prevent_cx_collapse=1, prevent_ddr_collapse=1). Tested
//! (linux/power/cx-collapse/PROTOCOL.md section 9, README "底噪研究·执行记录"): y10 2x30 min, y12 30 min + E5 30 min
//! (Wi-Fi traffic) + E4 4 min (the panel switched every 20 s), all screen off on battery, zero resets; screen-off
//! power 0.27-0.30 W vs 0.33 W with the knobs off the same night.
//!
//! ARMED only while every connected display (the panel, and an external one on USB-C) has been off for ARM_DELAY_S,
//! the battery discharges, and cx-exp.sh's preconditions for making a reset cheap and visible hold: download_mode
//! off (the kernel boots with "full" and y700-dumpmode-off clears it at 180 s - a reset in full parks the SoC in the
//! XBL dump screen at ~1.6 W), uptime >= 240 s, the flight recorder running. DISARMED the moment a display is on
//! again (polled every POLL_S), the charger is in (polled every CHARGER_EVERY_S), an experiment or a screen-off
//! power bench runs (they own the knobs / measure the knobs-off floor), the owner disabled it, or the service stops.
//! While the owner uses the tablet nothing differs from before.
//!
//! Fail-safe: /var/lib/y700/cx-auto.armed (fsync'ed, with the boot id) exists while armed and for LINGER_S after a
//! disarm - the resets the CX work fears land 10-30 s after their trigger (0106: the panel switching), so one right
//! after a screen-on still counts. Found at start from a PREVIOUS boot = that boot ended armed (a reset, a crash, the
//! battery running out - a clean shutdown stops this service first, which removes it): cx-auto disables itself
//! (/var/lib/y700/cx-auto.disabled, with the reason) instead of arming again - one reset at most, never a loop;
//! y700-checklist reports it. From THIS boot = only the daemon restarted: disarm and carry on.
//! Re-enable: `y700-cx-auto --enable`. Off for good: `y700-cx-auto --disable`.
//! /run/y700-cx-auto.armed tells the flight recorder that knobs set by this are not an experiment (it stays at its
//! 10 s cadence; a 1 s one would eat a good part of what this saves). One instance only (flock).
//!
//! PLANNED, NOT IMPLEMENTED (linux/power/PLAN-deep-powersave.md, 2026-10-19; the Chinese description is in the root
//! README.md, :1529-1535 as of 10-19 - line numbers drift, search for the cx-auto paragraphs):
//! - T0 stuck detection + evidence (PLAN CPU-2 :161-166, phase P1.5): from armed+120 s read the
//!   power-domain-system entry count (/sys/kernel/debug/pm_genpd/power-domain-system/idle_states) over 5 min
//!   sliding windows; two consecutive windows < 1/s = cx_stuck -> `systemd-run --unit y700-diag-stuck-<ts>
//!   --collect ...` (y700-whoawake 60 s + plasmashell schedstat and /proc/interrupts 60 s deltas) into
//!   /var/log/y700-cx-auto/stuck-<ts>.txt; a counter under /var/lib/y700/ feeds the status page's e3a_fail_rate_3d
//!   (PLAN M-6 :145-149).
//! - T1/T2 after a stuck verdict (PLAN CPU-3 :167-173, phase N3, owner's call PLAN section 7 rows 7-9):
//!   STUCK_ACTION=none|blink|restart-shell in /etc/default/y700-cx-auto; blink = dim, screen on <= 10 s with touch
//!   inhibited, off again; restart-shell = restart plasmashell and verify; at most once per screen-off, >= 30 min
//!   apart; default none.
//! - --keep-cx (PLAN CPU-4 :174-177, phase P1.5): `cx-exp.sh --keep-cx` leaves ACO/ASO/AOSS alone (its EXIT trap
//!   restores nothing) so BENCHES can run under E3a; this daemon must then NOT disarm while a BENCHES unit exists.
//! - B2 charger_at fix (runs/audit-20261019.md:79, PLAN CHG-1 :344-346, section 7 row 6; ships with CPU-2 in
//!   P1.5): charger_at (:352, :378-388) is only refreshed every CHARGER_EVERY_S and is not reset on screen-on, so
//!   after a plug-in the daemon can keep treating the tablet as discharging for up to ~30 s (audit B2); one-line
//!   fix: when off_since goes None -> Some, set charger_at = -1e9.
//! None of the above is in the code below yet (2026-10-19, Win11-only P0 pass: comments only).
//!
//! Usage: y700-cx-auto            the daemon (root; y700-cx-auto.service)
//!        y700-cx-auto --status | --enable | --disable | --disarm (ExecStopPost)
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::io::AsRawFd;
use std::path::Path;

const ACO: &str = "/sys/module/cpuidle_psci_domain/parameters/allow_cluster_off";
const ASO: &str = "/sys/module/cpuidle_psci_domain/parameters/allow_system_off";
const AOSS_CX: &str = "/sys/kernel/debug/qcom_aoss/prevent_cx_collapse";
const AOSS_DDR: &str = "/sys/kernel/debug/qcom_aoss/prevent_ddr_collapse";
const DL_MODE: &str = "/sys/module/qcom_scm/parameters/download_mode";
const BAT_STATUS: &str = "/sys/class/power_supply/qcom-battmgr-bat/status";
const STATE_DIR: &str = "/var/lib/y700";
const ARMED: &str = "/var/lib/y700/cx-auto.armed";
const DISABLED: &str = "/var/lib/y700/cx-auto.disabled";
const RUN_FLAG: &str = "/run/y700-cx-auto.armed";
const LOCK: &str = "/run/y700-cx-auto.lock";
// besides every y700-cx-* unit (cx-exp, -ladder, -idle, -night; not this one and not the status page): the
// screen-off power benches (tools/), which measure the knobs-off floor
const BENCHES: [&str; 6] = ["y700-offmeasure", "y700-offbench", "y700-l1ssbench", "y700-powerbench", "y700-wakeups", "y700-standby-now"];
const POLL_S: i64 = 2;
const ARM_DELAY_S: f64 = 30.0; // the power key toggles the screen a lot: arm only after it stayed off this long
const LINGER_S: f64 = 60.0; // the armed marker outlives a disarm this long (see the fail-safe above)
const CHARGER_EVERY_S: f64 = 60.0; // the battery status is a glink round trip to the ADSP: not every poll

fn mono() -> f64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as f64 + ts.tv_nsec as f64 / 1e9
}

fn now_str() -> String {
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        let mut buf = [0u8; 32];
        let n = libc::strftime(buf.as_mut_ptr().cast(), buf.len(), c"%F %T".as_ptr(), &tm);
        String::from_utf8_lossy(&buf[..n]).into_owned()
    }
}

fn rd(path: &str) -> Option<String> {
    fs::read(path).ok().map(|b| String::from_utf8_lossy(&b).trim().to_string())
}

/// write a value to a knob; false when the write failed
fn put(path: &str, v: &str) -> bool {
    match OpenOptions::new().write(true).open(path).and_then(|mut f| f.write_all(v.as_bytes())) {
        Ok(()) => true,
        Err(e) => {
            println!("write {v} > {path}: {e}");
            false
        }
    }
}

/// write a file and fsync it and its directory (the markers must survive a reset)
fn put_durable(path: &str, content: &str) -> bool {
    let ok = File::create(path).and_then(|mut f| {
        f.write_all(content.as_bytes())?;
        f.sync_all()
    });
    if let Ok(d) = File::open(Path::new(path).parent().unwrap_or(Path::new("/"))) {
        let _ = d.sync_all();
    }
    ok.is_ok()
}

fn remove_durable(path: &str) {
    let _ = fs::remove_file(path);
    if let Ok(d) = File::open(Path::new(path).parent().unwrap_or(Path::new("/"))) {
        let _ = d.sync_all();
    }
}

/// an active experiment / bench unit. invocation:<unit> is a symlink to the invocation id - a DANGLING one, and
/// read_dir does not follow it (the first version used Path::exists, which does, and never saw a running cx-exp)
fn experiment_running() -> Option<String> {
    for e in fs::read_dir("/run/systemd/units").into_iter().flatten().flatten() {
        let n = e.file_name().to_string_lossy().into_owned();
        let Some(u) = n.strip_prefix("invocation:").and_then(|x| x.strip_suffix(".service")) else { continue };
        if (u.starts_with("y700-cx-") && u != "y700-cx-auto" && !u.starts_with("y700-cx-status")) || BENCHES.contains(&u) {
            return Some(u.to_string());
        }
    }
    None
}

fn knobs_on() -> bool {
    matches!(rd(ACO).as_deref(), Some("Y") | Some("1")) || matches!(rd(ASO).as_deref(), Some("Y") | Some("1"))
}

/// every CONNECTED display is off (the panel; an external monitor on USB-C counts too). False when none is connected
/// or one cannot be read: then never arm. Rescanned every poll (a monitor can be plugged in at any time).
fn displays_off() -> bool {
    let mut seen = false;
    for e in fs::read_dir("/sys/class/drm").into_iter().flatten().flatten() {
        let n = e.file_name().to_string_lossy().into_owned();
        if !n.starts_with("card") || !n.contains('-') || rd(&format!("/sys/class/drm/{n}/status")).as_deref() != Some("connected") {
            continue; // the disconnected DP-1 and the Writeback connector ("unknown") report dpms On forever
        }
        seen = true;
        if rd(&format!("/sys/class/drm/{n}/dpms")).as_deref() != Some("Off") {
            return false;
        }
    }
    seen
}

/// cx-exp.sh's preconditions that keep a reset cheap and visible, or None when they hold
fn arm_blocker() -> Option<String> {
    match rd(DL_MODE).as_deref() {
        Some("off") => {}
        dm => return Some(format!("download_mode={} (a reset would park the SoC in the dump screen)", dm.unwrap_or("?"))),
    }
    let up = rd("/proc/uptime").and_then(|u| u.split_whitespace().next().and_then(|x| x.parse::<f64>().ok())).unwrap_or(0.0);
    if up < 240.0 {
        return Some(format!("uptime {up:.0} s < 240 s"));
    }
    if fs::symlink_metadata("/run/systemd/units/invocation:y700-flightrec.service").is_err() {
        return Some("the flight recorder is not running".into());
    }
    None
}

struct Cx {
    armed: bool,
    linger_until: Option<f64>, // the armed marker goes at this monotonic time
    boot: String,
}

impl Cx {
    /// E3a, in cx-exp.sh's order: the AOP holds CX and DDR first, then the knobs. If the AOP refuses, nothing is
    /// opened (the knobs without it would be the untested E3c depth). False = not armed (no retry this screen-off).
    fn arm(&mut self, why: &str) -> bool {
        let release = || {
            put(AOSS_CX, "0");
            put(AOSS_DDR, "0");
        };
        if !(put(AOSS_CX, "1") && put(AOSS_DDR, "1")) {
            release();
            println!("not arming: the AOP refused to keep CX/DDR up (no retry until a display was on again)");
            return false;
        }
        if !put_durable(ARMED, &format!("{} boot={} {why}\n", now_str(), self.boot)) {
            release();
            println!("not arming: cannot write {ARMED} (no retry until a display was on again)");
            return false;
        }
        self.linger_until = None;
        if !displays_off() {
            // a display came on while the AOP and the marker were being written: do not open the knobs at all
            release();
            self.linger_until = Some(mono() + LINGER_S);
            println!("not arming: a display came on");
            return true; // not a failure: the next screen-off arms normally
        }
        let _ = fs::write(RUN_FLAG, "1\n");
        let ok = put(ACO, "1") & put(ASO, "1");
        self.armed = true;
        println!("armed (E3a): {why}{}", if ok { "" } else { " - a knob write failed" });
        true
    }

    /// the knobs first, then - only once they are really off - the AOP votes (cx-exp.sh's restore order); otherwise
    /// the AOP keeps holding CX/DDR (the knobs without its votes would be the untested E3c depth) and the next poll
    /// tries again. The armed marker lingers LINGER_S; `now_too` (a clean stop) removes it at once.
    fn disarm(&mut self, why: &str, now_too: bool) {
        put(ACO, "0");
        put(ASO, "0");
        if knobs_on() {
            println!("disarm ({why}): the knobs did not go off - keeping the AOP votes, retrying");
            return;
        }
        put(AOSS_CX, "0");
        put(AOSS_DDR, "0");
        let _ = fs::remove_file(RUN_FLAG);
        if now_too {
            remove_durable(ARMED);
            self.linger_until = None;
        } else {
            self.linger_until = Some(mono() + LINGER_S);
        }
        if self.armed {
            println!("disarmed: {why}");
        }
        self.armed = false;
    }
}

/// knobs this program opened (RUN_FLAG) with no daemon to close them: close them now, cx-exp.sh's restore order;
/// nothing when an experiment owns the knobs or there is no RUN_FLAG. Only safe without a running daemon (the
/// --disable case runs it next to a live one too: a harmless double close, the daemon then sees "disabled")
fn close_left_open(who: &str) {
    if !Path::new(RUN_FLAG).exists() || experiment_running().is_some() {
        return;
    }
    put(ACO, "0");
    put(ASO, "0");
    if knobs_on() {
        println!("{who}: the knobs did not go off - leaving the AOP votes in place");
        return;
    }
    put(AOSS_CX, "0");
    put(AOSS_DDR, "0");
    let _ = fs::remove_file(RUN_FLAG);
    println!("{who}: knobs left open by the daemon closed");
}

fn status() -> i32 {
    println!("cx-auto: {}", if Path::new(DISABLED).exists() { "DISABLED" } else { "enabled" });
    if let Some(r) = rd(DISABLED) {
        println!("  disabled because: {r}");
    }
    println!("  armed now: {}", if Path::new(RUN_FLAG).exists() { "yes" } else { "no" });
    println!("  knobs: aco={} aso={}", rd(ACO).unwrap_or("-".into()), rd(ASO).unwrap_or("-".into()));
    if let Some(u) = experiment_running() {
        println!("  experiment / bench unit active: {u}.service (it owns the knobs)");
    }
    if let Some(b) = arm_blocker() {
        println!("  would not arm now: {b}");
    }
    0
}

fn main() {
    std::process::exit(run());
}

fn run() -> i32 {
    let arg = std::env::args().nth(1).unwrap_or_default();
    let _ = fs::create_dir_all(STATE_DIR);
    match arg.as_str() {
        "--status" => return status(),
        "--enable" => {
            remove_durable(DISABLED);
            println!("cx-auto enabled (the daemon arms at the next screen-off on battery)");
            return 0;
        }
        "--disable" => {
            put_durable(DISABLED, &format!("{} the owner: y700-cx-auto --disable\n", now_str()));
            println!("cx-auto disabled (a running daemon disarms within {POLL_S} s)");
            close_left_open("--disable");
            return 0;
        }
        "--disarm" => {
            // ExecStopPost: the daemon is gone - by any exit (kill -9, a panic, a stop timeout; Restart= comes
            // after this): close what it opened. ARMED stays for the next start's same-boot / previous-boot logic.
            close_left_open("ExecStopPost");
            return 0;
        }
        "" => {}
        _ => {
            eprintln!("usage: y700-cx-auto [--status | --enable | --disable | --disarm]");
            return 1;
        }
    }
    // one daemon only: two would interleave arm and disarm (knobs on with the AOP votes off = E3c)
    let lock = match OpenOptions::new().create(true).write(true).open(LOCK) {
        Ok(f) => f,
        Err(e) => {
            println!("{LOCK}: {e}");
            return 1;
        }
    };
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        println!("another y700-cx-auto daemon runs (lock {LOCK}) - exiting");
        return 0;
    }

    // signals synchronously: sigtimedwait is the poll sleep, TERM/INT/HUP disarm and exit
    let mut set: libc::sigset_t = unsafe { std::mem::zeroed() };
    unsafe {
        libc::sigemptyset(&mut set);
        for s in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::sigaddset(&mut set, s);
        }
        libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
    }
    let boot = rd("/proc/sys/kernel/random/boot_id").unwrap_or_default();
    let mut cx = Cx { armed: false, linger_until: None, boot: boot.clone() };
    let mut force_disabled = false; // DISABLED could not be written: stay off for this boot anyway
    if let Some(prev) = rd(ARMED) {
        if !boot.is_empty() && prev.contains(&format!("boot={boot}")) {
            // only this daemon restarted (a crash of ours, Restart=on-failure): disarm and carry on
            cx.armed = true;
            cx.disarm("the daemon restarted while armed (same boot)", false);
        } else {
            let reason = format!("{} the previous boot ended while armed (armed at: {prev}) - a reset? not arming again", now_str());
            if !put_durable(DISABLED, &format!("{reason}\n")) {
                force_disabled = true;
            }
            remove_durable(ARMED);
            println!("{reason}");
        }
    }
    if experiment_running().is_none() && knobs_on() {
        cx.armed = true;
        cx.disarm("knobs found on at start without an experiment", false);
    }
    println!("watching the displays: arm E3a after {ARM_DELAY_S} s off on battery; {}",
             if force_disabled || Path::new(DISABLED).exists() { "DISABLED (y700-cx-auto --enable)" } else { "enabled" });
    let (mut off_since, mut charger_at, mut on_battery): (Option<f64>, f64, bool) = (None, -1e9, false);
    let mut hold = false; // an arm attempt failed: none again until a display was on
    let mut blocked: Option<String> = None; // the last precondition logged (once per screen-off)
    loop {
        let ts = libc::timespec { tv_sec: POLL_S as libc::time_t, tv_nsec: 0 };
        let sig = unsafe { libc::sigtimedwait(&set, std::ptr::null_mut(), &ts) };
        if sig > 0 {
            cx.armed = cx.armed || knobs_on() && Path::new(RUN_FLAG).exists();
            if cx.armed {
                cx.disarm("stopping", true);
            } else if cx.linger_until.is_some() {
                remove_durable(ARMED); // a clean stop: the lingering marker goes too
            }
            return 0;
        }
        let now = mono();
        if let Some(t) = cx.linger_until {
            if !cx.armed && now >= t {
                remove_durable(ARMED);
                cx.linger_until = None;
            }
        }
        let off = displays_off();
        let exp = experiment_running();
        let disabled = force_disabled || Path::new(DISABLED).exists();
        if !off {
            off_since = None;
            hold = false;
            blocked = None;
        } else if off_since.is_none() {
            off_since = Some(now);
        }
        let off_for = off_since.map_or(0.0, |t| now - t);
        // the battery status: only once the displays have been off for ARM_DELAY_S, then at most every CHARGER_EVERY_S
        if off && off_for >= ARM_DELAY_S && now - charger_at >= CHARGER_EVERY_S {
            charger_at = now;
            on_battery = rd(BAT_STATUS).as_deref() == Some("Discharging");
        }
        if cx.armed {
            let why = if !off {
                Some("a display on".to_string())
            } else if let Some(u) = &exp {
                Some(format!("{u} started"))
            } else if disabled {
                Some("disabled".to_string())
            } else if !on_battery {
                Some("charger in".to_string())
            } else {
                None
            };
            if let Some(w) = why {
                // an experiment starting: disarm fully - its E0 baseline needs the knobs off, and cx-exp.sh opens its
                // own level only after a 15 s screen-off wait, long after this
                cx.disarm(&w, false);
            }
        } else if off && !hold && exp.is_none() && !disabled && on_battery && off_for >= ARM_DELAY_S {
            match arm_blocker() {
                Some(b) => {
                    if blocked.as_deref() != Some(b.as_str()) {
                        println!("not arming yet: {b}");
                        blocked = Some(b);
                    }
                }
                None => {
                    if !cx.arm(&format!("displays off {off_for:.0} s, on battery")) {
                        hold = true;
                    }
                }
            }
        }
    }
}
