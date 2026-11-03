# sb-bed scenario (10-23): the control centre's 「后台应用」, the tray moved into the controls (README stage 4: 托盘
# （StatusNotifierItem）挪进控制中心), against fake-sni.py (a StatusNotifierWatcher and fake tray items on the bed's own
# bus, modelled on the live tray of 10-23: Electron's Claude, fcitx, and made-up ones; see its header).
#   SB_CC=/opt/y700-next/bin/y700-control-center sh ./sb-bed.sh tray.sh /root/sb-tray     (root; under 2 min of the
#   bed's 180 s; the shots, the control centre's and the fake's lines are in /root/sb-tray, the verdict on stdout)
# Checks the control centre's stderr lines ("tray: + KEY LABEL", "tray: - KEY", "tray: host registered as NAME",
# "tray: icon KEY theme NAME|pixmap WxH|none", "tray: activate KEY -> ok|error NAME|timeout", "tray: token KEY yes|no",
# "tray: menu KEY N rows depth D", "tray: labels KEY DEPTH TITLE :: ROW|ROW|...", "tray: click KEY ID", and
# "toast: TEXT" for what the user is told) against the fake's ("SNI <item> <Method> <args>"; KEY is taken from the
# "tray: +" line of the item's label), and reads every shot with tray-look.py (written below into the bed: the tray
# tiles in colA, the menu page's rows in colB, the power card; its lines go to the log as "tray-look <shot>: ...").
# Coordinates come from the shots, not from the contract: the tray tiles are the light runs between the Tailscale
# tile (y 276-335) and the power row (800-859 since 11-01, 766-825 before) in colA's three 104 px columns (x 840 / 958 / 1076), the menu rows the
# runs under the back button in colB (x 1204-1544, rows tapped at x 1374). Nothing is tapped that was not seen: the
# bed's control centre shows and switches the REAL system (its commands run in the bed's environment but against
# the real system bus and daemons: Wi-Fi, Bluetooth, Tailscale, power). A blind tap on the back button's spot
# (1222, 180) with the grid up turns the real Wi-Fi off, one on the Tailscale tile drops the ssh path. So a menu row
# or the back button is tapped only when the last shot showed the menu page (else the curtain is closed and opened
# again, which leaves any page), a tray tile only when the last shot found it between the two anchors, and the power
# card is closed by closing the curtain, never by a tap inside it (息屏 / 锁屏 there need no second tap).
# The curtain is opened over D-Bus (show), not pulled (curtain.sh covers the pull), so every touch lands on the
# open curtain; the holding finger is long-pressed on its empty left half (300, 700), which is no tap there.
# Steps and shots (OUT/*.png):
#   t0-none            the controls, no watcher on the bus (the control centre must not be one): no section
#   t1-tray            the fake comes up while they are open, three items already in its list (a host started after
#                      the apps: read from the list, "SNI watcher list 3"), three registering after the host did (the
#                      Registered signal); the host's name passes kded6's check; 5 tiles (not the Passive one), 3 + 2,
#                      whole (84 high), Claude's IconPixmap drawn (orange), the theme icons found ("tray: icon"), the
#                      attention dot on 提醒, 无激活 without an icon: the letter in a disc; 提醒 refuses GetAll (read one
#                      property at a time)
#   (tap Claude)       a token for our window first, then Activate (one connection: in order); the curtain closes
#   t2-claude-menu     long press: the real Claude menu, 7 rows, its labels; LayoutUpdated re-reads it; a disabled
#                      row does nothing; 「显示应用」 = Event 11 clicked, the curtain closes (Event 0 closed)
#   (closed)           a NewTitle while closed: not even heard; the next show reads every item
#   t3-fcitx-menu      long press: AboutToShow before GetLayout (fcitx fills its menu then), 中州韵's radio accent,
#                      the mnemonic stripped, every label on one line (LX: the icon column kept on rows without one);
#   t4-fcitx-sub       the submenu 雾凇拼音 (AboutToShow 305 + GetLayout 305, depth 1);
#   t4b-fcitx-back     back = the root again; t4c-fcitx-closed: back at the root = the grid, the curtain still open
#   t4d-folder-menu    ItemIsMenu: a tap opens the menu, Activate never called; the invisible item left out, "__"
#   t5-noact-fallback  Activate answers UnknownMethod: its menu instead, separators collapsed (item, one, item)
#   t5i-attention      a new IconName read and drawn (fcitx: configure); 文件夹 turns NeedsAttention: dots on 3 and 4
#   t5a-anim           an item whose icon changes 30 times a second (Spectacle's while it records): 6 whole tiles,
#                      read 2-5 times in 3 s; t5b-anim-menu: a long press on it holds (its tile is not made anew per
#                      frame); closed: not read at all and its signals' match rules dropped; read again on the show
#   t10-overflow       7 apps: 5 tiles + 「全部 7 个」; t10a-trayall: its list of 7 rows; t10b-slow-pending: 慢's row
#                      dimmed while its Activate is out (it never answers); t10c-slow-toast: after 1 s 「慢」没有响应,
#                      the page kept; t10d-nomenu: 无菜单 (Activate refused, no menu): 「无菜单」不能从这里打开
#   t5p-power-5-tiles  the power card with two tile rows: whole, on the unchanged bottom line, under Tailscale, the
#                      section faded out
#   t6a-passive        Claude Passive (read again while open): 4 tiles; t6b-fcitx-menu-open: fcitx's menu up, then
#                      fcitx's connection closes: t6c-menu-gone: the page goes with it (the grid), the curtain stays
#   t6-after-remove    3 tiles, the dot on tile 2
#   t7-power-with-tray the power card again with one row
#   t8-gone            the whole fake quits (watcher and items): no section; t9-back: a fresh fake, the host
#                      registers with the new watcher, its list read, 5 whole tiles again
# A failed check prints SBBED_EXPECT_FAIL (the bed's verdict); "tray.sh: ..." lines are notes.
FK=$T/bin/fake-sni.py
LOOK=$T/run/tray-look.py
if [ ! -f "$FK" ]; then
    echo "SBBED_EXPECT_FAIL: tray.sh: no $FK (sb-bed.sh copies fake-sni.py from its own directory)"; FAIL=1; return 0
fi
cat > "$LOOK" <<'PY'
# tray-look.py MODE PNG (tray.sh writes it into the bed; MODE tiles | rows | power): reads the controls' layout off a
# bed screenshot (1600x1002, the curtain open on the controls), so the scenario taps what is on the screen instead of
# what the contract predicts. A tile or row is lighter than the bare curtain next to it (white at 7-14 % over the
# tinted blur; accent when on): per pixel row, the mean luma of a narrow band just inside a column's edge minus that
# of a band of bare curtain beside the column; a run of pixel rows above THR is one tile / row / hairline. Prints
# "KEY values" lines for tray.sh's val(); INFO lines are only for the log.
import sys
import numpy as np
from PIL import Image

MODE, PNG = sys.argv[1], sys.argv[2]
img = np.asarray(Image.open(PNG).convert("RGB")).astype(np.float32)
luma = img @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
THR = 6.0
Y0, Y1 = 150, min(1000, img.shape[0])
# the far column (colA, x 840-1180): three tray tiles of 104 a row, 14 apart; each with the reference band left of it
# (bare curtain left of colA, then the 14 px gaps between the tiles)
TCOLS = [(840, (822, 832)), (958, (946, 956)), (1076, (1064, 1074))]
ACCENT = (46, 107, 246)
ORANGE = (217, 119, 87)       # fake-sni.py's Claude icon (IconPixmap)


def band(x0, x1, r0, r1):
    return luma[Y0:Y1, x0:x1].mean(axis=1) - luma[Y0:Y1, r0:r1].mean(axis=1)


def segs(on):
    out = []
    start = None
    for i, v in enumerate(on):
        if v and start is None:
            start = i
        elif not v and start is not None:
            out.append([Y0 + start, Y0 + i - 1])
            start = None
    if start is not None:
        out.append([Y0 + start, Y1 - 1])
    merged = []
    for r in out:              # a glyph crossing the band splits a run by a pixel or two
        if merged and r[0] - merged[-1][1] <= 3:
            merged[-1][1] = r[1]
        else:
            merged.append(r)
    return merged


def near(rgb, x0, x1, y0, y1, tol):
    box = img[y0:y1, x0:x1]
    return int((np.abs(box - np.array(rgb, dtype=np.float32)).max(axis=2) < tol).sum())


def ln(a, b):
    return b - a + 1


def colA():
    """col1's runs, the Tailscale tile (276-335) and the power row (800-859) as anchors"""
    rs = segs(band(852, 858, 822, 832) > THR)
    ts = next((r for r in rs if 268 <= r[0] <= 284 and 50 <= ln(*r) <= 70), None)
    pw = next((r for r in rs if 852 <= r[1] <= 868 and 50 <= ln(*r) <= 70), None)
    print("INFO col1 runs", " ".join("%d-%d" % tuple(r) for r in rs))
    return rs, ts, pw


def tray_tiles(lo, hi):
    """the tray tiles between y lo and hi, row-major: (top, bottom, column x0)"""
    found = []
    for x0, ref in TCOLS:
        for a, b in segs(band(x0 + 12, x0 + 18, *ref) > THR):
            if a >= lo and b <= hi and 40 <= ln(a, b) <= 92:    # 84, or a tile cut by something over it
                found.append((a, b, x0))
    found.sort()
    rows = []
    for t in found:
        if rows and t[0] - rows[-1][0][0] <= 6:
            rows[-1].append(t)
        else:
            rows.append([t])
    return [t for r in rows for t in sorted(r, key=lambda t: t[2])]


if MODE == "tiles":
    rs, ts, pw = colA()
    if not ts or not pw:
        print("LAYOUT bad")      # no Tailscale tile / power row where they belong: tray.sh taps nothing in colA
        print("TILES 0")
        sys.exit(0)
    print("LAYOUT ok")
    print("TS %d %d" % tuple(ts))
    print("POWER %d %d" % tuple(pw))
    tiles = tray_tiles(ts[1] + 6, pw[0] - 6)
    print("TILES %d" % len(tiles))
    print("TH", " ".join(str(ln(a, b)) for a, b, x0 in tiles))      # each tile's height: 84 whole
    dots = []
    for a, b, x0 in tiles:
        print("T %d %d" % (x0 + 52, (a + b) // 2))
        dots.append(near(ACCENT, x0 + 70, x0 + 102, a + 2, min(a + 34, b), 45))
    print("DOTS", " ".join(map(str, dots)))
    print("DOTAT", " ".join(str(i + 1) for i, n in enumerate(dots) if n >= 12))
    if tiles:
        a, b, x0 = tiles[0]
        print("ORANGE %d" % near(ORANGE, x0, x0 + 104, a, b + 1, 40))
    else:
        print("ORANGE 0")
elif MODE == "rows":
    # the thumb column (colB, x 1204-1544): a band 6 px inside each edge (an icon at the left or a chevron at the
    # right of a row then leaves the other one), references in the 24 px gap left of it and the margin right of it
    on = (band(1210, 1215, 1186, 1198) > THR) | (band(1534, 1539, 1556, 1570) > THR)
    rs = segs(on)
    grid = any(158 <= a <= 168 and 88 <= ln(a, b) <= 106 for a, b in rs)        # Wi-Fi | Bluetooth, 100 high
    back = any(158 <= a <= 174 and 18 <= ln(a, b) <= 38 and b <= 202 for a, b in rs)   # the 36 px back disc
    print("PAGE", "grid" if grid else "list" if back else "unknown")
    toks = []
    lx = []
    for a, b in rs:
        if a < 204:
            continue
        n = ln(a, b)
        if n <= 4:
            k = "s"
        elif 40 <= n <= 70:
            # accent = the row's fill is the opaque accent (a plain row is white over the blur, which can be blue too)
            box = np.concatenate([img[a:b + 1, 1210:1215], img[a:b + 1, 1534:1539]], axis=1).reshape(-1, 3).mean(axis=0)
            k = "a" if np.abs(box - np.array(ACCENT)).max() < 36 else "n"
            # where the row's content starts: the first column, from inside its left edge, with a pixel near the
            # row's middle well above the row's own fill (white text, a light icon)
            cy = (a + b) // 2
            ref = luma[cy - 5:cy + 6, 1207:1216].mean()
            hit = np.nonzero(luma[cy - 5:cy + 6, 1216:1500].max(axis=0) > ref + 50)[0]
            lx.append(str(1216 + int(hit[0])) if hit.size else "-1")
        else:
            k = "?%d" % n
        toks.append("%s:%d" % (k, (a + b) // 2))
    print("ROWS", " ".join(toks))
    print("LX", " ".join(lx))
    print("INFO colB runs", " ".join("%d-%d" % tuple(r) for r in rs))
elif MODE == "power":
    rs, ts, pw = colA()
    card = next((r for r in rs if r[1] >= 800 and ln(*r) >= 120), None)
    print("CARD %d %d" % tuple(card) if card else "CARD none")
    if ts:
        print("TS %d %d" % tuple(ts))
    print("TILESVISIBLE %d" % len(tray_tiles((ts[1] if ts else 336) + 6, card[0] - 4 if card else 760)))
else:
    sys.exit("tray-look.py: MODE is tiles, rows or power")
PY
HOLD_AT="300 700"; HOLD_MS=1000

say() { echo "tray.sh: $*"; echo "tray.sh: $*" >> "$LOG"; }
bad() { echo "SBBED_EXPECT_FAIL: tray.sh: $*"; echo "tray.sh: FAIL $*" >> "$LOG"; FAIL=1; }
cc() { busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter "$1" >/dev/null 2>&1 || say "cc $1 failed"; }
fake() { busctl --user call fyi.y700.FakeSni /FakeSni fyi.y700.FakeSni "$@" >/dev/null 2>&1 || say "fake $* failed"; }
startfake() { python3 "$FK" >> "$LOG" 2>&1 & }
# TEXT's count in the log since the mark; waitfor TEXT [N [S]]: until it is there N times (at most S s, default 5)
cnt() { tail -n +$((MARK + 1)) "$LOG" | grep -cF -- "$1"; }
waitfor() {
    tw=0
    while [ "$(cnt "$1")" -lt "${2:-1}" ]; do
        tw=$((tw + 1)); [ $tw -gt $((${3:-5} * 5)) ] && return 1
        sleep 0.2
    done
}
# A's first line since the mark comes before B's (both there)
lineof() { tail -n +$((MARK + 1)) "$LOG" | grep -nF -- "$1" | head -n 1 | cut -d: -f1; }
before() { la=$(lineof "$1"); lb=$(lineof "$2"); [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; }
# the key the control centre gave the item labelled $1 (its latest "tray: + KEY LABEL" line)
keyof() { grep -F "tray: + " "$LOG" | sed -n "s/^.*tray: + \([^ ]*\) $1\$/\1/p" | tail -n 1; }
# the curtain open? (KWin lists the control centre's window only while it is mapped; the mark stays where it is)
shown() { n0=$(wc -l < "$LOG"); wins; tail -n +$((n0 + 1)) "$LOG" | grep -qF "y700-control-center/"; }
# snap NAME MODE: a shot read by tray-look.py (MODE tiles | rows | power); val KEY: a value of that reading
snap() { shot "$1"; LK=$(python3 "$LOOK" "$2" "$OUT/$1.png" 2>&1); echo "$LK" | sed "s/^/tray-look $1: /" >> "$LOG"; }
val() { echo "$LK" | sed -n "s/^$1 //p" | head -n 1; }
# the control centre's match rules on the bus (the bed's dbus-daemon has the Debug.Stats interface): its D-Bus
# signal subscriptions, to see them dropped while the curtain is down
ccmatch() {
    own=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetNameOwner s fyi.y700.ControlCenter 2>/dev/null \
        | sed -n 's/^s "\(.*\)"$/\1/p')
    [ -n "$own" ] || return 0
    busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Debug.Stats GetConnectionStats s "$own" 2>/dev/null \
        | grep -o '"MatchRules" u [0-9]*' | sed 's/.* //'
}

# the tray tiles' centres from the last tiles shot, one "X Y" a line, row-major (= the watcher's order)
TL=""
tiles() { TL=$(echo "$LK" | sed -n 's/^T //p'); }
tilexy() { echo "$TL" | sed -n "${1}p"; }
tiletap() {
    tp=$(tilexy "$1")
    if [ -n "$tp" ]; then tap $tp; else bad "$2: no tray tile $1 on the last shot, not tapped"; return 1; fi
}
tilelong() {   # a long press: 1 s, the holding finger down first as for tap
    tp=$(tilexy "$1")
    if [ -z "$tp" ]; then bad "$2: no tray tile $1 on the last shot, not pressed"; return 1; fi
    printf 'd 1 %s\ns %s\nd 0 %s\ns 1000\nu 0\ns 30\nu 1\n' "$HOLD_AT" "$HOLD_MS" "$tp" | "$T/bin/ftouch"
}
# every tile on the last tiles shot whole: 84 high (82-86 with the band's anti-aliasing), none cut by its box
wholetiles() {
    for h in $(val TH); do
        if [ "$h" -lt 82 ] || [ "$h" -gt 86 ]; then bad "$1: a tray tile $h px high on the shot, 84 whole (heights: $(val TH))"; return; fi
    done
}
# the menu page on the last rows shot: its K-th row (separators not counted), its row pattern, its back button
onpage() { [ "$(val PAGE)" = list ]; }
rowy() { val ROWS | tr ' ' '\n' | grep -v -e '^s' -e '^$' | sed -n "${1}p" | cut -d: -f2; }
taprow() {
    ry=$(rowy "$1")
    if onpage && [ -n "$ry" ] && [ "$ry" -ge 204 ] && [ "$ry" -le 960 ]; then tap 1374 "$ry"
    else bad "$2: no row $1 on the last shot's menu page (PAGE $(val PAGE)), not tapped"; return 1; fi
}
back() {
    if onpage; then tap 1222 180; sleep 0.7
    else say "$1: no menu page on the last shot: the curtain closed and opened again instead of back"
        cc hide; sleep 0.8; cc show; sleep 0.9; fi
}
# pat NAME WANT: the rows read off the last shot are WANT (n a row, a an accent row = a checked radio / checkmark,
# s a separator); a hairline inset from the row edges is not seen there, so the rows alone matching passes with a note
pat() {
    if ! onpage; then bad "$1: no menu page on the shot (PAGE $(val PAGE))"; return 1; fi
    got=$(val ROWS | sed 's/:[0-9]*//g')
    [ "$got" = "$2" ] && return 0
    if [ "$(echo "$got" | tr -d 's ')" = "$(echo "$2" | tr -d 's ')" ]; then
        say "$1: rows '$got' (separators not seen at the row edges), want '$2'"; return 0
    fi
    bad "$1: menu rows '$got', want '$2'"; return 1
}
# lxcheck NAME KEY DEPTH: on the last rows shot, every row's content starts where its level puts it, against the
# level's last "tray: labels KEY DEPTH" line ("*" = an entry with an icon, "-" = a separator): no icon in the level,
# the labels at the row's inset (x 1220); some, the icon column kept on every row (a row without one: its label at
# 1252, after 22 + 10); a row with one starts at its icon (or its label, for an icon with a dark left edge)
lxcheck() {
    lbl=$(tail -n +$((MARK + 1)) "$LOG" | grep -F "tray: labels $2 $3 " | tail -n 1 | sed 's/^.* :: //')
    if [ -z "$lbl" ]; then bad "$1: no 'tray: labels $2 $3' line"; return; fi
    r=$(printf '%s\n%s\n' "$lbl" "$(val LX)" | awk '
        NR == 1 { n = split($0, p, "|"); k = 0; icons = 0
                  for (i = 1; i <= n; i++) if (p[i] != "-") { k++; q[k] = p[i]; if (substr(p[i], 1, 1) == "*") icons = 1 } }
        NR == 2 { m = split($0, x, " ")
                  if (m != k) { print k " labels, " m " rows read off the shot"; exit }
                  for (i = 1; i <= k; i++) {
                      lo = 1218; hi = 1236
                      if (substr(q[i], 1, 1) == "*") hi = 1268
                      else if (icons) { lo = 1250; hi = 1268 }
                      if (x[i] + 0 < lo || x[i] + 0 > hi) { print "row " i " (" q[i] ") starts at x " x[i] ", want " lo "-" hi; exit }
                  } }')
    [ -z "$r" ] || bad "$1: $r"
}
# powertest NAME: the power button (seen in t1) opens the card: whole (~250 high), its bottom on the line the power
# row had, below the Tailscale tile, no tray tile left visible; closed again by closing the curtain
powertest() {
    if [ -z "$PW" ]; then bad "$1: the power row was not seen in t1, not tapped"; return; fi
    tap 870 "$PWY"; sleep 0.7
    snap "$1" power
    pcard=$(val CARD)
    if [ -z "$pcard" ] || [ "$pcard" = none ]; then bad "$1: no power card on the shot"
    else
        c0=${pcard% *}; c1=${pcard#* }
        [ $((c1 - PW1)) -ge -3 ] && [ $((c1 - PW1)) -le 3 ] || bad "$1: the card ends at y $c1, the bottom line was $PW1"
        [ $((c1 - c0 + 1)) -ge 240 ] || bad "$1: the card shows $((c1 - c0 + 1)) px of its ~250 (squeezed or clipped)"
        [ "$c0" -gt $((TS1 + 8)) ] || bad "$1: the card (top $c0) runs into the Tailscale tile (bottom $TS1)"
    fi
    [ "$(val TILESVISIBLE)" = 0 ] || bad "$1: $(val TILESVISIBLE) tray tiles still visible with the card open"
    cc hide; sleep 0.8; cc show; sleep 0.9
}

# ---------------- t0: no watcher yet (the control centre must not be one), the controls without a section
mark t0
if busctl --user status org.kde.StatusNotifierWatcher >/dev/null 2>&1; then
    bad "t0: org.kde.StatusNotifierWatcher has an owner before fake-sni.py: $(busctl --user status org.kde.StatusNotifierWatcher 2>/dev/null | grep -E '^(PID|Comm)=' | tr '\n' ' ')"
fi
cc show; sleep 1
shown || bad "t0: the controls did not open (show)"
snap t0-none tiles
[ "$(val LAYOUT)" = ok ] || bad "t0: the Tailscale tile / power row not where tray-look.py expects them: colA is read wrong"
[ "$(val TILES)" = 0 ] || bad "t0: $(val TILES) tray tiles without any item"
grep -qF "tray: + " "$LOG" && bad "t0: 'tray: +' lines without a watcher"

# ---------------- t1: the fake comes up while the controls are open
mark t1
startfake
waitfor "FAKESNI READY" 1 10 || bad "t1: fake-sni.py not ready ($(grep -F FAKESNI "$LOG" | tail -n 1))"
waitfor "tray: + " 5 5 || bad "t1: $(cnt 'tray: + ') of 5 items added"
sleep 0.4
expect "SNI watcher RegisterStatusNotifierHost"
expect "tray: host registered as"
# kded6 takes a host only by a name of its form that has an owner, and says nothing either way
expect "SNI watcher host added org.kde.StatusNotifierHost-"
reject "SNI watcher host ignored"
# the three that were there before the host: from the list it read (they never register again); the other three by
# the Registered signal
expect "SNI watcher list 3"
[ "$(cnt 'SNI watcher RegisterStatusNotifierItem')" = 3 ] || bad "t1: $(cnt 'SNI watcher RegisterStatusNotifierItem') registrations, the fake makes 3 after the host (3 were in its list)"
# 提醒 has no GetAll: one property at a time
expect "SNI alert GetAll refused"
expect "SNI alert Get Title"
# the Passive one may be announced (known, only not shown): that it is hidden is the shot's business (5 tiles)
[ "$(cnt 'tray: + ')" -le 6 ] || bad "t1: $(cnt 'tray: + ') items added, the fake has 6"
keys() { KC=$(keyof Claude); KF=$(keyof 输入法); KD=$(keyof 文件); KA=$(keyof 提醒); KN=$(keyof 无激活); }
tw=0; keys
while [ -z "$KC" ] || [ -z "$KF" ] || [ -z "$KD" ] || [ -z "$KA" ] || [ -z "$KN" ]; do
    tw=$((tw + 1)); [ $tw -gt 10 ] && break
    sleep 0.2; keys
done
say "keys: Claude=$KC 输入法=$KF 文件=$KD 提醒=$KA 无激活=$KN"
[ -n "$KC" ] || bad "t1: no item labelled Claude (Electron: Title empty, no IconName -> the ToolTip's title)"
[ -n "$KF" ] && [ -n "$KD" ] && [ -n "$KA" ] && [ -n "$KN" ] || bad "t1: not every item has its Title as the label"
# where each icon came from: Electron's pixmap, theme names (the attention one for 提醒), none (the letter)
expect "tray: icon $KC pixmap 64x64"
expect "tray: icon $KF theme input-keyboard"
expect "tray: icon $KD theme folder"
expect "tray: icon $KA theme dialog-warning"
expect "tray: icon $KN none"
sleep 0.3
snap t1-tray tiles
tiles
[ "$(val TILES)" = 5 ] || bad "t1: $(val TILES) tray tiles on the shot, want 5 (3 + 2)"
wholetiles t1
[ "$(val ORANGE)" -ge 150 ] 2>/dev/null || bad "t1: Claude's IconPixmap (an orange disc) not on the first tile ($(val ORANGE) px; ARGB32 in network byte order?)"
[ "$(val DOTAT)" = 4 ] || bad "t1: the attention dot on tile(s) '$(val DOTAT)', want 4 (提醒, NeedsAttention)"
PW=$(val POWER); TS=$(val TS)
if [ -n "$PW" ] && [ -n "$TS" ]; then PW1=${PW#* }; PWY=$(( (${PW% *} + ${PW#* }) / 2 )); TS1=${TS#* }; else PW=""; fi

# ---------------- a tap on Claude: our token first, then Activate; ok -> the curtain closes
# (each step below checks only when its tile was there to touch: a missing tile is one failure, not a page of them)
mark claude-tap
if tiletap 1 claude-tap; then
    sleep 1.2
    expect "SNI claude ProvideXdgActivationToken token="
    reject "SNI claude ProvideXdgActivationToken token=EMPTY"
    expect "SNI claude Activate "
    expect "tray: token $KC yes"
    expect "tray: activate $KC -> ok"
    before "SNI claude ProvideXdgActivationToken" "SNI claude Activate " || bad "claude-tap: the token did not come before Activate"
    [ "$(cnt 'token=not-gran')" = 0 ] || say "WARN claude-tap: KWin refused the token (not-granted-666): the app cannot raise itself"
    axy=$(tail -n +$((MARK + 1)) "$LOG" | sed -n 's/^SNI claude Activate \([-0-9]*\) \([-0-9]*\)$/\1 \2/p' | head -n 1)
    if [ -n "$axy" ]; then
        echo "$axy $(tilexy 1)" | awk '{ d = $1 - $3; e = $2 - $4; exit !(d * d <= 64 && e * e <= 64) }' \
            || bad "claude-tap: Activate at $axy, the tile's centre is $(tilexy 1) (window coordinates)"
    fi
    shown && bad "claude-tap: the curtain is still open after Activate answered"
    cc show; sleep 0.9
fi

# ---------------- long press on Claude: its menu (no introspection data: plain calls only), the real layout
mark claude-menu
if tilelong 1 claude-menu; then
    sleep 1
    expect "SNI claude AboutToShow 0"
    expect "SNI claude GetLayout 0 -1"
    expect "SNI claude Event 0 opened"
    expect "tray: menu $KC 7 rows depth 0"
    expect "tray: labels $KC 0 Claude :: 显示应用|打开快速输入|-|Demo 套餐|用量：50%|-|退出"
    before "SNI claude AboutToShow 0" "SNI claude GetLayout 0" || bad "claude-menu: GetLayout before AboutToShow"
    snap t2-claude-menu rows
    if pat t2 "n n s n n s n"; then
        lxcheck t2 "$KC" 0
        mark claude-relayout
        fake Relayout s claude
        waitfor "SNI claude GetLayout 0" 1 3 || bad "claude-relayout: LayoutUpdated with the menu open, the level not read again"
        # 「Demo 套餐」 (the 3rd row) is disabled: nothing happens, the page stays
        mark claude-disabled
        taprow 3 claude-disabled; sleep 0.7
        reject "SNI claude Event 14"
        reject "tray: click"
        shown || bad "claude-disabled: the curtain closed"
        # 「显示应用」: clicked, then the curtain closes, and with it the menu
        mark claude-click
        taprow 1 claude-click; sleep 1.2
        expect "SNI claude Event 11 clicked"
        expect "tray: click $KC 11"
        expect "SNI claude Event 0 closed"
        shown && bad "claude-click: the curtain is still open after a menu row acted"
    fi
fi
cc hide; sleep 0.8

# ---------------- closed: a change is not even heard (no D-Bus traffic while closed: the screen may be off); the
# next show reads every item
mark closed-change
fake SetTitle ss folder 文件夹
sleep 1
reject "Get Status"
mark closed-show
cc show; sleep 1
expect "SNI folder Get Status"
expect "SNI claude Get Status"

# ---------------- fcitx: the root filled on AboutToShow, radio items, a submenu, a mnemonic; back twice
mark fcitx
if tilelong 2 fcitx; then
    sleep 1
    expect "SNI fcitx AboutToShow 0"
    expect "SNI fcitx Event 0 opened"
    expect "tray: menu $KF 12 rows depth 0"
    expect "Configure 输入法设置"
    reject "_Configure"
    before "SNI fcitx AboutToShow 0" "SNI fcitx GetLayout 0" || bad "fcitx: GetLayout before AboutToShow (fcitx fills its menu on AboutToShow)"
    snap t3-fcitx-menu rows
    if pat t3 "n a n s n n n n n n s n"; then
        lxcheck t3 "$KF" 0
        mark fcitx-sub
        taprow 4 fcitx-sub; sleep 1
        expect "SNI fcitx AboutToShow 305"
        expect "SNI fcitx GetLayout 305"
        expect "tray: menu $KF 5 rows depth 1"
        expect "tray: labels $KF 1 雾凇拼音 :: "
        reject "SNI fcitx Event 305 clicked"
        reject "tray: click"
        snap t4-fcitx-sub rows
        pat t4 "n a s n n" && lxcheck t4 "$KF" 1
        mark fcitx-back
        back fcitx-back
        snap t4b-fcitx-back rows
        pat t4b "n a n s n n n n n n s n"
        reject "SNI fcitx Event 0 closed"
    fi
    mark fcitx-close
    back fcitx-close
    snap t4c-fcitx-closed rows
    [ "$(val PAGE)" = grid ] || bad "t4c: the controls' grid not back after back at the menu's root (PAGE $(val PAGE))"
    expect "SNI fcitx Event 0 closed"
    shown || bad "fcitx-close: the curtain closed"
fi

# ---------------- folder (ItemIsMenu): a tap opens its menu, Activate is never called
mark folder
if tiletap 3 folder; then
    sleep 1
    reject "SNI folder Activate"
    expect "SNI folder GetLayout 0"
    expect "tray: menu $KD 2 rows"
    expect "打开 my_files"
    snap t4d-folder-menu rows
    pat t4d "a n" && lxcheck t4d "$KD" 0
    shown || bad "folder: the curtain closed"
    mark folder-back
    back folder-back
    expect "SNI folder Event 0 closed"
fi

# ---------------- noact: Activate answers UnknownMethod -> its menu instead (leading / double / trailing
# separators collapsed: item, separator, item)
mark noact
if tiletap 5 noact; then
    sleep 1.2
    expect "SNI noact Activate "
    expect "tray: activate $KN -> error"
    expect "SNI noact GetLayout 0"
    expect "tray: menu $KN 3 rows"
    reject "toast: "
    snap t5-noact-fallback rows
    pat t5 "n s n"
    shown || bad "noact: the curtain closed (a failed Activate with a menu keeps it open)"
    mark noact-back
    back noact-back
fi

# ---------------- an icon and a status changing while open: read again (a burst is one read) and drawn
mark icon-change
fake SetIcon ss fcitx configure
waitfor "tray: icon $KF theme configure" 1 3 || bad "icon-change: fcitx's new IconName (NewIcon) not read and drawn"
mark attention
fake SetStatus ss folder NeedsAttention
waitfor "SNI folder Get Status" 1 3 || bad "attention: no read after folder's NewStatus"
sleep 0.4
snap t5i-attention tiles
tiles
[ "$(val DOTAT)" = "3 4" ] || bad "t5i: the attention dot on tile(s) '$(val DOTAT)', want '3 4' (文件夹 now NeedsAttention, 提醒)"
mark icon-restore
fake SetIcon ss fcitx input-keyboard
fake SetStatus ss folder Active
waitfor "tray: icon $KF theme input-keyboard" 1 3 || bad "icon-restore: fcitx's icon not back"
sleep 1.2

# ---------------- an icon that never stops (Spectacle's while it records: a NewIcon per frame): read at most once a
# second, its last frame included; its tile kept (a long press on it holds); not even heard while the curtain is down
mark anim
fake Spawn s anim
waitfor "tray: + " 1 4 || bad "anim: the animated item not added"
KAN=$(keyof 动画)
sleep 1.2
expect "tray: icon $KAN pixmap 64x64"
snap t5a-anim tiles
tiles
[ "$(val TILES)" = 6 ] || bad "t5a: $(val TILES) tray tiles, want 6 (two whole rows)"
wholetiles t5a
mark anim-rate
sleep 3
nr=$(cnt "SNI anim Get Status")
say "anim-rate: $nr reads in 3 s of 30 NewIcon a second"
[ "$nr" -ge 2 ] && [ "$nr" -le 5 ] || bad "anim-rate: $nr reads of the animated item in 3 s, want 2-5 (one a second)"
mark anim-menu
if tilelong 6 anim-menu; then
    sleep 1
    expect "tray: menu $KAN 1 rows depth 0"
    snap t5b-anim-menu rows
    onpage || bad "t5b: no menu page after a long press on the animated tile (PAGE $(val PAGE)): the press was cut"
    back anim-menu-back
fi
mark anim-closed
mo=$(ccmatch)
cc hide; sleep 1.5
mc=$(ccmatch)
mark anim-quiet
sleep 2
reject "SNI anim Get Status"
say "anim-closed: the control centre's match rules: open $mo, closed $mc"
if [ -z "$mo" ] || [ -z "$mc" ]; then bad "anim-closed: no match rule count from the bus (Debug.Stats)"
elif [ "$mc" -ge "$mo" ]; then bad "anim-closed: match rules open $mo, closed $mc: the items' signals still subscribed while closed"; fi
mark anim-show
cc show; sleep 1
expect "SNI anim Get Status"
mark anim-remove
fake Remove s anim
waitfor "tray: - $KAN" 1 3 || bad "anim-remove: no 'tray: - $KAN'"
sleep 0.4

# ---------------- more apps than places: 「全部 N 个」 and the list of all; a tap that is never answered (慢) and one
# refused by an app without a menu (无菜单): said so, the page kept
mark overflow
fake Spawn s slow
fake Spawn s nomenu
waitfor "tray: + " 2 4 || bad "overflow: $(cnt 'tray: + ') of 2 items added"
KS=$(keyof 慢); KM=$(keyof 无菜单)
sleep 0.6
snap t10-overflow tiles
tiles
[ "$(val TILES)" = 6 ] || bad "t10: $(val TILES) tray tiles, want 6 (5 apps + 「全部 7 个」)"
wholetiles t10
mark trayall
if tiletap 6 trayall; then
    sleep 0.8
    snap t10a-trayall rows
    pat t10a "n n n n n n n"
    reject "Activate"                                   # the 「全部」 tile is no app's
    mark slow
    if taprow 6 slow; then
        sleep 0.35
        snap t10b-slow-pending rows
        sleep 1.3
        expect "SNI slow Activate "
        expect "tray: activate $KS -> timeout"
        expect "toast: 「慢」没有响应"
        reject "长按可打开它的菜单"                       # 慢 has no menu
        shown || bad "slow: the curtain closed after an Activate that was never answered"
        snap t10c-slow-toast rows
        onpage || bad "t10c: the list of all apps gone after an unanswered Activate (PAGE $(val PAGE))"
        mark nomenu
        if taprow 7 nomenu; then
            sleep 1
            expect "SNI nomenu Activate "
            expect "tray: activate $KM -> error"
            expect "toast: 「无菜单」不能从这里打开"
            reject "tray: menu $KM"
            shown || bad "nomenu: the curtain closed after a refused Activate"
            snap t10d-nomenu rows
        fi
    fi
    mark trayall-back
    back trayall-back
fi
fake Remove s slow
fake Remove s nomenu
waitfor "tray: - " 2 3 || bad "overflow: $(cnt 'tray: - ') of 2 dropped"
sleep 0.5

mark power5
powertest t5p-power-5-tiles

# ---------------- Claude goes Passive (read again while open: its tile goes); fcitx's menu up when fcitx goes
mark passive
fake SetStatus ss claude Passive
sleep 1.3
expect "SNI claude Get Status"
snap t6a-passive tiles
tiles
[ "$(val TILES)" = 4 ] || bad "t6a: $(val TILES) tray tiles, want 4 (输入法, 文件夹, 提醒, 无激活)"
mark menu-gone
if tilelong 1 menu-gone; then
    sleep 1
    expect "tray: menu $KF 12 rows depth 0"
    snap t6b-fcitx-menu-open rows
    onpage || bad "t6b: no menu page for fcitx (PAGE $(val PAGE))"
fi
mark remove
fake Remove s fcitx
waitfor "tray: - $KF" 1 3 || bad "remove: no 'tray: - $KF' after fcitx's connection closed"
expect "SNI watcher dropped"
sleep 0.6
snap t6c-menu-gone rows
[ "$(val PAGE)" = grid ] || bad "t6c: the menu page of an app that went is still up (PAGE $(val PAGE))"
shown || bad "menu-gone: the curtain closed"
snap t6-after-remove tiles
[ "$(val TILES)" = 3 ] || bad "t6: $(val TILES) tray tiles, want 3 (文件夹, 提醒, 无激活)"
[ "$(val DOTAT)" = 2 ] || bad "t6: the attention dot on tile(s) '$(val DOTAT)', want 2"
[ "$(val ORANGE)" -lt 30 ] 2>/dev/null || bad "t6: Claude's orange icon still on the first tile ($(val ORANGE) px) though Passive"

mark power3
powertest t7-power-with-tray

# ---------------- the whole fake quits (watcher and items): every item goes, the section with them
mark quit
fake Quit
waitfor "tray: - " 3 4 || bad "quit: $(cnt 'tray: - ') items dropped, want 3 or more (文件夹, 提醒, 无激活; the Passive ones too if they were announced)"
sleep 0.6
snap t8-gone tiles
[ "$(val TILES)" = 0 ] || bad "t8: $(val TILES) tray tiles after every item went away"
shown || bad "t8: the curtain closed"

# ---------------- a fresh fake: the host notices the new watcher, registers again, reads its list, the items come back
mark restart
startfake
waitfor "FAKESNI READY" 1 10 || bad "restart: fake-sni.py not ready"
waitfor "tray: + " 5 5 || bad "restart: $(cnt 'tray: + ') of 5 items added"
expect "tray: host registered as"
expect "SNI watcher list 3"
sleep 0.6
snap t9-back tiles
[ "$(val TILES)" = 5 ] || bad "t9: $(val TILES) tray tiles, want 5"
wholetiles t9
fake Quit
sleep 0.4
cc hide
say "done (FAIL=$FAIL)"
