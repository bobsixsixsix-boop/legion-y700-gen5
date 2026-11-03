#!/bin/bash
# gate-special.sh [case...]: the review's corner cases (2026-10-15), with Telegram on the left and Kate on the right.
#  1 long press across windows while the keyboard is up: it must not slide out under the finger
#    (fcitx5's focus-out Hide is deferred while the gate is still judging the touch)
#  2 an activation KWin makes itself (tray "show virtual keyboard" = forceActivate): keyboard comes up
#  3 the effect unloaded behind our back (what a compositor restart does): focus-driven fallback works
#    and the effect is loaded again
#  4 (2026-10-21) the task-switcher cards opened with nothing focused for text: the keyboard stays down.
#    KWin 6.6 makes the input method active for ANY focused effect scene; the effect now reports it as
#    "internal other" and that activation no longer counts as KWin-initiated. Opened by the shortcut
#    (= the G9 double tap); a bottom-edge swipe from the desktop is the same case (that touch lands on
#    plasmashell, which the gate ignores, so there is no app touch either). Case 2 is its regression
#    check: a real KWin-initiated activation must still bring the keyboard up.
#  5 (2026-10-21, informational) the keyboard up for Kate, then the cards by the shortcut and closed again:
#    prints what the keyboard does (designed: stays behind the cards, still up for Kate afterwards)
# No arguments: all cases. Cases 1 and 3 need Telegram open on the left half (they tap at fixed
# coordinates; case 1's search field is Telegram 7.3's, with the window at 10,10 780x900 like
# gate-matrix.sh places it, 2026-10-30); 2, 4 and 5 tap nothing: `gate-special.sh 2 4 5` is safe next to the owner's windows.
# Run as root on the tablet; case 1 needs y700-vtouch running. Moves the screen: tell the owner first.
K=/usr/local/libexec
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
CASES=" ${*:-1 2 3 4 5} "
want() { [[ "$CASES" == *" $1 "* ]]; }
st() { "${U[@]}" busctl --user call fyi.y700.Osk /Osk fyi.y700.Osk debug ss state x | grep -o 'shown[^,]*' | head -1; }
gatelog() { "${U[@]}" busctl --user call fyi.y700.Osk /Osk fyi.y700.Osk debug ss gate x | python3 $K/gate-unescape.py "${1:-4}"; }
act() { echo "for (const w of workspace.windowList()) if (w.resourceClass == '$1' && w.normalWindow) workspace.activeWindow = w;" | $K/kwin-eval.sh >/dev/null; sleep 0.8; }
vt() { printf '%s\n' "$1" | tr ';' '\n' > /run/y700-vtouch.fifo; }
cards() { "${U[@]}" busctl --user call org.kde.kglobalaccel /component/kwin org.kde.kglobalaccel.Component invokeShortcut s y700-taskswitcher; sleep 1.5; }
cardsup() { "${U[@]}" busctl --user get-property org.kde.KWin /Effects org.kde.kwin.Effects activeEffects | grep -q '"y700-taskswitcher"'; }
ts_loaded() { "${U[@]}" busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects isEffectLoaded s y700-taskswitcher | grep -q true; }
imon() { "${U[@]}" busctl --user get-property org.kde.KWin /VirtualKeyboard org.kde.kwin.VirtualKeyboard active | awk '{print $2}'; }

# the cards (4, 5) minimize every window they show: remember what was shown and which window was in front
# ("pid:class" tokens on one line: kwin-eval.sh only reads back the first line a script prints)
SHOWN=$(echo 'out(workspace.windowList().filter(w => w.normalWindow && !w.minimized).map(w => w.pid + ":" + w.resourceClass).join(" "))' | $K/kwin-eval.sh)
PREV=$(echo 'const a = workspace.activeWindow; out(a && a.normalWindow ? a.pid + ":" + a.resourceClass : "")' | $K/kwin-eval.sh)
restore() {   # $1: the window to put in front (default: the one in front at the start)
    printf 'workspace.showingDesktop = false; const ids = "%s".split(" "); for (const w of workspace.windowList()) if (w.normalWindow && ids.includes(w.pid + ":" + w.resourceClass)) w.minimized = false; for (const w of workspace.windowList()) if (w.normalWindow && w.pid + ":" + w.resourceClass == "%s") { workspace.activeWindow = w; break; }\n' "$SHOWN $KATE" "${1:-$PREV}" | $K/kwin-eval.sh >/dev/null
}

kp=; KATE=
if want 1 || want 3 || want 5; then
    ps=$(pgrep -u user -x plasmashell | head -1); mapfile -d '' senv < /proc/$ps/environ
    echo "y700 gate test" > /tmp/y700-gate-test.txt; chmod 666 /tmp/y700-gate-test.txt
    sudo -u user env -i "${senv[@]}" setsid kate -n /tmp/y700-gate-test.txt >/dev/null 2>&1 & kp=$!; sleep 4
    echo "for (const w of workspace.windowList()) if (w.resourceClass == 'org.kde.kate' && w.normalWindow) { w.setMaximize(false,false); w.frameGeometry = {x:810,y:10,width:780,height:900}; workspace.activeWindow = w; }" | $K/kwin-eval.sh >/dev/null; sleep 1
    KATE=$(echo 'const a = workspace.activeWindow; out(a && a.resourceClass == "org.kde.kate" ? a.pid + ":" + a.resourceClass : "")' | $K/kwin-eval.sh)
fi

if want 1; then
echo "== 1 long press on Telegram's search field while the keyboard is up in Kate"
vt "tap 1102 285 80"; sleep 1.2; echo "   keyboard after tapping Kate's editor: $(st)"
vt "down 316 96"; sleep 0.55; echo "   550 ms into the press on Telegram: $(st)  (want true: no slide-out)"
vt "up"; sleep 0.8; echo "   after the lift: $(st)  (want true: v2-show)"; gatelog 3
fi

if want 2; then
echo "== 2 KWin-initiated activation (forceActivate) with nothing focused for text"
"${U[@]}" /usr/local/bin/y700-osk hide; sleep 1.2
"${U[@]}" busctl --user set-property org.kde.KWin /VirtualKeyboard org.kde.kwin.VirtualKeyboard active b false; sleep 0.5
"${U[@]}" busctl --user call org.kde.KWin /VirtualKeyboard org.kde.kwin.VirtualKeyboard forceActivate; sleep 1
kb=$(st); echo "   keyboard: $kb  (want true)"; gatelog 3
echo "$kb" | grep -q true && echo "   PASS  forceActivate still brings the keyboard up" || echo "   FAIL  forceActivate did not bring the keyboard up"
fi

if want 3; then
echo "== 3 effect unloaded behind our back, then a focus-driven Show (activate Kate)"
"${U[@]}" /usr/local/bin/y700-osk hide; act org.telegram.desktop; sleep 1.5
"${U[@]}" busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects unloadEffect s y700_oskgate; sleep 1.5
act org.kde.kate; sleep 1
echo "   keyboard: $(st)  (want true: fallback)"
sleep 1; echo "   effect loaded again: $("${U[@]}" busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects isEffectLoaded s y700_oskgate)"; gatelog 4
fi

if want 4; then
echo "== 4 task-switcher cards opened from the desktop (shortcut = G9 double tap): no keyboard"
if ts_loaded; then
    "${U[@]}" /usr/local/bin/y700-osk hide; sleep 1.2
    echo 'workspace.showingDesktop = true;' | $K/kwin-eval.sh >/dev/null; sleep 1
    # the input method must be inactive before, or opening the cards activates nothing and the case passes
    # without exercising the gate (case 2 leaves it active, and showingDesktop moves no focus when the
    # desktop already was in front)
    "${U[@]}" busctl --user set-property org.kde.KWin /VirtualKeyboard org.kde.kwin.VirtualKeyboard active b false; sleep 0.5
    echo "   input method active before: $(imon)  (want false)"
    t0=$(gatelog 1 | awk '{print $2}')
    cards
    up=$(cardsup && echo true || echo false); kb=$(st)
    echo "   cards up: $up, keyboard: $kb  (want true, shown false)"
    # only the lines after the cards were asked for: a plain tail long enough for minimizeAll's focus
    # hops and the five gated Shows reached back into case 2's KWin-initiated Show (2026-10-21)
    log=$(gatelog 30 | awk -v t="${t0:-0}" '$2 + 0 > t + 0'); echo "$log"
    # KWin 6.6: an im-active marked "internal other", gated; KWin >= 6.7 (upstream 430eacb550): no
    # activation at all. Either way no KWin-initiated Show and the keyboard stays down. Without the
    # im-active on 6.6 the gate was not tested: fail rather than pass on a version we never checked.
    kv=$(dpkg-query -W -f '${Version}' kwin-wayland 2>/dev/null)
    if [ "$up" = true ] && echo "$kb" | grep -q false && ! grep -q 'launcher Show for a KWin' <<< "$log"; then
        if grep -q 'im-active.*internal other' <<< "$log"; then
            echo "   PASS  im-active reported as internal other and gated"
        elif dpkg --compare-versions "$kv" ge 4:6.7; then
            echo "   PASS  no keyboard (KWin $kv: no activation for a non-text focus, upstream 430eacb550)"
        else
            echo "   FAIL  no im-active with the input method inactive before, on KWin $kv: the gate was not exercised" \
                "(or this KWin carries upstream 430eacb550: then let this case accept it)"
        fi
    else
        echo "   FAIL  want the cards up, the keyboard down and no 'launcher Show for a KWin-initiated activation'"
    fi
    cardsup && cards
    restore
    sleep 1
else
    echo "   SKIP  y700-taskswitcher effect not loaded"
fi
fi

if want 5; then
echo "== 5 keyboard up for Kate, cards by the shortcut, closed again (informational)"
if ts_loaded && [ -n "$KATE" ]; then
    act org.kde.kate; "${U[@]}" /usr/local/bin/y700-osk show; sleep 1.2
    echo "   keyboard in Kate before: $(st)"
    cards
    echo "   cards up: $(cardsup && echo true || echo false), keyboard behind them: $(st)"
    cardsup && cards
    sleep 1
    echo "   cards closed, front: $(echo 'const a = workspace.activeWindow; out(a ? a.resourceClass : "none")' | $K/kwin-eval.sh), keyboard: $(st)"
    gatelog 8
    "${U[@]}" /usr/local/bin/y700-osk hide
    restore
else
    echo "   SKIP  y700-taskswitcher effect not loaded or Kate did not come up"
fi
fi

"${U[@]}" /usr/local/bin/y700-osk hide
# $kp is sudo's pid, not Kate's (setsid forks): 2026-10-21 Kate stayed open after the run
[ -n "$kp" ] && { pkill -u user -f '^kate -n /tmp/y700-gate-test.txt' 2>/dev/null; kill $kp 2>/dev/null; sleep 1
    pkill -9 -u user -f '^kate -n /tmp/y700-gate-test.txt' 2>/dev/null; }
rm -f /tmp/y700-gate-test.txt
restore
