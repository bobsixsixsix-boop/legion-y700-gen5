#!/bin/sh
# Shift / caps-lock / symbol-panel / clear-gesture state machine check, safe to run while someone uses
# the tablet: it drives a --preview keyboard (English layout, window never mapped) through the debug
# hook. In preview nothing reaches fcitx5; what WOULD have been typed is read back from the typed log.
# Run as user, or as root (it switches to user). Needs the installed /usr/local/bin/y700-osk.
if [ "$(id -u)" = 0 ]; then exec sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 sh "$(readlink -f "$0")" "$@"; fi
B="busctl --user call fyi.y700.OskPreview /Osk fyi.y700.Osk debug ss"
# busctl prints non-ASCII as octal escapes: decode them (symbols, è)
dbg() { $B "$1" "${2:-x}" 2>&1 | sed 's/^s "//; s/"$//; s/\\\([0-7][0-7][0-7]\)/\\0\1/g' | { IFS= read -r l; printf '%b\n' "$l"; }; }
ok=0; bad=0
# printf, not echo: dash's echo would turn a backslash-n in the text into a newline
check() { if printf '%s\n' "$2" | grep -q -- "$3"; then echo "PASS $1"; ok=$((ok+1)); else echo "FAIL $1: got $2 (want $3)"; bad=$((bad+1)); fi; }
typed() { dbg state | sed 's/.*\\"typed\\":\\"\([^"]*\)\\".*/\1/' ; }
field() { dbg state | sed "s/.*\\\\\"$1\\\\\":\([^,}]*\).*/\1/"; }
taps() { for k in "$@"; do dbg tap "$k" >/dev/null; done; }
seq_() { dbg seq "$1" >/dev/null; }      # one bus call: back-to-back events for timing-sensitive sequences
fresh() { dbg reset >/dev/null; }

if busctl --user status fyi.y700.OskPreview >/dev/null 2>&1; then echo "a preview keyboard is already running (fyi.y700.OskPreview is taken); stop it first"; exit 3; fi
Y700_OSK_PREVIEW_MS=120000 Y700_OSK_HIDDEN=1 y700-osk --preview=en >/dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT INT TERM
i=0; until dbg state 2>/dev/null | grep -q '\\"zh\\"'; do i=$((i+1)); [ $i -gt 40 ] && { echo "preview keyboard did not come up"; exit 3; }; sleep 0.25; done
st=$(dbg state); check "preview up, English" "$st" '\\"zh\\":false'

fresh; taps shift a b
check "tap shift: one upper-case letter" "$(typed)" '^Ab$'; check "  shift off afterwards" "$(field shift)" '^0$'

fresh; taps shift a shift b
check "shift, letter, shift, letter" "$(typed)" '^AB$'

fresh; seq_ "tap shift;tap shift"
check "double tap: caps lock" "$(field shift)" '^2$'
taps a b c; check "  letters stay upper case" "$(typed)" '^ABC$'
taps shift; check "  one more tap unlocks" "$(field shift)" '^0$'
taps d; check "  back to lower case" "$(typed)" '^ABCd$'

fresh; dbg down shift >/dev/null; sleep 0.5; dbg up shift >/dev/null; taps shift
check "long first press, then a quick second tap: still a double tap (window runs from the release)" "$(field shift)" '^2$'
taps shift

fresh; dbg down shift >/dev/null; taps a b c; st=$(dbg state)
check "hold shift: upper case while held" "$(typed)" '^ABC$'; check "  still held" "$st" '\\"shiftHeld\\":1'
dbg up shift >/dev/null; check "  release after typing: off" "$(field shift)" '^0$'
taps d; check "  next letter lower case" "$(typed)" '^ABCd$'

fresh; seq_ "down shift;down a;up shift;up a"
check "two thumbs, shift lifts first" "$(typed)" '^A$'; check "  shift off" "$(field shift)" '^0$'

fresh; seq_ "down shift;tap h;tap e;tap l;tap l;down o;up shift;up o"
check "held shift, shift lifts just before the last letter: HELLO" "$(typed)" '^HELLO$'; check "  shift off" "$(field shift)" '^0$'

fresh; seq_ "down a;down shift;up a;up shift"
check "two thumbs, letter lands 1st (within grace)" "$(typed)" '^A$'; check "  shift off" "$(field shift)" '^0$'

fresh; seq_ "tap shift;down a;down shift;up a;up shift;tap b"
check "shift once, letter held, second shift before it lifts: AB, no stuck caps lock" "$(typed)" '^AB$'; check "  shift off" "$(field shift)" '^0$'

fresh; taps shift; sleep 0.6; taps shift
check "slow second tap: off, not locked" "$(field shift)" '^0$'
taps a; check "  lower case" "$(typed)" '^a$'

fresh; taps shift; dbg flick q >/dev/null; taps a
check "flick with shift once: hint, then the letter takes the shift" "$(typed)" '^1A$'

fresh; dbg down shift >/dev/null; taps comma; dbg up shift >/dev/null; taps a
check "held shift used by a non-letter: off on release" "$(typed)" '^,a$'

fresh; taps shift; dbg hold e:500 >/dev/null; sleep 0.7; taps c
check "shift once used by a long-press alternate (whichever item was under the finger), next letter lower case" "$(typed)" '^.c$'

fresh; dbg symlock off >/dev/null; dbg panel sym >/dev/null; st=$(dbg state)
check "symbol panel opens on the English page" "$st" '\\"symCat\\":1'
dbg sym 0 >/dev/null; check "first English symbol is !" "$(typed)" '^!$'
check "  unlocked: panel closed" "$(field panel)" '^\\"\\"$'
dbg panel sym >/dev/null; dbg symlock on >/dev/null; dbg sym 1 >/dev/null; dbg sym 2 >/dev/null
check "locked: panel stays open" "$(field panel)" 'sym'; check "  @ #" "$(typed)" '^!@#$'
dbg sym x >/dev/null; check "  bad index ignored" "$(typed)" '^!@#$'
dbg panel close >/dev/null; dbg symlock off >/dev/null

fresh; dbg down del >/dev/null; dbg move del:0:-40 >/dev/null; st=$(dbg state)
check "slide up from delete right away: clear pill shows" "$st" '\\"clearPill\\":true'
dbg move del:0:-90 >/dev/null; st=$(dbg state); check "  finger over the pill: hot" "$st" '\\"clearHot\\":true'
dbg move del:0:-160 >/dev/null; st=$(dbg state); check "  overshooting above the pill still counts" "$st" '\\"clearHot\\":true'
dbg up del >/dev/null; check "  release clears (one delete on press, then clear)" "$(typed)" '^<del><clr>$'
check "  pill gone" "$(field clearPill)" '^false$'
fresh; seq_ "down del;move del:0:-40;move del:-300:-40;up del"
check "slide up then away: nothing cleared, no repeat while sliding" "$(typed)" '^<del>$'

fresh
echo "---- $ok passed, $bad failed"
[ "$bad" = 0 ]
