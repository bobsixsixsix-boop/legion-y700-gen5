#!/usr/bin/env python3
# Per session of a txdbg apjoin run: the WMI commands (>) and events (<) and HTT messages from the AP vdev's
# creation up to the first EAPOL frame, with names from wmi.h, times relative to the vdev create.
# Usage: wmi-seq.py <join dir> [k ...]      (default: every k*.log)
import re, sys, pathlib

H = pathlib.Path("/usr/local/src/linux-t47/drivers/net/wireless/ath/ath12k/wmi.h").read_text()
H = re.sub(r"/\*.*?\*/", "", H, flags=re.S)
grp = {}
for m in re.finditer(r"\b(WMI_GRP_\w+)\s*=\s*(0x[0-9a-fA-F]+|\d+|WMI_GRP_\w+)", H):
    v = m.group(2)
    grp[m.group(1)] = grp[v] if v in grp else int(v, 0)


def enum(name):
    body = re.search(r"enum " + name + r"\s*\{(.*?)\};", H, re.S).group(1)
    out, cur = {}, -1
    for ent in body.split(","):
        ent = re.sub(r"//.*", "", ent).strip()
        if not ent or ent.startswith("#"):
            continue
        if "=" in ent:
            k, v = [x.strip() for x in ent.split("=", 1)]
            g = re.match(r"(?:WMI_TLV_CMD|WMI_TLV_EV|WMI_EVT_GRP_START_ID)\((\w+)\)", v)
            a = re.match(r"(WMI_\w+)\s*\+\s*(\w+)$", v)
            if g:
                cur = (grp[g.group(1)] << 12) | 1
            elif a:
                cur = {n: i for i, n in out.items()}[a.group(1)] + int(a.group(2), 0)
            elif re.match(r"WMI_\w+$", v):
                cur = {n: i for i, n in out.items()}.get(v, cur)
            else:
                cur = int(v, 0)
        else:
            k = ent
            cur += 1
        out[cur] = k
    return out


CMD, EVT = enum("wmi_tlv_cmd_id"), enum("wmi_tlv_event_id")
TS = re.compile(r"^(\d\d):(\d\d):(\d\d\.\d+) ")
O = pathlib.Path(sys.argv[1])
ks = sys.argv[2:] or sorted((p.stem[1:] for p in O.glob("k*.log")), key=int)
for k in ks:
    lines = (O / f"k{k}.log").read_text(errors="replace").splitlines()
    tl = []
    for ln in lines:
        m = TS.match(ln)
        if m:
            tl.append((int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3)), ln))
    t0 = next((t for t, ln in tl if "y700dbg: vdev create" in ln and "type 1" in ln), tl[0][0] if tl else 0)
    print(f"===== s{k}")
    for t, ln in tl:
        rel = f"{t - t0:8.3f}"
        w = re.search(r"y700wmi: ([<>]) ([0-9a-f]+) len (\d+) ?(.*)", ln)
        if w:
            d, i = w.group(1), int(w.group(2), 16)
            name = (CMD if d == ">" else EVT).get(i, hex(i))
            print(rel, d, name.replace("_CMDID", "").replace("_EVENTID", ""), w.group(3), w.group(4)[:96])
            continue
        h = re.search(r"y700htc: type ([0-9a-f]+) len (\d+) (.*)", ln)
        if h:
            print(rel, "H", "htt", h.group(1), h.group(2), h.group(3)[:96])
            continue
        if "y700tx: p 888e" in ln:
            print(rel, "EAPOL TX")
            break
        d = re.search(r"y700dbg: (.*)", ln)
        if d:
            print(rel, "#", d.group(1)[:110])
