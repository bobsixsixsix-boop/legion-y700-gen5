#!/usr/bin/env python3
"""Set the launch options of a Steam-owned game (Steam must be shut down, it rewrites localconfig.vdf).
usage: steam-launchopts.py APPID [OPTIONS]   (empty OPTIONS clears them)
Finds the "APPID" block under Software/Valve/Steam/apps (indent 5 tabs, as Steam writes it),
replaces or adds its "LaunchOptions". Backup: localconfig.vdf.y700bak-<appid>"""
import glob, re, shutil, sys

appid = sys.argv[1]
opts = sys.argv[2] if len(sys.argv) > 2 else ""
S = "/home/user/.local/share/Steam"
# the account logged in last: loginusers.vdf entry with AutoLogin/MostRecent 1, else the newest Timestamp
# (SteamID64 -> account id = low 32 bits)
lu = open(S + "/config/loginusers.vdf", encoding="utf-8").read()
entries = re.findall(r'"(\d{17})"\s*\{([^}]*)\}', lu)
def ts(body):
    m = re.search(r'"Timestamp"\s*"(\d+)"', body); return int(m.group(1)) if m else 0
auto = [sid for sid, body in entries if re.search(r'"(AutoLogin|MostRecent)"\s*"1"', body)]
best = auto[0] if auto else (max(entries, key=lambda e: ts(e[1]))[0] if entries else None)
recent = [int(best) & 0xFFFFFFFF] if best else []
files = glob.glob(S + "/userdata/*/config/localconfig.vdf")
cand = [f for f in files if recent and "/userdata/%d/" % recent[0] in f] or files
assert len(cand) == 1, (cand, recent)
p = cand[0]
print("account", p.split("/")[-3])
t = open(p, encoding="utf-8").read()
m = re.search(r"\n(\t{5})\"%s\"\n\1\{\n" % re.escape(appid), t)
assert m, "no apps block for " + appid
ind = m.group(1)
start = m.end()
end = t.index("\n" + ind + "}", start)
block = t[start:end]
val = opts.replace("\\", "\\\\").replace('"', '\\"')
if '"LaunchOptions"' in block:
    block, n = re.subn(r'("LaunchOptions"\t\t)"(?:[^"\\]|\\.)*"', lambda mm: mm.group(1) + '"' + val + '"', block)
    assert n == 1, "LaunchOptions present but not replaced"
else:
    block = block + "\n" + ind + '\t"LaunchOptions"\t\t"' + val + '"'
shutil.copy2(p, p + ".y700bak-" + appid)
new = t[:start] + block + t[end:]
assert new.count("{") == new.count("}")
open(p, "w", encoding="utf-8").write(new)
print("LaunchOptions[%s] = %s" % (appid, opts or "(cleared)"))
