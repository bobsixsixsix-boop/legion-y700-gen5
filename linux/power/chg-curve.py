#!/usr/bin/python3
# Read-only charge curve: one line every INT s until full (or MAX s). Only reads sysfs; writes /root/chg-curve-<MMDD-HHMM>.txt.
import glob, os, sys, time

INT = float(os.environ.get("INT", 10))
MAX = float(sys.argv[1]) if len(sys.argv) > 1 else 7200
B = "/sys/class/power_supply/qcom-battmgr-bat/"
U = "/sys/class/power_supply/qcom-battmgr-usb/"


def rd(p):
    try:
        with open(p) as f:
            return f.read().strip()
    except OSError:
        return "?"


def num(p, scale):
    try:
        return int(rd(p)) / scale
    except ValueError:
        return float("nan")


zones = {}
for z in glob.glob("/sys/class/thermal/thermal_zone*"):
    t = rd(z + "/type").removesuffix("-thermal")
    if t in ("batt", "batt2", "skin", "usb", "usb2-conn", "quiet", "pmih0108", "wls"):  # pmih0108: charger PMIC (assumed)
        zones[t] = z + "/temp"
zones = dict(sorted(zones.items()))
dpms = (glob.glob("/sys/class/drm/card*-DSI-1/dpms") or ["/nonexistent"])[0]
out = open(time.strftime("/root/chg-curve-%m%d-%H%M.txt"), "w", buffering=1)
out.write("# t cap%% status batV batA batW batC usbV usbVmax usbImax dpms " + " ".join(zones) + "\n")
t0 = time.monotonic()
full = 0
while time.monotonic() - t0 < MAX:
    v, a = num(B + "voltage_now", 1e6), num(B + "current_now", 1e6)
    st = rd(B + "status")
    out.write(f"{time.strftime('%T')} {rd(B + 'capacity')} {st} {v:.3f} {a:+.2f} {v * a:+.1f} {num(B + 'temp', 10):.1f} "
              f"{num(U + 'voltage_now', 1e6):.2f} {num(U + 'voltage_max', 1e6):.2f} {num(U + 'current_max', 1e6):.1f} {rd(dpms)} "
              + " ".join(f"{num(p, 1000):.1f}" for p in zones.values()) + "\n")
    full = full + 1 if st in ("Full", "Not charging", "Discharging") else 0
    if full >= 6:                       # a minute of not charging: done (full, unplugged or stopped)
        break
    time.sleep(INT)
out.write(f"# end {time.strftime('%T')}\n")
