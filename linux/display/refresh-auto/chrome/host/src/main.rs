//! y700-chrome-video-state (2026-10-18): Chrome native messaging host of the "Y700 video state" extension
//! (`../ext/`). Chrome starts it while a page plays a video and sends JSON messages
//! `{"playing":1,"fullscreen":1,"osd":0,"danmaku":0,"fps":29.97,"why":""}` (4-byte native-endian length + UTF-8 JSON
//! on stdin).
//! Each is written, only when it differs from the last one, to `$XDG_RUNTIME_DIR/y700-video/chrome-<browser pid>` in
//! the format of the wiliwili patch and the mpv script (tmp + rename), so y700-refresh-auto matches it against the
//! active window's pid (Chrome's windows belong to the browser process). On EOF (the extension closed the port, Chrome
//! quit) and on SIGTERM (Chrome's EnsureProcessTerminated) the file is removed. Nothing is ever written to stdout.
//! `why` (what the extension took for danmaku) is written as a `why=` line only when not empty, cut to 100 characters
//! of `[A-Za-z0-9 #._>-]`: for diagnosis, y700-refresh-auto ignores keys it does not know.
//! No dependencies: the messages are flat objects of numbers and one string, parsed by hand.
use std::ffi::CString;
use std::fs;
use std::io::{self, Read};
use std::os::raw::{c_char, c_int};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::PathBuf;

extern "C" {
    fn signal(sig: c_int, handler: usize) -> usize;
    fn unlink(path: *const c_char) -> c_int;
    fn _exit(code: c_int) -> !;
}

const SIGTERM: c_int = 15;
static mut STATE_PATH: [u8; 512] = [0; 512]; // NUL-terminated, for the signal handler (unlink is async-signal-safe)

extern "C" fn on_term(_: c_int) {
    unsafe {
        unlink(std::ptr::addr_of!(STATE_PATH) as *const c_char);
        _exit(0);
    }
}

/// the browser process: the first ancestor running .../chrome without --type= (the host is normally its child)
fn browser_pid() -> u32 {
    let first = std::os::unix::process::parent_id();
    let mut pid = first;
    for _ in 0..6 {
        let cmd = fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
        let mut args = cmd.split(|&b| b == 0).filter(|a| !a.is_empty());
        let exe = args.next().unwrap_or_default();
        let is_chrome = exe.ends_with(b"/chrome") || exe == b"chrome";
        if is_chrome && !cmd.windows(7).any(|w| w == b"--type=") {
            return pid;
        }
        let stat = fs::read_to_string(format!("/proc/{pid}/stat")).unwrap_or_default();
        // pid (comm) state ppid ...: comm may contain spaces and parentheses, so split after the last ')'
        let ppid = stat.rsplit_once(')').and_then(|(_, r)| r.split_whitespace().nth(1)).and_then(|p| p.parse().ok());
        match ppid {
            Some(p) if p > 1 => pid = p,
            _ => break,
        }
    }
    first
}

/// the number after "key": in a flat JSON object (0 if missing)
fn field(msg: &str, key: &str) -> f64 {
    let pat = format!("\"{key}\"");
    let Some(i) = msg.find(&pat) else { return 0.0 };
    let rest = msg[i + pat.len()..].trim_start();
    let rest = rest.strip_prefix(':').unwrap_or(rest).trim_start();
    let end = rest.find(|c: char| !(c.is_ascii_digit() || "+-.eE".contains(c))).unwrap_or(rest.len());
    rest[..end].parse().unwrap_or(0.0)
}

/// the string after "key": in a flat JSON object, reduced to a safe one-line form ("" if missing)
fn text(msg: &str, key: &str) -> String {
    let pat = format!("\"{key}\"");
    let Some(i) = msg.find(&pat) else { return String::new() };
    let rest = msg[i + pat.len()..].trim_start();
    let rest = rest.strip_prefix(':').unwrap_or(rest).trim_start();
    let Some(rest) = rest.strip_prefix('"') else { return String::new() };
    let mut out = String::new();
    let mut esc = false;
    for c in rest.chars() {
        if esc {
            esc = false; // an escaped character is dropped: none of ours needs one
        } else if c == '\\' {
            esc = true;
        } else if c == '"' {
            break;
        } else if c.is_ascii_alphanumeric() || " #._>-".contains(c) {
            out.push(c);
            if out.len() >= 100 {
                break;
            }
        }
    }
    out
}

fn state(pid: u32, msg: &str) -> String {
    let b = |k| if field(msg, k) != 0.0 { 1 } else { 0 };
    let fps = field(msg, "fps");
    let fps = if fps.is_finite() && fps > 0.0 && fps < 1000.0 { fps } else { 0.0 };
    let why = text(msg, "why");
    let why = if why.is_empty() { why } else { format!("why={why}\n") };
    format!("pid={pid}\nplaying={}\nfullscreen={}\nosd={}\ndanmaku={}\nfps={fps:.3}\n{why}",
            b("playing"), b("fullscreen"), b("osd"), b("danmaku"))
}

fn main() {
    let pid = browser_pid();
    let run = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| {
        let uid = fs::metadata("/proc/self").map(|m| m.uid()).unwrap_or(1000);
        PathBuf::from(format!("/run/user/{uid}"))
    });
    let dir = run.join("y700-video");
    let _ = fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir);
    let path = dir.join(format!("chrome-{pid}"));
    let tmp = dir.join(format!("chrome-{pid}.tmp"));
    if let Ok(c) = CString::new(path.as_os_str().as_bytes()) {
        let b = c.as_bytes_with_nul();
        if b.len() <= 512 {
            unsafe {
                std::ptr::copy_nonoverlapping(b.as_ptr(), std::ptr::addr_of_mut!(STATE_PATH) as *mut u8, b.len());
                signal(SIGTERM, on_term as extern "C" fn(c_int) as usize);
            }
        }
    }
    let mut stdin = io::stdin().lock();
    let mut last = String::new();
    loop {
        let mut len = [0u8; 4];
        if stdin.read_exact(&mut len).is_err() {
            break;
        }
        let n = u32::from_ne_bytes(len) as usize;
        if n > 65536 {
            break; // not our extension's messages
        }
        let mut buf = vec![0u8; n];
        if stdin.read_exact(&mut buf).is_err() {
            break;
        }
        let s = state(pid, &String::from_utf8_lossy(&buf));
        if s != last && fs::write(&tmp, &s).and_then(|_| fs::rename(&tmp, &path)).is_ok() {
            last = s;
        }
    }
    let _ = fs::remove_file(&path);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parse() {
        let m = r#"{"playing":1,"fullscreen":1,"osd":0,"danmaku":0,"fps":29.97}"#;
        assert_eq!(state(42, m), "pid=42\nplaying=1\nfullscreen=1\nosd=0\ndanmaku=0\nfps=29.970\n");
        assert_eq!(field(r#"{"fps": 60, "playing" : 1}"#, "playing"), 1.0);
        assert_eq!(state(7, "{}"), "pid=7\nplaying=0\nfullscreen=0\nosd=0\ndanmaku=0\nfps=0.000\n");
        assert_eq!(field(r#"{"fps":1e9}"#, "fps"), 1e9);
        assert!(state(7, r#"{"fps":1e9}"#).ends_with("fps=0.000\n"));
        let m = r#"{"playing":1,"fullscreen":1,"osd":0,"danmaku":1,"fps":60,"why":"anim div.dm>span#x"}"#;
        assert!(state(1, m).ends_with("fps=60.000\nwhy=anim div.dm>span#x\n"));
        assert!(state(1, r#"{"danmaku":0,"why":""}"#).ends_with("fps=0.000\n"));
        assert_eq!(text(r#"{"why":"a\nb=c\"d\\"e"}"#, "why"), "abcd");
        assert_eq!(text(r#"{"why":5}"#, "why"), "");
        assert_eq!(text(&format!("{{\"why\":\"{}\"}}", "x".repeat(300)), "why").len(), 100);
    }
}
