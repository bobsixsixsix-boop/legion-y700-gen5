#!/bin/bash
# install-yuv709-shim.sh (2026-10-23): ROOT on the tablet, from a copy of y700/linux/video (needs yuv709-shim.c,
# nv12-egl-matrix.c and, since 11-09, test-yuv709-loader-lock.sh). Installs the BT.709 shim for every Chrome start (menu, taskbar, xdg-open, Plasma session restore,
# which replays Chrome's own command line and bypasses the launchers), the same way as linux/gpu/install-no-waitboost.sh:
#   1. builds yuv709-shim.c and nv12-egl-matrix.c, and tests the shim (LD_PRELOAD, ld.so.preload hidden):
#      nv12m as the desktop user with Y700_YUV709=1 (stands in for Chrome): 1280x720 NV12 and 1920x1080 P010 with the 601
#      hint must come out BT.709 and 640x480 stay BT.601; without Y700_YUV709 (not Chrome) 1280x720 must stay BT.601; a
#      process with no libgallium calling it must get NULL back, not an abort; its first call must not deadlock with a
#      dlopen in another thread (test-yuv709-loader-lock.sh, 11-09)
#   2. tries the new library, still in the temp dir, as an LD_PRELOAD on ls, sh, bash, python3, systemctl, sudo,
#      sshd -t (before step 3: with the line already in /etc/ld.so.preload the mv makes it live everywhere), with
#      only this library's own line hidden from /etc/ld.so.preload: a missing or broken installed copy would otherwise
#      fail every program here and the rerun meant to replace it could never get past this step; the other lines stay,
#      so a broken other library stops the run here (exit 3, nothing changed) instead of in step 5, which would take
#      out this library's healthy line (10-31 reviews)
#   3. installs /usr/local/lib/y700-yuv709.so as a NEW file + mv (running processes map the old inode)
#   4. adds its path to /etc/ld.so.preload (atomic mv, other lines such as y700-no-waitboost.so kept). Outside
#      /opt/google/chrome/chrome the shim passes every call straight through.
#   5. runs the same programs again WITHOUT LD_PRELOAD; if any fails or complains, the line is taken out again
#   6. installs /usr/local/libexec/y700-yuv709-aptcheck + /etc/apt/apt.conf.d/99y700-yuv709: after every dpkg run that
#      changed Mesa's libgallium or the turnip, this script runs again (step 1 is the check); see that file (10-23)
# Takes effect for Chrome processes started afterwards; a running Chrome keeps what it has (restart it).
# Undo: install-yuv709-shim.sh --uninstall (removes the line, keeps the .so and the apt hook, which does nothing without
# the line); then restart Chrome. One Chrome without it:
# start it with Y700_YUV709=0 in its environment.
# install-yuv709-shim.sh --test: step 1 only (build and test the yuv709-shim.c next to this script, e.g. a candidate),
# prints TESTS_OK; nothing installed, /etc/ld.so.preload untouched (2026-11-09).
set -eu
SO=/usr/local/lib/y700-yuv709.so
PRE=/etc/ld.so.preload
U=$(id -nu 1000)
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
find "$H" -maxdepth 1 -type f \( -name '*.c' -o -name '*.sh' -o -name y700-yuv709-aptcheck \) -exec sed -i 's/\r$//' {} +
W=$(mktemp -d /tmp/yuv709-install.XXXX); trap 'rm -rf $W' EXIT; chmod 755 $W
gcc -O2 -Wall -Wextra -shared -fPIC -o $W/y700-yuv709.so "$H/yuv709-shim.c" -ldl
gcc -O1 -o $W/nv12m "$H/nv12-egl-matrix.c" -I/usr/include/libdrm -ldl -lm
cat > $W/nogallium.c <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
typedef void *(*fn)(void *, int, int, int, unsigned long, int *, int, int *, int *, int, int, int, int, unsigned,
                    unsigned *, void *);
int main(int argc, char **argv) {
	void *h = argc > 1 ? dlopen(argv[1], RTLD_NOW) : NULL;
	fn f = h ? (fn)dlsym(h, "dri2_from_dma_bufs") : NULL;
	if (!f) { puts("no symbol"); return 2; }
	unsigned e = 0;
	void *r = f(NULL, 1920, 1080, 0x3231564e, 0, NULL, 2, NULL, NULL, 0x327f, 0x3283, 0, 0, 0, &e, NULL);
	puts(r ? "non-NULL" : "NULL");
	return r != NULL;
}
EOF
gcc -O1 -Wall -o $W/nogallium $W/nogallium.c -ldl
iso() { # without /etc/ld.so.preload (the installed copy would hide a broken new one): private mount namespace
	if [ -s $PRE ]; then unshare -m --propagation private sh -c 'mount --bind /dev/null "$0" && exec "$@"' $PRE "$@"; else "$@"; fi
}
nv() { # $1: extra env ("" or Y700_YUV709=1), rest: nv12m args; prints what the 601 / narrow import came out as
	local e=$1; shift
	iso sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 VK_ICD_FILENAMES=/var/lib/tb323fu/mesa/icd/turnip.json \
		MESA_LOADER_DRIVER_OVERRIDE=zink LD_PRELOAD=$W/y700-yuv709.so $e timeout 60 $W/nv12m mod "$@" 2>/dev/null |
		awk '/^hint 601  range narrow/ { sub(/.*-> /, ""); sub(/ \(.*/, ""); print }'
}
bad=0
t() { # $1: what, $2: expected, $3: got
	if [ "$3" = "$2" ]; then echo "ok   $1: $3"; else echo "FAIL $1: expected '$2', got '$3'"; bad=1; fi
}
t "Chrome, 1280x720 NV12, 601 hint" "709 limited" "$(nv Y700_YUV709=1 1280x720)"
t "Chrome, 1920x1080 P010, 601 hint" "709 limited" "$(nv Y700_YUV709=1 p010 1920x1080)"
t "Chrome, 640x480 NV12 (SD), 601 hint" "601 limited" "$(nv Y700_YUV709=1 640x480)"
t "not Chrome, 1280x720 NV12, 601 hint" "601 limited" "$(nv "" 1280x720)"
t "Chrome, no libgallium loaded" "NULL" "$(iso env Y700_YUV709=1 $W/nogallium $W/y700-yuv709.so 2>/dev/null || true)"
# the 11-09 loader deadlock (dl* called inside dl_iterate_phdr's callback): a missing test file is a FAIL, not a skip
LT=$H/test-yuv709-loader-lock.sh
t "no loader deadlock against a dlopen in another thread, 20 runs" "LOCKTEST_OK" \
	"$(if [ -f "$LT" ]; then iso bash "$LT" $W/y700-yuv709.so 20 2>&1 | tail -n 1; else echo "$LT missing"; fi)"
[ $bad = 0 ] || { echo "shim tests FAILED, not installing" >&2; exit 5; }
[ "${1:-}" = --test ] && { echo "TESTS_OK (--test: nothing installed)"; exit 0; }

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
others env LD_PRELOAD=$W/y700-yuv709.so bash -c "$(declare -p CHECKS); $(declare -f run_checks); run_checks LD_PRELOAD" ||
	{ echo "the new library, or another line in $PRE (see the error), breaks a system program; not installing" >&2; exit 3; }

install -m 755 $W/y700-yuv709.so $SO.new && mv -f $SO.new $SO

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
# after every dpkg run: Mesa changed -> this script again, its tests above are the check (y700-yuv709-aptcheck's header).
# install unlinks the old file first, so the hook can be replaced while it is the one running this script
if [ -f "$H/y700-yuv709-aptcheck" ]; then
	install -D -m 755 "$H/y700-yuv709-aptcheck" /usr/local/libexec/y700-yuv709-aptcheck
	echo 'DPkg::Post-Invoke { "/usr/local/libexec/y700-yuv709-aptcheck || true"; };' > /etc/apt/apt.conf.d/99y700-yuv709
	/usr/local/libexec/y700-yuv709-aptcheck --stamp >/dev/null
	echo "apt hook: /etc/apt/apt.conf.d/99y700-yuv709 (Mesa recorded: $(cat /usr/local/share/y700-video/yuv709.mesa))"
else
	echo "WARNING: $H/y700-yuv709-aptcheck missing, no apt hook (copy all of linux/video/{yuv709-shim.c,nv12-egl-matrix.c,install-yuv709-shim.sh,y700-yuv709-aptcheck,test-yuv709-loader-lock.sh})" >&2
fi
if [ -x /opt/google/chrome/chrome ]; then
	LD_TRACE_LOADED_OBJECTS=1 /opt/google/chrome/chrome 2>&1 | grep -q y700-yuv709 && echo "a plain chrome start loads the shim (ldd view)" || echo "WARNING: chrome does not list the shim" >&2
fi
