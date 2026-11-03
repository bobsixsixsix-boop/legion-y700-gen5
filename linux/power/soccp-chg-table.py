#!/usr/bin/env python3
"""Charging table from a soccp-chg-ulog.py capture, offline (Win11 or tablet), standard library only.

    python -X utf8 -I soccp-chg-table.py chg-ulog-MMDD-HHMM.txt[.gz] [BIN_S]     (default 30 s bins)

One row per bin: SoC, screen, port, mode, input (VBUS x IBUS), battery (VBAT x IBAT), TBAT, and the firmware's own
limits at the end of the bin (PD request, the Lenovo charge-pump limits ibus/fcc, the buck's set_usb_icl/set_wls_icl).
Mode CP = the two charge pumps (PPS; input from mcp_lenovo_update_info, Linux cannot read it); buck = the main
charger (fixed PD / 5 V; input from battmgr USB voltage_now x current_now on the "---" lines). Battery power:
mcp_lenovo_update_info when present, else battmgr bat current x voltage ("---" lines from 2026-11-03 on carry V and
dpms; older captures have neither, so their buck rows show no battery W or screen). Mode ? = no input reading in
the bin (the firmware did not log the pumps then)."""
import gzip, re, sys

R_POLL = re.compile(r"^--- (\d\d:\d\d:\d\d)\s+usb ([\d.]+)V ([\d.-]+)A.*?\| bat (\d+)% ([+-][\d.]+)A (?:([\d.]+)V )?([\d.]+)C"
                    r"(?:.*\| dpms (\w+))?")
R_CP1 = re.compile(r"SOC = \[(\d+)\], VBAT = \[(\d+)mV.*IBAT = \[(-?\d+)mA.*TBAT = \[(\d+)\]")
R_CP2 = re.compile(r"IBUS:\[(-?\d+) .*VBUS:\[(\d+)\]")
R_LIM = re.compile(r"limit: vbat = \[(\d+)\], ibat = \[(\d+) .*ibus = \[(\d+)\], fcc = \[(\d+)\]")
R_REQ = re.compile(r"PortNum=(\d), PD Contract request: voltage=(\d+) mV, Current=(\d+) mA, bPPS=(\d)")
R_ICL = re.compile(r"\bset_(usb|wls)_icl: (?:icl_ma:|wls_icl = )(\d+)")


def sec(hms):
    h, m, s = map(int, hms.split(":"))
    return h * 3600 + m * 60 + s


def rows(path):
    """Yield (t, kind, values) in file order; firmware lines get the time of the poll line above them."""
    t = None
    with (gzip.open(path, "rt", errors="replace") if path.endswith(".gz") else open(path, errors="replace")) as f:
        for line in f:
            m = R_POLL.match(line)
            if m:
                t = sec(m[1])
                yield t, "poll", m.groups()
                continue
            if t is None:
                continue
            for kind, rx in (("cp1", R_CP1), ("cp2", R_CP2), ("lim", R_LIM), ("req", R_REQ), ("icl", R_ICL)):
                m = rx.search(line)
                if m:
                    yield t, kind, m.groups()
                    break


def mean(xs):
    return sum(xs) / len(xs) if xs else None


def f(x, fmt):
    return format(x, fmt) if x is not None else "-".rjust(len(format(0, fmt)))


def table(path, bin_s=30):
    out = [f"{'time':8} {'SoC':>4} {'scr':>3} {'mode':>4} {'Vin':>5} {'Iin':>5} {'Pin W':>5} {'Vbat':>5} {'Ibat':>5} "
           f"{'Pbat W':>6} {'Tbat':>5}  firmware limits at bin end"]
    cur, b = None, None
    lim = {"req": "-", "cp": "-", "icl": {}}

    def flush():
        if not b or not (b["cp_in"] or b["buck_in"] or b["bat"]):
            return
        cp = bool(b["cp_in"])
        pin = mean([v * i for v, i in (b["cp_in"] if cp else b["buck_in"])])
        vin = mean([v for v, _ in (b["cp_in"] if cp else b["buck_in"])])
        iin = mean([i for _, i in (b["cp_in"] if cp else b["buck_in"])])
        bat = b["cp_bat"] or b["bat"]
        vb, ib = mean([v for v, _, _ in bat if v]), mean([i for _, i, _ in bat])
        pb = mean([v * i for v, i, _ in bat if v])
        tb = mean([t for _, _, t in bat])
        icl = " ".join(f"{k}_icl={v}" for k, v in sorted(lim["icl"].items()))
        out.append(f"{b['hms']:8} {b['soc']:>3}% {b['dpms'][:3]:>3} {'CP' if cp else 'buck' if b['buck_in'] else '?':>4} {f(vin, '5.2f')} "
                   f"{f(iin, '5.2f')} {f(pin, '5.1f')} {f(vb, '5.3f')} {f(ib, '5.2f')} {f(pb, '6.1f')} {f(tb, '5.1f')}  "
                   f"req {lim['req']}  cp {lim['cp']}  {icl}")

    for t, kind, v in rows(path):
        k = t // bin_s
        if k != cur:
            flush()
            cur = k
            b = {"hms": "%02d:%02d:%02d" % (k * bin_s // 3600, k * bin_s // 60 % 60, k * bin_s % 60),
                 "soc": "?", "dpms": "?", "cp_in": [], "buck_in": [], "cp_bat": [], "bat": []}
        if kind == "poll":
            _, uv, ua, soc, ba, bv, bt, dpms = v
            b["soc"], b["dpms"] = soc, dpms or "?"
            if float(ua) > 0.05:
                b["buck_in"].append((float(uv), float(ua)))
            b["bat"].append((float(bv) if bv else None, float(ba), float(bt)))
        elif kind == "cp1":
            b["soc"] = v[0]
            b["cp_bat"].append((int(v[1]) / 1000, int(v[2]) / 1000, int(v[3]) / 10))
        elif kind == "cp2" and int(v[0]) > 50:
            b["cp_in"].append((int(v[1]) / 1000, int(v[0]) / 1000))
        elif kind == "lim":
            lim["cp"] = f"ibus<={v[2]} fcc={v[3]} vbat<={v[0]}"
        elif kind == "req":
            lim["req"] = f"p{v[0]} {int(v[1]) / 1000:.2f}V {int(v[2]) / 1000:.1f}A {'PPS' if v[3] == '1' else 'fixed'}"
        elif kind == "icl":
            lim["icl"][v[0]] = v[1]
    flush()
    return out


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        import os, tempfile
        sample = ("--- 14:00:55  usb 9.19V 0.00A vmax 9600000 imax 3000000 type x | bat 90% +3.64A 32.5C\n"
                  "0x1: Info: mcp_lenovo_update_info: [LENOVO_ICM_CP] SOC = [90], VBAT = [4472mV 4464mV 4472mV], "
                  "IBAT = [5278mA 2800mA 2478mA], TBAT = [325], CYCLE =[x\n"
                  "0x2: Info: mcp_lenovo_update_info: [LENOVO_ICM_CP] IBUS:[2952 1495 1457 0] VBUS:[9258] CHGR_STAT:[3]\n"
                  "0x3: Info: mcp_lenovo_sub_charging_main: [LENOVO_ICM_CP] limit: vbat = [4555], ibat = [8400 4680 4140], "
                  "ibus = [3000], fcc = [8400]\n"
                  "0x4: Info: ssdev_typec_pd_set_pd_contract: PortNum=0, PD Contract request: voltage=9652 mV, "
                  "Current=3000 mA, bPPS=1: PDO#3\n"
                  "--- 14:01:40  usb 8.66V 2.49A vmax 9000000 imax 3000000 type x | wls 0.00V 0.00A | "
                  "bat 75% +3.90A 4.190V 32.1C | dpms On\n"
                  "0x5: Info: set_usb_icl: icl_ma:2500, suspended:0, otg:0\n")
        p = os.path.join(tempfile.mkdtemp(), "t.txt")
        open(p, "w").write(sample)
        t = table(p)
        assert len(t) == 3, t
        assert " 90%   ?   CP  9.26  2.95  27.3 4.472  5.28   23.6  32.5  req p0 9.65V 3.0A PPS  cp ibus<=3000 fcc=8400" in t[1], t[1]
        assert " 75%  On buck  8.66  2.49  21.6 4.190  3.90   16.3  32.1" in t[2] and "usb_icl=2500" in t[2], t[2]
        print("selftest ok")
        sys.exit(0)
    for line in table(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 30):
        print(line)
