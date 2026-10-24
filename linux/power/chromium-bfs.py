#!/usr/bin/env python3
"""Start Chrome and the Claude desktop app with Chromium's frame-callback-driven begin-frame source
(--enable-features=WaylandExternalBeginFrameSource; upstream since 2026-05, still disabled by default in 155).
Without it Chromium paces its GPU-process compositor (VizCompositorTh) with a refresh-rate timer, so it keeps
waking 60-120 times a second while KWin 6.6 has the window xdg "suspended" (screen off, minimized, another
desktop): 12-40 mW here, and cpu0-5 / the system domain never power down. With it: 60 -> <2 wakeups/s
(Chrome 155, screen off, 2026-10-18, runs/day-20261018/bfstest-1224.txt; README "通用解法调研").

- Claude: installs /usr/local/bin/claude-desktop (claude-desktop-bfs next to this file). It comes before /usr/bin
  in the session PATH, and every Claude launcher says Exec=claude-desktop (the app rewrites its own .desktop,
  so editing that would not stick).
- Chrome: merges the feature into the --enable-features= list of every Exec line that starts Chrome in the
  owner's three launchers (the same set as linux/gpu/chrome-zink.py). Chrome honours only the LAST
  --enable-features switch, so adding a second one would silently drop WebRtcPipeWireCamera and the rest.
Idempotent; the first change keeps a .y700bak-bfs copy (the desktop copy's goes to ~/.local/share/y700-backups:
Plasma shows a backup on the desktop as a second icon). `--undo` reverses both. Run as root on the tablet.
Chrome / Claude must be fully quit and started again for it to apply."""
import os, re, shutil, subprocess, sys

FEATURE = "WaylandExternalBeginFrameSource"
home = "/home/user"
wrapper_src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "claude-desktop-bfs")
wrapper = "/usr/local/bin/claude-desktop"
files = [os.path.join(home, ".local/share/applications/google-chrome.desktop"),
         os.path.join(home, ".local/share/applications/com.google.Chrome.desktop"),
         os.path.join(home, "Desktop/google-chrome.desktop")]
undo = "--undo" in sys.argv
starts_chrome = re.compile(r"^Exec=(?:env \S+ )*(/usr/bin/google-chrome|/opt/google/chrome/)")


def with_feature(line, add):
    m = re.search(r"--enable-features=(\S+)", line)
    if m:
        feats = [f for f in m.group(1).split(",") if f and f != FEATURE] + ([FEATURE] if add else [])
        if feats:
            return line[:m.start(1)] + ",".join(feats) + line[m.end(1):]
        return (line[:m.start()].rstrip() + " " + line[m.end():].lstrip()).rstrip()
    if not add:
        return line
    end = line.find(" ", starts_chrome.match(line).start(1))  # right after the Chrome binary
    end = len(line) if end < 0 else end
    return line[:end] + " --enable-features=" + FEATURE + line[end:]


# Claude
if undo:
    if os.path.exists(wrapper) and FEATURE in open(wrapper).read():
        os.remove(wrapper)
        print(f"removed {wrapper}")
    else:
        print(f"{wrapper} is not ours or missing - left alone")
else:
    new = open(wrapper_src).read()
    if os.path.exists(wrapper) and open(wrapper).read() == new:
        print(f"{wrapper} already installed")
    else:
        if os.path.exists(wrapper) and FEATURE not in open(wrapper).read():
            sys.exit(f"{wrapper} exists and is not ours - not overwriting it")
        open(wrapper, "w").write(new)
        os.chmod(wrapper, 0o755)
        print(f"installed {wrapper}")

# Chrome
for path in files:
    if not os.path.exists(path):
        print(f"skip (missing) {path}")
        continue
    lines = open(path, encoding="utf-8").read().split("\n")
    n = 0
    for i, ln in enumerate(lines):
        if starts_chrome.match(ln):
            new = with_feature(ln, not undo)
            if new != ln:
                lines[i] = new; n += 1
    if n:
        bak = path + ".y700bak-bfs"
        if os.path.dirname(path) == os.path.join(home, "Desktop"):
            os.makedirs(os.path.join(home, ".local/share/y700-backups"), exist_ok=True)
            bak = os.path.join(home, ".local/share/y700-backups", os.path.basename(path) + ".y700bak-bfs")
        if not undo and not os.path.exists(bak):
            shutil.copy2(path, bak)
        st = os.stat(path)
        open(path, "w", encoding="utf-8").write("\n".join(lines))
        os.chown(path, st.st_uid, st.st_gid)
    print(f"{'undid' if undo else 'patched'} {n} Exec line(s) in {path}")

# Plasma launches from its service cache (ksycoca), keyed by LANG + XDG_DATA_DIRS: rebuild it as the owner with
# plasmashell's own environment, or the menu keeps the old Exec (linux/gpu/chrome-zink.py, 2026-10-14)
try:
    pid = subprocess.run(["pgrep", "-o", "-x", "plasmashell"], capture_output=True, text=True).stdout.split()[0]
    env = dict(kv.split("=", 1) for kv in open(f"/proc/{pid}/environ").read().split("\0") if "=" in kv)
    st = os.stat(f"/proc/{pid}")
    subprocess.run(["kbuildsycoca6"], env=env, user=st.st_uid, group=st.st_gid, extra_groups=[],
                   capture_output=True, timeout=120, check=True)
    print("rebuilt Plasma's service cache with the session environment")
except Exception as e:
    print(f"could not rebuild Plasma's service cache ({e!r}): log out and in, or run kbuildsycoca6 in the session")
