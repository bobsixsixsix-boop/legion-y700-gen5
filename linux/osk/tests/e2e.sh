#!/bin/sh
# End-to-end check of y700-osk on the tablet (run as root; needs y700-osk active: y700-osk-ctl on).
# Opens the probe text field, drives the keyboard through its debug hook (the same code path as a
# finger), and checks what text actually reached the app. Prints PASS/FAIL per step.
U="sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0"
PROBE=/usr/local/src/y700-osk/tests/probe/build/y700-osk-probe
OUT=/tmp/y700-osk-probe.out
# busctl prints non-ASCII as octal escapes (\344\275\240): turn them back into text so the checks can grep for 你好
dbg() { $U busctl --user call fyi.y700.Osk /Osk fyi.y700.Osk debug ss "$1" "$2" 2>&1 | sed 's/^s //; s/\\\([0-7][0-7][0-7]\)/\\0\1/g' | { IFS= read -r l; printf '%b\n' "$l"; }; }
text() { tail -n 1 "$OUT" | sed 's/^TEXT //'; }
ok=0; bad=0
# Safety: the debug taps type into whatever has focus. Run only while nobody uses the tablet
# (display off) unless --force, and stop at once if the first word does not land in the probe.
if [ "$1" != "--force" ] && ! grep -q Off /sys/class/drm/card*-DSI-1/dpms 2>/dev/null; then echo "display is on: someone may be typing; run with --force to override"; exit 3; fi
# printf, not echo: dash's echo would turn the backslash-n in the probe's JSON into a newline
check() { if printf '%s\n' "$2" | grep -q -- "$3"; then echo "PASS $1"; ok=$((ok+1)); else echo "FAIL $1: got $2 (want $3)"; bad=$((bad+1)); fi; }
langof() { printf '%s' "$1" | python3 -c 'import sys,re; m=re.search(r"lang\\?\":\\?\"(\w+)", sys.stdin.read()); print(m.group(1) if m else "zh")'; }

: > "$OUT"
# start from a hidden keyboard: with the tap gate it stays up across focus hops nobody tapped for
$U /usr/local/bin/y700-osk hide >/dev/null 2>&1; sleep 0.5
$U QT_QPA_PLATFORM=wayland $PROBE 120 > "$OUT" 2>/dev/null &
sleep 2.5
st=$(dbg state x)
# Since 2026-10-15 a focused field alone does not bring the keyboard up while the KWin gate is loaded
# (only a tap on the field does: see src/gate.h). The probe takes focus programmatically, so check
# that, then bring the keyboard up the way a confirmed tap does (Osk::show(false), here via the CLI).
if dbg gate x | grep -q 'alive=1'; then
    check "focus alone does not bring the keyboard up (tap-gated)" "$st" '\\"shown\\":false'
    $U /usr/local/bin/y700-osk show >/dev/null 2>&1; sleep 0.8; st=$(dbg state x)
fi
check "keyboard shown" "$st" '\\"shown\\":true'
check "commit addon loaded" "$st" '\\"commit\\":true'
# the IM is wherever the owner left it: the steps below start from Chinese
origLang=$(langof "$st")   # the owner's current (and remembered) language: put back at the end
if [ "$origLang" != "zh" ]; then echo "note: started in $origLang, switching to Chinese"; dbg lang zh >/dev/null; sleep 0.7; fi
check "Chinese" "$(dbg state x)" '\\"zh\\":true'

for k in n i h a o; do dbg tap $k >/dev/null; sleep 0.15; done
sleep 0.4; st=$(dbg state x)
check "pinyin composing" "$st" '你好'
dbg tap space >/dev/null; sleep 0.5
check "space commits first candidate" "$(text)" '你好'
if ! text | grep -q '你好'; then echo "ABORT: text did not reach the probe (focus is elsewhere?)"; pkill -x y700-osk-probe 2>/dev/null; exit 4; fi

dbg tap comma >/dev/null; sleep 0.4
check "Chinese comma" "$(text)" '你好，'

dbg flick q >/dev/null; sleep 0.4
check "flick types the hint" "$(text)" '你好，1'

dbg tap lang >/dev/null; sleep 0.6; st=$(dbg state x)
check "switch to English" "$st" '\\"zh\\":false'
for k in h i; do dbg tap $k >/dev/null; sleep 0.15; done; sleep 0.4
check "English letters" "$(text)" '你好，1hi'
dbg tap del >/dev/null; sleep 0.4
check "backspace" "$(text)" '你好，1h"'
dbg tap shift >/dev/null; dbg tap a >/dev/null; dbg tap b >/dev/null; sleep 0.4
check "shift once: Ab" "$(text)" '1hAb"'
dbg down shift >/dev/null; dbg tap c >/dev/null; dbg tap d >/dev/null; dbg up shift >/dev/null; dbg tap e >/dev/null; sleep 0.4
check "hold shift: CDe" "$(text)" '1hAbCDe"'
dbg seq "tap shift;tap shift" >/dev/null; dbg tap f >/dev/null; dbg tap g >/dev/null; dbg tap shift >/dev/null; dbg tap h >/dev/null; sleep 0.4
check "caps lock: FGh" "$(text)" '1hAbCDeFGh"'
dbg tap enter >/dev/null; sleep 0.4
check "enter = new line in a text editor" "$(text)" 'FGh\\n'
dbg hold enter:450 >/dev/null; sleep 0.9; st=$(dbg state x)
check "long-press enter (Shift+Return via key-helper) keeps the keyboard up" "$st" '\\"shown\\":true'
check "  and it typed a new line" "$(text)" 'FGh\\n\\n'
dbg tap x >/dev/null; dbg tap y >/dev/null; sleep 0.4
dbg undo >/dev/null; sleep 0.7
check "Ctrl+Z undoes the last typing (the editor may merge it with the newline before it)" "$(text)" 'FGh\(\\n\)*"\]$'
dbg tap x >/dev/null; dbg tap y >/dev/null; sleep 0.4
dbg clearall >/dev/null; sleep 0.8
check "clear (Ctrl+A, BackSpace) empties the field" "$(text)" '^\[""\]$'
# fast typing: one contact jumping from n to j (the key right above) in ONE update is two fingers,
# not an upward flick on n - that typed n's hint ';' (owner, 2026-10-15)
dbg seq "down n;move n:0:-74;up n" >/dev/null; sleep 0.5
check "fast typing: a contact jumping n -> j types nj (not n's flick ';')" "$(text)" '^\["nj"\]$'
dbg clearall >/dev/null; sleep 0.8
dbg lang zh >/dev/null; sleep 0.6

dbg hold a:600 >/dev/null; sleep 1.0
check "long-press letter: the item under the finger (middle of ~ A a) typed" "$(text)" '^\["A"\]$'


# 日文罗马字 (mozc): a tapped candidate goes in without Return (addon SelectCandidateCommit)
dbg lang ja >/dev/null; sleep 0.8; st=$(dbg state x)
check "switch to Japanese romaji" "$st" '\\"lang\\":\\"ja\\"'
before=$(text)
for k in n i h o n g o; do dbg tap $k >/dev/null; sleep 0.15; done
sleep 0.6; st=$(dbg state x)
check "mozc composing shows candidates" "$st" '\\"ncand\\":[1-9]'
dbg pick 0 >/dev/null; sleep 0.6; st=$(dbg state x)
check "tapped mozc candidate is committed (kanji in the field)" "$(text)" '日本'
check "  and nothing is left composing" "$st" '\\"preedit\\":\\"\\"'

# the owner's language (the test switched it, and switches are remembered)
dbg lang "$origLang" >/dev/null; sleep 0.5

echo "---- $ok passed, $bad failed"
pkill -x y700-osk-probe 2>/dev/null; sleep 1.2
# with someone at the tablet (--force) focus returns to their window, which may well have a text field
if [ "$1" != "--force" ]; then
    st=$(dbg state x)
    if $U busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 DebugInfo | grep -q 'focus:1'; then
        echo "SKIP keyboard hides: another text field took focus when the probe closed (the keyboard is right to stay)"
    else check "keyboard hides when the field goes away" "$st" '\\"shown\\":false'; fi
fi
