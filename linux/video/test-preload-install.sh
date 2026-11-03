#!/bin/bash
# test-preload-install.sh (2026-10-31 audit): offline test of the two ld.so.preload installers' order and of the yuv709
# apt hook's outcomes. ROOT ON THE TABLET, from a copy of y700/linux/video plus linux/gpu/install-no-waitboost.sh next to
# it or at ../gpu/. Needs what the installers' checks run (python3, sudo, systemctl, sshd), unshare and mount, a
# multiarch libm (/lib/<triplet>/libm.so.6) and an existing /etc/ld.so.preload (the tablet has one; the stale and other
# cases bind over it in a private mount namespace). A missing file or prerequisite is a FAIL, not a skip. No gcc, no
# GPU, no Chrome; nothing under /usr/local, /etc or the journal is changed:
#   order    each installer's part from CHECKS= to "touch $PRE" (its others() included), plus its iso() so that older
#            versions run too, with SO, PRE and W pointed into a temp dir. A text file as the "new library" is what
#            ld.so refuses to preload (an error on stderr, the stand-in for a library that breaks programs): the
#            installer must exit 3 and leave the installed copy as it was (before the fix it had already replaced it,
#            and with its line in /etc/ld.so.preload that is live at once).
#            A real library (a copy of libm) must pass and be installed.
#   stale    the installed copy is broken (a text file) and listed in /etc/ld.so.preload (a temp file bound over it in a
#            private mount namespace, after a healthy other line), the new library is real: it must pass and replace the
#            broken one. In e4a4183 the pre-check saw our own line, every program failed on the broken copy, exit 3, and a
#            rerun could never repair it.
#   other    the installed copy is healthy, ANOTHER line in /etc/ld.so.preload is broken, the new library is real: the
#            installer must stop at exit 3 with nothing changed. In aaad521 the pre-check hid all of /etc/ld.so.preload,
#            passed, replaced the library, and step 5 then took out our healthy line (exit 4, wrong library blamed).
#   aptcheck y700-yuv709-aptcheck --force with fake installers (exit 4, exit 3), DRYRUN, a fake logger, a fake libgallium:
#            exit 4 -> "taken out" + notify 已摘掉; exit 3 -> "nothing changed".
# 10 checks; prints ALL PASS only when all 10 ran and passed.
set -u
H=$(cd "$(dirname "$0")" && pwd)
B=$(mktemp -d /tmp/preload-install-test.XXXX); trap 'rm -rf $B' EXIT
fails=0
passes=0
check() { if [ "$2" = 1 ]; then echo "PASS $1"; passes=$((passes + 1)); else echo "FAIL $1 ${3:-}"; fails=$((fails + 1)); fi; }
LIBM=$(ls /lib/*-linux-gnu/libm.so.6 /usr/lib/*-linux-gnu/libm.so.6 2>/dev/null | head -n 1)

order() { # $1: installer, $2: "bogus", "real", "stale" or "other"; prints the region's exit code, then the installed file's tag
	local inst=$1 kind=$2 d lib
	d=$(mktemp -d $B/o.XXXX); mkdir $d/w
	lib=$(awk 'match($0, /^install -m 755 \$W\/[^ ]+/) { print substr($0, 19, RLENGTH - 18); exit }' "$inst")
	awk '/^iso\(\) \{/, /^\}/' "$inst" > $d/region      # unused by the current installers; e4a4183/aaad521 need it
	awk '/^CHECKS=\(/ { on = 1 } /^touch \$PRE/ { on = 0 } on' "$inst" >> $d/region
	echo old-good > $d/lib.so
	echo "$d/lib.so" > $d/preload
	if [ $kind = bogus ]; then echo "not a library" > $d/w/$lib; else cp "$LIBM" $d/w/$lib; fi
	case $kind in
	stale) echo "broken installed copy" > $d/lib.so; printf '%s\n%s\n' "$LIBM" "$d/lib.so" > $d/preload ;;
	other) cp "$LIBM" $d/lib.so; echo x >> $d/w/$lib      # healthy installed copy; the new one differs from it
	       echo "not a library" > $d/other.so; printf '%s\n%s\n' "$d/other.so" "$d/lib.so" > $d/preload ;;
	esac
	cp $d/lib.so $d/orig
	if [ $kind = stale ] || [ $kind = other ]; then
		unshare -m --propagation private bash -c 'mount --bind "$1" /etc/ld.so.preload || exit 99
			set -eu; SO=$2; PRE=/etc/ld.so.preload; W=$3; . $4' _ $d/preload $d/lib.so $d/w $d/region >$d/out 2>&1
	else
		( set -eu; SO=$d/lib.so; PRE=$d/preload; W=$d/w; . $d/region ) >$d/out 2>&1
	fi
	echo $?
	if cmp -s $d/lib.so $d/orig; then echo kept; elif cmp -s $d/lib.so "$LIBM"; then echo new; else echo replaced; fi
	[ -e $d/lib.so.new ] && echo leftover || echo clean
}

[ "$(id -u)" = 0 ] || check "running as root" 0
for x in python3 sudo systemctl unshare mount; do command -v $x >/dev/null || check "prerequisite: $x" 0; done
[ -x /usr/sbin/sshd ] || check "prerequisite: /usr/sbin/sshd" 0
[ -n "$LIBM" ] || check "prerequisite: a multiarch libm.so.6" 0
[ -f /etc/ld.so.preload ] || check "prerequisite: /etc/ld.so.preload exists (the stale case binds over it)" 0
NWB=$H/install-no-waitboost.sh; [ -f "$NWB" ] || NWB=$H/../gpu/install-no-waitboost.sh
for inst in "$H/install-yuv709-shim.sh" "$NWB"; do
	n=$(basename "$inst")
	if [ ! -f "$inst" ]; then check "$n: installer not found at $inst" 0; continue; fi
	r=$(order "$inst" bogus | tr '\n' ' ')
	check "$n: a library ld.so cannot preload -> exit 3, installed copy untouched" "$([ "$r" = "3 kept clean " ] && echo 1)" "($r)"
	r=$(order "$inst" real | tr '\n' ' ')
	check "$n: a working library -> passes and is installed" "$([ "$r" = "0 new clean " ] && echo 1)" "($r)"
	r=$(order "$inst" stale | tr '\n' ' ')
	check "$n: installed copy broken and in ld.so.preload, new library works -> replaced" \
		"$([ "$r" = "0 new clean " ] && echo 1)" "($r)"
	r=$(order "$inst" other | tr '\n' ' ')
	check "$n: another line in ld.so.preload broken -> exit 3, installed copy untouched" \
		"$([ "$r" = "3 kept clean " ] && echo 1)" "($r)"
done

A=$H/y700-yuv709-aptcheck
if [ ! -f "$A" ]; then check "aptcheck not found at $A" 0; else
	mkdir $B/bin $B/gal
	printf '#!/bin/sh\nexit 0\n' > $B/bin/logger; chmod 755 $B/bin/logger
	: > $B/gal/libgallium-26.0.99-test.so
	echo /usr/local/lib/y700-yuv709.so > $B/pre-with
	printf '#!/bin/bash\necho "ok   Chrome, 1280x720 NV12, 601 hint: 709 limited"\necho "FAIL (ld.so.preload) [ls /] test"\necho "removed it"\nexit 4\n' > $B/inst4
	printf '#!/bin/bash\necho "FAIL (LD_PRELOAD) [ls /] test"\necho "the new library, or another line in /etc/ld.so.preload (see the error), breaks a system program; not installing" >&2\nexit 3\n' > $B/inst3
	hook() { PATH=$B/bin:$PATH Y700_YUV_DRYRUN=1 Y700_YUV_INSTALLER=$1 Y700_YUV_STAMP=$B/stamp Y700_YUV_GALLIUM_DIR=$B/gal \
		Y700_YUV_PRELOAD=$B/pre-with bash "$A" --force 2>&1; }
	o=$(hook $B/inst4)
	check "aptcheck: installer exit 4 -> taken out, notify 已摘掉" \
		"$(echo "$o" | grep -q 'took its line out' && echo "$o" | grep -q 'DRYRUN notify: Chrome 视频颜色垫片已摘掉' &&
		   ! echo "$o" | grep -q 'nothing changed' && echo 1)" "$o"
	o=$(hook $B/inst3)
	check "aptcheck: installer exit 3 -> nothing changed, notify 没法验证" \
		"$(echo "$o" | grep -q 'installer exit 3, cannot tell' && echo "$o" | grep -q 'DRYRUN notify: Chrome 视频颜色垫片：新版 Mesa 下没法验证' && echo 1)" "$o"
fi
[ $passes = 10 ] || [ $fails -gt 0 ] || { echo "FAIL only $passes of 10 checks ran"; fails=1; }
[ $fails = 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
