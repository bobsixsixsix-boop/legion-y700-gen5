#!/bin/bash
# Moonlight's frame rate in the y700 HUD (top-left line), instead of the panel refresh rate.
#
# usage (root or user): ml-hud-fps.sh [on|off|status]
# The HUD (linux/games/hud/overlay/src/sampler.rs) shows "<n> FPS" only for a GPU process that has an FPS log; with
# none it falls back to the panel's refresh ("120Hz"), which is what Moonlight got. Same trick as y700-gl-hud for
# OpenGL games: Mesa's Gallium HUD, invisible, dumps the fps once a second into GALLIUM_HUD_DUMP_DIR, and the sampler
# finds that dir in the process's environ. Moonlight is a flatpak, so the variables and the dump dir go in as a user
# override (~/.local/share/flatpak/overrides/com.moonlight_stream.Moonlight; there was none before, "off" deletes it).
# The dir is exposed at the same path inside the sandbox, so the environ path is valid outside too.
# What the number is: Moonlight's EGL swaps per second = new stream frames put on screen (with frame pacing on, a
# repeated frame is no swap), so 120 at a clean 120 fps stream, lower when frames are late or dropped.
set -eu
APP=com.moonlight_stream.Moonlight
D=/home/user/.cache/y700-hud/gl/moonlight
as_user() { if [ "$(id -un)" = user ]; then "$@"; else sudo -u user "$@"; fi; }
case ${1:-on} in
on)
    as_user mkdir -p "$D"
    as_user flatpak override --user "$APP" \
        --env=GALLIUM_HUD=fps --env=GALLIUM_HUD_VISIBLE=false --env=GALLIUM_HUD_PERIOD=1 \
        --env=GALLIUM_HUD_DUMP_DIR="$D" --filesystem="$D:create"
    ;;
off)
    as_user flatpak override --user --reset "$APP"
    ;;
status) ;;
*) echo "usage: $0 [on|off|status]" >&2; exit 2 ;;
esac
as_user flatpak override --user --show "$APP"
