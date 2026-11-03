#!/usr/bin/env python3
"""Read the charger firmware's own log (the "ulog") on the TB323FU.

On this SoC (SM8850 / Kaanapali) the battery manager and USB-PD policy run on the SoCCP (d00000.remoteproc, started by
the boot loader, Linux only attaches). The firmware offers its log on the glink channel PMIC_LOGS_SOCCP_APPS, which
no kernel driver claims: mainline's pmic_pdcharger_ulog (CONFIG_QCOM_PMIC_PDCHARGER_ULOG, not built here) only knows
the ADSP name PMIC_LOGS_ADSP_APPS. Its protocol is tiny, so this does the same from user space: bind the channel to
rpmsg_chrdev (driver_override) -> /dev/rpmsgN, send {owner 32778, type 1, opcode 0x18, size 8192} every INT s, print
the text that comes back. Read-only towards the firmware: GET_CHG_ULOG is the request mainline's ulog driver sends;
nothing here sets a charging property.

The binding is LEFT IN PLACE on purpose (until reboot). Unbinding closes the glink channel, the firmware closes its
side too, the kernel unregisters the rpmsg device and the firmware never announces it again - and it refuses an
OPEN from our side (RPMSG_CREATE_EPT_IOCTL on rpmsg_ctrl0 -> open() times out after 5 s, EINVAL). Learned on
2026-10-18; after that only a reboot brings the channel back. Closing /dev/rpmsgN is harmless: rpmsg_char uses the
device's default endpoint and does not destroy it on release.

    soccp-chg-ulog.py [seconds]      (default 20; output also to /root/chg-ulog-MMDD-HHMM.txt)
    INT=0.5 polls faster (default 1 s, like the kernel driver); QUIET=1 writes only the file (for systemd-run).
Plug or replug the charger while it runs to catch the PD negotiation (source capabilities, chosen PDO/APDO).
At the default level the firmware logs about 3 KB/s while charging; each answer holds at most 8 KB."""
import os, select, signal, struct, sys, time

DEV = "d00000.remoteproc:glink-edge.PMIC_LOGS_SOCCP_APPS.-1.-1"
SYSDEV = "/sys/bus/rpmsg/devices/" + DEV
DRV = "/sys/bus/rpmsg/drivers/rpmsg_chrdev"
OWNER_CHG_ULOG, TYPE_REQ_RESP, GET_CHG_ULOG = 32778, 1, 0x18
ULOG_SIZE = 8192
USB = "/sys/class/power_supply/qcom-battmgr-usb/"
BAT = "/sys/class/power_supply/qcom-battmgr-bat/"
WLS = "/sys/class/power_supply/qcom-battmgr-wls/"
DPMS = "/sys/class/drm/card1-DSI-1/dpms"

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 20
INT = float(os.environ.get("INT", 1))
QUIET = os.environ.get("QUIET") == "1"
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))


def rd(p):
    try:
        return open(p).read().strip()
    except OSError:
        return "?"


def num(p, scale):
    try:
        return int(rd(p)) / scale
    except ValueError:
        return float("nan")


def state():
    # the firmware runs the side port as its second ("wireless") input (10-18 log: wls_in=1, set_wls_icl), so wls may
    # be where a side-port charger shows (not verified yet); dpms for the screen on/off split
    return (f"usb {num(USB + 'voltage_now', 1e6):.2f}V {num(USB + 'current_now', 1e6):.2f}A "
            f"vmax {rd(USB + 'voltage_max')} imax {rd(USB + 'current_max')} type {rd(USB + 'usb_type')} | "
            f"wls {num(WLS + 'voltage_now', 1e6):.2f}V {num(WLS + 'current_now', 1e6):.2f}A | "
            f"bat {rd(BAT + 'capacity')}% {num(BAT + 'current_now', 1e6):+.2f}A {num(BAT + 'voltage_now', 1e6):.3f}V "
            f"{num(BAT + 'temp', 10):.1f}C | dpms {rd(DPMS)}")


if not os.path.isdir(SYSDEV):
    sys.exit(f"no {DEV}: the channel is gone (closed earlier in this boot?) - only a reboot brings it back")
if not os.path.islink(SYSDEV + "/driver"):
    with open(SYSDEV + "/driver_override", "w") as f:
        f.write("rpmsg_chrdev")
    with open(DRV + "/bind", "w") as f:
        f.write(DEV)
elif os.path.basename(os.readlink(SYSDEV + "/driver")) != "rpmsg_chrdev":
    sys.exit(f"{DEV} is bound to {os.readlink(SYSDEV + '/driver')}, not rpmsg_chrdev")
node = None
for _ in range(50):
    try:
        node = "/dev/" + os.listdir(SYSDEV + "/rpmsg")[0]
        if os.path.exists(node):
            break
    except OSError:
        pass
    node = None
    time.sleep(0.1)
if not node:
    sys.exit("bound, but no /dev/rpmsgN appeared")

out = open(time.strftime("/root/chg-ulog-%m%d-%H%M.txt"), "w", buffering=1)


def log(s):
    if not QUIET:
        print(s, flush=True)
    out.write(s + "\n")


log(f"chg-ulog {time.strftime('%F %T')}  {node}  {secs:g}s INT={INT:g}\n{state()}")
fd = os.open(node, os.O_RDWR)
seen = []                                       # print only lines not seen in an earlier answer
end = time.monotonic() + secs
try:
    while time.monotonic() < end:
        os.write(fd, struct.pack("<IIII", OWNER_CHG_ULOG, TYPE_REQ_RESP, GET_CHG_ULOG, ULOG_SIZE))
        r, _, _ = select.select([fd], [], [], 3)
        if not r:
            log(f"{time.strftime('%T')} (no answer in 3 s)")
            continue
        data = os.read(fd, 65536)
        owner, typ, op = struct.unpack_from("<III", data)
        if op != GET_CHG_ULOG:
            log(f"{time.strftime('%T')} unexpected owner {owner} type {typ} opcode {op:#x} len {len(data)}")
            continue
        text = data[12:].split(b"\0", 1)[0].decode(errors="replace")
        new = [l for l in text.splitlines() if l.strip() and l not in seen]
        if new:
            log(f"--- {time.strftime('%T')}  {state()}")
            for l in new:
                log(l)
            seen = (seen + new)[-4000:]
        time.sleep(INT)
finally:
    os.close(fd)
    log(f"done {time.strftime('%T')}  (channel stays bound to rpmsg_chrdev until reboot, see the docstring)")
