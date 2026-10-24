#!/usr/bin/env python3
"""RTT prober for streaming runs: ICMP to the gateway and TCP connect to the host.

The Windows host drops ICMP echo (public firewall profile), so the host RTT is
the TCP handshake time to Apollo's HTTP port 47989 (SYN -> SYN/ACK, the
connection is closed right away).  Both probes run at 2 Hz: faster probing
would itself keep the Wi-Fi radio awake and hide power-save effects.

CSV: t,target,rtt_ms   (rtt_ms empty = no answer within 1 s)
usage: ml-rtt.py OUT.csv GATEWAY HOST [PORT]
"""
import csv, re, signal, socket, subprocess, sys, threading, time

OUT, GW, HOST = sys.argv[1], sys.argv[2], sys.argv[3]
PORT = int(sys.argv[4]) if len(sys.argv) > 4 else 47989
INTERVAL = 0.5
stop = threading.Event()
lock = threading.Lock()
f = open(OUT, "w", newline="")
w = csv.writer(f)
w.writerow(["t", "target", "rtt_ms"])


def emit(t, target, rtt):
    with lock:
        w.writerow([f"{t:.3f}", target, "" if rtt is None else f"{rtt:.2f}"])
        f.flush()


def ping_loop():
    p = subprocess.Popen(["ping", "-D", "-n", "-O", "-i", str(INTERVAL), "-W", "1", GW],
                         stdout=subprocess.PIPE, text=True, bufsize=1)
    for line in p.stdout:
        if stop.is_set():
            break
        m = re.match(r"\[(\d+\.\d+)\].*time=([\d.]+) ms", line)
        if m:
            emit(float(m.group(1)), "gw", float(m.group(2)))
            continue
        m = re.match(r"\[(\d+\.\d+)\] no answer yet", line)
        if m:
            emit(float(m.group(1)), "gw", None)
    p.terminate()


def tcp_loop():
    nxt = time.monotonic() + 0.25  # interleave with the pings
    while not stop.is_set():
        stop.wait(max(0, nxt - time.monotonic()))
        nxt += INTERVAL
        t = time.time()
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
        t0 = time.perf_counter()
        try:
            s.connect((HOST, PORT))
            rtt = (time.perf_counter() - t0) * 1000
        except OSError:
            rtt = None
        finally:
            s.close()  # linger 0 -> RST, no TIME_WAIT pile-up
        emit(t, "host", rtt)


def _stop(*_):
    stop.set()


signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)
threads = [threading.Thread(target=ping_loop, daemon=True), threading.Thread(target=tcp_loop, daemon=True)]
for th in threads:
    th.start()
while not stop.is_set():
    stop.wait(1)
time.sleep(0.6)
f.close()
