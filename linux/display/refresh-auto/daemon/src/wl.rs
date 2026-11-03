//! The screen's power state as KWin reports it: a minimal Wayland client (the wire protocol by hand, libc only) that
//! binds every wl_output and KWin's org_kde_kwin_dpms_manager (the protocol kscreen-doctor --dpms and PowerDevil use)
//! and keeps each output's mode (0 On, 1 Standby, 2 Suspend, 3 Off) as of its last `done`. KWin sends a mode event
//! when the mode changes, so a dark screen costs no wakeups; the Python version read the DSI dpms node every second
//! while the panel was below its base rate. Copied from linux/display/autobright/src/wl.rs and extended: outputs are
//! bound at version 4 for their name, so that the panel (DSI-*) counts alone once it is known - an external screen that
//! stays on must not keep the panel's video rate past its own screen-off.
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::time::Duration;

const DISPLAY: u32 = 1;
const REGISTRY: u32 = 2;
const DPMS_MANAGER: &str = "org_kde_kwin_dpms_manager";
const MODE_ON: u32 = 0;
/// wl_output version 4 has the name event (opcode 4)
const OUTPUT_VERSION: u32 = 4;

fn bad(msg: String) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

#[derive(Default)]
struct Output {
    obj: u32,
    dpms: Option<u32>,
    pending: Option<u32>,
    mode: Option<u32>, // as of the last done
    name: Option<String>,
}

impl Output {
    fn panel(&self) -> bool {
        self.name.as_deref().is_some_and(|n| n.starts_with("DSI"))
    }
}

pub struct Wl {
    s: UnixStream,
    buf: Vec<u8>,
    next_id: u32,
    manager: Option<u32>,
    outputs: HashMap<u32, Output>, // by global name
    synced: Option<u32>,           // the last wl_callback that fired
}

fn message(obj: u32, op: u16, args: &[u8]) -> Vec<u8> {
    let mut m = Vec::with_capacity(8 + args.len());
    m.extend_from_slice(&obj.to_le_bytes());
    m.extend_from_slice(&(((8 + args.len()) as u32) << 16 | op as u32).to_le_bytes());
    m.extend_from_slice(args);
    m
}

fn string_arg(s: &str) -> Vec<u8> {
    let mut a = ((s.len() + 1) as u32).to_le_bytes().to_vec();
    a.extend_from_slice(s.as_bytes());
    a.push(0);
    while a.len() % 4 != 0 {
        a.push(0);
    }
    a
}

/// A string argument at byte `at` of a message's arguments, and where the next argument starts.
fn string_at(a: &[u8], at: usize) -> (String, usize) {
    let len = a.get(at..at + 4).map_or(0, |b| u32::from_le_bytes(b.try_into().unwrap()) as usize);
    let s = a.get(at + 4..at + 4 + len.saturating_sub(1)).map(String::from_utf8_lossy).unwrap_or_default().into_owned();
    (s, at + 4 + (len + 3) / 4 * 4)
}

impl Wl {
    /// Connects to $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY and waits (5 s at most) until every output's mode is known.
    /// An error when KWin does not offer the DPMS protocol: then there is nothing to wait on.
    pub fn open() -> io::Result<Wl> {
        let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_default();
        let name = std::env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-0".into());
        let path = if name.starts_with('/') { name } else { format!("{dir}/{name}") };
        let s = UnixStream::connect(&path).map_err(|e| io::Error::new(e.kind(), format!("{path}: {e}")))?;
        let mut wl = Wl::new(s)?;
        wl.roundtrip()?; // the globals: outputs and the manager bound, a dpms object asked for per output
        if wl.manager.is_none() {
            // Unsupported: the caller does not try again (the globals will not change in this session)
            return Err(io::Error::new(io::ErrorKind::Unsupported, format!("KWin offers no {DPMS_MANAGER}")));
        }
        wl.roundtrip()?; // their names, first mode and done
        Ok(wl)
    }

    fn new(s: UnixStream) -> io::Result<Wl> {
        s.set_read_timeout(Some(Duration::from_secs(5)))?;
        s.set_write_timeout(Some(Duration::from_secs(5)))?;
        let mut wl = Wl { s, buf: Vec::new(), next_id: 3, manager: None, outputs: HashMap::new(), synced: None };
        wl.send(DISPLAY, 1, &REGISTRY.to_le_bytes())?; // wl_display.get_registry
        Ok(wl)
    }

    pub fn fd(&self) -> RawFd {
        self.s.as_raw_fd()
    }

    /// On unless every output that counts is in a power-saving mode: the panel's outputs once one is known by name,
    /// else all of them (no outputs at all counts as on, as the Python version's "no DPMS node" did).
    pub fn screen_on(&self) -> bool {
        let panel = self.outputs.values().any(Output::panel);
        let modes: Vec<u32> = self.outputs.values().filter(|o| !panel || o.panel()).filter_map(|o| o.mode).collect();
        modes.is_empty() || modes.contains(&MODE_ON)
    }

    /// The outputs' names and modes (the live test prints them).
    #[cfg(test)]
    pub fn outputs(&self) -> Vec<(Option<String>, Option<u32>)> {
        self.outputs.values().map(|o| (o.name.clone(), o.mode)).collect()
    }

    fn id(&mut self) -> u32 {
        self.next_id += 1;
        self.next_id - 1
    }

    fn send(&mut self, obj: u32, op: u16, args: &[u8]) -> io::Result<()> {
        self.s.write_all(&message(obj, op, args))
    }

    fn roundtrip(&mut self) -> io::Result<()> {
        let cb = self.id();
        self.send(DISPLAY, 0, &cb.to_le_bytes())?; // wl_display.sync
        while self.synced != Some(cb) {
            self.read()?;
        }
        Ok(())
    }

    fn bind(&mut self, name: u32, iface: &str, version: u32) -> io::Result<u32> {
        let id = self.id();
        let mut a = name.to_le_bytes().to_vec();
        a.extend(string_arg(iface));
        a.extend_from_slice(&version.to_le_bytes());
        a.extend_from_slice(&id.to_le_bytes());
        self.send(REGISTRY, 0, &a)?;
        Ok(id)
    }

    fn watch(&mut self, name: u32) -> io::Result<()> {
        let (Some(mgr), Some(out)) = (self.manager, self.outputs.get(&name).map(|o| o.obj)) else { return Ok(()) };
        let id = self.id();
        self.send(mgr, 0, &[id.to_le_bytes(), out.to_le_bytes()].concat())?; // org_kde_kwin_dpms_manager.get
        self.outputs.get_mut(&name).unwrap().dpms = Some(id);
        Ok(())
    }

    /// Reads what is there (the main loop calls it when poll() says there is something) and handles every whole
    /// message. EOF (KWin gone) is an error.
    pub fn read(&mut self) -> io::Result<()> {
        let mut chunk = [0u8; 4096];
        let n = loop {
            // recv with SO_RCVTIMEO (open()'s roundtrips) is never restarted after a signal (signal(7))
            match self.s.read(&mut chunk) {
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                r => break r?,
            }
        };
        if n == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "the compositor closed the connection"));
        }
        self.buf.extend_from_slice(&chunk[..n]);
        while self.buf.len() >= 8 {
            let obj = u32::from_le_bytes(self.buf[0..4].try_into().unwrap());
            let so = u32::from_le_bytes(self.buf[4..8].try_into().unwrap());
            let (size, op) = ((so >> 16) as usize, (so & 0xffff) as u16);
            if size < 8 {
                return Err(bad(format!("a wayland message of {size} bytes")));
            }
            if self.buf.len() < size {
                break;
            }
            let args: Vec<u8> = self.buf.drain(..size).skip(8).collect();
            self.event(obj, op, &args)?;
        }
        Ok(())
    }

    fn event(&mut self, obj: u32, op: u16, a: &[u8]) -> io::Result<()> {
        let u = |i: usize| a.get(i * 4..i * 4 + 4).map(|b| u32::from_le_bytes(b.try_into().unwrap()));
        match (obj, op) {
            (DISPLAY, 0) => {
                // wl_display.error(object, code, message)
                let msg = string_at(a, 8).0;
                return Err(bad(format!("wayland error {} on object {}: {msg}", u(1).unwrap_or(0), u(0).unwrap_or(0))));
            }
            (REGISTRY, 0) => {
                // global(name, interface, version)
                let Some(name) = u(0) else { return Ok(()) };
                let (iface, at) = string_at(a, 4);
                let version = a.get(at..at + 4).map_or(1, |b| u32::from_le_bytes(b.try_into().unwrap()));
                if iface == "wl_output" {
                    let o = self.bind(name, "wl_output", version.clamp(1, OUTPUT_VERSION))?;
                    self.outputs.insert(name, Output { obj: o, ..Output::default() });
                    self.watch(name)?;
                } else if iface == DPMS_MANAGER && self.manager.is_none() {
                    self.manager = Some(self.bind(name, DPMS_MANAGER, 1)?);
                    for n in self.outputs.keys().copied().collect::<Vec<_>>() {
                        self.watch(n)?;
                    }
                }
            }
            (REGISTRY, 1) => {
                // global_remove(name): an output gone no longer counts (its objects are left to the compositor)
                if let Some(name) = u(0) {
                    self.outputs.remove(&name);
                }
            }
            _ => {
                if let Some(o) = self.outputs.values_mut().find(|o| o.dpms == Some(obj)) {
                    match op {
                        1 => o.pending = u(0),            // mode
                        2 => o.mode = o.pending.or(o.mode), // done
                        _ => {}                           // supported
                    }
                } else if let Some(o) = self.outputs.values_mut().find(|o| o.obj == obj) {
                    if op == 4 {
                        o.name = Some(string_at(a, 0).0); // wl_output.name (geometry, mode, done, scale: nothing to do)
                    }
                } else if op == 0 && obj > REGISTRY {
                    self.synced = Some(obj); // wl_callback.done (delete_id: nothing to do)
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn global(name: u32, iface: &str, version: u32) -> Vec<u8> {
        let mut a = name.to_le_bytes().to_vec();
        a.extend(string_arg(iface));
        a.extend_from_slice(&version.to_le_bytes());
        message(REGISTRY, 0, &a)
    }

    /// Reads the client's requests off the server end: (object, opcode, args).
    fn requests(srv: &mut UnixStream) -> Vec<(u32, u16, Vec<u8>)> {
        srv.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
        let mut all = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            match srv.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => all.extend_from_slice(&chunk[..n]),
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => break, // the timeout: all read
            }
        }
        let mut out = Vec::new();
        while all.len() >= 8 {
            let obj = u32::from_le_bytes(all[0..4].try_into().unwrap());
            let so = u32::from_le_bytes(all[4..8].try_into().unwrap());
            let size = (so >> 16) as usize;
            out.push((obj, (so & 0xffff) as u16, all[8..size].to_vec()));
            all.drain(..size);
        }
        out
    }

    #[test]
    fn binds_and_follows_the_screen() {
        let (c, mut srv) = UnixStream::pair().unwrap();
        let mut wl = Wl::new(c).unwrap();
        // KWin's globals on the tablet (11-03): the manager comes before the output
        srv.write_all(&[global(28, DPMS_MANAGER, 1), global(31, "zxdg_output_manager_v1", 3), global(64, "wl_output", 4)].concat()).unwrap();
        wl.read().unwrap();
        let reqs = requests(&mut srv);
        assert_eq!(reqs[0], (DISPLAY, 1, 2u32.to_le_bytes().to_vec())); // get_registry
        let le = |b: &[u8]| u32::from_le_bytes(b.try_into().unwrap());
        // global name, version, new id (ids from 3)
        let binds: Vec<_> = reqs.iter().filter(|r| r.0 == REGISTRY).map(|r| (le(&r.2[0..4]), le(&r.2[r.2.len() - 8..r.2.len() - 4]), le(&r.2[r.2.len() - 4..]))).collect();
        assert_eq!(binds, [(28, 1, 3), (64, 4, 4)]);
        let get = reqs.iter().find(|r| r.0 == 3).unwrap(); // manager.get(new dpms 5, output 4)
        assert_eq!((get.1, get.2.clone()), (0, [5u32.to_le_bytes(), 4u32.to_le_bytes()].concat()));
        assert!(wl.screen_on()); // nothing known yet
        let mode = |m: u32| message(5, 1, &m.to_le_bytes());
        srv.write_all(&[message(5, 0, &1u32.to_le_bytes()), mode(3), message(5, 2, &[])].concat()).unwrap();
        wl.read().unwrap();
        assert!(!wl.screen_on());
        srv.write_all(&mode(0)).unwrap(); // not committed until done
        wl.read().unwrap();
        assert!(!wl.screen_on());
        srv.write_all(&message(5, 2, &[])).unwrap();
        wl.read().unwrap();
        assert!(wl.screen_on());
        // a second output (an old KWin: version 3, no names) that is off does not make the screen off; the first one
        // going away does
        srv.write_all(&global(70, "wl_output", 3)).unwrap();
        wl.read().unwrap();
        let reqs = requests(&mut srv);
        assert!(reqs.iter().any(|r| r.0 == REGISTRY && le(&r.2[r.2.len() - 8..r.2.len() - 4]) == 3));
        assert!(reqs.iter().any(|r| r.0 == 3 && r.2 == [7u32.to_le_bytes(), 6u32.to_le_bytes()].concat()));
        srv.write_all(&[message(7, 1, &3u32.to_le_bytes()), message(7, 2, &[])].concat()).unwrap();
        wl.read().unwrap();
        assert!(wl.screen_on());
        srv.write_all(&message(REGISTRY, 1, &64u32.to_le_bytes())).unwrap();
        wl.read().unwrap();
        assert!(!wl.screen_on());
        // a message split across reads is put together (the second output's dpms object is 7)
        let m = [message(7, 1, &0u32.to_le_bytes()), message(7, 2, &[])].concat();
        srv.write_all(&m[..6]).unwrap();
        wl.read().unwrap();
        assert!(!wl.screen_on());
        srv.write_all(&m[6..]).unwrap();
        wl.read().unwrap();
        assert!(wl.screen_on());
    }

    #[test]
    fn the_panel_counts_alone_once_named() {
        let (c, mut srv) = UnixStream::pair().unwrap();
        let mut wl = Wl::new(c).unwrap();
        // manager 3, the panel (output 4, dpms 5) and an external screen (output 6, dpms 7): KWin's order, so the ids are
        // known (outputs that came before the manager are watched in hash order)
        srv.write_all(&[global(28, DPMS_MANAGER, 1), global(64, "wl_output", 4), global(65, "wl_output", 4)].concat()).unwrap();
        wl.read().unwrap();
        let reqs = requests(&mut srv);
        assert!(reqs.iter().any(|r| r.0 == 3 && r.2 == [5u32.to_le_bytes(), 4u32.to_le_bytes()].concat()));
        assert!(reqs.iter().any(|r| r.0 == 3 && r.2 == [7u32.to_le_bytes(), 6u32.to_le_bytes()].concat()));
        let on = |dpms: u32, m: u32| [message(dpms, 1, &m.to_le_bytes()), message(dpms, 2, &[])].concat();
        srv.write_all(&[on(5, 3), on(7, 0)].concat()).unwrap();
        wl.read().unwrap();
        assert!(wl.screen_on()); // no names yet: any output that is on
        srv.write_all(&[message(4, 4, &string_arg("DSI-1")), message(6, 4, &string_arg("DP-1")), message(4, 2, &[])].concat()).unwrap();
        wl.read().unwrap();
        assert!(!wl.screen_on()); // the panel is off
        let mut names: Vec<_> = wl.outputs().into_iter().map(|o| o.0.unwrap()).collect();
        names.sort();
        assert_eq!(names, ["DP-1", "DSI-1"]);
        srv.write_all(&on(5, 0)).unwrap();
        wl.read().unwrap();
        assert!(wl.screen_on());
        srv.write_all(&on(7, 3)).unwrap();
        wl.read().unwrap();
        assert!(wl.screen_on());
    }

    #[test]
    fn roundtrip_and_errors() {
        let (c, mut srv) = UnixStream::pair().unwrap();
        let mut wl = Wl::new(c).unwrap();
        // the sync's callback (id 3) fires after the globals; no manager among them
        srv.write_all(&[global(64, "wl_output", 4), message(3, 0, &9u32.to_le_bytes())].concat()).unwrap();
        wl.roundtrip().unwrap();
        assert!(wl.manager.is_none());
        let mut err = 4u32.to_le_bytes().to_vec();
        err.extend_from_slice(&1u32.to_le_bytes());
        err.extend(string_arg("invalid method"));
        srv.write_all(&message(DISPLAY, 0, &err)).unwrap();
        assert_eq!(wl.read().err().unwrap().to_string(), "wayland error 1 on object 4: invalid method");
        requests(&mut srv); // closed with our requests unread, the socket would say ECONNRESET instead
        drop(srv);
        assert_eq!(wl.read().err().unwrap().kind(), io::ErrorKind::UnexpectedEof);
    }
}
