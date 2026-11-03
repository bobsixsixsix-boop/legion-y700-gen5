# sb-bed scenario (10-30): the battery page (linux/power/battery/page; DESIGN.md §6, §6b.c, §8) on the canned reports,
# at whatever size the bed runs. Run it through batpage-run.sh, which plays it at 1600x1002 and at 1002x1600 (SB_SIZE)
# and stages what it needs in one directory: the page binary (y700-battery-page), the canned reports (batpage/*.json)
# and bp-look.py, with Y700_BATTERY_REPORT = its ok.json, so the scenario finds the rest next to that file:
#   sh ./batpage-run.sh /root/batpage        (root, the screen off; PAGE_BIN=BIN for a page not installed yet)
# The bed passes Y700_BATTERY_REPORT on (sb-bed.sh, env -i), so the control centre's battery pill opens the page on
# ok.json too (p8), and points XDG_CACHE_HOME / XDG_STATE_HOME into itself: no page here reads the owner's ledger or
# writes the owner's cache.
# p0-p7 and p9 start the page straight (the staged copy; its output goes to OUT/page.log); p8 goes the owner's way:
# the pill -> /usr/local/bin/y700-battery (batpage-run.sh binds a staged copy over it when PAGE_BIN is not the
# installed page) -> the page.
# Steps and shots (OUT/*.png), each looked at by bp-look.py (DESIGN.md §8: nothing right of the right margin, the
# segmented control and the list end on it, rows 76 apart, the window maximized); a FAIL prints SBBED_EXPECT_FAIL:
#   p0-since-full    ok.json, the start range (自上次充满 selected)
#   p1-24h / p2-7d   a tap on that segment: its block selected, the page changed
#   p3-detail        landscape: a tap on the first row, the detail replaces the list. Portrait: the page restarted with
#                    --range 7d --detail <ok.json's first 7-day row> (main.cpp's bed-only arguments): there the list
#                    sits below the chart, off the first screen, and the detail is pushed as a whole page either way
#   p4-back          the back key (the control centre's fake Esc, what the side-edge swipe sends: fyi.y700.ControlCenter
#                    back): the list again, like p2. Once more on the list closes the window (no shot)
#   p5-empty / p6-just-full / p7-partial   empty.json / just_full.json / partial.json
#   p8-cc, p8-pill   the pill on the curtain; a tap on it opens one page, like p0 (it read the canned report)
#   p8-cc2, p8-again a second tap with that page open: still one battery page, no KDE page (the launcher closes the
#                    open one first)
#   p9-portrait-end  portrait only: ok.json, two swipes up to the end of the page (the list's rows, the margin)
# The holding finger (sb-bed.sh, tap) rests on the status bar (400, 12) for taps on the page: the shellbar starts a
# pull only after the finger moved 6 px down (y700-shellbar main.cpp), and the page sees one finger only (a second
# one held on the page would be the portrait Flickable's, or the landscape chart's read-out). On the curtain it is
# held long on the curtain's empty part, as in battcap.sh (a short press there would close the curtain).
BPD=$(dirname "${Y700_BATTERY_REPORT:-/nonexistent/ok.json}")
PG=$BPD/y700-battery-page; LOOK=$BPD/bp-look.py; PLOG=$OUT/page.log; STEP=start
say() { echo "batpage.sh: $*"; echo "batpage.sh: $*" >> "$LOG"; }
bad() { echo "SBBED_EXPECT_FAIL: batpage.sh: $*"; echo "batpage.sh: FAIL $*" >> "$LOG"; FAIL=1; }
if [ ! -x "$PG" ] || [ ! -f "$LOOK" ] || [ ! -f "$BPD/ok.json" ]; then
    bad "no staged page, bp-look.py or ok.json next to Y700_BATTERY_REPORT=${Y700_BATTERY_REPORT:-} (run it through batpage-run.sh)"
    return 0
fi
: > "$PLOG"
LAND=0; [ "$SB_W" -gt "$SB_H" ] && LAND=1
# M: the page's side margin (DESIGN.md §6: 56 landscape, 32 portrait); CCM: the control centre's (Main.qml: 56 from
# 1200 px up, else 28), where the pill ends; CURT: an empty spot of the curtain (portrait: left of the controls,
# which take x 270-974 there)
if [ $LAND = 1 ]; then M=56; CURT="300 700"; else M=32; CURT="130 900"; fi
if [ "$SB_W" -ge 1200 ]; then CCM=56; else CCM=28; fi
PAGEHOLD="400 12"
HOLD_AT=$PAGEHOLD; HOLD_MS=150
say "bed ${SB_W}x$SB_H ($([ $LAND = 1 ] && echo landscape || echo portrait)), page $PG"

cc() { busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter "$1" >/dev/null 2>&1 || say "cc $1 failed"; }
back() { busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter back sb y700-battery false >/dev/null 2>&1 || say "$STEP: the back call failed"; }

# pageinfo: what KWin has -> BN battery page windows (class y700-battery: the page's desktop file name), BK KDE power
# pages (kcm_mobile_power: the old launcher's), and for the top battery page BPID, FRAME / CLIENT / AREA (x,y,w,h: the
# frame, the client and KWin's maximize area for it; "none" where this KWin's script API had none), BACT (1 = the
# active window), DOCK (shellbar windows besides the status bar: the dock or a banner would be in the shot)
PAGEJS='var all = workspace.stackingOrder;
function cls(c) { return all.filter(function (w) { return w.resourceClass == c; }); }
function r(g) { return g && g.width !== undefined ? [g.x, g.y, g.width, g.height].map(Math.round).join(",") : "none"; }
var ws = cls("y700-battery"), w = ws.length ? ws[ws.length - 1] : null, a = "none";
if (w) { try { a = r(workspace.clientArea(KWin.MaximizeArea, w)); } catch (e) { a = "none"; } }
var dock = cls("y700-shellbar").filter(function (s) { return s.height > 40 && !s.hidden && !s.minimized; }).length;
print("bpinfo " + ws.length + " " + cls("kcm_mobile_power").length + " " + (w && w.pid ? w.pid : 0) + " " + (w ? r(w.frameGeometry) : "none") + " " + (w ? r(w.clientGeometry) : "none") + " " + a + " " + (w && w.active ? 1 : 0) + " " + dock);'
pageinfo() {
    n0=$(wc -l < "$LOG")
    eval_js "$PAGEJS"
    set -f; set -- $(tail -n +$((n0 + 1)) "$LOG" | grep -o 'bpinfo .*' | tail -n 1); set +f
    if [ $# -ge 9 ]; then
        BN=$2; BK=$3; BPID=$4; FRAME=$5; CLIENT=$6; AREA=$7; BACT=$8; DOCK=$9
    else
        BN=0; BK=0; BPID=0; FRAME=none; CLIENT=none; AREA=none; BACT=0; DOCK=0
        echo "batpage.sh: no bpinfo line from KWin" >> "$LOG"
    fi
}
# waitpages N: until KWin lists N battery page windows (about 10 s)
waitpages() { tw=0; while pageinfo; [ "$BN" != "$1" ]; do tw=$((tw + 1)); [ $tw -ge 12 ] && return 1; sleep 0.5; done; }
# geom: CX CY CW CH (the client in screen coordinates; the frame when KWin gave no client) and R, the right margin
# in the client's own coordinates (1544 / 970)
geom() {
    c=$CLIENT; [ "$c" = none ] && c=$FRAME
    case $c in
        *,*,*,*) CX=${c%%,*}; c=${c#*,}; CY=${c%%,*}; c=${c#*,}; CW=${c%%,*}; CH=${c#*,} ;;
        *) CX=0; CY=28; CW=$SB_W; CH=$((SB_H - 28)) ;;
    esac
    R=$((CW - M))
}
# ptap X Y: a tap at the page's own (client) coordinates
ptap() { tap $((CX + $1)) $((CY + $2)); }
# segtap I: the middle of segment I (DESIGN.md §6: landscape 3 x 176 ending on the right margin, y 24-80; portrait
# 312 / 313 / 313 from x 32, y 96-152)
segtap() {
    if [ $LAND = 1 ]; then
        ptap $((R - 440 + 176 * $1)) 52
    else
        case $1 in 0) ptap 188 124 ;; 1) ptap 500 124 ;; *) ptap 813 124 ;; esac
    fi
}
# the battery pages and KDE power pages this bed opened, only those (the owner's are on wayland-0): the page as the
# scenario starts it (the staged copy) or as the launcher execs it (installed, or batpage-run.sh's staged copy)
killpages() {
    for p in $(pgrep -u "$(id -u)" -f "^($BPD|/usr/local/libexec)/y700-battery-page( |\$)") \
             $(pgrep -u "$(id -u)" -f '^(/usr/bin/)?kcmshell6 kcm_mobile_power$'); do
        tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -qx "WAYLAND_DISPLAY=$WAYLAND_DISPLAY" && kill "$p"
    done
}
closepages() {
    pageinfo
    [ "$BN" = 0 ] && [ "$BK" = 0 ] && return 0
    killpages
    tw=0
    while pageinfo; [ "$BN" != 0 ] || [ "$BK" != 0 ]; do
        tw=$((tw + 1)); [ $tw -ge 10 ] && { say "$STEP: a page still listed after killing them"; return 1; }
        sleep 0.5
    done
}
# open_page FILE [ARGS]: the page on that canned report, alone, up and active; then geom. (Not f: sb-bed.sh's eval_js
# sets f, and closepages runs it.)
open_page() {
    rep=$1; shift
    closepages
    echo "=== $STEP: $rep $*" >> "$PLOG"
    Y700_BATTERY_REPORT="$BPD/$rep" "$PG" "$@" >> "$PLOG" 2>&1 &
    if ! waitpages 1; then bad "$STEP: no page window within 10 s of starting it on $rep (OUT/page.log)"; return 1; fi
    sleep 1.2      # its first frames; the segmented control's block settles in 180 ms
    pageinfo
    if [ "$BACT" != 1 ]; then
        # a window started from a shell has no activation token; the owner's comes from the launcher
        say "$STEP: the page is not the active window: activated through KWin"
        eval_js 'var ws = workspace.stackingOrder.filter(function (w) { return w.resourceClass == "y700-battery"; }); if (ws.length) workspace.activeWindow = ws[ws.length - 1];'
        pageinfo
    fi
    [ "$DOCK" = 0 ] || say "$STEP: $DOCK shellbar window(s) besides the status bar are up (the dock?): they are in the shot"
    geom
}
# look NAME CHECKS [bp-look.py options]: shot NAME and bp-look.py on it; each FAIL line is a bad. The options go as
# --opt=VALUE: a rectangle can start with a minus
look() {
    n=$1; ck=$2; shift 2
    pageinfo; geom
    shot "$n"
    res=$(python3 "$LOOK" page "$OUT/$n.png" --checks="$ck" --frame="$FRAME" --client="$CLIENT" --area="$AREA" "$@" 2>&1); rc=$?
    printf '%s\n' "$res" | while IFS= read -r l; do echo "bp-look $n: $l"; done >> "$LOG"
    np=0
    while IFS= read -r l; do
        case $l in
            PASS*) np=$((np + 1)) ;;
            FAIL*) bad "$n: ${l#FAIL }" ;;
        esac
    done <<EOF
$res
EOF
    [ $rc = 0 ] || bad "$n: bp-look.py exited $rc (its output is in the log)"
    say "$n: $np check(s) passed ($ck)"
}
# pill NAME: the pill on shot NAME -> PX0 PX1 PY0 PY1, PW (content width), PCX PCY (its middle); pillok: where
# Main.qml puts it (content 30-160 wide, at most 30 high, its right end within 45 px left of the curtain's margin)
pill() {
    set -f; set -- $(python3 "$LOOK" pill "$OUT/$1.png" 2>&1); set +f
    echo "bp-look pill: $*" >> "$LOG"
    if [ "${1:-}" = PILL ] && [ "${2:-}" != none ] && [ $# = 6 ]; then
        PX0=$2; PX1=$3; PY0=$4; PY1=$5
    else
        PX0=0; PX1=0; PY0=0; PY1=0
    fi
    PW=$((PX1 - PX0 + 1)); PCX=$(((PX0 + PX1) / 2)); PCY=$(((PY0 + PY1) / 2))
}
pillok() { [ $PW -ge 30 ] && [ $PW -le 160 ] && [ $((PY1 - PY0)) -le 30 ] && [ $PX1 -ge $((SB_W - CCM - 45)) ] && [ $PX1 -le $((SB_W - CCM + 1)) ]; }

# the checks for a page with a list: landscape has the list on the first screen, portrait only after a scroll (p9)
FULL=max,margin,seg-right,sel; [ $LAND = 1 ] && FULL=$FULL,list-right,pitch
ID7=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["ranges"]["7d"]["items"][0]["id"])' "$BPD/ok.json" 2>/dev/null)

# ---------------- p0-p4: ok.json, the segments, a detail and back
STEP=p0; mark p0
if open_page ok.json; then
    look p0-since-full "$FULL" --sel=0

    STEP=p1; mark p1
    segtap 1; sleep 1
    look p1-24h "$FULL,differs" --sel=1 --differs="$OUT/p0-since-full.png"
    STEP=p2; mark p2
    segtap 2; sleep 1
    look p2-7d "$FULL,differs" --sel=2 --differs="$OUT/p1-24h.png"

    STEP=p3; mark p3
    ok3=1
    if [ $LAND = 1 ]; then
        ptap $((R - 264)) 222; sleep 1          # the first row's middle: y 184 + 76 / 2
    elif [ -n "$ID7" ]; then
        open_page ok.json --range 7d --detail "$ID7" || ok3=0
    else
        bad "p3: no first row in ok.json's 7-day range"; ok3=0
    fi
    if [ $ok3 = 1 ]; then
        look p3-detail margin,nolist,differs --differs="$OUT/p2-7d.png"

        STEP=p4; mark p4
        back; sleep 1
        expect "back: y700-battery ->"
        pageinfo
        if [ "$BN" = 1 ]; then
            look p4-back "$FULL,like" --sel=2 --like="$OUT/p2-7d.png"
            mark p4-close
            back
            if waitpages 0; then say "p4: the back key on the list closed the page"
            else bad "p4: the back key on the list did not close the page ($BN window(s) after 10 s)"; fi
            expect "back: y700-battery ->"
        else
            bad "p4: $BN page window(s) after the back key in the detail, want 1 (the detail closes, not the window)"
        fi
    fi
fi

# ---------------- p5-p7: the other reports
STEP=p5; mark p5
open_page empty.json && look p5-empty max,margin,seg-right,sel --sel=0
STEP=p6; mark p6
open_page just_full.json && look p6-just-full max,margin,seg-right,sel --sel=0
STEP=p7; mark p7
open_page partial.json && look p7-partial "$FULL" --sel=0

# ---------------- p8: from the control centre's pill, one page only
STEP=p8; mark p8
closepages
HOLD_AT=$CURT; HOLD_MS=1000
cc show; sleep 1.6
shot p8-cc; pill p8-cc
say "p8: the pill at x $PX0-$PX1 y $PY0-$PY1"
if ! pillok; then
    bad "p8: no pill where it belongs on p8-cc (x $PX0-$PX1 y $PY0-$PY1); nothing tapped"
else
    tap $PCX $PCY; sleep 1
    HOLD_AT=$PAGEHOLD; HOLD_MS=150
    if waitpages 1; then
        sleep 1.2; pageinfo; P1=$BPID
        [ "$BACT" = 1 ] || say "p8: the page the pill opened is not the active window"
        [ "$BK" = 0 ] || bad "p8: a KDE power page opened as well"
        look p8-pill "$FULL,like" --sel=0 --like="$OUT/p0-since-full.png"

        mark p8-again
        HOLD_AT=$CURT; HOLD_MS=1000
        cc show; sleep 1.6
        shot p8-cc2; pill p8-cc2
        if pillok; then
            tap $PCX $PCY; sleep 5
            HOLD_AT=$PAGEHOLD; HOLD_MS=150
            pageinfo; shot p8-again
            say "p8: $BN battery page(s), $BK KDE power page(s) 5 s after a second tap (pid $P1 -> $BPID)"
            { [ "$BN" = 1 ] && [ "$BK" = 0 ]; } || bad "p8: $BN battery page(s) and $BK KDE power page(s) after a second tap with one open, want 1 and 0 (y700-battery closes the open one first)"
        else
            bad "p8: no pill over the open page on p8-cc2 (x $PX0-$PX1 y $PY0-$PY1); nothing tapped"
        fi
    else
        if [ "$BK" != 0 ]; then
            bad "p8: the pill opened KDE's power page, not the battery page (/usr/local/bin/y700-battery the old launcher, or no page where it looks)"
        else
            bad "p8: no page within 10 s of a tap on the pill"
        fi
    fi
fi
HOLD_AT=$PAGEHOLD; HOLD_MS=150
cc hide; sleep 0.8

# ---------------- p9: portrait, the end of the page
if [ $LAND = 0 ]; then
    STEP=p9; mark p9
    if open_page ok.json; then
        sx=$((CX + CW / 2))
        swipe $sx $((CY + CH - 300)) $sx $((CY + 300)) 250; sleep 1.2
        swipe $sx $((CY + CH - 300)) $sx $((CY + 300)) 250; sleep 2
        look p9-portrait-end max,margin,list-right,pitch,differs --differs="$OUT/p0-since-full.png"
    fi
fi

STEP=end
closepages
cc hide
# the page's own QML / JS messages (the bed checks only the shellbar's and the control centre's); QML is compiled in
# (qt_add_qml_module URI Y700.BatteryPage), so the paths read qrc:/qt/qml/Y700/BatteryPage/X.qml:N
qe=$(grep -E 'Y700/BatteryPage/[A-Za-z]+\.(qml|js):[0-9]+' "$PLOG" | head -8)
if [ -n "$qe" ]; then
    bad "QML messages from the page (OUT/page.log):"
    printf '%s\n' "$qe" | while IFS= read -r l; do echo "  | $l"; done
fi
say "done (FAIL=$FAIL)"
