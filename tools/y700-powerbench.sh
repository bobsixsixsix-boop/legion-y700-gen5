#!/bin/bash
# y700-powerbench.sh: where does the battery go with the screen on and nothing happening? (2026-10-15, owner:
# "是不是外设功耗偏高，续航优化只能砍亮度刷新率？"). ON BATTERY (unplug first), owner not touching the tablet.
# Runs by itself (systemd-run) so no ssh traffic pollutes it; one line per state from y700-powersample:
#   A  as is                        B  + all windows hidden (show desktop: nothing repaints)
#   C  + performance HUD off        D..G backlight 100 / 50 / 10 / 1 %  (autobright paused, slope of the backlight)
#   H  original brightness, panel fixed at 120 Hz on a still screen     I  screen off (DPMS): the platform floor
#   J  screen off + every desktop app frozen (cgroup freezer on the app-*.scope/.service user units: Chrome,
#      Claude, Telegram, Steam, games...; not Plasma/KWin, not our y700 units) - the owner's question
#      "does freezing the apps while the screen is off save much?" (2026-10-15), answered with a number
# Everything is put back at the end (trap): brightness, autobright, HUD mode, refresh policy, windows, DPMS, frozen apps.
# usage (root): systemd-run --unit y700-powerbench --collect /usr/local/libexec/y700-powerbench.sh
#   log: /var/log/y700-powerbench.txt     SETTLE / SECS override the per-state times
#   STATES=IJ runs only those states (letters), e.g. STATES=IJ systemd-run ... (screen-off states alone)
U=(sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus HOME=/home/user)
LOG=/var/log/y700-powerbench.txt
SETTLE=${SETTLE:-15}; SECS=${SECS:-60}; SHORT=${SHORT:-40}; STATES=${STATES:-ABCDEFGHIJ}
st() { case "$STATES" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
SB=(busctl --user call org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0 org.kde.ScreenBrightness.Display)
bright() { "${U[@]}" busctl --user get-property org.kde.ScreenBrightness /org/kde/ScreenBrightness/display0 org.kde.ScreenBrightness.Display Brightness | awk '{print $2}'; }
setbright() { "${U[@]}" "${SB[@]}" SetBrightness iu "$1" 1 >/dev/null; }
# "all windows hidden" = minimize every normal window and restore exactly those afterwards. NOT
# workspace.showingDesktop: that property does not exist in KWin 6.6 scripting (a silent no-op - the
# first run's B/C/H rows still had the Claude window on screen), and even a real show-desktop keeps the
# windows painted (windowaperture), so their frames would still pin the panel at 120 Hz.
MINI=/run/y700-powerbench.minimized
desktop() {
	if [ "$1" = true ]; then
		echo 'for (const w of workspace.windowList()) if (w.normalWindow && !w.minimized) { w.minimized = true; out(w.internalId); }' \
			| /usr/local/libexec/kwin-eval.sh > $MINI 2>/dev/null
		echo "$(date +%T) minimized $(wc -l < $MINI) windows" >> $LOG
	elif [ -s $MINI ]; then
		ids=$(sed 's/.*/"&"/' $MINI | paste -sd, -)
		echo "const ids = [$ids]; for (const w of workspace.windowList()) if (ids.includes(String(w.internalId))) w.minimized = false;" \
			| /usr/local/libexec/kwin-eval.sh >/dev/null 2>&1
		rm -f $MINI
	fi
}
sample() { sleep "$1"; /usr/local/libexec/y700-powersample.py "$2" "$3" >> $LOG 2>&1; }
FROZEN=/run/y700-powerbench.frozen
freeze_apps() {   # apps launched from Plasma each live in their own app-*.scope / app-*.service user unit
	"${U[@]}" systemctl --user list-units --type=scope,service --state=running --no-legend --plain 2>/dev/null \
		| awk '$1 ~ /^app-/ && $1 !~ /y700|plasma|kwin|fcitx|pipewire|wireplumber|dbus|xdg|kde/ {print $1}' > $FROZEN
	while read -r u; do "${U[@]}" systemctl --user freeze "$u" 2>/dev/null; done < $FROZEN
	echo "$(date +%T) frozen $(wc -l < $FROZEN) app units: $(tr '\n' ' ' < $FROZEN)" >> $LOG
}
thaw_apps() {
	[ -s $FROZEN ] || return 0
	while read -r u; do "${U[@]}" systemctl --user thaw "$u" 2>/dev/null; done < $FROZEN
	rm -f $FROZEN
}

b0=$(bright)
hud0=$("${U[@]}" /home/user/.local/bin/y700-hud-toggle status 2>/dev/null)
ab0=$("${U[@]}" systemctl --user is-active y700-autobright.service)
pol0=$(tb323fu-ctl --json status 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["Refresh"]["Policy"])' 2>/dev/null)
restore() {
	thaw_apps
	"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1
	[ "$pol0" = auto ] && tb323fu-ctl refresh auto >/dev/null 2>&1
	setbright "$b0"
	[ "$ab0" = active ] && "${U[@]}" systemctl --user start y700-autobright.service
	[ -n "$hud0" ] && [ "$hud0" != off ] && "${U[@]}" /home/user/.local/bin/y700-hud-toggle "$hud0" >/dev/null 2>&1
	desktop false
	[ -n "$INH" ] && { pkill -P "$INH" 2>/dev/null; kill "$INH" 2>/dev/null; }
	echo "$(date +%T) restored: brightness $b0, autobright $ab0, HUD $hud0, refresh $pol0" >> $LOG
}
trap restore EXIT
trap 'exit 1' INT TERM

# no idle dimming / screen-off / lock during the bench
"${U[@]}" kde-inhibit --power --screenSaver sleep 1500 >/dev/null 2>&1 </dev/null & INH=$!   # stdio detached: no ssh pipe held
# the display may already be off (PowerDevil idle policy): every screen-on state needs it on
"${U[@]}" kscreen-doctor --dpms on >/dev/null 2>&1; sleep 2

{ echo; echo "=== $(date '+%F %T') powerbench: brightness $b0, autobright $ab0, HUD $hud0, refresh policy $pol0, $(cat /sys/class/power_supply/qcom-battmgr-bat/status) $(cat /sys/class/power_supply/qcom-battmgr-bat/capacity)%"; } >> $LOG

st A && sample "$SETTLE" "$SECS" "A as is"
if st B; then desktop true;                                             sample "$SETTLE" "$SECS" "B windows hidden"; fi
if st C; then "${U[@]}" /home/user/.local/bin/y700-hud-toggle off >/dev/null 2>&1; sample "$SETTLE" "$SECS" "C + HUD off"; fi
if st D || st E || st F || st G; then
"${U[@]}" systemctl --user stop y700-autobright.service    # it would learn our brightness changes
st D && { setbright 10000;                                              sample 8 "$SHORT" "D backlight 100%"; }
st E && { setbright 5000;                                               sample 8 "$SHORT" "E backlight 50%"; }
st F && { setbright 1000;                                               sample 8 "$SHORT" "F backlight 10%"; }
st G && { setbright 100;                                                sample 8 "$SHORT" "G backlight 1%"; }
setbright "$b0"
fi
if st H && [ "$pol0" = auto ]; then
	tb323fu-ctl refresh manual 120 >/dev/null 2>&1;                     sample 8 "$SHORT" "H fixed 120 Hz, still"
	tb323fu-ctl refresh auto >/dev/null 2>&1
fi
if st I || st J; then "${U[@]}" kscreen-doctor --dpms off >/dev/null 2>&1; fi
st I && sample 25 90 "I screen off (DPMS)"
if st J; then freeze_apps; sample $(st I && echo 10 || echo 25) 90 "J screen off + apps frozen"; thaw_apps; fi
echo "$(date +%T) done" >> $LOG
