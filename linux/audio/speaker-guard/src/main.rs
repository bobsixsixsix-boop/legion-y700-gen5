// y700-speaker-guard: keep the speakers behind their protection.
//
// The upstream platform package opens the amplifiers up (aw_dev_*_volume 21 instead of the safe 159) while PipeWire
// runs, on the assumption that everything reaching the speakers goes through the protecting filter chain
// (effect_input.speakers: high-pass, compressor, RMS limit, limiter). Three things break that assumption and nothing
// upstream catches them:
//   1. a user or an app picks "Speakers (raw, unprotected)" (the ALSA sink) as the default output;
//   2. an app sends its own stream straight to that raw sink (per-app output choice, pactl move-sink-input): the
//      default output stays right, the protection node exists, and the stream still bypasses it;
//   3. the filter-chain node dies while PipeWire keeps running.
// The check (user service, a few pactl / pw-metadata calls) puts the default output back on the tuned sink, moves
// bypassing streams onto it, and keeps the amplifier gain conditional on the whole picture: protection node present,
// hardware sink present, no bypassing stream. While any of that is false the amplifiers sit at the safe attenuation
// (upstream helper), and they are only raised again once the raise command succeeded. It also hands the output to
// headphones (Bluetooth, USB) when they connect and back to the tuned sink when they go (2026-10-19).
//
// When it runs: on every sink / sink-input / server event (default output changed, a stream appeared or moved, a sink
// appeared, vanished or changed volume), once the events have been quiet for 0.3 s (at most 2 s of draining, so a
// volume drag still gets a check every 2 s); otherwise every 10 min while everything is in order and every 2 s while
// it is not (protection or hardware sink missing, gain held down), which keeps the "~10 s without the hardware sink ->
// repair" timing below. Without the event connection (pipewire-pulse restarting) the 2 s poll covers the gap.
//
// Rust port (2026-11-03) of the bash service (last bash version: git 05ebb3c, linux/audio/y700-speaker-guard; README
// "扬声器守护"). Checks, log lines and notifications are the same; deliberate differences are marked RUST:. Where the
// bash version's CPU went (11-03, screen off: 0.185 % of a core, 26 forks a minute): the 30 s "all is well" check -
// pw-cli ls Node (a dump of the whole registry), pw-metadata, five pactl clients and ~20 grep/awk/cut forks - and
// `pactl subscribe` handing the shell a line for every one of those pactl clients connecting and leaving. Here the
// events come from a native-protocol client subscribed to sink, sink-input and server events only, so our own pactl
// calls no longer wake us; a check is three commands; and the check without an event runs every 10 min, not 30 s.

use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const PROT: &str = "effect_input.speakers"; // upstream protection chain (what the amplifier gain is conditional on)
const PROT_OUT: &str = "effect_output.speakers"; // its playback side: the only stream that may feed the hardware sink
const TUNED: &str = "effect_input.y700_lenovo"; // our Lenovo tuning, feeds PROT; the default output users should see
const HW: &str = "alsa_output.platform-sound.HiFi__Speaker__sink";
const GAIN: &str = "/usr/libexec/tb323fu/tb323fu-speaker-gain";
const KEY: &str = "default.configured.audio.sink";
const HEARTBEAT_MS: u64 = 600_000; // RUST: the check without an event while all is well (bash: 30 s)
const RETRY_MS: u64 = 2000;

fn say(msg: &str) {
    eprintln!("{msg}");
    #[cfg(test)]
    tests::LOGGED.with(|l| l.borrow_mut().push(msg.to_string()));
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

// ---- reading pactl / pw-metadata / pw-cli output (LC_ALL=C: pactl translates its headings)

#[derive(Debug, Default)]
struct Sink {
    index: String,
    name: String,
    desc: String,
    vol: Option<u32>, // the first channel's volume in %
}

fn first_percent(s: &str) -> Option<u32> {
    s.split_whitespace().find_map(|w| w.strip_suffix('%')?.parse().ok())
}

/// `pactl list sinks`
fn parse_sinks(text: &str) -> Vec<Sink> {
    let mut v: Vec<Sink> = Vec::new();
    for line in text.lines() {
        if let Some(i) = line.strip_prefix("Sink #") {
            v.push(Sink { index: i.trim().to_string(), ..Default::default() });
            continue;
        }
        let (Some(s), t) = (v.last_mut(), line.trim_start()) else { continue };
        if let Some(n) = t.strip_prefix("Name: ") {
            s.name = n.to_string();
        } else if let Some(d) = t.strip_prefix("Description: ") {
            s.desc = d.to_string();
        } else if let Some(r) = t.strip_prefix("Volume: ") {
            s.vol = s.vol.or(first_percent(r));
        }
    }
    v
}

/// `pactl list sink-inputs`: the streams on sink #`hw` other than the protection chain's own output (a stream without
/// node.name counts as bypassing, as in the shell)
fn streams_on(text: &str, hw: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur: Option<(String, String, String)> = None; // id, sink, node.name
    let flush = |c: Option<(String, String, String)>, out: &mut Vec<String>| {
        if let Some((id, sink, name)) = c {
            if sink == hw && name != PROT_OUT {
                out.push(id);
            }
        }
    };
    for line in text.lines() {
        if let Some(id) = line.strip_prefix("Sink Input #") {
            flush(cur.take(), &mut out);
            cur = Some((id.trim().to_string(), String::new(), String::new()));
            continue;
        }
        let (Some(c), t) = (cur.as_mut(), line.trim_start()) else { continue };
        if let Some(s) = t.strip_prefix("Sink: ") {
            c.1 = s.trim().to_string();
        } else if let Some(n) = t.strip_prefix("node.name = ") {
            c.2 = n.trim().trim_matches('"').to_string();
        }
    }
    flush(cur, &mut out);
    out
}

/// `pw-metadata 0 default.configured.audio.sink`: the configured default ("" when unset). None when one read printed
/// two different names: around boot the key can come several times while it is being changed (README "音量键", 10-23).
/// The shell then matched none of its cases and left the default alone that round; the same name repeated is one name.
fn configured(text: &str) -> Option<String> {
    let mut names = text.split("\"name\":\"").skip(1).map(|r| r.split('"').next().unwrap_or(""));
    let first = names.next().unwrap_or("");
    names.all(|n| n == first).then(|| first.to_string())
}

/// `pw-cli ls Device`: the id of the sound card's device
fn card_id(text: &str) -> Option<String> {
    let mut id = None;
    for line in text.lines() {
        if let Some(r) = line.strip_prefix("\tid ") {
            id = r.split(',').next().map(|s| s.trim().to_string());
        } else if line.contains("device.name = \"alsa_card.platform-sound\"") {
            return id.filter(|s| !s.is_empty());
        }
    }
    None
}

// ---- the check

trait Sys {
    /// exit status and stdout of a command (stderr dropped, like the shell's 2>/dev/null)
    fn run(&mut self, argv: &[&str]) -> (bool, String);
    /// the card's playback PCM exists (no hardware sink then means broken routing, not a missing card)
    fn pcm_present(&mut self) -> bool;
    /// seconds since the guard started (the shell's SECONDS)
    fn now(&mut self) -> i64;
}

struct Real(Instant);

impl Sys for Real {
    fn run(&mut self, argv: &[&str]) -> (bool, String) {
        // std resets the signal mask (TERM/INT are blocked here for the signalfd) and SIGPIPE in the child
        match Command::new(argv[0]).args(&argv[1..]).env("LC_ALL", "C").stdin(Stdio::null()).stderr(Stdio::null()).output() {
            Ok(o) => (o.status.success(), String::from_utf8_lossy(&o.stdout).into_owned()),
            Err(_) => (false, String::new()),
        }
    }
    fn pcm_present(&mut self) -> bool {
        Path::new("/proc/asound/card0/pcm0p").exists()
    }
    fn now(&mut self) -> i64 {
        self.0.elapsed().as_secs() as i64
    }
}

struct Guard<S: Sys> {
    sys: S,
    gain_on: bool, // what we believe the amplifiers are at (upstream unit raised them at start)
    nohw: i64,
    kded_fixed: i64,       // seconds of the last kded6 restart (volume keys on a fixed stage)
    ext_prev: Vec<String>, // headphone sinks (Bluetooth, USB) seen at the previous check
    healthy: bool,
}

impl<S: Sys> Guard<S> {
    fn new(sys: S) -> Self {
        Guard { sys, gain_on: true, nohw: 0, kded_fixed: -600, ext_prev: Vec::new(), healthy: false }
    }

    fn set_default(&mut self, sink: &str) {
        let v = format!("{{\"name\":\"{sink}\"}}");
        self.sys.run(&["pw-metadata", "0", KEY, v.as_str()]);
    }

    fn notify(&mut self, icon: &str, title: &str, body: &str) {
        self.sys.run(&["notify-send", "-a", "Y700", "-i", icon, title, body]);
    }

    /// only remember a state the helper confirmed; a failed command is retried next round
    fn set_gain(&mut self, on: bool) {
        if self.gain_on != on && self.sys.run(&[GAIN, if on { "on" } else { "off" }]).0 {
            self.gain_on = on;
        }
    }

    fn raw_streams(&mut self, hw: &str) -> Vec<String> {
        streams_on(&self.sys.run(&["pactl", "list", "sink-inputs"]).1, hw)
    }

    fn check(&mut self) {
        let (ok, text) = self.sys.run(&["pactl", "list", "sinks"]);
        if !ok {
            // RUST: no sink list (pipewire-pulse restarting): nothing to decide from, everything stays as it is and the
            // next look is in 2 s. The shell went on with empty lists, which also moved the output off a connected
            // headset ("output gone").
            self.healthy = false;
            return;
        }
        // RUST: which of the three nodes exist comes from this list, not `pw-cli ls Node`: they are all sinks, and the
        // list is needed anyway (headphones, volumes), while pw-cli dumped the whole registry every check
        let sinks = parse_sinks(&text);
        let find = |n: &str| sinks.iter().find(|s| s.name == n);
        let (have_prot, have_hw, have_tuned) = (find(PROT).is_some(), find(HW).is_some(), find(TUNED).is_some());
        let cfg = configured(&self.sys.run(&["pw-metadata", "0", KEY]).1);
        match cfg.as_deref() {
            Some(c) if c.ends_with("HiFi__Speaker__sink") || c.starts_with("effect_input.speaker_plus") => {
                self.set_default(TUNED);
                self.notify(
                    "audio-speakers",
                    "扬声器输出已切回“联想调音”",
                    "“Speakers (raw, unprotected)”绕过扬声器保护，功放会过载；它只用于调试。",
                );
            }
            // after a PipeWire restart WirePlumber lands on the upstream "Speakers" (or nothing): put the tuned sink
            // back once its node exists (it chains into the protection, so nothing is lost)
            Some(c) if (c.is_empty() || c == PROT) && have_tuned => self.set_default(TUNED),
            _ => {}
        }
        // Headphones (Bluetooth, USB audio) take the output when they connect and give it back when they go, like a
        // phone (2026-10-19, a Bluetooth headset connected, sound still on the speakers). Nothing else did it: the
        // configured default stays on the tuned sink (above; WirePlumber keeps it while that sink exists), our two
        // speaker stages have priority.session 1400/1500 against a Bluetooth sink's 1010, and pipewire-pulse's
        // module-switch-on-connect is not loaded. Edge-triggered: only a sink that was not there at the previous check
        // (or at guard start) is switched to, so choosing the speakers while the headset stays connected sticks. When
        // the chosen headset goes, the output goes back to another connected one, else the tuned sink - not to
        // whatever WirePlumber's history holds (the upstream "Speakers" stage, or a sink that is not there).
        let is_ext = |n: &str| n.starts_with("bluez_output.") || n.starts_with("alsa_output.usb-");
        let ext: Vec<String> = sinks.iter().filter(|s| is_ext(&s.name)).map(|s| s.name.clone()).collect();
        if let Some(new) = ext.iter().rev().find(|s| !self.ext_prev.contains(s)) {
            self.set_default(new);
            let desc = find(new).map(|s| s.desc.as_str()).filter(|d| !d.is_empty()).unwrap_or(new);
            say(&format!("output connected: {new} is now the default"));
            self.notify("audio-headphones", &format!("声音已切到“{desc}”"), "断开后自动回到扬声器（联想调音）。");
        } else if let Some(c) = cfg.as_deref().filter(|c| is_ext(c) && !ext.iter().any(|e| e == c)) {
            if let Some(back) = ext.last().map(String::as_str).or(have_tuned.then_some(TUNED)) {
                self.set_default(back);
                say(&format!("output gone: {c}, default back to {back}"));
            }
        }
        self.ext_prev = ext;
        // streams feeding the raw hardware sink directly: everything on it except the protection chain's own output is
        // moved to the tuned sink. The amplifiers only go down for a stream that is STILL on the raw sink after the
        // move (one that refused it, e.g. asked not to be moved): lowering them after a successful move protected
        // nothing - the stream was already safe - and was an unramped 13 dB gain step (POPS.md, a pop candidate).
        // Measured 2026-10-17 (bypass-test.sh): moved 0.26 s after it appeared.
        let mut bypass = Vec::new();
        if let Some(hw) = find(HW) {
            bypass = self.raw_streams(&hw.index);
            if !bypass.is_empty() {
                for id in &bypass {
                    self.sys.run(&["pactl", "move-sink-input", id.as_str(), TUNED]);
                }
                bypass = self.raw_streams(&hw.index); // what is left: only these keep the amplifiers down
                let body = if bypass.is_empty() {
                    "已把它移到“联想调音”。"
                } else {
                    "它不让移动，功放降到安全档，直到它停止。"
                };
                self.notify("audio-speakers", "一个应用的声音绕过了扬声器保护", body);
            }
        }
        // the hardware sink itself gone (card still there)? Seen 2026-10-13 after a PipeWire restart: WirePlumber's
        // UCM disable turned the DSP routes off, the re-open failed with EINVAL, it fell back to the "pro-audio"
        // profile and saved that choice. Put the mixer defaults back and select the HiFi profile again.
        let now = self.sys.now();
        if !have_hw && self.sys.pcm_present() {
            // time-based, not a round count: events can run several checks a second during a PipeWire restart
            if self.nohw == 0 {
                self.nohw = now.max(1); // 0 means "sink present"
            }
            if now - self.nohw >= 10 {
                // audio-defaults re-initialises the mixer and leaves the amplifiers at the safe 159: that is a new
                // hardware state, so forget the old gain belief and raise it again only once the sink, the protection
                // node and the routing are back (checked below on the following rounds)
                self.sys.run(&["/usr/libexec/tb323fu/tb323fu-audio-defaults", "0"]);
                self.gain_on = false;
                if let Some(card) = card_id(&self.sys.run(&["pw-cli", "ls", "Device"]).1) {
                    self.sys.run(&["wpctl", "set-profile", card.as_str(), "1"]);
                }
                self.notify(
                    "audio-speakers",
                    "扬声器设备已自动恢复",
                    "DSP 路由被关掉、声卡掉到了 Pro Audio 配置；已恢复默认路由并切回 HiFi。",
                );
                self.nohw = 0;
            }
        } else {
            self.nohw = 0;
        }
        // the two fixed stages behind the tuned sink stay at unity: the user's volume is the tuned sink's (control
        // centre / Plasma applet on the default sink). After the 2026-10-13 PipeWire restarts the protection sink sat
        // at 45 % and the hardware sink at 73 %, i.e. -10 dB on top of the chain's own curve, and "test sound" on the
        // tuned sink was inaudible while raw was loud.
        // Not the stage that IS the default output: with the tuned sink missing (y700-lenovo-tuning failing and
        // restarting, the case above that leaves the default on PROT) that stage carries the user's volume, and pinning
        // it locked the volume keys and the control centre at 100 % - without the tuning's attenuation (2026-10-31
        // audit). Looked up only when a stage is off 100 %: no extra pactl on every event.
        // RUST: the volumes are the sink list's from the start of the check (the shell asked get-sink-volume here):
        // nothing in between changes them, and a change after it is an event that runs the next check.
        let mut moved = String::new();
        let mut def: Option<String> = None;
        for fixed in [PROT, HW] {
            let Some(v) = find(fixed).and_then(|s| s.vol) else { continue };
            if v == 100 {
                continue;
            }
            let d = def.get_or_insert_with(|| self.sys.run(&["pactl", "get-default-sink"]).1.trim_end().to_string());
            if d.as_str() == fixed {
                continue;
            }
            self.sys.run(&["pactl", "set-sink-volume", fixed, "100%"]);
            moved += &format!(" {fixed}={v}%");
        }
        // A fixed stage moved while the whole chain is up and the tuned sink is the default: some volume control is
        // bound to that stage instead of the user's volume. The one seen three times is the volume keys (kded6's
        // audioshortcutsservice latched onto the boot-time default, 2026-10-17: the keys moved "Speakers" 100->95->100
        // all night, the tuned sink never moved). A fresh kded6 binds to the current default; at most every 10 min (a
        // PipeWire restart also leaves the stages off 100 % - the same restart then just refreshes kded6's view).
        // The log line is what y700-checklist counts ("restarting plasma-kded6").
        if !moved.is_empty()
            && have_prot
            && have_hw
            && now - self.kded_fixed >= 600
            && self.sys.run(&["pactl", "get-default-sink"]).1.trim_end() == TUNED
            && self.sys.run(&["systemctl", "--user", "is-active", "--quiet", "plasma-kded6.service"]).0
        {
            self.kded_fixed = now;
            say(&format!("fixed stage moved ({moved}): restarting plasma-kded6 so the volume keys bind to {TUNED}"));
            self.sys.run(&["systemctl", "--user", "restart", "plasma-kded6.service"]);
        }
        // amplifier gain: up only while the protection node and the hardware sink exist and nothing bypasses them
        let safe = have_prot && have_hw && bypass.is_empty();
        self.set_gain(safe);
        // in order = gain confirmed up and nothing was moved: only then may the next check wait for events.
        // RUST: and the configured default was readable (two names at once: look again in 2 s, not in 10 min)
        self.healthy = self.gain_on && safe && cfg.is_some();
    }
}

// ---- the events: a minimal PulseAudio native-protocol client (pipewire-pulse speaks it), doing what `pactl subscribe`
// does and nothing else: AUTH, SET_CLIENT_NAME, SUBSCRIBE, then SUBSCRIBE_EVENT packets. Wire format (libpulse
// pstream.c / tagstruct.c; checked with strace against pactl on the tablet, 11-03): a header of five big-endian u32
// (payload length, channel = -1 for commands, offset high/low, flags) and a tagstruct payload in which every value
// follows a type byte ('L' u32, 't' NUL-terminated string, 'x' u32 length + bytes, 'P' property list ... 'N').
// Protocol 35 without the shm/memfd flags: no shared memory, and no streams.

const CMD_ERROR: u32 = 0;
const CMD_REPLY: u32 = 2;
const CMD_AUTH: u32 = 8;
const CMD_SET_CLIENT_NAME: u32 = 9;
const CMD_SUBSCRIBE: u32 = 35;
const CMD_SUBSCRIBE_EVENT: u32 = 66;
const PROTOCOL: u32 = 35;
/// sink | sink-input | server: what the shell reacted to (" on sink #", " on sink-input #", " on server"). Client
/// events, one pair per pactl call (ours included), are not subscribed to at all.
const MASK: u32 = 0x0001 | 0x0004 | 0x0080;
const MAX_PACKET: usize = 1 << 20;

fn put_u32(b: &mut Vec<u8>, v: u32) {
    b.push(b'L');
    b.extend_from_slice(&v.to_be_bytes());
}

fn put_bytes(b: &mut Vec<u8>, d: &[u8]) {
    b.push(b'x');
    b.extend_from_slice(&(d.len() as u32).to_be_bytes());
    b.extend_from_slice(d);
}

fn packet(cmd: u32, tag: u32, args: impl FnOnce(&mut Vec<u8>)) -> Vec<u8> {
    let mut p = Vec::new();
    put_u32(&mut p, cmd);
    put_u32(&mut p, tag);
    args(&mut p);
    let mut out = Vec::with_capacity(20 + p.len());
    for v in [p.len() as u32, u32::MAX, 0, 0, 0] {
        out.extend_from_slice(&v.to_be_bytes());
    }
    out.extend(p);
    out
}

/// the first `n` values of a payload when they are all u32
fn u32s(p: &[u8], n: usize) -> Option<Vec<u32>> {
    (0..n)
        .map(|i| match p.get(i * 5..i * 5 + 5)? {
            [b'L', a, b, c, d] => Some(u32::from_be_bytes([*a, *b, *c, *d])),
            _ => None,
        })
        .collect()
}

struct Pulse {
    sock: UnixStream,
    buf: Vec<u8>,
}

impl Pulse {
    fn connect() -> io::Result<Pulse> {
        let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
        Pulse::start(UnixStream::connect(format!("{dir}/pulse/native"))?)
    }

    /// the three commands in one write, then their replies (in order: the subscription's is the last)
    fn start(sock: UnixStream) -> io::Result<Pulse> {
        sock.set_read_timeout(Some(Duration::from_secs(5)))?;
        sock.set_write_timeout(Some(Duration::from_secs(5)))?;
        let mut out = packet(CMD_AUTH, 0, |b| {
            put_u32(b, PROTOCOL);
            put_bytes(b, &[0; 256]); // the cookie: pipewire-pulse does not check it (the socket is the user's)
        });
        out.extend(packet(CMD_SET_CLIENT_NAME, 1, |b| {
            let v = b"y700-speaker-guard\0";
            b.extend_from_slice(b"Ptapplication.name\0");
            put_u32(b, v.len() as u32);
            put_bytes(b, v);
            b.push(b'N');
        }));
        out.extend(packet(CMD_SUBSCRIBE, 2, |b| put_u32(b, MASK)));
        let mut p = Pulse { sock, buf: Vec::new() };
        p.sock.write_all(&out)?;
        loop {
            // events arriving in the same read() as the last reply are dropped: a check follows the connect anyway
            for pkt in p.read()? {
                match u32s(&pkt, 3).as_deref().or(u32s(&pkt, 2).as_deref()) {
                    Some([CMD_ERROR, tag, rest @ ..]) => {
                        return Err(bad(&format!("pulse server refused command {tag} (error {rest:?})")))
                    }
                    Some([CMD_REPLY, 2, ..]) => return Ok(p),
                    _ => {}
                }
            }
        }
    }

    /// one read(): the command packets it completed. Data packets (channel != -1, for streams) are dropped: there are
    /// none. EOF, a timeout and an oversized packet are errors: the caller reconnects.
    fn read(&mut self) -> io::Result<Vec<Vec<u8>>> {
        let mut chunk = [0u8; 4096];
        let n = self.sock.read(&mut chunk)?;
        if n == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        self.buf.extend_from_slice(&chunk[..n]);
        let mut out = Vec::new();
        while self.buf.len() >= 20 {
            let word = |i: usize| u32::from_be_bytes([self.buf[i], self.buf[i + 1], self.buf[i + 2], self.buf[i + 3]]);
            let (len, channel) = (word(0) as usize, word(4));
            if len > MAX_PACKET {
                return Err(bad(&format!("pulse packet of {len} bytes")));
            }
            if self.buf.len() < 20 + len {
                break;
            }
            let pkt: Vec<u8> = self.buf.drain(..20 + len).skip(20).collect();
            if channel == u32::MAX {
                out.push(pkt);
            }
        }
        Ok(out)
    }

    /// the sink, sink-input and server events among what one read() completed
    fn events(&mut self) -> io::Result<usize> {
        Ok(self
            .read()?
            .iter()
            .filter(|p| matches!(u32s(p, 3).as_deref(), Some([CMD_SUBSCRIBE_EVENT, _, e]) if [0, 2, 7].contains(&(e & 0xf))))
            .count())
    }
}

/// wait up to `ms` for an event, then let the burst (stream start, volume drag, PipeWire restart) finish: 0.3 s without
/// another one, at most 2 s. false: TERM or INT.
fn wait(sig: i32, pulse: &mut Option<Pulse>, ms: u64) -> bool {
    let deadline = Instant::now() + Duration::from_millis(ms);
    let mut settle: Option<(Instant, Instant)> = None; // (quiet from, at the latest)
    loop {
        let now = Instant::now();
        let until = settle.map_or(deadline, |(q, e)| q.min(e));
        if now >= until {
            return true;
        }
        let timeout = ((until - now).as_micros() + 999) / 1000;
        let mut fds = [
            libc::pollfd { fd: sig, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: pulse.as_ref().map_or(-1, |p| p.sock.as_raw_fd()), events: libc::POLLIN, revents: 0 },
        ];
        if unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout as i32) } < 0 {
            continue;
        }
        if fds[0].revents != 0 {
            return false;
        }
        if fds[1].revents == 0 {
            continue;
        }
        match pulse.as_mut().map(Pulse::events) {
            Some(Ok(0)) | None => {}
            Some(Ok(_)) => {
                let t = Instant::now();
                settle = Some((t + Duration::from_millis(300), settle.map_or(t + Duration::from_secs(2), |s| s.1)));
            }
            Some(Err(e)) => {
                // RUST: logged (the shell restarted its subscriber silently); a check runs now, then every 2 s
                say(&format!("pulse event connection lost ({e}); checking every 2 s until it is back"));
                *pulse = None;
                return true;
            }
        }
    }
}

fn main() {
    // TERM / INT through a signalfd, so poll() can wait 10 min for an event and still stop at once
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
    let mut guard = Guard::new(Real(Instant::now()));
    let mut pulse: Option<Pulse> = None;
    let mut down = false; // logged once per outage
    say("watching the default output, the speaker sinks and their streams"); // RUST: the shell said nothing at start
    loop {
        if pulse.is_none() {
            // subscribe before the check, so nothing between the two is missed
            match Pulse::connect() {
                Ok(p) => {
                    if down {
                        say("pulse event connection back");
                    }
                    (pulse, down) = (Some(p), false);
                }
                Err(e) => {
                    if !down {
                        say(&format!("no pulse event connection ({e}); checking every 2 s until there is one"));
                    }
                    down = true;
                }
            }
        }
        guard.check();
        let ms = if guard.healthy && pulse.is_some() { HEARTBEAT_MS } else { RETRY_MS };
        if !wait(sig, &mut pulse, ms) {
            break;
        }
        down |= pulse.is_none(); // lost in wait(), which said so
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::sync::mpsc;

    thread_local! {
        pub static LOGGED: RefCell<Vec<String>> = RefCell::new(Vec::new());
    }

    const L: &str = TUNED;
    const P: &str = PROT;
    const H: &str = HW;
    const O: &str = PROT_OUT;
    const B: &str = "bluez_output.test_headset.1";
    const U: &str = "alsa_output.usb-test_dac";

    /// the fakes of the shell test bed (linux/audio/test-speaker-guard.sh, 10-31): sinks (index = position + 100), the
    /// configured and the current default (it follows the configured one when that sink exists, as WirePlumber does),
    /// volumes (100 when not set), streams (id, sink, node.name, movable), and every command that is not a read
    #[derive(Default)]
    struct Fake {
        sinks: Vec<String>,
        cfg: String,
        default: String,
        vol: HashMap<String, u32>,
        inputs: Vec<(String, String, String, bool)>,
        log: Vec<String>,
        runs: usize,
        pcm: bool,
        now: i64,
        pactl_down: bool,
        gain_fails: bool,
        changing_from: String, // printed before the configured default by a read (the key being changed)
    }

    fn fake(sinks: &[&str], cfg: &str, default: &str) -> Fake {
        LOGGED.with(|l| l.borrow_mut().clear());
        Fake { sinks: sinks.iter().map(|s| s.to_string()).collect(), cfg: cfg.into(), default: default.into(), ..Default::default() }
    }

    impl Fake {
        fn index(&self, name: &str) -> String {
            self.sinks.iter().position(|s| s == name).map_or("-".into(), |i| (i + 100).to_string())
        }
        fn volume(&self, name: &str) -> u32 {
            *self.vol.get(name).unwrap_or(&100)
        }
        fn on(&self, id: &str) -> &str {
            &self.inputs.iter().find(|i| i.0 == id).unwrap().1
        }
    }

    impl Sys for Fake {
        fn run(&mut self, argv: &[&str]) -> (bool, String) {
            self.runs += 1;
            let ok = |s: String| (true, s);
            match argv {
                ["pactl", ..] if self.pactl_down => (false, String::new()),
                ["pactl", "list", "sinks"] => ok(self
                    .sinks
                    .iter()
                    .map(|n| {
                        let v = self.volume(n);
                        format!(
                            "Sink #{}\n\tState: SUSPENDED\n\tName: {n}\n\tDescription: Fake {n}\n\tVolume: front-left: 1 /  {v}% / \
                             0.00 dB,   front-right: 1 /  {v}% / 0.00 dB\n\t        balance 0.00\n\tBase Volume: 65536 / 100% / 0.00 dB\n",
                            self.index(n)
                        )
                    })
                    .collect()),
                ["pactl", "list", "sink-inputs"] => ok(self
                    .inputs
                    .iter()
                    .map(|(id, sink, name, _)| {
                        format!("Sink Input #{id}\n\tDriver: PipeWire\n\tSink: {}\n\tProperties:\n\t\tnode.name = \"{name}\"\n", self.index(sink))
                    })
                    .collect()),
                ["pactl", "get-default-sink"] => ok(format!("{}\n", self.default)),
                ["pactl", "set-sink-volume", s, v] => {
                    self.log.push(argv.join(" "));
                    self.vol.insert(s.to_string(), v.trim_end_matches('%').parse().unwrap());
                    ok(String::new())
                }
                ["pactl", "move-sink-input", id, s] => {
                    self.log.push(argv.join(" "));
                    let exists = self.sinks.iter().any(|n| n == s);
                    match self.inputs.iter_mut().find(|i| i.0 == *id) {
                        Some(i) if exists && i.3 => {
                            i.1 = s.to_string();
                            ok(String::new())
                        }
                        _ => (false, String::new()),
                    }
                }
                ["pw-metadata", "0", KEY] => ok([self.changing_from.as_str(), self.cfg.as_str()]
                    .iter()
                    .filter(|n| !n.is_empty())
                    .fold("Found \"default\" metadata 44\n".to_string(), |s, n| {
                        s + &format!("update: id:0 key:'{KEY}' value:'{{\"name\":\"{n}\"}}' type:'Spa:String:JSON'\n")
                    })),
                ["pw-metadata", "0", KEY, v] => {
                    self.cfg = configured(v).unwrap();
                    self.log.push(format!("metadata {}", self.cfg));
                    if self.sinks.contains(&self.cfg) {
                        self.default = self.cfg.clone();
                    }
                    ok(String::new())
                }
                [GAIN, x] => {
                    self.log.push(format!("gain {x}"));
                    (!self.gain_fails, String::new())
                }
                ["pw-cli", "ls", "Device"] => ok(include_str!("../fixtures/sg-devices.txt").into()),
                _ => {
                    // notify-send, systemctl, wpctl, audio-defaults
                    self.log.push(argv.join(" "));
                    ok(String::new())
                }
            }
        }
        fn pcm_present(&mut self) -> bool {
            self.pcm
        }
        fn now(&mut self) -> i64 {
            self.now
        }
    }

    fn checked(f: Fake) -> Guard<Fake> {
        let mut g = Guard::new(f);
        g.check();
        g
    }

    fn logged(g: &Guard<Fake>, prefix: &str) -> usize {
        g.sys.log.iter().filter(|l| l.starts_with(prefix)).count()
    }

    fn said() -> Vec<String> {
        LOGGED.with(|l| l.borrow().clone())
    }

    // ---- the shell test bed's eleven checks, same order

    /// A2: the tuning sink is not there (y700-lenovo-tuning failing): the default sits on the protection stage, which
    /// then carries the user's volume - the old guard pinned it back to 100 % on every volume key press
    #[test]
    fn tuned_sink_missing() {
        let mut f = fake(&[P, H], P, P);
        f.vol.insert(P.into(), 40);
        f.vol.insert(H.into(), 73);
        let g = checked(f);
        assert_eq!(g.sys.volume(P), 40, "the default stage keeps the user's 40 %");
        assert_eq!(g.sys.volume(H), 100, "the hardware stage is still pinned");
        assert_eq!(logged(&g, "systemctl --user restart plasma-kded6"), 0, "kded6 is not restarted");
    }

    /// whole chain up, the volume keys moved the fixed stage (10-17): pinned back and kded6 restarted
    #[test]
    fn chain_up_fixed_stage_moved() {
        let mut f = fake(&[L, P, H], L, L);
        f.vol.insert(P.into(), 95);
        let g = checked(f);
        assert_eq!(g.sys.volume(P), 100);
        assert_eq!(logged(&g, "systemctl --user restart plasma-kded6.service"), 1);
        assert_eq!(
            said(),
            ["fixed stage moved ( effect_input.speakers=95%): restarting plasma-kded6 so the volume keys bind to effect_input.y700_lenovo"]
        );
    }

    /// raw sink chosen as the default output: back to the tuned sink, with a notification
    #[test]
    fn raw_chosen() {
        let g = checked(fake(&[L, P, H], H, H));
        assert_eq!(g.sys.cfg, L);
        assert_eq!(logged(&g, "notify-send -a Y700 -i audio-speakers 扬声器输出已切回“联想调音”"), 1);
    }

    /// after a PipeWire restart WirePlumber lands on the upstream Speakers stage: tuned sink put back
    #[test]
    fn speakers_after_a_restart() {
        assert_eq!(checked(fake(&[L, P, H], P, P)).sys.cfg, L);
        assert_eq!(checked(fake(&[L, P, H], "", P)).sys.cfg, L);
        assert_eq!(checked(fake(&[P, H], "", P)).sys.cfg, "", "no tuned sink: left alone");
    }

    /// a stream straight on the raw sink is moved; the protection chain's own output stays; the gain stays up
    #[test]
    fn bypass_moved() {
        let mut f = fake(&[L, P, H], L, L);
        f.inputs = vec![("3".into(), H.into(), O.into(), false), ("7".into(), H.into(), "app".into(), true)];
        let g = checked(f);
        assert_eq!((g.sys.on("7"), g.sys.on("3")), (L, H));
        assert_eq!(logged(&g, "gain"), 0);
        assert_eq!(logged(&g, "notify-send -a Y700 -i audio-speakers 一个应用的声音绕过了扬声器保护 已把它移到“联想调音”。"), 1);
        assert!(g.healthy);
    }

    /// a stream that refuses the move keeps the amplifiers at the safe attenuation
    #[test]
    fn bypass_refusing_the_move() {
        let mut f = fake(&[L, P, H], L, L);
        f.inputs = vec![("7".into(), H.into(), "pinned".into(), false)];
        let g = checked(f);
        assert_eq!(logged(&g, "gain off"), 1);
        assert_eq!(logged(&g, "notify-send -a Y700 -i audio-speakers 一个应用的声音绕过了扬声器保护 它不让移动"), 1);
        assert!(!g.healthy);
    }

    /// protection chain node gone: gain off
    #[test]
    fn protection_node_missing() {
        let g = checked(fake(&[L, H], L, L));
        assert_eq!(logged(&g, "gain off"), 1);
        assert!(!g.healthy);
    }

    /// headphones present at the guard's start count as new: they become the default
    #[test]
    fn headphones_at_start() {
        let g = checked(fake(&[L, P, H, B], L, L));
        assert_eq!(g.sys.cfg, B);
        assert_eq!(said(), [format!("output connected: {B} is now the default")]);
        assert_eq!(logged(&g, &format!("notify-send -a Y700 -i audio-headphones 声音已切到“Fake {B}”")), 1);
    }

    // ---- added with the port

    /// all in order: three commands, nothing changed, the long wait allowed
    #[test]
    fn in_order_is_three_reads() {
        let g = checked(fake(&[L, P, H], L, L));
        assert!(g.healthy);
        assert!(g.sys.log.is_empty(), "{:?}", g.sys.log);
        assert_eq!(g.sys.runs, 3);
    }

    /// only a new headset takes the output: choosing the speakers while it stays connected sticks
    #[test]
    fn headphones_edge_triggered() {
        let mut g = checked(fake(&[L, P, H, B], L, L));
        g.sys.cfg = L.into();
        g.check();
        assert_eq!(g.sys.cfg, L);
    }

    /// the chosen headset goes: to another connected one, then to the tuned sink
    #[test]
    fn headphones_gone() {
        let mut g = checked(fake(&[L, P, H, B, U], L, L));
        assert_eq!(g.sys.cfg, U, "the last new one");
        g.sys.sinks.retain(|s| s != U);
        g.check();
        assert_eq!(g.sys.cfg, B);
        g.sys.sinks.retain(|s| s != B);
        g.check();
        assert_eq!(g.sys.cfg, L);
        assert_eq!(said()[1..], [format!("output gone: {U}, default back to {B}"), format!("output gone: {B}, default back to {L}")]);
    }

    /// the hardware sink gone while the card is there: repaired after 10 s, not before; the timer restarts with the sink
    #[test]
    fn hardware_sink_repair_after_10_s() {
        let mut f = fake(&[L, P], L, L);
        f.pcm = true;
        let mut g = checked(f);
        assert_eq!(logged(&g, "gain off"), 1);
        g.sys.now = 10;
        g.check();
        assert_eq!(logged(&g, "/usr/libexec/tb323fu/tb323fu-audio-defaults"), 0, "9 s since it went (timer starts at 1)");
        g.sys.now = 11;
        g.check();
        assert_eq!(logged(&g, "/usr/libexec/tb323fu/tb323fu-audio-defaults 0"), 1);
        assert_eq!(logged(&g, "wpctl set-profile 91 1"), 1, "card id from the 11-03 pw-cli dump");
        assert_eq!(logged(&g, "notify-send -a Y700 -i audio-speakers 扬声器设备已自动恢复"), 1);
        assert!(!g.gain_on);
        g.sys.sinks.push(H.into());
        g.check();
        assert_eq!(logged(&g, "gain on"), 1, "raised again once all is back");
        assert!(g.healthy && g.nohw == 0);
        g.sys.pcm = false;
        g.sys.sinks.retain(|s| s != H);
        g.sys.now = 100;
        g.check();
        assert_eq!(g.nohw, 0, "no card: nothing to repair");
    }

    /// kded6 is restarted at most every 10 min
    #[test]
    fn kded6_at_most_every_10_min() {
        let mut f = fake(&[L, P, H], L, L);
        f.vol.insert(P.into(), 95);
        let mut g = checked(f);
        for (t, restarts) in [(100, 1), (599, 1), (600, 2)] {
            g.sys.vol.insert(P.into(), 95);
            g.sys.now = t;
            g.check();
            assert_eq!(logged(&g, "systemctl --user restart plasma-kded6.service"), restarts, "at {t} s");
            assert_eq!(g.sys.volume(P), 100);
        }
    }

    /// no sink list (pipewire-pulse restarting): nothing is touched, not even a connected headset's default
    #[test]
    fn pactl_down_changes_nothing() {
        let mut f = fake(&[L, P, H, B], B, B);
        f.pactl_down = true;
        let mut g = Guard::new(f);
        g.ext_prev = vec![B.into()];
        g.check();
        assert_eq!((g.sys.runs, g.sys.cfg.as_str(), g.healthy), (1, B, false));
        assert_eq!(g.ext_prev, [B]);
    }

    /// the configured default read with two names at once (raw, then the tuned sink): left alone this round, as in the
    /// shell, and looked at again in 2 s
    #[test]
    fn configured_default_being_changed() {
        let mut f = fake(&[L, P, H], L, L);
        f.changing_from = H.into();
        let g = checked(f);
        assert!(g.sys.log.is_empty(), "{:?}", g.sys.log);
        assert!(!g.healthy);
    }

    /// a gain command that fails is not believed: tried again on the next check
    #[test]
    fn failed_gain_is_retried() {
        let mut f = fake(&[L, H], L, L);
        f.gain_fails = true;
        let mut g = checked(f);
        g.check();
        assert_eq!(logged(&g, "gain off"), 2);
        assert!(g.gain_on && !g.healthy);
    }

    // ---- parsers on the tablet's own output (fixtures/, LC_ALL=C as user, 11-03)

    #[test]
    fn parse_the_tablets_sinks() {
        let s = parse_sinks(include_str!("../fixtures/sg-sinks.txt"));
        let names: Vec<&str> = s.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, [P, H, L]);
        assert_eq!(s.iter().map(|s| (s.index.as_str(), s.vol)).collect::<Vec<_>>(), [("37", Some(100)), ("98", Some(100)), ("124", Some(25))]);
        assert_eq!(s[2].desc, "扬声器（联想调音）");
        assert_eq!(s[1].desc, "Speakers (raw, unprotected)");
    }

    #[test]
    fn parse_the_tablets_streams() {
        let t = include_str!("../fixtures/sg-inputs.txt");
        assert!(streams_on(t, "98").is_empty(), "only the protection chain's output is on the raw sink");
        assert_eq!(streams_on(t, "124"), ["84"], "the keyboard clicks on the tuned sink");
        assert_eq!(streams_on("Sink Input #5\n\tSink: 98\n", "98"), ["5"], "no node.name: bypassing");
    }

    #[test]
    fn parse_the_tablets_metadata_and_card() {
        assert_eq!(configured(include_str!("../fixtures/sg-meta.txt")).as_deref(), Some(L));
        assert_eq!(configured("Found \"default\" metadata 44\n").as_deref(), Some(""));
        let line = |n: &str| format!("update: id:0 key:'{KEY}' value:'{{\"name\":\"{n}\"}}' type:'Spa:String:JSON'\n");
        assert_eq!(configured(&(line(L) + &line(L))).as_deref(), Some(L), "the same name twice (10-22, 10-23 at boot)");
        assert_eq!(configured(&(line(P) + &line(L))), None);
        assert_eq!(card_id(include_str!("../fixtures/sg-devices.txt")).as_deref(), Some("91"));
        assert_eq!(card_id("\tid 52, type PipeWire:Interface:Device/3\n"), None);
    }

    // ---- the event connection against a fake server

    fn take(s: &mut UnixStream) -> Vec<u8> {
        let mut h = [0u8; 20];
        s.read_exact(&mut h).unwrap();
        assert_eq!(h[4..20], [255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        let mut p = vec![0; u32::from_be_bytes([h[0], h[1], h[2], h[3]]) as usize];
        s.read_exact(&mut p).unwrap();
        p
    }

    fn reply(tag: u32, values: &[u32]) -> Vec<u8> {
        packet(CMD_REPLY, tag, |b| values.iter().for_each(|v| put_u32(b, *v)))
    }

    fn event(e: u32, index: u32) -> Vec<u8> {
        packet(CMD_SUBSCRIBE_EVENT, u32::MAX, |b| {
            put_u32(b, e);
            put_u32(b, index);
        })
    }

    #[test]
    fn subscribe_and_count_events() {
        let (client, mut server) = UnixStream::pair().unwrap();
        let (go, ready) = mpsc::channel();
        let t = std::thread::spawn(move || {
            let auth = take(&mut server);
            assert_eq!(u32s(&auth, 3), Some(vec![CMD_AUTH, 0, 35]));
            assert_eq!((auth[15..20].to_vec(), auth.len()), (vec![b'x', 0, 0, 1, 0], 20 + 256));
            let name = take(&mut server);
            assert_eq!(u32s(&name, 2), Some(vec![CMD_SET_CLIENT_NAME, 1]));
            assert_eq!(&name[10..], b"Ptapplication.name\0L\0\0\0\x13x\0\0\0\x13y700-speaker-guard\0N");
            assert_eq!(u32s(&take(&mut server), 3), Some(vec![CMD_SUBSCRIBE, 2, 0x85]));
            server.write_all(&reply(0, &[35])).unwrap();
            server.write_all(&reply(1, &[7])).unwrap();
            let r = reply(2, &[]); // header and payload in separate writes, as pipewire-pulse sends them
            server.write_all(&r[..20]).unwrap();
            server.write_all(&r[20..]).unwrap();
            ready.recv().unwrap();
            // a client coming (every pactl call) does not count, a sink-input change and a server change do; a data
            // packet (channel 0) is skipped
            let mut burst = event(0x05, 9);
            burst.extend(event(0x12, 5));
            burst.extend([0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7, 7]);
            burst.extend(event(0x17, 0));
            server.write_all(&burst).unwrap();
        });
        let mut p = Pulse::start(client).unwrap();
        go.send(()).unwrap();
        let mut n = 0;
        while n < 2 {
            n += p.events().unwrap();
        }
        assert_eq!(n, 2);
        t.join().unwrap();
        assert!(p.events().is_err(), "EOF once the server is gone");
    }

    #[test]
    fn refused_or_oversized_is_an_error() {
        let (client, mut server) = UnixStream::pair().unwrap();
        server.write_all(&packet(CMD_ERROR, 0, |b| put_u32(b, 1))).unwrap();
        assert!(Pulse::start(client).err().unwrap().to_string().contains("refused command 0"));
        let (client, mut server) = UnixStream::pair().unwrap();
        server.write_all(&[0, 0x20, 0, 0, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).unwrap();
        assert!(Pulse::start(client).err().unwrap().to_string().contains("pulse packet of"));
    }

    /// On the tablet as the session user (README "扬声器守护"): the real pipewire-pulse takes the handshake and sends a
    /// sink event when a null sink comes and goes.
    #[test]
    #[ignore]
    fn live_pipewire_pulse() {
        let mut p = Pulse::connect().unwrap();
        let out = Command::new("pactl").args(["load-module", "module-null-sink", "sink_name=y700-sg-live"]).output().unwrap();
        let id = String::from_utf8_lossy(&out.stdout).trim().to_string();
        assert!(out.status.success() && !id.is_empty());
        assert!(Command::new("pactl").args(["unload-module", &id]).status().unwrap().success());
        let mut n = 0;
        while n == 0 {
            n += p.events().expect("an event within 5 s");
        }
        eprintln!("live: {n} event(s) in the first read");
    }
}
