#!/usr/bin/env python3
"""Per-second sampler for Moonlight streaming runs on the Y700 (read-only).

Writes one CSV row per second: Wi-Fi link (iw station dump), interface bytes,
UDP counters (RcvbufErrors = socket buffer overruns), iris decoder IRQs
(proxy for decoded frames/s), CPU/GPU frequency, temperatures, battery power
and the panel refresh rate.  Stops on SIGTERM/SIGINT.

usage: ml-probe.py OUT.csv [IFACE]
"""
import csv, re, signal, subprocess, sys, time

OUT = sys.argv[1]
IF = sys.argv[2] if len(sys.argv) > 2 else "wlp1s0"
stop = False


def _stop(*_):
    global stop
    stop = True


signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)


def rd(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def iris_irq():
    with open("/proc/interrupts") as f:
        for line in f:
            if line.rstrip().endswith(" iris"):
                parts = line.split()
                return sum(int(x) for x in parts[1:] if x.isdigit())
    return 0


def udp():
    with open("/proc/net/snmp") as f:
        rows = [l.split() for l in f if l.startswith("Udp:")]
    return dict(zip(rows[0][1:], (int(x) for x in rows[1][1:])))


STA_KEYS = {
    "tx retries": "tx_retries", "tx failed": "tx_failed",
    "beacon loss": "bcn_loss", "beacon rx": "bcn_rx",
    "rx drop misc": "rx_drop_misc", "signal": "signal",
    "tx bitrate": "tx_rate", "rx bitrate": "rx_rate",
}


def station():
    d = {}
    try:
        out = subprocess.run(["iw", "dev", IF, "station", "dump"], capture_output=True,
                             text=True, timeout=2).stdout
    except (subprocess.TimeoutExpired, OSError):
        return d
    for line in out.splitlines():
        k, _, v = line.strip().partition(":")
        k = k.strip()
        if k in STA_KEYS and STA_KEYS[k] not in d:
            v = v.strip()
            if k in ("tx bitrate", "rx bitrate"):
                m = re.match(r"([\d.]+) MBit/s(?:.*?(\d+)MHz)?(?:.*?MCS (\d+))?", v)
                d[STA_KEYS[k]] = m.group(1) if m else ""
                d[STA_KEYS[k] + "_mcs"] = (m.group(3) or "") if m else ""
                d[STA_KEYS[k] + "_bw"] = (m.group(2) or "") if m else ""
            else:
                d[STA_KEYS[k]] = v.split()[0]
    return d


def power_save():
    try:
        out = subprocess.run(["iw", "dev", IF, "get", "power_save"], capture_output=True,
                             text=True, timeout=2).stdout
        return "on" if " on" in out else "off"
    except (subprocess.TimeoutExpired, OSError):
        return ""


def temp(zone):
    v = rd(f"/sys/class/thermal/thermal_zone{zone}/temp")
    return f"{int(v) / 1000:.1f}" if v.lstrip("-").isdigit() else ""


def panel_hz():
    m = re.search(r"\bhz (\d+)", rd("/sys/module/msm/parameters/idle_refresh_state"))
    return m.group(1) if m else ""


def bat_w():
    i = rd("/sys/class/power_supply/qcom-battmgr-bat/current_now")
    v = rd("/sys/class/power_supply/qcom-battmgr-bat/voltage_now")
    try:
        return f"{-int(i) * int(v) / 1e12:.2f}"  # discharge positive
    except ValueError:
        return ""


COUNTERS = ["rx_bytes", "tx_bytes", "rx_packets", "tx_dropped", "rx_dropped"]
FIELDS = (["t", "ps", "signal", "tx_rate", "tx_rate_mcs", "tx_rate_bw", "rx_rate", "rx_rate_mcs",
           "d_tx_retries", "d_tx_failed", "d_bcn_loss", "d_bcn_rx", "d_rx_drop_misc",
           "rx_mbps", "tx_mbps", "d_rx_packets", "d_rx_dropped",
           "d_udp_in", "d_udp_rcvbuf_err", "d_udp_in_err", "d_iris_irq",
           "cpu0_mhz", "cpu6_mhz", "gpu_mhz", "t_skin", "t_cpu", "t_gpu", "bat_w", "panel_hz"])


def snap():
    s = {"st": station(), "udp": udp(), "irq": iris_irq(), "t": time.time()}
    for c in COUNTERS:
        s[c] = int(rd(f"/sys/class/net/{IF}/statistics/{c}", "0"))
    return s


def main():
    f = open(OUT, "w", newline="")
    w = csv.DictWriter(f, fieldnames=FIELDS)
    w.writeheader()
    prev = snap()
    ps = power_save()
    n = 0
    next_t = time.monotonic() + 1
    while not stop:
        time.sleep(max(0, next_t - time.monotonic()))
        next_t += 1
        cur = snap()
        dt = max(cur["t"] - prev["t"], 1e-3)
        st, pst = cur["st"], prev["st"]

        def dsta(k):
            try:
                return int(st[k]) - int(pst[k])
            except (KeyError, ValueError):
                return ""
        if n % 10 == 0:
            ps = power_save()
        row = {
            "t": f"{cur['t']:.3f}", "ps": ps,
            "signal": st.get("signal", ""), "tx_rate": st.get("tx_rate", ""),
            "tx_rate_mcs": st.get("tx_rate_mcs", ""), "tx_rate_bw": st.get("tx_rate_bw", ""),
            "rx_rate": st.get("rx_rate", ""), "rx_rate_mcs": st.get("rx_rate_mcs", ""),
            "d_tx_retries": dsta("tx_retries"), "d_tx_failed": dsta("tx_failed"),
            "d_bcn_loss": dsta("bcn_loss"), "d_bcn_rx": dsta("bcn_rx"),
            "d_rx_drop_misc": dsta("rx_drop_misc"),
            "rx_mbps": f"{(cur['rx_bytes'] - prev['rx_bytes']) * 8 / dt / 1e6:.2f}",
            "tx_mbps": f"{(cur['tx_bytes'] - prev['tx_bytes']) * 8 / dt / 1e6:.2f}",
            "d_rx_packets": cur["rx_packets"] - prev["rx_packets"],
            "d_rx_dropped": cur["rx_dropped"] - prev["rx_dropped"],
            "d_udp_in": cur["udp"]["InDatagrams"] - prev["udp"]["InDatagrams"],
            "d_udp_rcvbuf_err": cur["udp"]["RcvbufErrors"] - prev["udp"]["RcvbufErrors"],
            "d_udp_in_err": cur["udp"]["InErrors"] - prev["udp"]["InErrors"],
            "d_iris_irq": cur["irq"] - prev["irq"],
            "cpu0_mhz": int(rd("/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq", "0")) // 1000,
            "cpu6_mhz": int(rd("/sys/devices/system/cpu/cpufreq/policy6/scaling_cur_freq", "0")) // 1000,
            "gpu_mhz": int(rd("/sys/class/devfreq/3d00000.gpu/cur_freq", "0")) // 1000000,
            "t_skin": temp(59), "t_cpu": temp(6), "t_gpu": temp(37),
            "bat_w": bat_w(), "panel_hz": panel_hz(),
        }
        w.writerow(row)
        f.flush()
        prev = cur
        n += 1
    f.close()


if __name__ == "__main__":
    main()
