#!/usr/bin/env python3
"""Summarise Moonlight runs collected by host-run.py (runs/streaming/<label>/).

usage: py -3 analyze.py [--detail] LABEL_OR_GLOB...
Prints one markdown table row per run.  The measuring window is from the first
video packet + 15 s (page load, Wi-Fi settling after the ssh that started the run)
to the quit - 8 s (the test page goes down ~4 s before the quit).  --detail also lists the worst seconds of each run.

Columns
  in/dec fps   Moonlight global stats (whole session)
  net/jit %    frames dropped by the network / by jitter (Moonlight)
  dec ms       average decode time; host ms = host processing latency avg/max
  short s      seconds in the window where the iris decoder raised < 85 % of the
               run's median IRQs per second = hitch candidates (IRQs per frame
               depend on the codec, so the run is its own reference)
  rtt host     TCP-handshake RTT to the host, p50/p95/p99/max ms, lost probes
  rtt gw       ICMP to the gateway, same
  retry/fail   tablet tx retries / failures (sum), bcn = beacon losses
  rcvbuf       UDP receive-buffer overruns (sum) on the tablet
  W, skin      tablet battery discharge power (avg) and max skin temperature
  enc          Apollo encoder re-creations inside the session (display changes)
  host dip s   seconds in the window where NVENC encoded < 90 % of the target fps
               (frames the host never produced: capture/page, not Wi-Fi or decode)
  page dip s   seconds where the test page itself drew < 85 % of its median rate
               ("mixed": more than one test page was posting, the column is meaningless)
--series prints the per-second timeline instead (tablet IRQs/rx, host fps, page fps).
"""
import csv, datetime, glob, re, statistics, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent / "runs" / "streaming"


def pct(v, p):
    if not v:
        return float("nan")
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))]


def gstats(log):
    s = {}
    pats = {
        "in_fps": r"Incoming frame rate from network: ([\d.]+)",
        "dec_fps": r"Decoding frame rate: ([\d.]+)",
        "ren_fps": r"Rendering frame rate: ([\d.]+)",
        "host": r"Host processing latency min/max/average: ([\d.]+)/([\d.]+)/([\d.]+)",
        "net": r"Frames dropped by your network connection: ([\d.]+)%",
        "jit": r"Frames dropped due to network jitter: ([\d.]+)%",
        "lat": r"Average network latency: (\d+) ms \(variance: (\d+) ms\)",
        "dec": r"Average decoding time: ([\d.]+) ms",
        "queue": r"Average frame queue delay: ([\d.]+) ms",
        "ren": r"Average rendering time \(including monitor V-sync latency\): ([\d.]+) ms",
    }
    for k, p in pats.items():
        m = re.search(p, log)
        s[k] = m.groups() if m else None
    s["idr"] = max(0, len(re.findall(r"IDR frame request sent", log)) - 1)
    s["decoder"] = (re.findall(r"Chose \w+ for codec (\S+)", log) or ["?"])[-1]
    s["errors"] = len(re.findall(r"Unrecoverable|Waiting for IDR|decoder failed|Reinitializing", log))
    return s


def times(meta):
    t = {}
    for line in meta.splitlines():
        m = re.match(r"\S+ @([\d.]+) (T0|T1)", line)
        if m:
            t[m.group(2)] = float(m.group(1))
    return t


def rows(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def fnum(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def host_fps(d):
    """{epoch second: NVENC average fps} from host-nvenc.csv (both logger formats)."""
    f = d / "host-nvenc.csv"
    if not f.exists():
        return {}
    out = {}
    with open(f, newline="") as fh:
        rd = list(csv.reader(fh))
    if not rd:
        return out
    hdr = [h.strip() for h in rd[0]]
    for r in rd[1:]:
        try:
            if "enc_fps" in hdr:   # Sampler format: t,enc_sessions,enc_fps,...
                out[int(float(r[0]))] = float(r[hdr.index("enc_fps")])
            else:                  # old `nvidia-smi -l 1 -f` format: local timestamp, sessions, fps, ...
                ts = datetime.datetime.strptime(r[0].strip(), "%Y/%m/%d %H:%M:%S.%f").timestamp()
                out[int(ts)] = float(r[2])
        except (ValueError, IndexError):
            pass
    return out


def page_posts(d, a, b):
    f = d / "host-page.csv"
    return sum(1 for r in rows(f) if a <= float(r["t"]) <= b + 1) if f.exists() else 0


def page_fps(d):
    f = d / "host-page.csv"
    return {int(float(r["t"])): int(r["page_frames"]) for r in rows(f)} if f.exists() else {}


def series(d):
    t = times((d / "meta.txt").read_text(errors="replace"))
    hf, pf = host_fps(d), page_fps(d)
    print(f"## {d.name}  (s after first video packet)")
    for r in rows(d / "probe.csv"):
        s = float(r["t"]) - t.get("T0", 0)
        if -2 <= s <= t.get("T1", 1e18) - t.get("T0", 0) + 2:
            k = int(float(r["t"]))
            print(f"{s:6.1f} irq={r['d_iris_irq']:>4} rx={float(r['rx_mbps']):5.1f}Mb/s pk={r['d_rx_packets']:>5} "
                  f"retry={r['d_tx_retries']} bcnloss={r['d_bcn_loss']} rcvbuf={r['d_udp_rcvbuf_err']} "
                  f"cpu={r['cpu0_mhz']}/{r['cpu6_mhz']} gpu={r['gpu_mhz']} host_fps={hf.get(k, '-')} page_fps={pf.get(k, '-')}")


def summarise(d, detail=False):
    meta = (d / "meta.txt").read_text(errors="replace")
    params = dict(re.findall(r"(\w+)=(\S*)", meta.splitlines()[0]))
    log = (d / "moonlight.log").read_text(errors="replace") if (d / "moonlight.log").exists() else ""
    g = gstats(log)
    t = times(meta)
    if "T0" not in t or "T1" not in t:
        return f"| {d.name} | FAILED (no video) |"
    a, b = t["T0"] + 15, t["T1"] - 8  # host-run takes the page down at ~T1-4
    fps = int(params["fps"])
    pr = [r for r in rows(d / "probe.csv") if a <= float(r["t"]) <= b]
    irq = [int(r["d_iris_irq"]) for r in pr]
    # IRQs per frame differ by codec (HEVC ~3, H.264 ~1.5): compare with the run's own median
    med = statistics.median(irq) if irq else 0
    short = [r for r in pr if int(r["d_iris_irq"]) < 0.85 * med]
    sumi = lambda k: sum(int(r[k]) for r in pr if r[k] not in ("", None))
    rt = [r for r in rows(d / "rtt.csv") if a <= float(r["t"]) <= b]
    def rtts(tg):
        v = [fnum(r["rtt_ms"]) for r in rt if r["target"] == tg]
        ok = [x for x in v if x is not None]
        return ok, len(v) - len(ok)
    h, hl = rtts("host")
    gw, gl = rtts("gw")
    w = [fnum(r["bat_w"]) for r in pr if fnum(r["bat_w"]) is not None]
    skin = [fnum(r["t_skin"]) for r in pr if fnum(r["t_skin"]) is not None]
    apollo = (d / "apollo.log").read_text(errors="replace") if (d / "apollo.log").exists() else ""
    enc = max(0, len(re.findall(r"Starting async encoder teardown", apollo)) - 1)  # last one = session end
    ps = sorted({r["ps"] for r in pr})
    hf = {k: v for k, v in host_fps(d).items() if a <= k <= b}
    hdip = sum(1 for v in hf.values() if v < 0.9 * fps)
    pf = {k: v for k, v in page_fps(d).items() if a <= k <= b}
    pmed = statistics.median(pf.values()) if pf else 0
    pdip = f"{sum(1 for v in pf.values() if v < 0.85 * pmed)}/{len(pf)}" if pf else "-"
    if pf and page_posts(d, a, b) > 1.3 * len(pf):
        pdip = "mixed"  # >1 test page posting: a stale Edge window (runs before kill_edge, 10-19 21:1x)
    f2 = lambda x: "-" if x is None else x
    host = g["host"]
    line = (f"| {d.name} | {params['codec']} {params['res']}@{fps} {int(params['kbps'])//1000}M ps={'/'.join(ps)} "
            f"| {f2(g['in_fps'] and g['in_fps'][0])}/{f2(g['dec_fps'] and g['dec_fps'][0])} "
            f"| {f2(g['net'] and g['net'][0])}/{f2(g['jit'] and g['jit'][0])} "
            f"| {f2(g['dec'] and g['dec'][0])} | {host[2] + '/' + host[1] if host else '-'} "
            f"| {len(short)}/{len(pr)} | {g['idr']} "
            f"| {pct(h,50):.1f}/{pct(h,95):.1f}/{pct(h,99):.1f}/{max(h) if h else float('nan'):.0f} ({hl}) "
            f"| {pct(gw,50):.1f}/{pct(gw,95):.1f}/{pct(gw,99):.1f}/{max(gw) if gw else float('nan'):.0f} ({gl}) "
            f"| {sumi('d_tx_retries')}/{sumi('d_tx_failed')} bcn {sumi('d_bcn_loss')} | {sumi('d_udp_rcvbuf_err')} "
            f"| {statistics.mean(w) if w else float('nan'):.2f} | {max(skin) if skin else float('nan'):.1f} | {enc} "
            f"| {hdip}/{len(hf)} | {pdip} |")
    out = [line]
    if detail:
        worst = sorted(pr, key=lambda r: int(r["d_iris_irq"]))[:8]
        for r in sorted(worst, key=lambda r: float(r["t"])):
            out.append(f"    t+{float(r['t']) - t['T0']:6.1f}s irq={r['d_iris_irq']} rx={r['rx_mbps']}Mb/s sig={r['signal']} "
                       f"rate={r['rx_rate']}/{r['tx_rate']} retry={r['d_tx_retries']} bcnloss={r['d_bcn_loss']} rcvbuf={r['d_udp_rcvbuf_err']} "
                       f"cpu={r['cpu0_mhz']}/{r['cpu6_mhz']} gpu={r['gpu_mhz']}")
        spikes = [r for r in rt if fnum(r["rtt_ms"]) is None or fnum(r["rtt_ms"]) > 30]
        out.append(f"    rtt>30ms or lost: " + ", ".join(f"{r['target']}@{float(r['t']) - t['T0']:.0f}s={r['rtt_ms'] or 'lost'}" for r in spikes[:25]))
    return "\n".join(out)


HEADER = ("| run | config | in/dec fps | net/jit % | dec ms | host ms avg/max | short s | IDR | rtt host p50/95/99/max (lost) "
          "| rtt gw p50/95/99/max (lost) | retry/fail | rcvbuf | W | skin °C | enc | host dip s | page dip s |\n|" + "---|" * 17)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    args = sys.argv[1:]
    detail, ser = "--detail" in args, "--series" in args
    args = [x for x in args if x not in ("--detail", "--series")] or ["*"]
    dirs = []
    for a in args:
        dirs += sorted(Path(p) for p in glob.glob(str(ROOT / a)) if (Path(p) / "meta.txt").exists())
    if ser:
        for d in dirs:
            series(d)
        return
    print(HEADER)
    for d in dirs:
        try:
            print(summarise(d, detail))
        except Exception as e:  # keep going on half-collected runs
            print(f"| {d.name} | error: {e} |")


if __name__ == "__main__":
    main()
