#!/usr/bin/env python3
"""Windows-side driver for the Y700 Moonlight measurements (run with `py -3`).

For each run: copy the tablet scripts, start `ml-run.sh` on the tablet with
systemd-run (the only ssh before the measurement), wait for Apollo's virtual
display to appear, put the motion test page on it (Edge, separate throw-away
profile, fullscreen), log NVENC stats (nvidia-smi), this PC's Wi-Fi link
(netsh), a ping to the gateway and the page's own frame rate (HTTP post to
127.0.0.1:47311) once per second, take the page down just
before the tablet quits, then fetch the tablet's results and Apollo's log slice.
No ssh to the tablet while a run is measuring.

usage:
  py -3 host-run.py RUN_LINE...            # each: "label codec WxH fps kbps secs ps content [extra flags]"
  py -3 host-run.py --plan plan.txt        # one RUN_LINE per line, '#' comments
content = dynamic | static | none (none: leave the virtual display's desktop alone)
"""
import ctypes, ctypes.wintypes as wt, csv, os, re, shlex, subprocess, sys, threading, time
from pathlib import Path

TABLET = os.environ.get("ML_TABLET", "root@100.64.0.10")
KEY = str(Path.home() / ".ssh" / "y700_ed25519")
SSH = ["C:/Windows/System32/OpenSSH/ssh.exe", "-i", KEY, "-o", "BatchMode=yes"]
SCP = ["C:/Windows/System32/OpenSSH/scp.exe", "-q", "-i", KEY, "-o", "BatchMode=yes"]
HERE = Path(__file__).resolve().parent
RESULTS = HERE.parent.parent / "runs" / "streaming"
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
APOLLO_LOG = Path(r"C:\Program Files\Apollo\config\sunshine.log")
GW = "192.168.0.1"
PAGE_PORT = 47311

ctypes.windll.shcore.SetProcessDpiAwareness(2)  # real pixel coordinates


def monitors():
    out = []
    CB = ctypes.WINFUNCTYPE(ctypes.c_int, wt.HMONITOR, wt.HDC, ctypes.POINTER(wt.RECT), wt.LPARAM)

    def cb(h, dc, r, lp):
        rc = r.contents
        out.append((rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top))
        return 1
    ctypes.windll.user32.EnumDisplayMonitors(0, 0, CB(cb), 0)
    return out


def ssh(cmd, check=True):
    return subprocess.run(SSH + [TABLET, cmd], capture_output=True, text=True, check=check)


class Sampler(threading.Thread):
    """Runs fn() every second and writes its dict to CSV."""

    def __init__(self, path, fn):
        super().__init__(daemon=True)
        self.path, self.fn, self.stop = path, fn, threading.Event()

    def run(self):
        with open(self.path, "w", newline="") as f:
            w = None
            nxt = time.monotonic()
            while not self.stop.is_set():
                row = {"t": f"{time.time():.3f}", **self.fn()}
                if w is None:
                    w = csv.DictWriter(f, fieldnames=list(row))
                    w.writeheader()
                w.writerow(row)
                f.flush()
                nxt += 1
                self.stop.wait(max(0, nxt - time.monotonic()))


def netsh():
    # started from Git Bash netsh answers in UTF-8 Chinese, from PowerShell in English:
    # decode either way and accept both sets of labels (runs before 10-19 21:xx only got rssi)
    raw = subprocess.run(["netsh", "wlan", "show", "interfaces"], capture_output=True).stdout
    try:
        out = raw.decode("utf-8")
    except UnicodeDecodeError:
        out = raw.decode("mbcs", errors="replace")
    d = {}
    for key, name in (("Signal|信号", "signal"), ("Rssi", "rssi"), ("Receive rate|接收速率", "rx_rate"),
                      ("Transmit rate|传输速率", "tx_rate"), ("Channel|通道", "channel"), ("Band|波段", "band")):
        m = re.search(rf"^\s*(?:{key})\s*(?:\(Mbps\))?\s*:\s*(.+)$", out, re.M)
        d[name] = m.group(1).strip() if m else ""
    return d


NVQ = ("encoder.stats.sessionCount,encoder.stats.averageFps,encoder.stats.averageLatency,"
       "utilization.encoder,utilization.gpu,clocks.video")


def nvsmi():
    # one query per call: `nvidia-smi -l 1 -f file` buffers its output and loses the
    # tail when it is terminated (the first runs only had the first ~60 s)
    out = subprocess.run(["nvidia-smi", f"--query-gpu={NVQ}", "--format=csv,noheader,nounits"],
                         capture_output=True, text=True).stdout.strip().split(",")
    names = ("enc_sessions", "enc_fps", "enc_latency_us", "util_enc", "util_gpu", "clk_video")
    return {n: (out[i].strip() if i < len(out) else "") for i, n in enumerate(names)}


class PageLog(threading.Thread):
    """Tiny HTTP sink for motion.html: once a second the page posts how many frames it
    drew and its longest rAF gap, so a host-side dip can be told apart from Edge."""

    def __init__(self, path):
        super().__init__(daemon=True)
        import http.server
        outer = self
        self.f = open(path, "w", newline="")
        self.f.write("t,page_frames,page_max_gap_ms,page_min_hz\n")

        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode(errors="replace")
                outer.f.write(f"{time.time():.3f},{body}\n"); outer.f.flush()
                self.send_response(204); self.end_headers()

            def log_message(self, *a):
                pass
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", PAGE_PORT), H)

    def run(self):
        self.srv.serve_forever()

    def stop(self):
        self.srv.shutdown(); self.srv.server_close(); self.f.close()


class Pinger(threading.Thread):
    def __init__(self, path):
        super().__init__(daemon=True)
        self.path, self.p = path, None

    def run(self):
        self.p = subprocess.Popen(["ping", "-t", "-w", "1000", GW], stdout=subprocess.PIPE,
                                  text=True, encoding="mbcs", errors="replace")
        with open(self.path, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["t", "rtt_ms"])
            for line in self.p.stdout:
                m = re.search(r"(?:time|时间)[=<]\s*(\d+)\s*ms", line)
                if m:
                    w.writerow([f"{time.time():.3f}", m.group(1)])
                elif re.search(r"timed out|超时", line):
                    w.writerow([f"{time.time():.3f}", ""])
                f.flush()

    def stop(self):
        if self.p:
            self.p.terminate()


def apollo_slice(t0, t1, path):
    if not APOLLO_LOG.exists():
        return
    a, b = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t0)), time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t1))
    with open(APOLLO_LOG, encoding="utf-8", errors="replace") as f, open(path, "w", encoding="utf-8") as o:
        keep = False
        for line in f:
            m = re.match(r"\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)", line)
            if m:
                keep = a <= m.group(1) <= b
            if keep:
                o.write(line)


SCRUB = [(re.compile(r"\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b"), "<mac>"),
         (re.compile(r"\b[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}\b"), "<uuid>"),
         (re.compile(r"(uniqueid=)[0-9A-Za-z]+"), r"\1<id>"),
         (re.compile(r'(unique ID from settings: ")[0-9A-Za-z]+'), r"\1<id>")]


def scrub(out):
    """Results go into the repo: drop MACs, host/client UUIDs and Moonlight unique ids."""
    for n in ("moonlight.log", "apollo.log"):
        f = out / n
        if f.exists():
            t = f.read_text(encoding="utf-8", errors="replace")
            for rx, rep in SCRUB:
                t = rx.sub(rep, t)
            f.write_text(t, encoding="utf-8", newline="")  # keep LF (default writes CRLF)


EDGE_PROFILE = Path(os.environ["TEMP"]) / "ml-edge-kiosk"


def kill_edge():
    """Kill every Edge process of the throw-away test profile.  `taskkill /T` on the
    Popen pid is not enough: if a browser for that profile is still alive, the new
    msedge.exe only hands it the URL and exits, the old windows stay (a stale page
    then sat on top of the virtual display and froze the "static" run, 10-19 21:0x)."""
    ps = ("Get-CimInstance Win32_Process -Filter \"name='msedge.exe'\" | "
          "Where-Object { $_.CommandLine -like '*ml-edge-kiosk*' } | "
          "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; "
          "@(Get-CimInstance Win32_Process -Filter \"name='msedge.exe'\" | "
          "Where-Object { $_.CommandLine -like '*ml-edge-kiosk*' }).Count")
    for _ in range(5):
        r = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True)
        if r.stdout.strip() == "0":
            return
        time.sleep(1)
    print(f"  warning: test Edge still running ({r.stdout.strip()} processes)", flush=True)


def push_scripts():
    ssh("mkdir -p /root/streaming")
    subprocess.run(SCP + [str(HERE / n) for n in ("ml-run.sh", "ml-probe.py", "ml-rtt.py", "ml-flips.py")]
                   + [f"{TABLET}:/root/streaming/"], check=True)


def one_run(line):
    parts = shlex.split(line)
    label, codec, res, fps, kbps, secs, ps, content = parts[:8]
    extra = parts[8:]
    w, h = (int(x) for x in res.lower().split("x"))
    secs = int(secs)
    out = RESULTS / label
    out.mkdir(parents=True, exist_ok=True)
    print(f"[{time.strftime('%T')}] run {label}: {codec} {res}@{fps} {kbps} kbps {secs}s ps={ps} {content} {' '.join(extra)}", flush=True)
    # a display of the requested size left over from an interrupted session (Apollo keeps
    # a paused session's virtual display) would never count as "new": wait it out
    for _ in range(60):
        if not any(m[2:] == (w, h) for m in set(monitors()) - set(STATIC_MONITORS)):
            break
        time.sleep(1)
    else:
        print(f"  skipped: a {w}x{h} display is already up (stale Apollo session? `moonlight quit`)", flush=True)
        return
    before = set(monitors())
    tstart = time.time()
    # ML_UCLAMP=N / ML_UCLAMP_KWIN=N: Moonlight / KWin under a uclamp.min of N for the run (see ml-run.sh)
    setenv = "".join(f"--setenv={k}={int(os.environ[k])} " for k in ("ML_UCLAMP", "ML_UCLAMP_KWIN")
                     if os.environ.get(k))
    if os.environ.get("ML_LAUNCHER"):  # stream through this launcher on the tablet (e.g. y700-moonlight)
        setenv += f"--setenv=ML_LAUNCHER={shlex.quote(os.environ['ML_LAUNCHER'])} "
    ssh(f"systemd-run --unit=ml-{label} --collect {setenv}/bin/bash /root/streaming/ml-run.sh "
        + " ".join(shlex.quote(x) for x in [label, codec, res, fps, kbps, str(secs), ps] + extra))

    nv = Sampler(out / "host-nvenc.csv", nvsmi); nv.start()
    pl = PageLog(out / "host-page.csv"); pl.start()
    wl = Sampler(out / "host-wlan.csv", netsh); wl.start()
    pg = Pinger(out / "host-ping.csv"); pg.start()
    edge = None
    vd = None
    deadline = time.time() + 60
    while time.time() < deadline and vd is None:
        for m in monitors():
            if m not in before and m[2] == w and m[3] == h:
                vd = m
        time.sleep(0.25)
    t_vd = time.time()
    if vd is None:
        print("  virtual display did not appear", flush=True)
    elif content != "none":
        time.sleep(1.5)  # let Windows settle the new display
        kill_edge()  # a leftover browser would swallow the launch and keep its old windows
        # InPrivate kiosk: a fresh --user-data-dir alone gets signed in to the Windows Microsoft
        # account and starts syncing (extensions included) - InPrivate never signs in.
        edge = subprocess.Popen([EDGE, f"--user-data-dir={EDGE_PROFILE}", "--inprivate", "--no-first-run",
                                 "--no-default-browser-check", "--disable-sync", "--disable-extensions",
                                 "--disable-features=Translate,msTranslate,msUndersideButton",
                                 *shlex.split(os.environ.get("ML_EDGE_FLAGS", "")),  # diagnostics, e.g. --disable-gpu-vsync
                                 f"--window-position={vd[0]},{vd[1]}", f"--window-size={w},{h}",
                                 "--kiosk", "--edge-kiosk-type=fullscreen",
                                 f"file:///{(HERE / 'motion.html').as_posix()}?mode={content}"])
        print(f"  virtual display {vd}, page up", flush=True)
    # tablet quits SECS after its first video packet (~ when the display appeared)
    time.sleep(max(0, t_vd + secs - 3 - time.time()))
    if edge:
        kill_edge()
    deadline = time.time() + 60
    while vd and vd in monitors() and time.time() < deadline:
        time.sleep(0.5)
    time.sleep(3)
    nv.stop.set(); wl.stop.set(); pg.stop(); pl.stop()
    tend = time.time()
    apollo_slice(tstart - 2, tend, out / "apollo.log")
    for _ in range(40):
        r = ssh(f"cat /root/streaming/runs/{label}/done 2>/dev/null", check=False)
        if r.stdout.strip():
            break
        time.sleep(3)
    subprocess.run(SCP + ["-r", f"{TABLET}:/root/streaming/runs/{label}/*", str(out)], check=False)
    scrub(out)
    print(f"  done ({r.stdout.strip() or 'no done marker'}) -> {out}", flush=True)


ML_QUIT = ("timeout 30 sudo -u user env LANG=C.UTF-8 XDG_RUNTIME_DIR=/run/user/1000 "
           "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 "
           "flatpak run com.moonlight_stream.Moonlight quit 192.168.0.94 >/dev/null 2>&1")
STATIC_MONITORS = []


def main():
    # close any session an interrupted run left paused on Apollo, then remember the
    # displays that are not Apollo's (e.g. another remote-play tool's 2560x1600 one)
    ssh(ML_QUIT, check=False)
    time.sleep(3)
    STATIC_MONITORS[:] = monitors()
    args = sys.argv[1:]
    if args[:1] == ["--plan"]:
        lines = [l.strip() for l in Path(args[1]).read_text(encoding="utf-8").splitlines()]
        lines = [l for l in lines if l and not l.startswith("#")]
    else:
        lines = args
    push_scripts()
    for i, line in enumerate(lines):
        one_run(line)
        if i + 1 < len(lines):
            time.sleep(20)  # let the tablet settle (Apollo removes the display, Wi-Fi idles)


if __name__ == "__main__":
    main()
