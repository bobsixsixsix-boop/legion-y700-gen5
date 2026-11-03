//! Just enough D-Bus for refresh-auto, on both buses: EXTERNAL auth as our uid with unix fd passing (logind's Inhibit
//! hands its delay lock over as an fd, SCM_RIGHTS), method calls with string / uint32 arguments and a timeout each,
//! match rules, the signals the service lives on, and method calls coming in - answered here with replies and errors,
//! routed the way GDBus routed them for the Python version (src/obj.rs). Extended from
//! linux/display/autobright/src/dbus.rs: neither packaged D-Bus crate is installed, and
//! zbus would pull in some 300 packages. Reads are buffered and taken apart only once whole, so a call that times out
//! leaves the stream in step; everything that comes in while a call waits (signals, calls to us) is kept for the main
//! loop. Little-endian messages only - what every peer on this arm64 tablet sends; anything else is skipped.
use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

pub const SYSTEM_BUS: &str = "/run/dbus/system_bus_socket";
const MAX_MESSAGE: usize = 1 << 27; // the spec's limit
pub const METHOD_CALL: u8 = 1;
pub const METHOD_RETURN: u8 = 2;
pub const ERROR: u8 = 3;
pub const SIGNAL: u8 = 4;
pub const NO_REPLY_EXPECTED: u8 = 1;
/// GDBus's default call timeout (-1): 25 s.
const DEFAULT_TIMEOUT_MS: u64 = 25000;

/// A call's argument, as far as the calls here need one.
#[derive(Debug, Clone, Copy)]
pub enum Arg<'a> {
    Str(&'a str),
    U32(u32),
}

/// Marshalling into one buffer; alignment counts from its start, which is the message's start or the body's (the
/// body starts 8-aligned, so the two agree).
pub struct W(pub Vec<u8>);

impl W {
    pub fn pad(&mut self, align: usize) {
        while self.0.len() % align != 0 {
            self.0.push(0);
        }
    }
    pub fn u32(&mut self, v: u32) {
        self.pad(4);
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    pub fn string(&mut self, s: &str) {
        self.u32(s.len() as u32);
        self.0.extend_from_slice(s.as_bytes());
        self.0.push(0);
    }
    pub fn signature(&mut self, s: &str) {
        self.0.push(s.len() as u8);
        self.0.extend_from_slice(s.as_bytes());
        self.0.push(0);
    }
    fn arg(&mut self, a: &Arg) {
        match a {
            Arg::Str(s) => self.string(s),
            Arg::U32(v) => self.u32(*v),
        }
    }
    pub fn header_field(&mut self, code: u8, kind: &str, value: &str) {
        self.pad(8);
        self.0.push(code);
        self.signature(kind);
        if kind == "g" {
            self.signature(value)
        } else {
            self.string(value)
        }
    }
    pub fn header_u32(&mut self, code: u8, v: u32) {
        self.pad(8);
        self.0.push(code);
        self.signature("u");
        self.u32(v);
    }
    /// The fixed header's field length (bytes 12..16), then the padding before the body, then the body.
    fn finish(mut self, body: &[u8]) -> Vec<u8> {
        let n = (self.0.len() - 16) as u32;
        self.0[12..16].copy_from_slice(&n.to_le_bytes());
        self.pad(8);
        self.0.extend_from_slice(body);
        self.0
    }
}

/// A string as a body ("s").
pub fn string_body(s: &str) -> Vec<u8> {
    let mut w = W(Vec::new());
    w.string(s);
    w.0
}

/// A method call message (iface "": none). Flags 0 like GDBus's calls: the bus may start the destination's service.
pub fn method_call(serial: u32, dest: &str, path: &str, iface: &str, member: &str, args: &[Arg]) -> Vec<u8> {
    let mut body = W(Vec::new());
    let mut sig = String::new();
    for a in args {
        sig.push(match a {
            Arg::Str(_) => 's',
            Arg::U32(_) => 'u',
        });
        body.arg(a);
    }
    let mut m = W(vec![b'l', METHOD_CALL, 0, 1]);
    m.u32(body.0.len() as u32);
    m.u32(serial);
    m.u32(0);
    m.header_field(1, "o", path);
    if !iface.is_empty() {
        m.header_field(2, "s", iface);
    }
    m.header_field(3, "s", member);
    m.header_field(6, "s", dest);
    if !sig.is_empty() {
        m.header_field(8, "g", &sig);
    }
    m.finish(&body.0)
}

/// A method return (error None) or an error reply to `to`, flagged no-reply-expected as GDBus's are.
pub fn reply_message(serial: u32, to: &Msg, error: Option<&str>, sig: &str, body: &[u8]) -> Vec<u8> {
    let mut m = W(vec![b'l', if error.is_some() { ERROR } else { METHOD_RETURN }, NO_REPLY_EXPECTED, 1]);
    m.u32(body.len() as u32);
    m.u32(serial);
    m.u32(0);
    if let Some(e) = error {
        m.header_field(4, "s", e);
    }
    m.header_u32(5, to.serial);
    if !to.sender.is_empty() {
        m.header_field(6, "s", &to.sender);
    }
    if !sig.is_empty() {
        m.header_field(8, "g", sig);
    }
    m.finish(body)
}

#[derive(Debug, Default)]
pub struct Msg {
    pub kind: u8,
    pub flags: u8,
    pub serial: u32,
    pub reply_serial: Option<u32>,
    pub error_name: Option<String>,
    pub sender: String,
    pub path: String,
    pub iface: Option<String>,
    pub member: String,
    pub signature: String,
    pub body: Vec<u8>,
    /// the unix fds that came with it (header field UNIX_FDS)
    pub fds: Vec<OwnedFd>,
}

pub struct R<'a> {
    pub b: &'a [u8],
    pub pos: usize,
}

impl R<'_> {
    pub fn new(b: &[u8]) -> R<'_> {
        R { b, pos: 0 }
    }
    fn align(&mut self, a: usize) {
        self.pos = (self.pos + a - 1) / a * a;
    }
    fn u8(&mut self) -> Option<u8> {
        let v = *self.b.get(self.pos)?;
        self.pos += 1;
        Some(v)
    }
    pub fn u32(&mut self) -> Option<u32> {
        self.align(4);
        let v = u32::from_le_bytes(self.b.get(self.pos..self.pos + 4)?.try_into().ok()?);
        self.pos += 4;
        Some(v)
    }
    fn bytes(&mut self, n: usize) -> Option<String> {
        let s = String::from_utf8_lossy(self.b.get(self.pos..self.pos + n)?).into_owned();
        self.pos += n + 1; // and the nul
        Some(s)
    }
    pub fn string(&mut self) -> Option<String> {
        let n = self.u32()? as usize;
        self.bytes(n)
    }
    fn signature(&mut self) -> Option<String> {
        let n = self.u8()? as usize;
        self.bytes(n)
    }
}

/// The first value of a body whose signature starts with `sig` (one basic type: u, i, b or h as u32).
pub fn first_u32(m: &Msg, sig: char) -> Option<u32> {
    m.signature.starts_with(sig).then(|| R::new(&m.body).u32())?
}

/// The leading strings of a body (NameOwnerChanged: name, old owner, new owner).
pub fn strings(m: &Msg) -> Vec<String> {
    let mut r = R::new(&m.body);
    m.signature.chars().take_while(|c| *c == 's').map_while(|_| r.string()).collect()
}

fn bad(what: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("D-Bus: {what}"))
}

enum Parsed {
    Need,
    Skip(usize),
    Msg(usize, Msg, u32),
}

/// One message off the front of `b`, once it is all there: its length, the message, and how many fds it carries. A
/// big-endian or unreadable message is skipped by its length; only lengths past the spec's limit (a stream out of step)
/// are an error.
fn parse(b: &[u8]) -> io::Result<Parsed> {
    if b.len() < 16 {
        return Ok(Parsed::Need);
    }
    let le = match b[0] {
        b'l' => true,
        b'B' => false,
        _ => return Err(bad("not a message")),
    };
    let n = |at: usize| {
        let a: [u8; 4] = b[at..at + 4].try_into().unwrap();
        (if le { u32::from_le_bytes(a) } else { u32::from_be_bytes(a) }) as usize
    };
    let (body_len, fields_len) = (n(4), n(12));
    if body_len > MAX_MESSAGE || fields_len > MAX_MESSAGE {
        return Err(bad("a message too large"));
    }
    let body_at = (16 + fields_len + 7) / 8 * 8;
    let total = body_at + body_len;
    if b.len() < total {
        return Ok(Parsed::Need);
    }
    if !le {
        return Ok(Parsed::Skip(total));
    }
    let mut m = Msg { kind: b[1], flags: b[2], serial: n(8) as u32, ..Msg::default() };
    let mut fds = 0;
    let mut r = R { b: &b[..16 + fields_len], pos: 16 };
    loop {
        r.align(8);
        if r.pos >= 16 + fields_len {
            break;
        }
        let Some(code) = r.u8() else { return Ok(Parsed::Skip(total)) };
        let Some(kind) = r.signature() else { return Ok(Parsed::Skip(total)) };
        let value = match kind.as_str() {
            "u" => r.u32().map(|v| v.to_string()),
            "s" | "o" => r.string(),
            "g" => r.signature(),
            _ => None,
        };
        let Some(value) = value else { return Ok(Parsed::Skip(total)) };
        match code {
            1 => m.path = value,
            2 => m.iface = Some(value),
            3 => m.member = value,
            4 => m.error_name = Some(value),
            5 => m.reply_serial = value.parse().ok(),
            7 => m.sender = value,
            8 => m.signature = value,
            9 => fds = value.parse().unwrap_or(0),
            _ => {}
        }
    }
    m.body = b[body_at..total].to_vec();
    Ok(Parsed::Msg(total, m, fds))
}

/// poll() for input: Ok(false) when the time ran out (or a signal came).
pub fn wait_readable(fd: RawFd, d: Duration) -> io::Result<bool> {
    let mut p = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    let ms = d.as_millis().clamp(1, i32::MAX as u128) as i32;
    match unsafe { libc::poll(&mut p, 1, ms) } {
        n if n > 0 => Ok(true),
        0 => Ok(false),
        _ => {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                Ok(false)
            } else {
                Err(e)
            }
        }
    }
}

pub struct Bus {
    s: UnixStream,
    /// our unique name (Hello's answer)
    pub name: String,
    serial: u32,
    buf: Vec<u8>,
    /// fds received and not yet given to their message
    fds: VecDeque<OwnedFd>,
    /// everything taken off the socket and not yet handled: signals, calls to us, stray replies
    pub pending: VecDeque<Msg>,
}

impl Bus {
    /// Connects to a bus socket, offers unix fd passing (the system bus agrees; a bus that does not just means no fds)
    /// and says Hello.
    pub fn connect(path: &str) -> io::Result<Bus> {
        let mut s = UnixStream::connect(path).map_err(|e| io::Error::new(e.kind(), format!("{path}: {e}")))?;
        s.set_read_timeout(Some(Duration::from_secs(10)))?;
        s.set_write_timeout(Some(Duration::from_secs(10)))?;
        let uid: String = unsafe { libc::geteuid() }.to_string().bytes().map(|b| format!("{b:02x}")).collect();
        s.write_all(format!("\0AUTH EXTERNAL {uid}\r\n").as_bytes())?;
        let line = auth_line(&mut s)?;
        if !line.starts_with("OK ") {
            return Err(bad(&format!("auth refused: {}", line.trim())));
        }
        s.write_all(b"NEGOTIATE_UNIX_FD\r\n")?;
        auth_line(&mut s)?; // AGREE_UNIX_FD, or ERROR: then no fds
        s.write_all(b"BEGIN\r\n")?;
        let mut bus = Bus { s, name: String::new(), serial: 0, buf: Vec::new(), fds: VecDeque::new(), pending: VecDeque::new() };
        let hello = bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", &[])?;
        bus.name = R::new(&hello.body).string().unwrap_or_default();
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

    /// The system bus: DBUS_SYSTEM_BUS_ADDRESS's unix:path= (as GDBus honours it), else the standard socket.
    pub fn system() -> io::Result<Bus> {
        let addr = std::env::var("DBUS_SYSTEM_BUS_ADDRESS").unwrap_or_default();
        match addr.split_once("unix:path=") {
            Some((_, p)) => Bus::connect(p.split(',').next().unwrap_or("")),
            None => Bus::connect(SYSTEM_BUS),
        }
    }

    pub fn fd(&self) -> RawFd {
        self.s.as_raw_fd()
    }

    /// One recvmsg() (the caller polled first), fds and all, and every whole message into `pending`. EOF (the bus
    /// gone) is an error.
    pub fn fill(&mut self) -> io::Result<()> {
        let mut chunk = [0u8; 65536];
        let mut cmsg = [0u64; 160]; // room for SCM_MAX_FD (253) fds
        let mut iov = libc::iovec { iov_base: chunk.as_mut_ptr().cast(), iov_len: chunk.len() };
        let mut mh: libc::msghdr = unsafe { std::mem::zeroed() };
        mh.msg_iov = &mut iov;
        mh.msg_iovlen = 1;
        mh.msg_control = cmsg.as_mut_ptr().cast();
        mh.msg_controllen = std::mem::size_of_val(&cmsg) as _;
        let n = loop {
            // CLOEXEC: a received fd (the sleep lock) must not leak into kscreen-doctor
            let n = unsafe { libc::recvmsg(self.s.as_raw_fd(), &mut mh, libc::MSG_CMSG_CLOEXEC) };
            if n >= 0 {
                break n as usize;
            }
            let e = io::Error::last_os_error();
            if e.kind() != io::ErrorKind::Interrupted {
                return Err(e);
            }
        };
        unsafe {
            let mut c = libc::CMSG_FIRSTHDR(&mh);
            while !c.is_null() {
                if (*c).cmsg_level == libc::SOL_SOCKET && (*c).cmsg_type == libc::SCM_RIGHTS {
                    let data = libc::CMSG_DATA(c) as *const RawFd;
                    let count = ((*c).cmsg_len as usize - libc::CMSG_LEN(0) as usize) / std::mem::size_of::<RawFd>();
                    for i in 0..count {
                        self.fds.push_back(OwnedFd::from_raw_fd(data.add(i).read_unaligned()));
                    }
                }
                c = libc::CMSG_NXTHDR(&mh, c);
            }
        }
        if n == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "the bus closed the connection"));
        }
        self.buf.extend_from_slice(&chunk[..n]);
        self.take()
    }

    fn take(&mut self) -> io::Result<()> {
        let mut at = 0;
        loop {
            match parse(&self.buf[at..])? {
                Parsed::Need => break,
                Parsed::Skip(n) => at += n,
                Parsed::Msg(n, mut m, nfds) => {
                    for _ in 0..nfds {
                        m.fds.extend(self.fds.pop_front());
                    }
                    self.pending.push_back(m);
                    at += n;
                }
            }
        }
        self.buf.drain(..at);
        if self.buf.is_empty() {
            self.fds.clear(); // fds no message claimed (a skipped one's): closed, never handed to the wrong message
        }
        Ok(())
    }

    fn send(&mut self, m: &[u8]) -> io::Result<()> {
        self.s.write_all(m)
    }

    /// One method call with GDBus's default timeout.
    pub fn call(&mut self, dest: &str, path: &str, iface: &str, member: &str, args: &[Arg]) -> io::Result<Msg> {
        self.call_t(DEFAULT_TIMEOUT_MS, dest, path, iface, member, args)
    }

    /// One method call; an error reply comes back as an io::Error "<name>: <text>", no reply in time as "Timeout was
    /// reached" (GLib's words). Whatever else arrives meanwhile stays in `pending`.
    pub fn call_t(&mut self, ms: u64, dest: &str, path: &str, iface: &str, member: &str, args: &[Arg]) -> io::Result<Msg> {
        self.serial += 1;
        let serial = self.serial;
        self.send(&method_call(serial, dest, path, iface, member, args))?;
        let end = Instant::now() + Duration::from_millis(ms);
        loop {
            let reply = |m: &Msg| m.reply_serial == Some(serial) && matches!(m.kind, METHOD_RETURN | ERROR);
            if let Some(i) = self.pending.iter().position(reply) {
                let m = self.pending.remove(i).unwrap();
                if m.kind == ERROR {
                    let name = m.error_name.clone().unwrap_or_default();
                    let text = if m.signature.starts_with('s') { R::new(&m.body).string() } else { None };
                    return Err(io::Error::other(format!("{name}: {}", text.unwrap_or_default()).trim_end().to_string()));
                }
                return Ok(m);
            }
            let left = end.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "Timeout was reached"));
            }
            if wait_readable(self.fd(), left)? {
                self.fill()?;
            }
        }
    }

    /// The answer to a call to us (nothing when the caller said it wants none).
    pub fn reply(&mut self, to: &Msg, sig: &str, body: &[u8]) -> io::Result<()> {
        self.answer(to, None, sig, body)
    }

    pub fn error(&mut self, to: &Msg, name: &str, text: &str) -> io::Result<()> {
        self.answer(to, Some(name), "s", &string_body(text))
    }

    fn answer(&mut self, to: &Msg, error: Option<&str>, sig: &str, body: &[u8]) -> io::Result<()> {
        if to.flags & NO_REPLY_EXPECTED != 0 {
            return Ok(());
        }
        self.serial += 1;
        let m = reply_message(self.serial, to, error, sig, body);
        self.send(&m)
    }

    pub fn add_match(&mut self, rule: &str) -> io::Result<()> {
        self.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", &[Arg::Str(rule)]).map(drop)
    }

    /// The unique name that owns `name` now (to check a signal's sender against); None when nobody does.
    pub fn name_owner(&mut self, name: &str) -> io::Result<Option<String>> {
        match self.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", &[Arg::Str(name)]) {
            Ok(m) => Ok(R::new(&m.body).string()),
            Err(e) if e.to_string().starts_with("org.freedesktop.DBus.Error.NameHasNoOwner") => Ok(None),
            Err(e) => Err(e),
        }
    }
}

/// One line of the auth conversation.
fn auth_line(s: &mut UnixStream) -> io::Result<String> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    while !line.ends_with(b"\r\n") && line.len() < 512 {
        s.read_exact(&mut byte)?;
        line.push(byte[0]);
    }
    Ok(String::from_utf8_lossy(&line).into_owned())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    /// A message as a bus would send it: header fields 1 path, 2 interface, 3 member, 7 sender, 8 signature
    /// (+ 5 reply serial), then the body.
    pub fn message(kind: u8, serial: u32, path: &str, iface: &str, member: &str, reply_to: Option<u32>, sig: &str, body: &[u8]) -> Vec<u8> {
        let mut m = W(vec![b'l', kind, 0, 1]);
        m.u32(body.len() as u32);
        m.u32(serial);
        m.u32(0);
        if !path.is_empty() {
            m.header_field(1, "o", path);
        }
        if !iface.is_empty() {
            m.header_field(2, "s", iface);
        }
        if !member.is_empty() {
            m.header_field(3, "s", member);
        }
        m.header_field(7, "s", ":1.40");
        if let Some(r) = reply_to {
            m.header_u32(5, r);
        }
        if !sig.is_empty() {
            m.header_field(8, "g", sig);
        }
        m.finish(body)
    }

    pub fn read_one(raw: &[u8]) -> Msg {
        match parse(raw).unwrap() {
            Parsed::Msg(n, m, _) => {
                assert_eq!(n, raw.len());
                m
            }
            _ => panic!("not one whole message"),
        }
    }

    fn bus(ours: UnixStream, serial: u32) -> Bus {
        Bus { s: ours, name: String::new(), serial, buf: Vec::new(), fds: VecDeque::new(), pending: VecDeque::new() }
    }

    #[test]
    fn call_message() {
        let msg = method_call(5, "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "Inhibit",
            &[Arg::Str("sleep"), Arg::Str("y700-refresh-auto"), Arg::Str("panel back to its base refresh rate"), Arg::Str("delay")]);
        assert_eq!(&msg[..4], b"l\x01\x00\x01"); // a call, flags 0 (as GDBus's)
        let m = read_one(&msg);
        assert_eq!((m.kind, m.serial, m.path.as_str(), m.iface.as_deref(), m.member.as_str(), m.signature.as_str()),
            (METHOD_CALL, 5, "/org/freedesktop/login1", Some("org.freedesktop.login1.Manager"), "Inhibit", "ssss"));
        let mut r = R::new(&m.body);
        assert_eq!([r.string(), r.string(), r.string(), r.string()].map(Option::unwrap),
            ["sleep", "y700-refresh-auto", "panel back to its base refresh rate", "delay"]);
        let msg = method_call(6, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            &[Arg::Str("fyi.y700.RefreshAuto"), Arg::U32(4)]);
        let m = read_one(&msg);
        let mut r = R::new(&m.body);
        assert_eq!((m.signature.as_str(), r.string().unwrap(), r.u32()), ("su", "fyi.y700.RefreshAuto".into(), Some(4)));
    }

    #[test]
    fn replies_to_a_call() {
        let call = read_one(&message(METHOD_CALL, 33, "/RefreshAuto", "fyi.y700.RefreshAuto", "status", None, "", &[]));
        let m = read_one(&reply_message(9, &call, None, "s", &string_body("{}")));
        assert_eq!((m.kind, m.flags, m.serial, m.reply_serial, m.signature.as_str()), (METHOD_RETURN, NO_REPLY_EXPECTED, 9, Some(33), "s"));
        assert_eq!(R::new(&m.body).string().unwrap(), "{}");
        let m = read_one(&reply_message(10, &call, Some("org.freedesktop.DBus.Error.UnknownMethod"), "s", &string_body("No such method “x”")));
        assert_eq!((m.kind, m.error_name.as_deref(), m.reply_serial), (ERROR, Some("org.freedesktop.DBus.Error.UnknownMethod"), Some(33)));
        assert_eq!(R::new(&m.body).string().unwrap(), "No such method “x”");
        // the destination is the caller
        let raw = reply_message(11, &call, None, "", &[]);
        assert!(raw.windows(6).any(|w| w == b":1.40\0"));
    }

    #[test]
    fn skips_what_it_cannot_read() {
        // a big-endian message, then an unreadable header field type, then a good signal: only the signal comes out
        let mut be = message(SIGNAL, 1, "/a", "a.b", "X", None, "", &[]);
        be[0] = b'B';
        for at in [4, 8, 12] {
            let v = u32::from_le_bytes(be[at..at + 4].try_into().unwrap());
            be[at..at + 4].copy_from_slice(&v.to_be_bytes());
        }
        let mut odd = W(vec![b'l', SIGNAL, 0, 1]);
        odd.u32(0);
        odd.u32(2);
        odd.u32(0);
        odd.pad(8);
        odd.0.push(1);
        odd.signature("x"); // a type no header field has
        odd.0.extend_from_slice(&[0; 8]);
        let odd = odd.finish(&[]);
        let good = message(SIGNAL, 3, "/ScreenSaver", "org.freedesktop.ScreenSaver", "ActiveChanged", None, "b", &1u32.to_le_bytes());
        let (ours, mut theirs) = UnixStream::pair().unwrap();
        let mut b = bus(ours, 1);
        theirs.write_all(&[be, odd, good].concat()).unwrap();
        b.fill().unwrap();
        assert_eq!(b.pending.len(), 1);
        assert_eq!((b.pending[0].member.as_str(), first_u32(&b.pending[0], 'b')), ("ActiveChanged", Some(1)));
        assert!(b.buf.is_empty());
    }

    #[test]
    fn call_keeps_what_comes_first_and_times_out_in_step() {
        let (ours, mut theirs) = UnixStream::pair().unwrap();
        let mut b = bus(ours, 1);
        // a signal and a call to us, then the reply to our call (serial 2), split across two writes
        let sig = message(SIGNAL, 7, "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "PrepareForSleep", None, "b", &0u32.to_le_bytes());
        let call = message(METHOD_CALL, 8, "/RefreshAuto", "fyi.y700.RefreshAuto", "status", None, "", &[]);
        let mut reply = W(Vec::new());
        reply.u32(1);
        let reply = message(METHOD_RETURN, 9, "", "", "", Some(2), "u", &reply.0);
        let all = [sig, call, reply].concat();
        theirs.write_all(&all[..all.len() - 5]).unwrap();
        let t = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            theirs.write_all(&all[all.len() - 5..]).unwrap();
            theirs
        });
        let m = b.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", &[Arg::Str("x"), Arg::U32(4)]).unwrap();
        assert_eq!(first_u32(&m, 'u'), Some(1));
        let mut theirs = t.join().unwrap();
        assert_eq!(b.pending.iter().map(|m| m.kind).collect::<Vec<_>>(), [SIGNAL, METHOD_CALL]);
        b.pending.clear();
        // no reply in time: an error; the late reply (serial 3) is left for the main loop to drop, the next call works
        let e = b.call_t(100, "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "start", &[]).unwrap_err();
        assert_eq!((e.kind(), e.to_string().as_str()), (io::ErrorKind::TimedOut, "Timeout was reached"));
        theirs.write_all(&message(METHOD_RETURN, 10, "", "", "", Some(3), "", &[])).unwrap();
        theirs.write_all(&error_reply(4, "org.freedesktop.DBus.Error.ServiceUnknown", "The name is not activatable")).unwrap();
        let e = b.call_t(1000, "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "start", &[]).unwrap_err();
        assert_eq!(e.to_string(), "org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable");
        assert_eq!(b.pending.len(), 1); // the stray reply
        assert_eq!(b.pending[0].reply_serial, Some(3));
    }

    /// An error reply: the name is header field 4, the text the body.
    pub fn error_reply(to: u32, name: &str, text: &str) -> Vec<u8> {
        let mut m = W(vec![b'l', ERROR, 0, 1]);
        let body = string_body(text);
        m.u32(body.len() as u32);
        m.u32(8);
        m.u32(0);
        m.header_field(4, "s", name);
        m.header_u32(5, to);
        m.header_field(8, "g", "s");
        m.finish(&body)
    }

    #[test]
    fn an_fd_comes_with_its_reply() {
        // logind's Inhibit reply: (h) = index 0 into the message's fds, the fd itself as SCM_RIGHTS
        let (ours, theirs) = UnixStream::pair().unwrap();
        let mut b = bus(ours, 1);
        let (lock, mut held) = UnixStream::pair().unwrap();
        let mut w = W(vec![b'l', METHOD_RETURN, 0, 1]);
        w.u32(4);
        w.u32(9);
        w.u32(0);
        w.header_u32(5, 2);
        w.header_field(8, "g", "h");
        w.header_u32(9, 1);
        let raw = w.finish(&0u32.to_le_bytes());
        let mut cmsg = [0u64; 4];
        let mut iov = libc::iovec { iov_base: raw.as_ptr() as *mut _, iov_len: raw.len() };
        let mut mh: libc::msghdr = unsafe { std::mem::zeroed() };
        mh.msg_iov = &mut iov;
        mh.msg_iovlen = 1;
        mh.msg_control = cmsg.as_mut_ptr().cast();
        mh.msg_controllen = unsafe { libc::CMSG_SPACE(4) } as _;
        unsafe {
            let c = libc::CMSG_FIRSTHDR(&mh);
            (*c).cmsg_level = libc::SOL_SOCKET;
            (*c).cmsg_type = libc::SCM_RIGHTS;
            (*c).cmsg_len = libc::CMSG_LEN(4) as _;
            (libc::CMSG_DATA(c) as *mut RawFd).write_unaligned(lock.as_raw_fd());
            assert_eq!(libc::sendmsg(theirs.as_raw_fd(), &mh, 0), raw.len() as isize);
        }
        drop(lock);
        let mut m = b.call("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "Inhibit", &[]).unwrap();
        assert_eq!((m.signature.as_str(), first_u32(&m, 'h'), m.fds.len()), ("h", Some(0), 1));
        let fd = m.fds.remove(0);
        let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFD) };
        assert_eq!(flags & libc::FD_CLOEXEC, libc::FD_CLOEXEC);
        // the lock is held while the fd is open, released when it is closed (what logind waits for)
        held.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        assert!(held.read(&mut [0u8; 1]).is_err()); // still open: no EOF
        drop(fd);
        // recv with SO_RCVTIMEO is never restarted (signal(7)): EINTR seen 4 in 60 runs on the tablet, source unknown
        let eof = loop {
            match held.read(&mut [0u8; 1]) {
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                r => break r.unwrap(),
            }
        };
        assert_eq!(eof, 0);
    }

    #[test]
    fn name_owner() {
        let (ours, mut theirs) = UnixStream::pair().unwrap();
        let mut b = bus(ours, 1);
        theirs.write_all(&message(METHOD_RETURN, 5, "", "", "", Some(2), "s", &string_body(":1.4"))).unwrap();
        assert_eq!(b.name_owner("org.freedesktop.login1").unwrap().as_deref(), Some(":1.4"));
        theirs.write_all(&error_reply(3, "org.freedesktop.DBus.Error.NameHasNoOwner", "Could not get owner of name 'org.freedesktop.login1': no such name")).unwrap();
        assert_eq!(b.name_owner("org.freedesktop.login1").unwrap(), None);
        let mut w = W(Vec::new());
        for s in ["org.freedesktop.login1", ":1.4", ":1.9"] {
            w.string(s);
        }
        assert_eq!(strings(&read_one(&message(SIGNAL, 1, "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged", None, "sss", &w.0))),
            ["org.freedesktop.login1", ":1.4", ":1.9"]);
    }

    #[test]
    fn eof_is_an_error() {
        let (ours, theirs) = UnixStream::pair().unwrap();
        let mut b = bus(ours, 1);
        drop(theirs);
        assert_eq!(b.fill().unwrap_err().kind(), io::ErrorKind::UnexpectedEof);
    }
}
