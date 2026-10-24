#!/bin/bash
# y14 prep step 2: dry-run of the y13 stack (minus 0131/0132, now in t52) on linux-t52 = v7.3 + t52.
# Works on a throwaway branch y14-dry (re-created from t52-base each run); never touches linux-t47.
set -u
W=/usr/local/src/linux-t52; IN=/root/y14-in
cd $W
G="git -c gc.auto=0 -c maintenance.auto=0"
[ "$(git branch --show-current)" = y14-dry ] && git reset -q --hard   # leftovers of an earlier dry run only
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "linux-t52 has local changes"; exit 1; }
$G switch -q -C y14-dry t52-base
series="$IN/00y1-*.patch $IN/00y2-*.patch $IN/00y3-*.patch $IN/00y4-*.patch $IN/00y5-*.patch
/root/y4-patches/0540-*-sm8850.patch /root/y4-patches/0620-*.patch /root/y4-patches/0621-*.patch /root/y4-patches/0622-*.patch
/root/y6-patches/1030-*.patch /root/y6-patches/1031-*.patch /root/y6-patches/1032-*.patch /root/y7-patches/1033-*.patch
/root/y8-patches/1041-*.patch /root/y8-patches/1042-*.patch /root/y8-patches/1043-*.patch
/root/y13-patches/1046-*.patch /root/y13-patches/1047-*.patch /root/y13-patches/1048-*.patch /root/y13-patches/1049-*.patch /root/y13-patches/1050-*.patch"
n=0; fail=0
for p in $series; do
	n=$((n + 1))
	[ -f "$p" ] || { echo "MISSING $p"; exit 1; }
	echo "=== [$n] $(basename $p)"
	if git apply --check -v "$p" > /tmp/y14-apply.out 2>&1; then
		grep -E "offset|fuzz|warning" /tmp/y14-apply.out | sed 's/^/    /'
		git apply "$p" && echo "    OK"
	else
		fail=$((fail + 1))
		echo "    CHECK FAILED:"; grep -vE "^(Checking patch|Hunk #[0-9]+ succeeded)" /tmp/y14-apply.out | sed 's/^/      /'
		if git apply --3way "$p" > /tmp/y14-3way.out 2>&1; then
			echo "    3WAY: clean"; sed 's/^/      /' /tmp/y14-3way.out
		else
			echo "    3WAY: conflict"; sed 's/^/      /' /tmp/y14-3way.out
			git diff --diff-filter=U | head -80
			echo "    (stopping: later patches would be checked against a conflicted tree)"; break
		fi
	fi
done
echo "applied $n patch files, $fail needed more than a plain apply"
git status --short
# compare every touched file with the y13 working tree (/usr/local/src/linux-t47, read only)
echo "=== file comparison against linux-t47 (y13)"
for f in $(git -C /usr/local/src/linux-t47 diff --name-only); do
	if cmp -s "$f" "/usr/local/src/linux-t47/$f"; then echo "SAME     $f"
	else echo "DIFFERS  $f"; fi
done
rm -f /tmp/y14-apply.out /tmp/y14-3way.out
