#!/bin/bash
# 2026-10-18 06:58: Claude desktop's VizCompositorThread went 0/s after the 06:47 screen cycle, ticks again by 06:57.
# Read-only, 20 s: system domain / cluster rates, and every claude-desktop / chrome thread with >= 1 wakeup/s (with its
# process type), so we can tell an animating renderer from a compositor waiting on a frame that is never presented.
export LC_ALL=C
G=/sys/kernel/debug/pm_genpd
pd() { for d in cluster cluster1 system; do sed -n 2p $G/power-domain-$d/idle_states | awk '{printf "%s ", $3}'; done; }
list() { for t in /proc/[0-9]*/task/[0-9]*; do p=${t#/proc/}; p=${p%%/*}; case "$(cat /proc/$p/comm 2>/dev/null)" in claude-desktop|chrome)
	ty=$(tr '\0' '\n' < /proc/$p/cmdline | sed -n 's/^--type=//p' | head -1); echo "$p/${t##*/} ${ty:-browser}:$(tr ' ' _ < $t/comm) $(awk '/ctxt_switches/ {s += $2} END {print s}' $t/status)";; esac; done; }
a=$(pd); la=$(list); sleep 20; b=$(pd); lb=$(list)
echo "$a $b" | awk '{printf "20 s: cl0 %.1f/s  cl1 %.1f/s  sys %.1f/s\n", ($4-$1)/20, ($5-$2)/20, ($6-$3)/20}'
join <(echo "$la" | sort) <(echo "$lb" | sort) | awk '{r = ($5 - $3) / 20; if (r >= 1) printf "  %6.1f/s %s %s\n", r, $1, $2}' | sort -rn | head -20
echo "== claude-desktop children (Claude Code etc.)"; for p in $(pgrep -x claude-desktop); do pgrep -P $p -l | grep -v claude-desktop; done | head
echo "== journal from claude-desktop / kwin since 06:48 (last 15)"; journalctl --since 06:48 --no-pager -o short-precise _COMM=claude-desktop _COMM=kwin_wayland 2>/dev/null | tail -15 | cut -c1-220
