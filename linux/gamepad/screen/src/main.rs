// y700-gamepad-screen: G9 2026 lighting off with the screen, and the screen back on from a G9 button.
//
// While the screen is dark the G9's light strips and Home LED are off (the OEM's own commands, as Lenovo Ultra Control
// sends them) and its input nodes are grabbed: the first press only turns the screen on. The USB input link stays up.
// The original lighting is journaled on disk (STATE, survives a power cut) before any change and put back on
// screen-on, service stop (ExecStopPost=... --restore) or startup. Only VID 3537 / PID 1136 is touched; no key
// mappings or firmware writes.
//
// Rust port (2026-11-03) of the Python service installed 10-19 and fixed 11-01 (last Python version: git 9cdcf36;
// README "G9 息屏关灯与按键亮屏"). Behaviour, log lines and the state file are the same; deliberate differences are
// marked RUST:. The one that matters: Python looked at the screen and the USB bus every 0.25 s whether or not a G9 was
// there - 0.30 % of a core on 11-03 with no pad plugged in at all. Here, with no G9 on the bus, the loop sleeps in
// poll() on the kernel's uevent socket (a few messages a minute, mostly the battery) and runs only when a device comes
// or goes; with a G9 on the bus it ticks every 0.25 s as before (screen power has no event, and the pad itself
// already costs ~150 USB interrupts a second).

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

const VID: &str = "3537";
const PID: &str = "1136";
const STATE: &str = "/var/lib/y700-gamepad-screen/state.json";
const TICK_MS: i32 = 250;
const EVIOCGRAB: libc::c_ulong = 0x4004_4590; // _IOW('E', 0x90, int)
const EV_KEY: u16 = 1;

fn say(msg: &str) {
    eprintln!("{msg}");
    #[cfg(test)]
    tests::LOGGED.with(|l| l.borrow_mut().push(msg.to_string()));
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

fn read(p: &Path) -> io::Result<String> {
    Ok(fs::read_to_string(p)?.trim().to_string())
}

fn is_g9(id: &[String]) -> bool {
    id.len() >= 2 && id[0] == VID && id[1] == PID
}

/// [idVendor, idProduct, busnum, devnum] of a USB device; None for interfaces and vanished devices
fn identity(usb: &Path) -> Option<Vec<String>> {
    ["idVendor", "idProduct", "busnum", "devnum"].iter().map(|n| read(&usb.join(n)).ok()).collect()
}

/// `p` lies strictly below `dir` (Python's `dir in p.parents`)
fn below(p: &Path, dir: &Path) -> bool {
    p != dir && p.starts_with(dir)
}

fn readable(fd: &impl AsRawFd, ms: i32) -> io::Result<bool> {
    let mut p = libc::pollfd { fd: fd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    match unsafe { libc::poll(&mut p, 1, ms) } {
        r if r < 0 => Err(io::Error::last_os_error()),
        r => Ok(r > 0),
    }
}

// ---- lighting: G9 2026 GCM lighting, matching Lenovo Ultra Control's own commands. Interface 1 uses unnumbered
// reports, transmitted at their actual length. 05/0c controls strips 1 and 2; 05/08 controls the Home LED (HID key
// c2). Capture and restore all lighting bytes; no key mappings or firmware writes.

/// (type, key, record size) of the three lighting records
const LAYOUTS: [(u8, u8, usize); 3] = [(12, 1, 12), (12, 2, 12), (8, 194, 10)];

fn sum(d: &[u8]) -> u8 {
    d.iter().fold(0u8, |a, &b| a.wrapping_add(b))
}

fn packet(d: &[u8]) -> Vec<u8> {
    let mut v = d.to_vec();
    v.push(sum(d));
    v
}

fn hex(d: &[u8]) -> String {
    d.iter().map(|b| format!("{b:02x}")).collect()
}

fn validate(values: &[String]) -> io::Result<Vec<Vec<u8>>> {
    if values.len() != LAYOUTS.len() {
        return Err(bad("incomplete G9 lighting backup"));
    }
    values
        .iter()
        .zip(LAYOUTS)
        .map(|(v, (typ, key, size))| {
            let d: Option<Vec<u8>> =
                (0..v.len()).step_by(2).map(|i| v.get(i..i + 2).and_then(|h| u8::from_str_radix(h, 16).ok())).collect();
            match d {
                Some(d) if d.len() == size && d[..5] == [5, typ, size as u8, 0, key] && d[size - 1] == sum(&d[..size - 1]) => {
                    Ok(d)
                }
                _ => Err(bad("invalid G9 lighting backup")),
            }
        })
        .collect()
}

/// the write for one validated backup record: as saved, or dark
fn command(original: &[u8], dark: bool) -> Vec<u8> {
    let mut d = original[..original.len() - 1].to_vec();
    d[3] = 1;
    if d[1] == 12 {
        // G9 quantizes HSV through RGB on writes and truncates on reads.
        // Replaying the read bytes repeatedly drifts hue/brightness down.
        // Round upward for the write representation (verified by readback).
        if d[5] != 0 {
            d[5] = d[5].saturating_add(1);
        }
        if d[7] != 0 {
            d[7] = d[7].saturating_add(1).min(100);
        }
    }
    if dark {
        if d[1] == 12 {
            d[8] = 255; // The OEM's supported strip effect "off".
        } else {
            d[7] = 0; // Home HSB brightness; retain hue and saturation.
        }
    }
    packet(&d)
}

struct Hidraw(File);

impl Hidraw {
    fn open(usb: &Path, sysfs: &Path) -> io::Result<Self> {
        let target = fs::canonicalize(usb)?;
        for e in fs::read_dir(sysfs.join("bus/hid/devices"))? {
            let hid = e?.path();
            let ours = hid.file_name().is_some_and(|n| n.to_string_lossy().contains(":3537:1136."));
            if !ours || !fs::canonicalize(&hid).is_ok_and(|r| below(&r, &target)) {
                continue;
            }
            if fs::read(hid.join("report_descriptor"))?.starts_with(&[0x06, 0x7a, 0xff]) {
                // RUST: no hidraw node (yet) is an error to retry; Python's next() raised StopIteration, which ended the loop
                let node = fs::read_dir(hid.join("hidraw"))?
                    .flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .find(|n| n.starts_with("hidraw"))
                    .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "G9 vendor HID interface has no hidraw node"))?;
                let f = OpenOptions::new().read(true).write(true).custom_flags(libc::O_NONBLOCK).open(format!("/dev/{node}"))?;
                return Ok(Hidraw(f));
            }
        }
        Err(io::Error::new(io::ErrorKind::NotFound, "G9 vendor HID interface not available"))
    }

    fn exchange(&mut self, data: &[u8]) -> io::Result<Vec<u8>> {
        let mut buf = [0u8; 256];
        while readable(&self.0, 0)? {
            self.0.read(&mut buf)?;
        }
        let mut out = vec![0u8]; // hidraw's zero report ID is not sent on USB.
        out.extend_from_slice(data);
        self.0.write_all(&out)?;
        let end = Instant::now() + Duration::from_millis(750);
        loop {
            let left = end.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            if !readable(&self.0, left.as_micros().div_ceil(1000) as i32)? {
                continue;
            }
            let n = self.0.read(&mut buf)?;
            let r = &buf[..n];
            if r.len() < 6 || r[..2] != data[..2] || r[3..5] != data[3..5] {
                continue;
            }
            let r = &r[..(r[2] as usize).min(r.len())];
            if r.len() >= 6 && r[r.len() - 1] == sum(&r[..r.len() - 1]) {
                return Ok(r.to_vec());
            }
        }
        Err(io::Error::new(io::ErrorKind::TimedOut, format!("no valid G9 reply to {}", hex(data))))
    }

    fn capture(&mut self) -> io::Result<Vec<String>> {
        let values = LAYOUTS
            .iter()
            .map(|&(typ, key, _)| self.exchange(&packet(&[5, typ, 6, 0, key])).map(|r| hex(&r)))
            .collect::<io::Result<Vec<_>>>()?;
        validate(&values)?;
        Ok(values)
    }

    fn apply(&mut self, values: &[String], dark: bool) -> io::Result<()> {
        for original in validate(values)? {
            let c = command(&original, dark);
            let reply = self.exchange(&c)?;
            if c[1] == 12 {
                if reply.len() != 7 || reply[5] != 1 {
                    return Err(io::Error::other("G9 rejected strip lighting update"));
                }
            } else if reply != c {
                return Err(io::Error::other("G9 Home lighting readback differs from requested value"));
            }
        }
        Ok(())
    }
}

// ---- buttons

/// The G9's grabbed input nodes: only read, and the first wake press goes to no background app.
/// Dropping it closes them, which releases the grabs.
struct Buttons(Vec<File>);

fn ids(event: &Path) -> Option<(String, String)> {
    Some((read(&event.join("device/id/vendor")).ok()?, read(&event.join("device/id/product")).ok()?))
}

fn grab(dev: &Path) -> io::Result<File> {
    let f = OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK).open(dev)?;
    if unsafe { libc::ioctl(f.as_raw_fd(), EVIOCGRAB as _, 1 as libc::c_int) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(f)
}

/// (type, code, value) of what one read returns; nothing queued is no events
fn events(mut f: &File) -> io::Result<Vec<(u16, u16, i32)>> {
    // struct input_event on arm64: timeval (16) + type (2) + code (2) + value (4)
    let mut buf = [0u8; 24 * 64];
    let n = match f.read(&mut buf) {
        Ok(n) => n,
        Err(e) if e.kind() == io::ErrorKind::WouldBlock => 0,
        Err(e) => return Err(e),
    };
    Ok(buf[..n]
        .chunks_exact(24)
        .map(|e| {
            (u16::from_ne_bytes([e[16], e[17]]), u16::from_ne_bytes([e[18], e[19]]), i32::from_ne_bytes([e[20], e[21], e[22], e[23]]))
        })
        .collect())
}

impl Buttons {
    fn open(usb: &Path, sysfs: &Path, grab: fn(&Path) -> io::Result<File>) -> io::Result<Self> {
        let target = fs::canonicalize(usb)?;
        let mut got = Buttons(Vec::new());
        for e in fs::read_dir(sysfs.join("class/input"))?.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if !name.starts_with("event") {
                continue;
            }
            let Ok(node) = fs::canonicalize(e.path()) else { continue };
            // y700-padkeys grabs the real joystick node and re-emits it through a uinput clone
            // with the same ids (no USB parent), so while it runs the buttons arrive on the clone.
            let clone = node.components().any(|c| c.as_os_str() == "virtual")
                && ids(&e.path()).is_some_and(|(v, p)| v == VID && p == PID);
            if !below(&node, &target) && !clone {
                continue;
            }
            match grab(&Path::new("/dev/input").join(&name)) {
                Ok(f) => {
                    got.0.push(f);
                    events(&got.0[got.0.len() - 1])?; // Discard events from before the screen went dark.
                }
                Err(e) if e.raw_os_error() == Some(libc::EBUSY) => continue, // padkeys holds the real node; its clone carries the same buttons
                Err(e) => return Err(e),
            }
        }
        if got.0.is_empty() {
            return Err(io::Error::new(io::ErrorKind::NotFound, "G9 input devices not available"));
        }
        Ok(got)
    }

    fn pressed(&self) -> io::Result<Option<u16>> {
        for f in &self.0 {
            // EV_KEY press; ignore stick drift.
            if let Some(&(_, code, _)) = events(f)?.iter().find(|&&(typ, _, value)| typ == EV_KEY && value == 1) {
                return Ok(Some(code));
            }
        }
        Ok(None)
    }
}

// ---- the screen

/// Turn on the active local session's display without unlocking it.
fn wake_display() -> bool {
    match try_wake() {
        Ok(ok) => ok,
        Err(e) => {
            say(&format!("could not wake the active local display: {e}"));
            false
        }
    }
}

// RUST: coreutils timeout(1) instead of subprocess's timeout= (a hung helper is killed the same way)
fn try_wake() -> io::Result<bool> {
    let query = |args: &[&str]| -> io::Result<String> {
        let o = Command::new("/usr/bin/timeout")
            .arg("3")
            .arg("/usr/bin/loginctl")
            .args(args)
            .stdin(Stdio::null())
            .stderr(Stdio::inherit())
            .output()?;
        if !o.status.success() {
            return Err(io::Error::other(format!("loginctl {} failed: {}", args.join(" "), o.status)));
        }
        Ok(String::from_utf8_lossy(&o.stdout).trim().to_string())
    };
    let session = query(&["show-seat", "seat0", "-p", "ActiveSession", "--value"])?;
    if session.is_empty() {
        return Ok(false);
    }
    let uid: libc::uid_t =
        query(&["show-session", session.as_str(), "-p", "User", "--value"])?.parse().map_err(|_| bad("loginctl gave no numeric uid"))?;
    let pw = unsafe { libc::getpwuid(uid) };
    if pw.is_null() {
        return Err(io::Error::new(io::ErrorKind::NotFound, format!("no passwd entry for uid {uid}")));
    }
    let user = unsafe { std::ffi::CStr::from_ptr((*pw).pw_name) }.to_string_lossy().into_owned();
    let runtime = format!("/run/user/{uid}");
    let mut sockets: Vec<String> = fs::read_dir(&runtime)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| fs::metadata(e.path()).is_ok_and(|m| m.file_type().is_socket()))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("wayland-"))
        .collect();
    sockets.sort();
    if sockets.is_empty() || !Path::new(&runtime).join("bus").exists() {
        return Ok(false);
    }
    let in_session = |prog: &[&str]| -> io::Result<Output> {
        Command::new("/usr/bin/timeout")
            .arg("5")
            .arg("/usr/sbin/runuser")
            .args(["-u", user.as_str(), "--", "/usr/bin/env"])
            .arg(format!("XDG_RUNTIME_DIR={runtime}"))
            .arg(format!("WAYLAND_DISPLAY={}", sockets[0]))
            .arg(format!("DBUS_SESSION_BUS_ADDRESS=unix:path={runtime}/bus"))
            .args(prog)
            .stdin(Stdio::null())
            .output()
    };
    in_session(&["/usr/bin/qdbus6", "org.freedesktop.ScreenSaver", "/ScreenSaver", "org.freedesktop.ScreenSaver.SimulateUserActivity"])?;
    let r = in_session(&["/usr/bin/kscreen-doctor", "--dpms", "on"])?;
    if !r.status.success() {
        say(&format!("display wake failed: {}", String::from_utf8_lossy(&r.stderr).trim()));
    }
    Ok(r.status.success())
}

// ---- the guard

/// What the guard does to hardware; the tests swap in a fake (the Python version's factories).
trait Hw {
    fn capture(&mut self, usb: &Path, sysfs: &Path) -> io::Result<Vec<String>>;
    fn apply(&mut self, usb: &Path, sysfs: &Path, lights: &[String], dark: bool) -> io::Result<()>;
    fn buttons(&mut self, usb: &Path, sysfs: &Path) -> io::Result<Buttons>;
    fn wake_screen(&mut self) -> bool;
}

struct Real;

// RUST: darkening opens the hidraw node twice the first time (capture, then apply); Python did both in one `with`
impl Hw for Real {
    fn capture(&mut self, usb: &Path, sysfs: &Path) -> io::Result<Vec<String>> {
        Hidraw::open(usb, sysfs)?.capture()
    }
    fn apply(&mut self, usb: &Path, sysfs: &Path, lights: &[String], dark: bool) -> io::Result<()> {
        Hidraw::open(usb, sysfs)?.apply(lights, dark)
    }
    fn buttons(&mut self, usb: &Path, sysfs: &Path) -> io::Result<Buttons> {
        Buttons::open(usb, sysfs, grab)
    }
    fn wake_screen(&mut self) -> bool {
        wake_display()
    }
}

/// state.json, one entry per USB device name: the Python version's format (json.dump of the same dict)
#[derive(Serialize, Deserialize)]
struct Record {
    identity: Vec<String>,
    lights: Vec<String>,
}

struct Guard<H: Hw> {
    sysfs: PathBuf,
    devices: PathBuf,
    state: PathBuf,
    records: BTreeMap<String, Record>,
    hw: H,
    inputs: HashMap<String, Buttons>,
    dark_ids: HashMap<String, Vec<String>>,
    retry_after: HashMap<String, Instant>,
    last_error: HashMap<String, String>,
    restore_error: HashMap<String, String>,
    known: Option<HashSet<(String, Vec<String>)>>,
    wake_until: Option<Instant>,
}

impl<H: Hw> Guard<H> {
    fn new(sysfs: &Path, state: &Path, hw: H) -> io::Result<Self> {
        let records = match fs::read_to_string(state) {
            Ok(s) => serde_json::from_str(&s)?,
            Err(e) if e.kind() == io::ErrorKind::NotFound => BTreeMap::new(),
            Err(e) => return Err(e),
        };
        Ok(Guard {
            sysfs: sysfs.into(),
            devices: sysfs.join("bus/usb/devices"),
            state: state.into(),
            records,
            hw,
            inputs: HashMap::new(),
            dark_ids: HashMap::new(),
            retry_after: HashMap::new(),
            last_error: HashMap::new(),
            restore_error: HashMap::new(),
            known: None,
            wake_until: None,
        })
    }

    fn pads_present(&self) -> bool {
        self.known.as_ref().is_some_and(|k| !k.is_empty())
    }

    /// all connected displays off: Some(true); one on: Some(false); unreadable or unexpected: None
    fn screen_off(&self) -> Option<bool> {
        let mut states = Vec::new();
        for e in fs::read_dir(self.sysfs.join("class/drm")).ok()?.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if !n.starts_with("card") || !n[4..].contains('-') || n.contains("Writeback") {
                continue;
            }
            let p = e.path();
            if read(&p.join("status")).ok()? == "connected" {
                match read(&p.join("enabled")).ok()?.as_str() {
                    "disabled" => states.push("Off".to_string()),
                    "enabled" => states.push(read(&p.join("dpms")).ok()?),
                    _ => return None,
                }
            }
        }
        if states.is_empty() || states.iter().any(|s| !["On", "Off", "Standby", "Suspend"].contains(&s.as_str())) {
            return None;
        }
        Some(states.iter().all(|s| s != "On"))
    }

    fn save(&self) -> io::Result<()> {
        let dir = self.state.parent().unwrap_or(Path::new("/"));
        fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
        let tmp = self.state.with_extension("tmp");
        let mut f = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp)?;
        f.set_permissions(fs::Permissions::from_mode(0o600))?;
        f.write_all(serde_json::to_string(&self.records)?.as_bytes())?;
        f.sync_all()?;
        fs::rename(&tmp, &self.state)?;
        File::open(dir)?.sync_all()
    }

    fn restore(&mut self, name: &str) -> io::Result<()> {
        self.inputs.remove(name);
        let usb = self.devices.join(name);
        if !identity(&usb).is_some_and(|id| is_g9(&id)) {
            return Ok(()); // Keep the durable lighting backup until this G9 returns.
        }
        self.hw.apply(&usb, &self.sysfs, &self.records[name].lights, false)?;
        self.records.remove(name);
        self.dark_ids.remove(name);
        self.save()?;
        say(&format!("restored original G9 {name} lighting"));
        Ok(())
    }

    fn restore_all(&mut self) {
        self.inputs.clear();
        for name in self.records.keys().cloned().collect::<Vec<_>>() {
            match self.restore(&name) {
                Ok(()) => {
                    self.restore_error.remove(&name);
                }
                Err(e) => {
                    // RUST: one line per distinct error; Python logged a traceback every 0.25 s tick while the screen was on
                    let e = e.to_string();
                    if self.restore_error.get(&name) != Some(&e) {
                        say(&format!("could not restore G9 {name} lighting; retaining backup: {e}"));
                    }
                    self.restore_error.insert(name, e);
                }
            }
        }
    }

    fn darken(&mut self, usb: &Path, name: &str, id: &[String]) -> io::Result<()> {
        if !self.records.contains_key(name) {
            let lights = self.hw.capture(usb, &self.sysfs)?;
            self.records.insert(name.to_string(), Record { identity: id.to_vec(), lights });
            self.save()?; // Survives reboot/crash before any controller setting changes.
        }
        self.hw.apply(usb, &self.sysfs, &self.records[name].lights, true)?;
        self.dark_ids.insert(name.to_string(), id.to_vec());
        say(&format!("screen off: all G9 {name} lights off; listening for wake buttons"));
        Ok(())
    }

    fn wake(&mut self, reason: &str) -> bool {
        self.restore_all();
        if self.hw.wake_screen() {
            self.wake_until = Some(Instant::now() + Duration::from_secs(5));
            say(&format!("{reason}; requested display on"));
            return true;
        }
        say(&format!("could not turn on the display after {reason}"));
        false
    }

    /// dark lights and grabbed buttons for one pad; a press it read
    fn handle(&mut self, name: &str, id: &[String]) -> io::Result<Option<u16>> {
        let usb = self.devices.join(name);
        if self.dark_ids.get(name).map(Vec::as_slice) != Some(id) {
            self.inputs.remove(name);
            self.darken(&usb, name, id)?;
        }
        if !self.inputs.contains_key(name) {
            let b = self.hw.buttons(&usb, &self.sysfs)?;
            self.inputs.insert(name.to_string(), b);
        }
        self.inputs[name].pressed()
    }

    fn tick(&mut self) {
        let pads: Vec<(String, Vec<String>)> = fs::read_dir(&self.devices)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| Some((e.file_name().to_string_lossy().into_owned(), identity(&e.path())?)))
            .filter(|(_, id)| is_g9(id))
            .collect();
        let present: HashSet<_> = pads.iter().cloned().collect();
        let reconnected = self.known.as_ref().is_some_and(|k| !present.is_subset(k));
        self.known = Some(present);
        let gone: Vec<String> = self.inputs.keys().filter(|n| !pads.iter().any(|(p, _)| p == *n)).cloned().collect();
        for name in gone {
            self.inputs.remove(&name);
            self.dark_ids.remove(&name);
        }
        if self.screen_off() != Some(true) {
            self.wake_until = None;
            self.restore_all();
            return;
        }
        if self.wake_until.is_some_and(|t| Instant::now() < t) {
            return;
        }
        if reconnected && self.wake("G9 reconnected while the screen was off") {
            return;
        }
        for (name, id) in &pads {
            if self.retry_after.get(name).is_some_and(|&t| Instant::now() < t) {
                continue;
            }
            match self.handle(name, id) {
                Ok(button) => {
                    self.last_error.remove(name);
                    if let Some(b) = button {
                        self.wake(&format!("G9 button {b} pressed"));
                        return;
                    }
                }
                Err(e) => {
                    // A stuck failure retried every 5 s once wrote 150 traceback lines a minute (11-01).
                    let e = e.to_string();
                    if self.last_error.get(name) != Some(&e) {
                        say(&format!("G9 lighting/wake handling failed; retrying every 5 seconds: {e}"));
                    }
                    self.last_error.insert(name.clone(), e);
                    self.inputs.remove(name); // dark_ids is only set after a good darken, so keep it
                    self.retry_after.insert(name.clone(), Instant::now() + Duration::from_secs(5));
                }
            }
        }
    }
}

/// the kernel's uevent broadcast (netlink group 1): every device add / remove / change
fn uevents() -> io::Result<OwnedFd> {
    let fd = unsafe {
        libc::socket(libc::AF_NETLINK, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK, libc::NETLINK_KOBJECT_UEVENT)
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    let mut sa: libc::sockaddr_nl = unsafe { std::mem::zeroed() };
    sa.nl_family = libc::AF_NETLINK as libc::sa_family_t;
    sa.nl_groups = 1;
    let len = std::mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t;
    if unsafe { libc::bind(fd.as_raw_fd(), &sa as *const libc::sockaddr_nl as *const libc::sockaddr, len) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(fd)
}

fn main() {
    let restore_only = match std::env::args().nth(1).as_deref() {
        None => false,
        Some("--restore") => true,
        Some(_) => {
            eprintln!("usage: y700-gamepad-screen [--restore]");
            std::process::exit(2);
        }
    };
    let mut guard = match Guard::new(Path::new("/sys"), Path::new(STATE), Real) {
        Ok(g) => g,
        Err(e) => {
            say(&format!("{STATE}: {e}"));
            std::process::exit(1);
        }
    };
    guard.restore_all();
    if restore_only {
        return;
    }
    // TERM / INT through a signalfd, so poll() below can sleep with no timeout and still stop at once
    let mut set: libc::sigset_t = unsafe { std::mem::zeroed() };
    let sig = unsafe {
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGTERM);
        libc::sigaddset(&mut set, libc::SIGINT);
        libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
        libc::signalfd(-1, &set, libc::SFD_CLOEXEC)
    };
    if sig < 0 {
        say(&format!("signalfd: {}", io::Error::last_os_error()));
        std::process::exit(1);
    }
    let uev = uevents().map_err(|e| say(&format!("no uevent socket ({e}); looking every 0.25 s instead"))).ok();
    say("watching display power; G9 lights off and button-to-screen wake enabled");
    let mut buf = [0u8; 8192];
    loop {
        guard.tick();
        let timeout = if uev.is_none() || guard.pads_present() { TICK_MS } else { -1 };
        let mut fds = [
            libc::pollfd { fd: sig, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: uev.as_ref().map_or(-1, |f| f.as_raw_fd()), events: libc::POLLIN, revents: 0 },
        ];
        if unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout) } < 0 {
            continue;
        }
        if fds[0].revents != 0 {
            break;
        }
        if fds[1].revents != 0 {
            // only "something changed": the tick rescans the bus, so a lost message (ENOBUFS) costs nothing
            while unsafe { libc::recv(fds[1].fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len(), 0) } >= 0
                || io::Error::last_os_error().raw_os_error() == Some(libc::ENOBUFS)
            {}
        }
    }
    guard.restore_all();
}

// Self-test on a fake sysfs (the tablet's 11-01 layout) with fake grabs; touches no real device. Ported from the
// Python version's test-gamepad-screen.py, plus the lighting bytes, the state file and the reconnect wake.
// Needs Linux (symlinks, pipes): cargo test --release --offline
#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::os::unix::fs::symlink;
    use std::sync::atomic::{AtomicUsize, Ordering};

    thread_local! {
        pub static LOGGED: RefCell<Vec<String>> = RefCell::new(Vec::new());
        static BUSY: RefCell<HashSet<String>> = RefCell::new(HashSet::new());
        static DENY: RefCell<HashSet<String>> = RefCell::new(HashSet::new());
        static GRABBED: RefCell<Vec<String>> = RefCell::new(Vec::new());
        static PIPES: RefCell<HashMap<String, File>> = RefCell::new(HashMap::new());
    }

    /// a grab is a pipe: the test writes events into its other end, and a write failing with EPIPE shows the
    /// guard closed (released) it
    fn fake_grab(dev: &Path) -> io::Result<File> {
        let dev = dev.to_string_lossy().into_owned();
        if BUSY.with(|b| b.borrow().contains(&dev)) {
            return Err(io::Error::from_raw_os_error(libc::EBUSY));
        }
        if DENY.with(|b| b.borrow().contains(&dev)) {
            return Err(io::Error::from_raw_os_error(libc::EACCES));
        }
        let mut fds = [0; 2];
        assert_eq!(unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) }, 0);
        GRABBED.with(|g| g.borrow_mut().push(dev.clone()));
        PIPES.with(|p| p.borrow_mut().insert(dev, unsafe { File::from_raw_fd(fds[1]) }));
        Ok(unsafe { File::from_raw_fd(fds[0]) })
    }

    fn grabbed() -> Vec<String> {
        let mut g = GRABBED.with(|g| g.borrow().clone());
        g.sort();
        g
    }

    fn all_released() -> bool {
        PIPES.with(|p| p.borrow_mut().values_mut().all(|w| w.write_all(&[0; 24]).is_err()))
    }

    fn press(dev: &str, code: u16) {
        let mut ev = [0u8; 24];
        ev[16..18].copy_from_slice(&EV_KEY.to_ne_bytes());
        ev[18..20].copy_from_slice(&code.to_ne_bytes());
        ev[20..24].copy_from_slice(&1i32.to_ne_bytes());
        PIPES.with(|p| p.borrow_mut().get_mut(dev).unwrap().write_all(&ev).unwrap());
    }

    fn errors() -> usize {
        LOGGED.with(|l| l.borrow().iter().filter(|m| m.contains("handling failed")).count())
    }

    #[derive(PartialEq)]
    enum Mode {
        Fail,
        Idle,
        Real,
    }

    struct Fake {
        mode: Mode,
        darkened: Vec<bool>,
        woke: usize,
    }

    impl Hw for Fake {
        fn capture(&mut self, _: &Path, _: &Path) -> io::Result<Vec<String>> {
            Ok(vec!["00".into()])
        }
        fn apply(&mut self, _: &Path, _: &Path, _: &[String], dark: bool) -> io::Result<()> {
            self.darkened.push(dark);
            Ok(())
        }
        fn buttons(&mut self, usb: &Path, sysfs: &Path) -> io::Result<Buttons> {
            match self.mode {
                Mode::Fail => Err(io::Error::from_raw_os_error(libc::EBUSY)),
                Mode::Idle => Ok(Buttons(Vec::new())),
                Mode::Real => Buttons::open(usb, sysfs, fake_grab),
            }
        }
        fn wake_screen(&mut self) -> bool {
            self.woke += 1;
            true
        }
    }

    fn guard(root: &Path, mode: Mode) -> Guard<Fake> {
        Guard::new(root, &root.join("state.json"), Fake { mode, darkened: Vec::new(), woke: 0 }).unwrap()
    }

    /// The tablet's layout on 11-01: G9 on 1-1 with a joystick and a Consumer Control node,
    /// padkeys' uinput clone under devices/virtual, plus unrelated input devices.
    fn fake_sysfs(clone: bool) -> PathBuf {
        // every test starts here: no grabs, logs or refusals left over from a test run earlier on this thread
        LOGGED.with(|l| l.borrow_mut().clear());
        BUSY.with(|b| b.borrow_mut().clear());
        DENY.with(|b| b.borrow_mut().clear());
        GRABBED.with(|g| g.borrow_mut().clear());
        PIPES.with(|p| p.borrow_mut().clear());
        static N: AtomicUsize = AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!("gs-test-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
        let _ = fs::remove_dir_all(&root);
        let usb = root.join("devices/platform/a600000.usb/xhci-hcd.0.auto/usb1/1-1");
        let node = |parent: &Path, inp: &str, ev: &str, vid: &str, pid: &str| {
            let dev = parent.join(inp);
            fs::create_dir_all(dev.join("id")).unwrap();
            fs::write(dev.join("id/vendor"), format!("{vid}\n")).unwrap();
            fs::write(dev.join("id/product"), format!("{pid}\n")).unwrap();
            fs::create_dir(dev.join(ev)).unwrap();
            symlink(&dev, dev.join(ev).join("device")).unwrap();
            fs::create_dir_all(root.join("class/input")).unwrap();
            symlink(dev.join(ev), root.join("class/input").join(ev)).unwrap();
        };
        node(&usb.join("1-1:1.0/0003:3537:1136.0001/input"), "input8", "event8", "3537", "1136");
        node(&usb.join("1-1:1.2/0003:3537:1136.0003/input"), "input9", "event9", "3537", "1136");
        if clone {
            node(&root.join("devices/virtual/input"), "input23", "event10", "3537", "1136");
        }
        node(&root.join("devices/virtual/input"), "input5", "event5", "0000", "0000");
        node(&root.join("devices/platform/gpio-keys/input"), "input1", "event1", "0001", "0001");
        for (n, v) in [("idVendor", "3537"), ("idProduct", "1136"), ("busnum", "1"), ("devnum", "3")] {
            fs::write(usb.join(n), format!("{v}\n")).unwrap();
        }
        fs::create_dir_all(root.join("bus/usb/devices")).unwrap();
        symlink(&usb, root.join("bus/usb/devices/1-1")).unwrap();
        let drm = root.join("class/drm/card1-DSI-1");
        fs::create_dir_all(&drm).unwrap();
        for (n, v) in [("status", "connected"), ("enabled", "enabled"), ("dpms", "Off")] {
            fs::write(drm.join(n), format!("{v}\n")).unwrap();
        }
        root
    }

    fn pad(root: &Path) -> PathBuf {
        root.join("bus/usb/devices/1-1")
    }

    // padkeys running (11-01): the real joystick node is grabbed, so take its clone and the
    // Consumer Control node instead of failing (it failed every 5 s, so buttons never woke the screen).
    #[test]
    fn padkeys_running_takes_the_clone() {
        let root = fake_sysfs(true);
        BUSY.with(|b| b.borrow_mut().insert("/dev/input/event8".into()));
        let b = Buttons::open(&pad(&root), &root, fake_grab).unwrap();
        assert_eq!(b.0.len(), 2);
        assert_eq!(grabbed(), ["/dev/input/event10", "/dev/input/event9"]);
    }

    // padkeys not installed: no clone, the real nodes are free.
    #[test]
    fn no_padkeys_takes_the_real_nodes() {
        let root = fake_sysfs(false);
        Buttons::open(&pad(&root), &root, fake_grab).unwrap();
        assert_eq!(grabbed(), ["/dev/input/event8", "/dev/input/event9"]);
    }

    // Any other grab failure still fails the set and releases what was already grabbed.
    #[test]
    fn other_grab_errors_fail_the_set() {
        let root = fake_sysfs(true);
        DENY.with(|b| b.borrow_mut().insert("/dev/input/event9".into()));
        let e = Buttons::open(&pad(&root), &root, fake_grab).err().expect("EACCES was swallowed");
        assert_eq!(e.raw_os_error(), Some(libc::EACCES));
        assert!(all_released());
    }

    // A stuck failure logs one line and darkens once; recovery re-arms the log.
    #[test]
    fn stuck_failure_logs_once() {
        let root = fake_sysfs(true);
        let mut g = guard(&root, Mode::Fail);
        for _ in 0..3 {
            g.retry_after.clear();
            g.tick();
        }
        assert_eq!((errors(), g.hw.darkened.clone()), (1, vec![true]));
        g.hw.mode = Mode::Idle;
        g.retry_after.clear();
        g.tick();
        g.hw.mode = Mode::Fail;
        g.inputs.remove("1-1");
        g.retry_after.clear();
        g.tick();
        assert_eq!(errors(), 2);
    }

    // End to end with padkeys running: a press on the clone wakes the screen and releases the grabs.
    #[test]
    fn press_on_clone_wakes_and_releases() {
        let root = fake_sysfs(true);
        BUSY.with(|b| b.borrow_mut().insert("/dev/input/event8".into()));
        let mut g = guard(&root, Mode::Real);
        g.tick();
        assert_eq!(grabbed(), ["/dev/input/event10", "/dev/input/event9"]);
        assert_eq!(g.hw.woke, 0);
        press("/dev/input/event10", 304);
        g.tick();
        assert_eq!(g.hw.woke, 1);
        assert_eq!(g.hw.darkened.last(), Some(&false));
        assert!(g.inputs.is_empty() && g.records.is_empty() && all_released());
    }

    // RUST: the event-driven loop's case - a G9 plugged in while dark (one tick on its uevent) wakes the screen,
    // and with no pad on the bus the loop has nothing to poll for.
    #[test]
    fn plugged_in_while_dark_wakes() {
        let root = fake_sysfs(true);
        fs::remove_file(pad(&root)).unwrap();
        let mut g = guard(&root, Mode::Idle);
        g.tick();
        assert!(!g.pads_present() && g.hw.woke == 0);
        symlink(root.join("devices/platform/a600000.usb/xhci-hcd.0.auto/usb1/1-1"), pad(&root)).unwrap();
        g.tick();
        assert!(g.pads_present() && g.hw.woke == 1);
    }

    #[test]
    fn screen_state_and_restore_on() {
        let root = fake_sysfs(true);
        let dpms = root.join("class/drm/card1-DSI-1/dpms");
        let mut g = guard(&root, Mode::Idle);
        assert_eq!(g.screen_off(), Some(true));
        g.tick();
        assert_eq!(g.hw.darkened, [true]);
        fs::write(&dpms, "On\n").unwrap();
        assert_eq!(g.screen_off(), Some(false));
        g.tick();
        assert_eq!(g.hw.darkened, [true, false]);
        assert!(g.records.is_empty());
        fs::write(root.join("class/drm/card1-DSI-1/enabled"), "weird\n").unwrap();
        assert_eq!(g.screen_off(), None);
    }

    // The Python version's state.json (json.dump, 11-01 17:03 on the tablet) loads, and what we write loads back.
    #[test]
    fn python_state_file() {
        let root = fake_sysfs(false);
        fs::write(
            root.join("state.json"),
            r#"{"1-1": {"identity": ["3537", "1136", "1", "2"], "lights": ["050c0c00017f6431016464fb", "050c0c00027f6431016464fc", "05080a00c2000064013e"]}}"#,
        )
        .unwrap();
        let g = guard(&root, Mode::Idle);
        assert_eq!(g.records["1-1"].identity, ["3537", "1136", "1", "2"]);
        assert_eq!(validate(&g.records["1-1"].lights).unwrap().len(), 3);
        g.save().unwrap();
        let again = guard(&root, Mode::Idle);
        assert_eq!(again.records["1-1"].lights, g.records["1-1"].lights);
    }

    // The writes for that backup, worked out by hand from the Python apply(): flag byte 3 = 1, strips' hue and
    // brightness rounded up by one, dark = strip effect ff / Home brightness 0, new checksum.
    #[test]
    fn lighting_bytes() {
        let v: Vec<String> =
            ["050c0c00017f6431016464fb", "050c0c00027f6431016464fc", "05080a00c2000064013e"].map(String::from).to_vec();
        let d = validate(&v).unwrap();
        assert_eq!(hex(&command(&d[0], true)), "050c0c0101806432ff6464fc");
        assert_eq!(hex(&command(&d[0], false)), "050c0c0101806432016464fe");
        assert_eq!(hex(&command(&d[2], true)), "05080a01c200000001db");
        assert_eq!(hex(&command(&d[2], false)), "05080a01c2000064013f");
        assert_eq!(hex(&packet(&[5, 12, 6, 0, 1])), "050c06000118");
        let mut broken = v.clone();
        broken[2] = "05080a00c2000064013f".into();
        assert!(validate(&broken).is_err() && validate(&v[..2]).is_err());
    }
}
