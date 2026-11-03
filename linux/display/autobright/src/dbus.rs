//! Just enough D-Bus for the light sensor (iio-sensor-proxy, system bus) and KDE's screen brightness (PowerDevil,
//! session bus): EXTERNAL auth as our uid, method calls with string / int32 / uint32 arguments, Properties.Get of a
//! double or an int32, match rules, and the two signals the service lives on (PropertiesChanged, NameOwnerChanged).
//! Hand-written because neither packaged D-Bus crate is installed and zbus
//! would pull in some 300 packages. Little-endian messages only - what every peer on this arm64 tablet sends.
use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::time::Duration;

pub const SYSTEM_BUS: &str = "/run/dbus/system_bus_socket";
const MAX_MESSAGE: usize = 1 << 20;
const METHOD_RETURN: u8 = 2;
const ERROR: u8 = 3;
pub const SIGNAL: u8 = 4;
const NO_REPLY_EXPECTED: u8 = 1;
/// Header flag: the bus is not to start the destination's service for us (iio-sensor-proxy quits with "No sensors"
/// when the sensor core is late; starting it again from here would only repeat that).
const NO_AUTO_START: u8 = 2;

/// A call's argument, as far as the calls here need one.
#[derive(Debug, Clone, Copy)]
pub enum Arg<'a> {
    Str(&'a str),
    I32(i32),
    U32(u32),
}

impl Arg<'_> {
    fn signature(&self) -> &'static str {
        match self {
            Arg::Str(_) => "s",
            Arg::I32(_) => "i",
            Arg::U32(_) => "u",
        }
    }
}

/// Marshalling into one buffer; alignment counts from its start, which is the message's start or the body's (the
/// body starts 8-aligned, so the two agree).
pub(crate) struct W(pub(crate) Vec<u8>);

impl W {
    pub(crate) fn pad(&mut self, align: usize) {
        while self.0.len() % align != 0 {
            self.0.push(0);
        }
    }
    pub(crate) fn u32(&mut self, v: u32) {
        self.pad(4);
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    pub(crate) fn string(&mut self, s: &str) {
        self.u32(s.len() as u32);
        self.0.extend_from_slice(s.as_bytes());
        self.0.push(0);
    }
    pub(crate) fn signature(&mut self, s: &str) {
        self.0.push(s.len() as u8);
        self.0.extend_from_slice(s.as_bytes());
        self.0.push(0);
    }
    fn arg(&mut self, a: &Arg) {
        match a {
            Arg::Str(s) => self.string(s),
            Arg::I32(v) => self.u32(*v as u32),
            Arg::U32(v) => self.u32(*v),
        }
    }
    pub(crate) fn header_field(&mut self, code: u8, kind: &str, value: &str) {
        self.pad(8);
        self.0.push(code);
        self.signature(kind);
        if kind == "g" {
            self.signature(value)
        } else {
            self.string(value)
        }
    }
}

/// A method call message.
pub fn method_call(serial: u32, flags: u8, dest: &str, path: &str, iface: &str, member: &str, args: &[Arg]) -> Vec<u8> {
    let mut body = W(Vec::new());
    let mut sig = String::new();
    for a in args {
        sig.push_str(a.signature());
        body.arg(a);
    }
    let mut m = W(vec![b'l', 1, flags | NO_AUTO_START, 1]);
    m.u32(body.0.len() as u32);
    m.u32(serial);
    m.u32(0); // header fields' length, filled in below
    m.header_field(1, "o", path);
    m.header_field(2, "s", iface);
    m.header_field(3, "s", member);
    m.header_field(6, "s", dest);
    if !sig.is_empty() {
        m.header_field(8, "g", &sig);
    }
    let n = (m.0.len() - 16) as u32;
    m.0[12..16].copy_from_slice(&n.to_le_bytes());
    m.pad(8);
    m.0.extend_from_slice(&body.0);
    m.0
}

#[derive(Debug, Default)]
pub struct Msg {
    pub kind: u8,
    pub reply_serial: Option<u32>,
    pub error_name: Option<String>,
    pub sender: String,
    pub path: String,
    pub member: String,
    pub signature: String,
    pub body: Vec<u8>,
}

/// A property value, as far as the two services here send them.
#[derive(Debug, Clone, PartialEq)]
pub enum Val {
    F64(f64),
    Int(i64),
    Str(String),
}

pub(crate) struct R<'a> {
    pub(crate) b: &'a [u8],
    pub(crate) pos: usize,
}

impl R<'_> {
    fn align(&mut self, a: usize) {
        self.pos = (self.pos + a - 1) / a * a;
    }
    fn u8(&mut self) -> Option<u8> {
        let v = *self.b.get(self.pos)?;
        self.pos += 1;
        Some(v)
    }
    fn u32(&mut self) -> Option<u32> {
        self.align(4);
        let v = u32::from_le_bytes(self.b.get(self.pos..self.pos + 4)?.try_into().ok()?);
        self.pos += 4;
        Some(v)
    }
    fn u64(&mut self) -> Option<u64> {
        self.align(8);
        let v = u64::from_le_bytes(self.b.get(self.pos..self.pos + 8)?.try_into().ok()?);
        self.pos += 8;
        Some(v)
    }
    fn bytes(&mut self, n: usize) -> Option<String> {
        let s = String::from_utf8_lossy(self.b.get(self.pos..self.pos + n)?).into_owned();
        self.pos += n + 1; // and the nul
        Some(s)
    }
    pub(crate) fn string(&mut self) -> Option<String> {
        let n = self.u32()? as usize;
        self.bytes(n)
    }
    fn signature(&mut self) -> Option<String> {
        let n = self.u8()? as usize;
        self.bytes(n)
    }
    /// A variant's value of a basic type; None for containers (nothing here sends one, and skipping them would need a
    /// full signature parser).
    fn variant(&mut self) -> Option<Val> {
        Some(match self.signature()?.as_str() {
            "d" => Val::F64(f64::from_bits(self.u64()?)),
            "i" => Val::Int(self.u32()? as i32 as i64),
            "u" | "b" => Val::Int(self.u32()? as i64),
            "x" => Val::Int(self.u64()? as i64),
            "t" => Val::Int(self.u64()? as i64),
            "y" => Val::Int(self.u8()? as i64),
            "s" | "o" => Val::Str(self.string()?),
            "g" => Val::Str(self.signature()?),
            _ => return None,
        })
    }
}

/// The value of a reply whose body is one variant (Properties.Get); None for anything else.
pub fn variant_reply(m: &Msg) -> Option<Val> {
    if m.kind != METHOD_RETURN || m.signature != "v" {
        return None;
    }
    R { b: &m.body, pos: 0 }.variant()
}

/// The body of PropertiesChanged (sa{sv}as): the interface and the changed properties, in order. Stops at the first
/// value it cannot read (a container), keeping what came before.
pub fn properties_changed(m: &Msg) -> Option<(String, Vec<(String, Val)>)> {
    if m.signature != "sa{sv}as" {
        return None;
    }
    let mut r = R { b: &m.body, pos: 0 };
    let iface = r.string()?;
    let len = r.u32()? as usize;
    r.align(8);
    let end = r.pos + len;
    let mut props = Vec::new();
    while r.pos < end {
        r.align(8);
        let Some(key) = r.string() else { break };
        let Some(v) = r.variant() else { break };
        props.push((key, v));
    }
    Some((iface, props))
}

/// The leading strings of a body (NameOwnerChanged: name, old owner, new owner).
pub fn strings(m: &Msg) -> Vec<String> {
    let mut r = R { b: &m.body, pos: 0 };
    m.signature.chars().take_while(|c| *c == 's').map_while(|_| r.string()).collect()
}

fn bad(what: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("D-Bus: {what}"))
}

/// Reads one message.
pub fn read_message(s: &mut impl Read) -> io::Result<Msg> {
    let mut whole = vec![0u8; 16];
    s.read_exact(&mut whole)?;
    if whole[0] != b'l' {
        return Err(bad("a big-endian message"));
    }
    let le32 = |b: &[u8]| u32::from_le_bytes(b.try_into().unwrap()) as usize;
    let (body_len, fields_len) = (le32(&whole[4..8]), le32(&whole[12..16]));
    if body_len > MAX_MESSAGE || fields_len > MAX_MESSAGE {
        return Err(bad("a message too large"));
    }
    let body_at = (16 + fields_len + 7) / 8 * 8;
    whole.resize(body_at + body_len, 0);
    s.read_exact(&mut whole[16..])?;
    let mut m = Msg { kind: whole[1], ..Msg::default() };
    let mut r = R { b: &whole[..16 + fields_len], pos: 16 };
    loop {
        r.align(8);
        if r.pos >= 16 + fields_len {
            break;
        }
        let code = r.u8().ok_or_else(|| bad("a cut-off header field"))?;
        let kind = r.signature().ok_or_else(|| bad("a cut-off header field"))?;
        let value = match kind.as_str() {
            "u" => r.u32().map(|v| v.to_string()),
            "s" | "o" => r.string(),
            "g" => r.signature(),
            _ => None,
        }
        .ok_or_else(|| bad("an unreadable header field"))?;
        match code {
            1 => m.path = value,
            3 => m.member = value,
            4 => m.error_name = Some(value),
            5 => m.reply_serial = value.parse().ok(),
            7 => m.sender = value,
            8 => m.signature = value,
            _ => {}
        }
    }
    m.body = whole.split_off(body_at);
    Ok(m)
}

pub struct Bus {
    s: UnixStream,
    serial: u32,
    /// signals that came in while a call waited for its reply, for the main loop
    pub pending: VecDeque<Msg>,
}

impl Bus {
    /// Connects to a bus socket and says Hello.
    pub fn connect(path: &str) -> io::Result<Bus> {
        let mut s = UnixStream::connect(path).map_err(|e| io::Error::new(e.kind(), format!("{path}: {e}")))?;
        s.set_read_timeout(Some(Duration::from_secs(10)))?;
        s.set_write_timeout(Some(Duration::from_secs(10)))?;
        let uid: String = unsafe { libc::geteuid() }.to_string().bytes().map(|b| format!("{b:02x}")).collect();
        s.write_all(format!("\0AUTH EXTERNAL {uid}\r\n").as_bytes())?;
        let mut line = Vec::new();
        let mut byte = [0u8; 1];
        while !line.ends_with(b"\r\n") && line.len() < 512 {
            s.read_exact(&mut byte)?;
            line.push(byte[0]);
        }
        if !line.starts_with(b"OK ") {
            return Err(bad(&format!("auth refused: {}", String::from_utf8_lossy(&line).trim())));
        }
        s.write_all(b"BEGIN\r\n")?;
        let mut bus = Bus { s, serial: 0, pending: VecDeque::new() };
        bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", &[])?;
        Ok(bus)
    }

    /// The session bus: DBUS_SESSION_BUS_ADDRESS's unix:path=, else $XDG_RUNTIME_DIR/bus (what systemd sets up).
    pub fn session() -> io::Result<Bus> {
        let addr = std::env::var("DBUS_SESSION_BUS_ADDRESS").unwrap_or_default();
        let path = match addr.split_once("unix:path=") {
            Some((_, p)) => p.split(',').next().unwrap_or("").to_string(),
            None => format!("{}/bus", std::env::var("XDG_RUNTIME_DIR").unwrap_or_default()),
        };
        Bus::connect(&path)
    }

    pub fn fd(&self) -> RawFd {
        self.s.as_raw_fd()
    }

    /// One method call; an error reply comes back as an io::Error with its name and message. Signals that arrive
    /// meanwhile go to `pending`.
    pub fn call(&mut self, dest: &str, path: &str, iface: &str, member: &str, args: &[Arg]) -> io::Result<Msg> {
        self.serial += 1;
        let serial = self.serial;
        self.s.write_all(&method_call(serial, 0, dest, path, iface, member, args))?;
        loop {
            let m = self.read()?;
            if m.reply_serial != Some(serial) {
                if m.kind == SIGNAL {
                    self.pending.push_back(m);
                }
                continue;
            }
            match m.kind {
                METHOD_RETURN => return Ok(m),
                ERROR => {
                    let name = m.error_name.clone().unwrap_or_default();
                    let text = if m.signature.starts_with('s') { R { b: &m.body, pos: 0 }.string() } else { None };
                    return Err(io::Error::other(format!("{name}: {}", text.unwrap_or_default()).trim_end().to_string()));
                }
                _ => continue,
            }
        }
    }

    /// A call nobody waits for (SetBrightness, as the Python version's fire-and-forget Gio call).
    pub fn send(&mut self, dest: &str, path: &str, iface: &str, member: &str, args: &[Arg]) -> io::Result<()> {
        self.serial += 1;
        self.s.write_all(&method_call(self.serial, NO_REPLY_EXPECTED, dest, path, iface, member, args))
    }

    pub fn get(&mut self, dest: &str, path: &str, iface: &str, name: &str) -> io::Result<Val> {
        let m = self.call(dest, path, "org.freedesktop.DBus.Properties", "Get", &[Arg::Str(iface), Arg::Str(name)])?;
        variant_reply(&m).ok_or_else(|| bad(&format!("{name}: not a value")))
    }

    pub fn add_match(&mut self, rule: &str) -> io::Result<()> {
        self.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", &[Arg::Str(rule)])
            .map(drop)
    }

    /// The unique name that owns `name` now (to check a signal's sender against); None when nobody does.
    pub fn name_owner(&mut self, name: &str) -> io::Result<Option<String>> {
        match self.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", &[Arg::Str(name)]) {
            Ok(m) => Ok(R { b: &m.body, pos: 0 }.string()),
            Err(e) if e.to_string().starts_with("org.freedesktop.DBus.Error.NameHasNoOwner") => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// The next message off the socket (the main loop calls it when poll() says there is one).
    pub fn read(&mut self) -> io::Result<Msg> {
        read_message(&mut self.s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A message as a bus would send it: header fields 1 path, 3 member, 8 signature (+ 5 reply serial), then body.
    pub(crate) fn message(kind: u8, path: &str, member: &str, reply_to: Option<u32>, sig: &str, body: &[u8]) -> Vec<u8> {
        let mut m = W(vec![b'l', kind, 0, 1]);
        m.u32(body.len() as u32);
        m.u32(7);
        m.u32(0);
        m.header_field(1, "o", path);
        m.header_field(3, "s", member);
        m.header_field(7, "s", ":1.40");
        if let Some(r) = reply_to {
            m.pad(8);
            m.0.push(5);
            m.signature("u");
            m.u32(r);
        }
        m.header_field(8, "g", sig);
        let n = (m.0.len() - 16) as u32;
        m.0[12..16].copy_from_slice(&n.to_le_bytes());
        m.pad(8);
        m.0.extend_from_slice(body);
        m.0
    }

    #[test]
    fn set_brightness_message() {
        let msg = method_call(5, NO_REPLY_EXPECTED, "org.kde.ScreenBrightness", "/org/kde/ScreenBrightness/display0",
            "org.kde.ScreenBrightness.Display", "SetBrightness", &[Arg::I32(4321), Arg::U32(1)]);
        assert_eq!(&msg[..4], b"l\x01\x03\x01"); // call, no reply expected | no auto start
        let m = read_message(&mut &msg[..]).unwrap();
        assert_eq!((m.kind, m.path.as_str(), m.member.as_str(), m.signature.as_str()),
            (1, "/org/kde/ScreenBrightness/display0", "SetBrightness", "iu"));
        assert_eq!(m.body, [4321u32.to_le_bytes(), 1u32.to_le_bytes()].concat());
    }

    #[test]
    fn sensor_properties_changed() {
        // iio-sensor-proxy's: LightLevel (d, 8-aligned after the variant's signature), a string, a boolean
        let mut b = W(Vec::new());
        b.string("net.hadess.SensorProxy");
        b.u32(0);
        let at = b.0.len() - 4;
        b.pad(8);
        let start = b.0.len();
        b.pad(8);
        b.string("LightLevel");
        b.signature("d");
        b.pad(8);
        b.0.extend_from_slice(&97.301216f64.to_le_bytes());
        b.pad(8);
        b.string("LightLevelUnit");
        b.signature("s");
        b.string("lux");
        b.pad(8);
        b.string("HasAmbientLight");
        b.signature("b");
        b.u32(1);
        let n = (b.0.len() - start) as u32;
        b.0[at..at + 4].copy_from_slice(&n.to_le_bytes());
        b.u32(0); // invalidated: empty
        let raw = message(SIGNAL, "/net/hadess/SensorProxy", "PropertiesChanged", None, "sa{sv}as", &b.0);
        let m = read_message(&mut &raw[..]).unwrap();
        assert_eq!((m.kind, m.sender.as_str(), m.path.as_str(), m.member.as_str()), (SIGNAL, ":1.40", "/net/hadess/SensorProxy", "PropertiesChanged"));
        let (iface, props) = properties_changed(&m).unwrap();
        assert_eq!(iface, "net.hadess.SensorProxy");
        assert_eq!(props, vec![
            ("LightLevel".to_string(), Val::F64(97.301216)),
            ("LightLevelUnit".to_string(), Val::Str("lux".into())),
            ("HasAmbientLight".to_string(), Val::Int(1)),
        ]);
    }

    #[test]
    fn brightness_and_a_container() {
        // PowerDevil's Brightness (i), then a value we cannot read: what came before is kept
        let mut b = W(Vec::new());
        b.string("org.kde.ScreenBrightness.Display");
        b.u32(0);
        let at = b.0.len() - 4;
        b.pad(8);
        let start = b.0.len();
        b.string("Brightness");
        b.signature("i");
        b.u32(-5i32 as u32);
        b.pad(8);
        b.string("Odd");
        b.signature("as");
        b.u32(0);
        let n = (b.0.len() - start) as u32;
        b.0[at..at + 4].copy_from_slice(&n.to_le_bytes());
        b.u32(0);
        let raw = message(SIGNAL, "/org/kde/ScreenBrightness/display0", "PropertiesChanged", None, "sa{sv}as", &b.0);
        let (_, props) = properties_changed(&read_message(&mut &raw[..]).unwrap()).unwrap();
        assert_eq!(props, vec![("Brightness".to_string(), Val::Int(-5))]);
    }

    #[test]
    fn name_owner_changed_and_replies() {
        let mut b = W(Vec::new());
        for s in ["net.hadess.SensorProxy", ":1.40", ""] {
            b.string(s);
        }
        let raw = message(SIGNAL, "/org/freedesktop/DBus", "NameOwnerChanged", None, "sss", &b.0);
        assert_eq!(strings(&read_message(&mut &raw[..]).unwrap()), ["net.hadess.SensorProxy", ":1.40", ""]);
        // Properties.Get replies
        let mut v = W(Vec::new());
        v.signature("i");
        v.u32(10000);
        let raw = message(METHOD_RETURN, "/", "", Some(3), "v", &v.0);
        let m = read_message(&mut &raw[..]).unwrap();
        assert_eq!((m.reply_serial, variant_reply(&m)), (Some(3), Some(Val::Int(10000))));
        let mut v = W(Vec::new());
        v.signature("d");
        v.pad(8);
        v.0.extend_from_slice(&3.47222f64.to_le_bytes());
        let m = read_message(&mut &message(METHOD_RETURN, "/", "", Some(4), "v", &v.0)[..]).unwrap();
        assert_eq!(variant_reply(&m), Some(Val::F64(3.47222)));
        assert!(read_message(&mut &[b'B', 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0][..]).is_err());
    }

    #[test]
    fn call_keeps_the_signals_that_come_first() {
        // a signal, then the reply to our call (serial 2: Hello was 1)
        let (ours, mut theirs) = UnixStream::pair().unwrap();
        let mut bus = Bus { s: ours, serial: 1, pending: VecDeque::new() };
        let mut b = W(Vec::new());
        for s in ["net.hadess.SensorProxy", "", ":1.50"] {
            b.string(s);
        }
        theirs.write_all(&message(SIGNAL, "/org/freedesktop/DBus", "NameOwnerChanged", None, "sss", &b.0)).unwrap();
        theirs.write_all(&message(METHOD_RETURN, "/", "", Some(2), "", &[])).unwrap();
        bus.call("net.hadess.SensorProxy", "/net/hadess/SensorProxy", "net.hadess.SensorProxy", "ClaimLight", &[]).unwrap();
        assert_eq!(bus.pending.len(), 1);
        assert_eq!(bus.pending[0].member, "NameOwnerChanged");
        // and an error reply is an error with its name
        theirs.write_all(&error_reply(3, "org.freedesktop.DBus.Error.AccessDenied", "Not Authorized: Sensor claim not allowed")).unwrap();
        let err = bus.call("net.hadess.SensorProxy", "/net/hadess/SensorProxy", "net.hadess.SensorProxy", "ClaimLight", &[]).err().unwrap();
        assert_eq!(err.to_string(), "org.freedesktop.DBus.Error.AccessDenied: Not Authorized: Sensor claim not allowed");
    }

    /// An error reply: the name is header field 4, the text the body.
    fn error_reply(to: u32, name: &str, text: &str) -> Vec<u8> {
        let mut e = W(Vec::new());
        e.string(text);
        let mut m = W(vec![b'l', ERROR, 0, 1]);
        m.u32(e.0.len() as u32);
        m.u32(8);
        m.u32(0);
        m.header_field(4, "s", name);
        m.pad(8);
        m.0.push(5);
        m.signature("u");
        m.u32(to);
        m.header_field(8, "g", "s");
        let n = (m.0.len() - 16) as u32;
        m.0[12..16].copy_from_slice(&n.to_le_bytes());
        m.pad(8);
        m.0.extend_from_slice(&e.0);
        m.0
    }

    #[test]
    fn name_owner() {
        let (ours, mut theirs) = UnixStream::pair().unwrap();
        let mut bus = Bus { s: ours, serial: 1, pending: VecDeque::new() };
        let mut b = W(Vec::new());
        b.string(":1.40");
        theirs.write_all(&message(METHOD_RETURN, "/", "", Some(2), "s", &b.0)).unwrap();
        assert_eq!(bus.name_owner("net.hadess.SensorProxy").unwrap().as_deref(), Some(":1.40"));
        theirs.write_all(&error_reply(3, "org.freedesktop.DBus.Error.NameHasNoOwner", "Could not get owner of name 'net.hadess.SensorProxy': no such name")).unwrap();
        assert_eq!(bus.name_owner("net.hadess.SensorProxy").unwrap(), None);
        theirs.write_all(&error_reply(4, "org.freedesktop.DBus.Error.AccessDenied", "no")).unwrap();
        assert!(bus.name_owner("net.hadess.SensorProxy").is_err());
    }
}
