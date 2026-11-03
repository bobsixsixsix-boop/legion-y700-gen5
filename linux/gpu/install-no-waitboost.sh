#!/bin/bash
# install-no-waitboost.sh (2026-10-18): ROOT on the tablet, from a copy of y700/linux/gpu. Installs the wait-boost shim for
# every Chrome start (menu, taskbar, xdg-open, Plasma session restore, which replays Chrome's own command line and so
# bypasses an env prefix in the launcher):
#   1. builds y700-no-waitboost.c with gcc and runs test-no-waitboost.c against it (as "chrome" and as "other")
#   2. tries the new library, still in the temp dir, as an LD_PRELOAD on ls, sh, bash, python3, systemctl, sudo,
#      sshd -t (before step 3: with the line already in /etc/ld.so.preload the mv makes it live everywhere), with
#      only this library's own line hidden from /etc/ld.so.preload: a missing or broken installed copy would otherwise
#      fail every program here and the rerun meant to replace it could never get past this step; the other lines stay,
#      so a broken other library stops the run here (exit 3, nothing changed) instead of in step 5, which would take
#      out this library's healthy line (10-31 reviews)
#   3. installs /usr/local/lib/y700-no-waitboost.so as a NEW file + mv (a running Chrome maps the old inode; writing over
#      it in place would corrupt that Chrome's code pages)
#   4. adds its path to /etc/ld.so.preload (atomic mv, other lines kept). The shim only does anything in a process named
#      "chrome" (KWin, sshd, ... just carry an idle library), like /etc/drirc is matched by executable name.
#   5. runs the same programs again WITHOUT LD_PRELOAD; if any fails or complains, the line is taken out again
# Takes effect for Chrome processes started afterwards; a running Chrome keeps what it has (restart it).
# Undo: install-no-waitboost.sh --uninstall (removes the line, keeps the .so). Without a restart: printf Y0 >
# /run/user/1000/y700-no-waitboost.ctl switches the shim off in running Chrome processes.
set -eu
SO=/usr/local/lib/y700-no-waitboost.so
PRE=/etc/ld.so.preload
H=$(cd "$(dirname "$0")" && pwd)

remove_line() { # without sed/grep subprocesses that could themselves be hit by a broken preload: bash only
	local out="" l found=0
	[ -e $PRE ] || return 0
	while IFS= read -r l || [ -n "$l" ]; do
		if [ "$l" = "$SO" ]; then found=1; else out+="$l"$'\n'; fi
	done < $PRE
	[ $found = 1 ] || { echo "no $SO line in $PRE"; return 0; }
	if [ -n "$out" ]; then printf '%s' "$out" > $PRE.new && mv -f $PRE.new $PRE; else : > $PRE; rm -f $PRE; fi
	echo "removed $SO from $PRE"
}

if [ "${1:-}" = "--uninstall" ]; then remove_line; exit 0; fi

command -v gcc >/dev/null || { echo "gcc missing (apt install gcc)" >&2; exit 2; }
find "$H" -maxdepth 1 -type f \( -name '*.c' -o -name '*.sh' \) -exec sed -i 's/\r$//' {} +
W=$(mktemp -d /tmp/nwb-install.XXXX); trap 'rm -rf $W' EXIT
gcc -O2 -Wall -Wextra -shared -fPIC -o $W/y700-no-waitboost.so "$H/y700-no-waitboost.c" -ldl
gcc -O2 -Wall -o $W/chrome "$H/test-no-waitboost.c"; cp $W/chrome $W/other; mkdir $W/rt
iso() { # without /etc/ld.so.preload (the installed copy would hide a broken new one): private mount namespace
	if [ -s $PRE ]; then unshare -m --propagation private sh -c 'mount --bind /dev/null "$0" && exec "$@"' $PRE "$@"; else "$@"; fi
}
iso env XDG_RUNTIME_DIR=$W/rt LD_PRELOAD=$W/y700-no-waitboost.so $W/chrome active $W/rt/y700-no-waitboost.ctl > $W/t1 || true
iso env XDG_RUNTIME_DIR=$W/rt LD_PRELOAD=$W/y700-no-waitboost.so $W/other > $W/t2 || true
tail -1 $W/t1 | grep -qx PASSED && tail -1 $W/t2 | grep -qx PASSED || { grep -h FAIL $W/t1 $W/t2 >&2; echo "unit tests FAILED" >&2; exit 5; }
echo "unit tests pass ($(grep -c '^ok' $W/t1) + $(grep -c '^ok' $W/t2) checks)"

CHECKS=("ls /" "sh -c true" "bash -c true" "python3 -c 1" "systemctl --version" "sudo -n true" "/usr/sbin/sshd -t")
run_checks() { # $1: label; prints the failures, returns 1 if any
	local c out bad=0
	for c in "${CHECKS[@]}"; do
		if ! out=$($c 2>&1 >/dev/null) || [ -n "$out" ]; then echo "FAIL ($1) [$c] ${out:0:120}"; bad=1; fi
	done
	return $bad
}
# the temp copy, BEFORE it replaces $SO: with the line already in $PRE (a rerun, the apt hook) the mv makes it live
# for every new process at once, and a library that fails here would have stayed installed (10-31 audit).
# Not under iso, which hides all of $PRE: a broken OTHER line would pass here and fail step 5, which then takes out
# our healthy line (exit 4). Our own line is hidden: a broken installed copy must not block its own repair (10-31 reviews)
others() { # "$@" with $PRE showing every line but ours (bash only, like remove_line)
	local l
	[ -e $PRE ] || { "$@"; return; }
	while IFS= read -r l || [ -n "$l" ]; do [ "$l" = "$SO" ] || printf '%s\n' "$l"; done < $PRE > $W/pre-others
	unshare -m --propagation private sh -c 'mount --bind "$0" "$1" && shift && exec "$@"' $W/pre-others $PRE "$@"
}
others env LD_PRELOAD=$W/y700-no-waitboost.so bash -c "$(declare -p CHECKS); $(declare -f run_checks); run_checks LD_PRELOAD" ||
	{ echo "the new library, or another line in $PRE (see the error), breaks a system program; not installing" >&2; exit 3; }

install -m 755 $W/y700-no-waitboost.so $SO.new && mv -f $SO.new $SO

touch $PRE
# rebuilt line by line: a last line without a newline would otherwise be glued to ours (two broken paths)
have=0; out=; l=; while IFS= read -r l || [ -n "$l" ]; do [ "$l" = "$SO" ] && have=1; out+="$l"$'\n'; done < $PRE
if [ $have = 0 ]; then
	printf '%s%s\n' "$out" "$SO" > $PRE.new && mv -f $PRE.new $PRE
fi
echo "$PRE now:"; cat $PRE
if run_checks "ld.so.preload"; then
	echo "INSTALL_OK $(sha256sum $SO | cut -c1-16)"
else
	echo "a program failed with the preload in place, taking it out again" >&2
	remove_line; run_checks "after undo" || true
	exit 4
fi
if [ -x /opt/google/chrome/chrome ]; then
	LD_TRACE_LOADED_OBJECTS=1 /opt/google/chrome/chrome 2>&1 | grep -q y700-no-waitboost && echo "a plain chrome start loads the shim (ldd view)" || echo "WARNING: chrome does not list the shim" >&2
fi
