# sb-bed scenario (11-10): the shellbar's three D-Bus methods that split screen's 「选择另一个应用」 calls
# (linux/split, KWin script y700-split; src/shell.h): dockApps() -> JSON, wallpaperUrl() -> file:// URL, launchApp(id).
#   SB_BAR=/tmp/y700sp2/b-sb/y700-shellbar SB_SPLIT=/tmp/y700sp2/linux/split/y700-split \
#     sh ./sb-bed.sh splitpick.sh /root/sb-splitpick      (root; chmod -R a+rX the checkout first: the bed runs as user)
# (SB_BAR a build with the default prefix: its QML is the installed one, which this change does not touch; leave it
# out once installed.) No tap anywhere: split screen is asked for by its shortcut on the bed's bus, so nothing on
# the tablet's screen moves and there is no haptic tick. Nothing is launched (launchApp gets an id the dock has not).
# Steps (OUT/*.png):
#   q0          dockApps: a JSON array, not empty, every entry with id, name and icon; wallpaperUrl: the picture of
#               the appletsrc this scenario writes (as stageback.sh: a Chinese file name, as on the tablet)
#   q1-pick     Kate up, the shortcut: Kate on the left half, the picker on the right over the blurred wallpaper with
#               the dock's apps under 「其他应用」 (look at the shot: the picker logs no list)
#   q2          launchApp with an id the dock has not: one "launch: no app" line from the bar, which still answers
# A failed check prints SBBED_EXPECT_FAIL (the bed's verdict); "splitpick.sh: ..." lines are notes.
say() { echo "splitpick.sh: $*"; echo "splitpick.sh: $*" >> "$LOG"; }
bad() { echo "SBBED_EXPECT_FAIL: splitpick.sh: $*"; echo "splitpick.sh: FAIL $*" >> "$LOG"; FAIL=1; }
sbret() { busctl --user --json=short call fyi.y700.Shellbar /Shellbar fyi.y700.Shellbar "$@" 2>&1; }

if [ -z "${SB_SPLIT:-}" ] || [ ! -f "$SB_SPLIT/contents/ui/Split.qml" ]; then
    bad "SB_SPLIT='${SB_SPLIT:-}' has no contents/ui/Split.qml"; return 0
fi
RC=$T/config/plasma-org.kde.plasma.desktop-appletsrc
cp "$T/wall.png" "$T/data/测试壁纸.png"
printf '[Containments][1]\nwallpaperplugin=org.kde.image\n\n[Containments][1][Wallpaper][org.kde.image][General]\nImage=file://%s\n' "$T/data/测试壁纸.png" > "$RC"
mkdir -p "$T/data/kwin/scripts" && cp -r "$SB_SPLIT" "$T/data/kwin/scripts/y700-split"
kwriteconfig6 --file kwinrc --group Plugins --key y700-splitEnabled true
kwriteconfig6 --file kwinrc --group Script-y700-split --key Debug true
mark load
# by path, as splittile.sh (a package copied in after the bed's KWin started is not loaded by reconfigure)
busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting loadDeclarativeScript ss \
    "$T/data/kwin/scripts/y700-split/contents/ui/main.qml" y700-split >/dev/null 2>&1
busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting start >/dev/null 2>&1
sleep 1.5
expect 'y700-split: loaded'

# ---------------- q0: the two getters
APPS=$(sbret dockApps)
CHK=$(printf '%s' "$APPS" | python3 -I -c 'import sys, json
try:
    a = json.loads(json.loads(sys.stdin.read())["data"][0])
except Exception as e:
    print("BAD not JSON: %s" % e); sys.exit()
if not isinstance(a, list) or not a:
    print("BAD empty or not a list"); sys.exit()
miss = [x.get("id", "?") for x in a if not (x.get("id") and x.get("name") and x.get("icon"))]
print(("BAD without id / name / icon: %s" % " ".join(miss)) if miss else "OK %d apps: %s" % (len(a), " ".join(x["id"] for x in a)))')
say "q0 dockApps: $CHK"
case "$CHK" in OK*) ;; *) bad "q0: dockApps answered '$APPS' ($CHK)" ;; esac
WALL=$(sbret wallpaperUrl | python3 -I -c 'import sys, json
try: print(json.loads(sys.stdin.read())["data"][0])
except Exception as e: print("BAD %s" % e)')
say "q0 wallpaperUrl: $WALL"
[ "$WALL" = "file://$T/data/测试壁纸.png" ] || bad "q0: wallpaperUrl is '$WALL', not the appletsrc's file://$T/data/测试壁纸.png"

# ---------------- q1: the picker
mark q1
app Kate '#3d7bf7'
sleep 0.5
busctl --user call org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component invokeShortcut s y700-split >/dev/null 2>&1 \
    || say "q1: invokeShortcut failed"
sleep 2
shot q1-pick
expect 'y700-split: state pick mode=pick pair= pick=Kate/0'
reject 'y700-split: toast'

# ---------------- q2: launchApp with an id the dock has not
mark q2
busctl --user call fyi.y700.Shellbar /Shellbar fyi.y700.Shellbar launchApp s y700-splitpick-none.desktop >/dev/null 2>&1 \
    || bad "q2: launchApp failed on the bus"
sleep 0.5
sbexpect 'launch: no app y700-splitpick-none.desktop'
case "$(sbret dockApps)" in *'"data"'*) ;; *) bad "q2: the bar does not answer dockApps after launchApp" ;; esac
say "done (FAIL=$FAIL)"
