// y700-padkeys: the G9 gamepad's home (Legion) key as the tablet's system key while the pad is on.
// Why (2026-10-20): with the G9 on, the tablet sits in its frame and the edge swipes (right edge =
// control centre, bottom edge = minimize) can't start at the glass edge any more, and the pad has
// keys to spare. Chosen scheme: single tap = toggle the control centre, double tap = toggle the
// task switcher cards (2026-10-21, the owner's pick; before: minimize the active window). The cards are
// the y700-taskswitcher KWin effect's global shortcut; going home is a card tap / the desktop away.
//
// The key is swallowed: the first version only listened (both sides were meant to get it),
// and while streaming Moonlight passed the press on to Windows, which opened its Xbox overlay and
// took the controller. So this grabs the real event device
// (EVIOCGRAB) and re-emits everything except BTN_MODE through a uinput clone with the same name,
// ids and capabilities (SDL's GUID and its button numbering stay the same, so Moonlight's mapping
// does too). 69-y700-padkeys.rules hides the real node from the desktop (no ID_INPUT_JOYSTICK, mode
// 0600) so apps see only the clone.
//
// The firmware sends the home key as a ~20 ms pulse however long it is held, so there is no long
// press; the back keys and the small extra key report nothing at all (firmware macro keys).
//
// Runs as root per event device (y700-padkeys@eventN.service, started by the udev rule), exits when
// the pad goes away (read fails with ENODEV); the uinput clone goes with the process. Blocks in
// read(); no polling.

use std::ffi::CString;
use std::io;
use std::process::Command;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

const EV_KEY: u16 = 0x01;
const EV_ABS: u16 = 0x03;
const EV_MSC: u16 = 0x04;
const EV_MAX: usize = 0x1f;
const KEY_MAX: usize = 0x2ff;
const ABS_MAX: usize = 0x3f;
const MSC_MAX: usize = 0x07;
const BTN_MODE: u16 = 0x13c;
// a second press within this window makes a double tap; the single tap waits it out
const DOUBLE_TAP: Duration = Duration::from_millis(300);
const SESSION_USER: &str = "user";

// ioctl numbers (asm-generic encoding: dir << 30 | size << 16 | type << 8 | nr)
const fn ioc(dir: u64, ty: u8, nr: u64, size: u64) -> u64 {
    (dir << 30) | (size << 16) | ((ty as u64) << 8) | nr
}
const R: u64 = 2;
const W: u64 = 1;
const fn eviocgbit(ev: u64, len: u64) -> u64 { ioc(R, b'E', 0x20 + ev, len) }
const fn eviocgabs(abs: u64) -> u64 { ioc(R, b'E', 0x40 + abs, 24) }
const fn eviocgname(len: u64) -> u64 { ioc(R, b'E', 0x06, len) }
const EVIOCGID: u64 = ioc(R, b'E', 0x02, 8);
const EVIOCGRAB: u64 = ioc(W, b'E', 0x90, 4);
const UI_SET_EVBIT: u64 = ioc(W, b'U', 100, 4);
const UI_SET_KEYBIT: u64 = ioc(W, b'U', 101, 4);
const UI_SET_ABSBIT: u64 = ioc(W, b'U', 103, 4);
const UI_SET_MSCBIT: u64 = ioc(W, b'U', 104, 4);
const UI_DEV_SETUP: u64 = ioc(W, b'U', 3, 92);
const UI_ABS_SETUP: u64 = ioc(W, b'U', 4, 28);
const UI_DEV_CREATE: u64 = ioc(0, b'U', 1, 0);

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct InputId { bustype: u16, vendor: u16, product: u16, version: u16 }

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct AbsInfo { value: i32, minimum: i32, maximum: i32, fuzz: i32, flat: i32, resolution: i32 }

#[repr(C)]
struct UinputSetup { id: InputId, name: [u8; 80], ff_effects_max: u32 }

#[repr(C)]
struct UinputAbsSetup { code: u16, _pad: u16, absinfo: AbsInfo }

fn check(r: libc::c_int, what: &str) -> io::Result<()> {
    if r < 0 {
        let e = io::Error::last_os_error();
        return Err(io::Error::new(e.kind(), format!("{what}: {e}")));
    }
    Ok(())
}

fn open(path: &str, flags: libc::c_int) -> io::Result<libc::c_int> {
    let c = CString::new(path).unwrap();
    let fd = unsafe { libc::open(c.as_ptr(), flags | libc::O_CLOEXEC) };
    check(fd, path)?;
    Ok(fd)
}

fn bits(fd: libc::c_int, ev: u16, max: usize) -> io::Result<Vec<u16>> {
    let mut buf = vec![0u8; max / 8 + 1];
    check(unsafe { libc::ioctl(fd, eviocgbit(ev as u64, buf.len() as u64) as _, buf.as_mut_ptr()) }, "EVIOCGBIT")?;
    Ok((0..=max).filter(|&i| buf[i / 8] & (1 << (i % 8)) != 0).map(|i| i as u16).collect())
}

fn set(fd: libc::c_int, req: u64, v: u16) -> io::Result<()> {
    check(unsafe { libc::ioctl(fd, req as _, v as libc::c_int) }, "UI_SET_*")
}

// the clone: same name, ids and capabilities as the real pad
fn clone_device(real: libc::c_int) -> io::Result<libc::c_int> {
    let mut id = InputId::default();
    check(unsafe { libc::ioctl(real, EVIOCGID as _, &mut id as *mut InputId) }, "EVIOCGID")?;
    let mut name = [0u8; 80];
    check(unsafe { libc::ioctl(real, eviocgname(79) as _, name.as_mut_ptr()) }, "EVIOCGNAME")?;

    let ui = open("/dev/uinput", libc::O_WRONLY | libc::O_NONBLOCK)?;
    let evs = bits(real, 0, EV_MAX)?;
    for &ev in &evs {
        set(ui, UI_SET_EVBIT, ev)?;
    }
    if evs.contains(&EV_KEY) {
        for k in bits(real, EV_KEY, KEY_MAX)? {
            set(ui, UI_SET_KEYBIT, k)?; // BTN_MODE stays declared: SDL numbers buttons by declared codes
        }
    }
    if evs.contains(&EV_MSC) {
        for m in bits(real, EV_MSC, MSC_MAX)? {
            set(ui, UI_SET_MSCBIT, m)?;
        }
    }
    if evs.contains(&EV_ABS) {
        for a in bits(real, EV_ABS, ABS_MAX)? {
            set(ui, UI_SET_ABSBIT, a)?;
            let mut s = UinputAbsSetup { code: a, _pad: 0, absinfo: AbsInfo::default() };
            check(unsafe { libc::ioctl(real, eviocgabs(a as u64) as _, &mut s.absinfo as *mut AbsInfo) }, "EVIOCGABS")?;
            check(unsafe { libc::ioctl(ui, UI_ABS_SETUP as _, &s as *const UinputAbsSetup) }, "UI_ABS_SETUP")?;
        }
    }
    let setup = UinputSetup { id, name, ff_effects_max: 0 };
    check(unsafe { libc::ioctl(ui, UI_DEV_SETUP as _, &setup as *const UinputSetup) }, "UI_DEV_SETUP")?;
    check(unsafe { libc::ioctl(ui, UI_DEV_CREATE as _) }, "UI_DEV_CREATE")?;
    let n = name.iter().position(|&b| b == 0).unwrap_or(name.len());
    eprintln!(
        "y700-padkeys: clone \"{}\" {:04x}:{:04x} v{:04x}",
        String::from_utf8_lossy(&name[..n]),
        id.vendor,
        id.product,
        id.version
    );
    Ok(ui)
}

// root -> the desktop session's bus
fn call(what: &str, args: &[&str]) {
    let machine = format!("--machine={SESSION_USER}@.host");
    match Command::new("busctl").arg(&machine).arg("--user").arg("call").args(args).status() {
        Ok(s) if s.success() => eprintln!("y700-padkeys: {what}"),
        Ok(s) => eprintln!("y700-padkeys: {what} failed ({s})"),
        Err(e) => eprintln!("y700-padkeys: {what} failed ({e})"),
    }
}

fn single() {
    call(
        "single tap: control centre toggle",
        &["fyi.y700.ControlCenter", "/ControlCenter", "fyi.y700.ControlCenter", "toggle"],
    );
}

fn double() {
    call(
        "double tap: task switcher toggle",
        &["org.kde.kglobalaccel", "/component/kwin", "org.kde.kglobalaccel.Component", "invokeShortcut", "s", "y700-taskswitcher"],
    );
}

fn main() {
    let path = match std::env::args().nth(1) {
        Some(p) => p,
        None => {
            eprintln!("usage: y700-padkeys /dev/input/eventN");
            std::process::exit(2);
        }
    };
    let setup = || -> io::Result<(libc::c_int, libc::c_int)> {
        let real = open(&path, libc::O_RDONLY)?;
        let ui = clone_device(real)?;
        check(unsafe { libc::ioctl(real, EVIOCGRAB as _, 1 as libc::c_int) }, "EVIOCGRAB")?;
        Ok((real, ui))
    };
    let (real, ui) = match setup() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("y700-padkeys: {path}: {e}");
            std::process::exit(1);
        }
    };
    eprintln!("y700-padkeys: grabbed {path}");

    // forwarder thread: everything but the home key to the clone, home key presses to the channel;
    // the channel closes when the device goes away
    let (tx, rx) = mpsc::channel::<Instant>();
    thread::spawn(move || {
        // struct input_event on arm64: timeval (16) + type (2) + code (2) + value (4)
        let mut buf = [0u8; 24 * 64];
        loop {
            let n = unsafe { libc::read(real, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
            if n <= 0 {
                return;
            }
            let n = n as usize;
            let mut out: Vec<u8> = Vec::with_capacity(n);
            for ev in buf[..n].chunks_exact(24) {
                let typ = u16::from_ne_bytes([ev[16], ev[17]]);
                let code = u16::from_ne_bytes([ev[18], ev[19]]);
                let value = i32::from_ne_bytes([ev[20], ev[21], ev[22], ev[23]]);
                if typ == EV_KEY && code == BTN_MODE {
                    if value == 1 && tx.send(Instant::now()).is_err() {
                        return;
                    }
                    continue;
                }
                out.extend_from_slice(ev);
            }
            if !out.is_empty() {
                unsafe { libc::write(ui, out.as_ptr() as *const libc::c_void, out.len()) };
            }
        }
    });

    let mut pending: Option<Instant> = None; // first tap of a possible double tap
    loop {
        let got = match pending {
            None => rx.recv().map_err(|_| mpsc::RecvTimeoutError::Disconnected),
            Some(t) => rx.recv_timeout((t + DOUBLE_TAP).saturating_duration_since(Instant::now())),
        };
        match got {
            Ok(t) => match pending {
                Some(first) if t.duration_since(first) <= DOUBLE_TAP => {
                    pending = None;
                    double();
                }
                late => {
                    if late.is_some() {
                        single(); // the first tap's window ran out just before this one came in
                    }
                    pending = Some(t);
                }
            },
            Err(mpsc::RecvTimeoutError::Timeout) => {
                pending = None;
                single();
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                eprintln!("y700-padkeys: {path} gone");
                return;
            }
        }
    }
}
