#!/usr/bin/env python3
"""Make the owner's Chrome launchers draw through zink (OpenGL on the tb323fu Turnip Vulkan driver)
instead of the distribution's freedreno GL (Mesa 26.0.8), which hangs the Adreno 840 when a heavy page
is touch-scrolled (2026-10-14: 40+ "hangcheck recover" in one evening; the same finger test
on zink: 0, VA-API hardware decoding unchanged).

Prefixes `env MESA_LOADER_DRIVER_OVERRIDE=zink` to every Exec= line that starts Chrome in the user's
launchers (~/.local/share/applications/{google-chrome,com.google.Chrome}.desktop and the copy on the
desktop). Idempotent; first run keeps a .y700bak-zink copy. `--undo` takes the prefix out again.
Run as the owner (or root with HOME pointing at the owner's home). Chrome must be fully quit and
started again for it to apply."""
import os, re, shutil, sys

PREFIX = "env MESA_LOADER_DRIVER_OVERRIDE=zink "
home = os.environ.get("HOME", "/home/user")
files = [os.path.join(home, ".local/share/applications/google-chrome.desktop"),
         os.path.join(home, ".local/share/applications/com.google.Chrome.desktop"),
         os.path.join(home, "Desktop/google-chrome.desktop")]
undo = "--undo" in sys.argv
starts_chrome = re.compile(r"^Exec=(?:env MESA_LOADER_DRIVER_OVERRIDE=zink )?(/usr/bin/google-chrome|/opt/google/chrome/)")

for path in files:
    if not os.path.exists(path):
        print(f"skip (missing) {path}")
        continue
    lines = open(path, encoding="utf-8").read().split("\n")
    n = 0
    for i, ln in enumerate(lines):
        if not starts_chrome.match(ln):
            continue
        has = ln.startswith("Exec=" + PREFIX)
        if undo and has:
            lines[i] = "Exec=" + ln[len("Exec=" + PREFIX):]; n += 1
        elif not undo and not has:
            lines[i] = "Exec=" + PREFIX + ln[len("Exec="):]; n += 1
    if n:
        # never next to the desktop copy: Plasma sniffs the content and shows the backup as a second
        # (old, non-zink) Chrome icon on the desktop (seen 2026-10-14)
        bak = path + ".y700bak-zink"
        if os.path.dirname(path) == os.path.join(home, "Desktop"):
            os.makedirs(os.path.join(home, ".local/share/y700-backups"), exist_ok=True)
            bak = os.path.join(home, ".local/share/y700-backups", os.path.basename(path) + ".y700bak-zink")
        if not undo and not os.path.exists(bak):
            shutil.copy2(path, bak)
        st = os.stat(path)
        open(path, "w", encoding="utf-8").write("\n".join(lines))
        os.chown(path, st.st_uid, st.st_gid)
    print(f"{'undid' if undo else 'patched'} {n} Exec line(s) in {path}")

# Plasma launches from its service cache (ksycoca), not from the .desktop files, and the cache file is
# keyed by LANG + XDG_DATA_DIRS: a kbuildsycoca6 run from ssh/sudo writes a DIFFERENT cache file and the
# menu keeps the old Exec (2026-10-14: the owner's Chrome came up without zink 5 minutes after the patch).
# Rebuild it with plasmashell's own environment.
import subprocess
try:
    pid = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "plasmashell"], capture_output=True,
                         text=True).stdout.split()[0]
    env = dict(kv.split("=", 1) for kv in open(f"/proc/{pid}/environ").read().split("\0") if "=" in kv)
    subprocess.run(["kbuildsycoca6"], env=env, capture_output=True, timeout=120)
    print("rebuilt Plasma's service cache with the session environment")
except Exception as e:
    print(f"could not rebuild Plasma's service cache ({e!r}): log out and in, or run kbuildsycoca6 in the session")
