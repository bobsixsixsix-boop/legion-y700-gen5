#!/bin/sh
# voice-drop.sh [--force]: speech still being recognised must not be typed once its field lost the focus or
# the keyboard went away (10-31 audit osk A3, the 10-19 audit's D2), and dictating into one field sentence
# by sentence must still lose nothing. Drives a --preview keyboard through the debug hook: hold space to
# talk (the microphone records under a second; nothing is kept), release, then send the preview what fcitx5
# sends when the field loses the focus, or hide it. The audio goes to voice-asr-fake.py on 127.0.0.1, never
# to the real speech gateway: the fake answers after 1.5 s and logs per request "delivered", or "dropped" when the keyboard closed
# the connection first (the result was thrown away unread).
#   1-3: the window is never mapped and a preview types nothing: safe while someone uses the tablet.
#   4:   maps the preview keyboard for ~3 s: only with the display off, or with --force.
# Run as user, or as root (it switches to user). Needs the installed /usr/local/bin/y700-osk.
if [ "$(id -u)" = 0 ]; then exec sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0 sh "$(readlink -f "$0")" "$@"; fi
HERE=$(dirname "$(readlink -f "$0")")
P="busctl --user call fyi.y700.OskPreview"
dbg() { $P /Osk fyi.y700.Osk debug ss "$1" "${2:-x}"; }
ok=0; bad=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; ok=$((ok+1)); else echo "FAIL $1: got '$2' (want '$3')"; bad=$((bad+1)); fi; }

if busctl --user status fyi.y700.OskPreview >/dev/null 2>&1; then echo "a preview keyboard is already running (fyi.y700.OskPreview is taken); stop it first"; exit 3; fi
T=$(mktemp -d /tmp/voice-drop-XXXXXX)
PORT=18733
printf 'voice-drop-test\n' > "$T/code"
python3 "$HERE/voice-asr-fake.py" "$PORT" 1.5 "$T/log" & SRV=$!
Y700_OSK_PREVIEW_MS=120000 Y700_OSK_HIDDEN=1 Y700_OSK_ASR_URL="http://127.0.0.1:$PORT/v1/asr" Y700_OSK_ASR_CODE_FILE="$T/code" \
	y700-osk --preview >/dev/null 2>&1 & PID=$!
trap 'kill $PID $SRV 2>/dev/null; rm -rf "$T"' EXIT INT TERM
i=0; until dbg state 2>/dev/null | grep -q zh; do i=$((i+1)); [ $i -gt 40 ] && { echo "preview keyboard did not come up"; exit 3; }; sleep 0.25; done

# hold space 1 s (talking starts after 250 ms: ~0.75 s recorded, over the 0.35 s minimum); returns after the release
talk() { dbg hold space:1000 >/dev/null; sleep 1.2; }
# what the server did with each request since the last call, in request order: "delivered dropped ..."
verdicts() { sleep 2.5; sort -n "$T/log" 2>/dev/null | cut -d' ' -f2 | paste -sd' ' -; : > "$T/log"; }

talk
check "1 control: the answer is read (none at all: no microphone, or the fake gateway did not start)" "$(verdicts)" "delivered"

# the first sentence is still being recognised when the second one starts (README: 一句一句说时上一句不丢)
talk; talk
check "2 two sentences in a row into one field: both read" "$(verdicts)" "delivered delivered"

talk
busctl --user --expect-reply=no call fyi.y700.OskPreview /org/fcitx/virtualkeyboard/impanel org.fcitx.Fcitx5.VirtualKeyboard1 HideVirtualKeyboard
check "3 fcitx5 Hide (the field lost the focus) while recognising: dropped" "$(verdicts)" "dropped"

if [ "$1" = "--force" ] || grep -q Off /sys/class/drm/card*-DSI-1/dpms 2>/dev/null; then
	$P /Osk fyi.y700.Osk show >/dev/null; sleep 0.6
	talk
	$P /Osk fyi.y700.Osk hide >/dev/null
	check "4 the keyboard hidden while recognising: dropped" "$(verdicts)" "dropped"
else
	echo "SKIP 4 (maps the preview keyboard for ~3 s): the display is on; run with --force, or while it is off"
fi
echo "$ok passed, $bad failed"
[ "$bad" = 0 ]
