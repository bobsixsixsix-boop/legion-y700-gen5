#!/bin/bash
# kill the whole Proton tree of Steam app $1 (never pkill -f a game's name from an ssh command line: it
# matches itself). The tree is found by environment, not by name: every process Steam starts for the
# game (reaper, Proton, wine, wineserver, the game itself) carries SteamAppId / SteamGameId = $1.
A=${1:-STEAM_APPID}
[ "$A" = STEAM_APPID ] && { echo "usage: steam-game-kill.sh STEAM_APPID (no default appid)" >&2; exit 2; }
tree() { for e in /proc/[0-9]*/environ; do
	p=${e#/proc/}; p=${p%/environ}; [ "$p" = "$$" ] && continue
	tr '\0' '\n' < "$e" 2>/dev/null | grep -qxE "Steam(App|Game)Id=$A" && echo "$p"; done; }
pids=$(tree); [ -n "$pids" ] || { echo "no process with SteamAppId/SteamGameId=$A"; exit 0; }
kill $pids 2>/dev/null; sleep 3
pids=$(tree); [ -n "$pids" ] && kill -9 $pids 2>/dev/null; sleep 1
echo "remaining: $(tree | wc -l)"
