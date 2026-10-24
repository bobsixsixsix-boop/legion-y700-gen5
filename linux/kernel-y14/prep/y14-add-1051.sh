#!/bin/bash
# y14: add 1051 (iris: keep the timestamp on error buffers) as the 22nd commit on branch y14, re-export the series.
# Input: /root/y14-in-1051/1051-media-iris-preserve-timestamps-on-error-buffers.patch (= linux/kernel-y8/1051-*.patch)
#        /root/y14-patches/series (the 21-patch series of 10-22)
# Output: /root/y14-export/ (22 patches + series), printed tree hash.
set -euo pipefail
W=/usr/local/src/linux-t52; P=/root/y14-in-1051/1051-media-iris-preserve-timestamps-on-error-buffers.patch
EXP=/root/y14-export; OLD=/root/y14-patches
cd $W
export GIT_COMMITTER_NAME=y700-kbuild GIT_COMMITTER_EMAIL=y700-kbuild@localhost
G="git -c gc.auto=0 -c maintenance.auto=0"
[ "$(git branch --show-current)" = y14 ] || { echo "not on y14"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "linux-t52 has local changes"; exit 1; }
if [ "$(git rev-parse 'HEAD^{tree}')" != 2f676d5be31b114f97da25ec68ab9daae80a295f ]; then
	echo "y14 HEAD tree is not the 10-22 one (already has 1051?)"; git log --oneline -3; exit 1
fi
[ "$(git rev-list --count t52-base..HEAD)" = 21 ]
F=drivers/media/platform/qcom/iris/iris_buffer.c
grep -c "vb2->timestamp = 0;" $F
$G am -q --no-gpg-sign "$P"
git log -1 --format='%h %an <%ae> | committer %cn <%ce> | %s'
git show --stat HEAD | tail -3
# the error branch now keeps the timestamp; the only "= 0" assignment is gone
grep -n "vb2->timestamp" $F
grep -q "vb2->timestamp = 0;" $F && { echo "1051 did not land"; exit 1; }
[ "$(grep -c "vb2->timestamp = buf->timestamp;" $F)" = 2 ]
sed -n '/if (buf->flags & V4L2_BUF_FLAG_ERROR) {/,/^\t}/p' $F
# re-export all 22 commits under their file names (series order = commit order)
rm -rf $EXP; mkdir -p $EXP
{ cat $OLD/series; echo 1051-media-iris-preserve-timestamps-on-error-buffers.patch; } > $EXP/series
[ "$(wc -l < $EXP/series)" = 22 ]
i=0
for c in $(git rev-list --reverse t52-base..HEAD); do
	i=$((i + 1)); name=$(sed -n "${i}p" $EXP/series)
	# commits 1-21 are checked by the byte comparison with the 10-22 export below; 1051 names its file
	if [ $i = 22 ]; then git log -1 --format=%B $c | grep -qxF "y700 patch file: $name" || { echo "commit $c does not name $name"; exit 1; }; fi
	git format-patch -q -1 --stdout $c > $EXP/$name
done
[ $i = 22 ]
for name in $(cat $OLD/series); do cmp $OLD/$name $EXP/$name || { echo "re-export of $name differs from the 10-22 export"; exit 1; }; done
echo "the 21 old patches re-export byte-identically"
# the export replays to the new y14 tree (temporary index; worktree untouched)
export GIT_INDEX_FILE=/tmp/y14-1051-index
rm -f $GIT_INDEX_FILE
git read-tree t52-base
while read -r name; do git apply --cached "$EXP/$name"; done < $EXP/series
new=$(git rev-parse 'HEAD^{tree}')
[ "$(git write-tree)" = "$new" ] && echo "EXPORT_REPLAY_OK $new" || { echo EXPORT_REPLAY_MISMATCH; exit 1; }
rm -f $GIT_INDEX_FILE; unset GIT_INDEX_FILE
git rev-parse HEAD
git rev-list --count t52-base..HEAD
git status --porcelain --untracked-files=no | wc -l
git diff --stat t52-base HEAD | tail -25
echo ADD1051_OK
