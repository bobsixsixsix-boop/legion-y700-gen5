#!/bin/bash
# y20 prep: branch y20 in /usr/local/src/linux-t52 = branch y19's commit exactly (05c8bc5831e5 = y18~1, tree e007de00615d).
# y20 changes no source, only the config (CONFIG_HID_MAGICMOUSE=m from linux/kernel-y8/owner-devices.fragment: the owner's
# Magic Mouse 2; linux/kernel-y20/NOTES.md). The branch exists so that kbuild-y20.sh builds from a tree that says "y20"
# (git branch --show-current), as every yNN since y14 has, and so that a later y19 rebuild cannot be mistaken for it.
# No patch is applied, nothing is exported: y19-branch.sh's export and replay (11-04 20:17, /root/y19-branch.log) already
# proved that /root/y19-patches re-creates this tree, and kbuild-y20.sh replays them again before building.
# Run as root on the tablet:  bash /root/y20-branch.sh 2>&1 | tee /root/y20-branch.log
# Output: branch y20 at y19's commit, CHECKED OUT in linux-t52; the lines Y20_HEAD=... and Y20_TREE=... (the values
#         kbuild-y20.sh pins: y19's, known on 11-04 before this script ever ran).
# y19 is only read. Safe to rerun: y20 at the right commit is just checked out again; y20 anywhere else is refused (look,
#   then by hand: git switch -q --detach <Y19_HEAD> first - y20 is the checked-out branch, git refuses to delete it
#   otherwise - then git branch -D y20 and rerun).
# Every writing git command runs with gc.auto=0 and maintenance.auto=0: linux-t52 is a worktree sharing linux-t47's object
#   store (never "git gc --prune=now" there).
set -euo pipefail
W=/usr/local/src/linux-t52
# Published copy: Y19_HEAD and Y16_HEAD here, Y20_HEAD (= y19's commit) and Y16_HEAD in kbuild-y20.sh, are the
# maintainer's commits and cannot be reproduced from the published patches (their mail headers differ); re-pin
# them to your own branches. Only the *_TREE values carry over.
Y19_HEAD=05c8bc5831e59f00ccd7f003d6f21e33f2e3490d; Y19_TREE=e007de00615d2baa0bd258582fab3e24f3094d15
Y16_HEAD=82bf9859f5f6f4f52bd24ef03376ce0dc965a165
[ "$(id -u)" = 0 ] || { echo "run as root (linux-t52 is root's)"; exit 1; }
cd $W
G="git -c gc.auto=0 -c maintenance.auto=0"
# ---- y19 exactly as kept (11-04 20:27): y16 + seven commits, y18~1
[ "$(git rev-parse -q --verify 'refs/heads/y19^{commit}')" = $Y19_HEAD ] || { echo "branch y19 is not $Y19_HEAD"; git log --oneline -1 y19 || true; exit 1; }
[ "$(git rev-parse 'y19^{tree}')" = $Y19_TREE ] || { echo "y19's tree is not $Y19_TREE"; exit 1; }
[ "$(git rev-list --count t52-base..y19)" = 35 ]
[ "$(git rev-parse 'y19~7')" = $Y16_HEAD ]
! git rev-parse -q --verify 'refs/heads/y18^{commit}' >/dev/null || [ "$(git rev-parse 'y18~1')" = $Y19_HEAD ] || { echo "y19 is not y18~1"; exit 1; }
# ---- the worktree: no half-done am/cherry-pick/rebase, nothing changed (the paths are per worktree)
busy() { [ -d "$(git rev-parse --git-path rebase-apply)" ] || [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path sequencer)" ] || git rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null; }
busy && { echo "an am / cherry-pick / rebase is in progress in $W: resolve it by hand (git status)"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "tracked files changed in $W:"; git status --short --untracked-files=no | head; exit 1; }
b=$(git branch --show-current || true)
echo "linux-t52 is on ${b:-a detached HEAD} at $(git rev-parse --short HEAD), clean"
# ---- branch y20 = y19's commit
if git rev-parse -q --verify refs/heads/y20 >/dev/null; then
	[ "$(git rev-parse y20)" = $Y19_HEAD ] || { echo "branch y20 exists at $(git rev-parse --short y20), not at y19's commit ${Y19_HEAD:0:12}: look (git log y20), then git switch -q --detach $Y19_HEAD (y20 is checked out, git will not delete it otherwise), git branch -D y20, and rerun"; exit 1; }
	echo "branch y20 exists at y19's commit: not recreated, only checked out"
else
	$G branch y20 $Y19_HEAD
	echo "y20 created at y19's commit $(git log -1 --format='%h %s' $Y19_HEAD)"
fi
[ "$(git branch --show-current)" = y20 ] || $G switch -q y20
# ---- what y20 is: y19's commit and tree, checked out, clean; y19 untouched
[ "$(git branch --show-current)" = y20 ]
[ "$(git rev-parse HEAD)" = $Y19_HEAD ]
[ "$(git rev-parse 'HEAD^{tree}')" = $Y19_TREE ]
[ -z "$(git status --porcelain --untracked-files=no)" ]
[ "$(git rev-parse y19)" = $Y19_HEAD ]
echo "y19 untouched: $Y19_HEAD"
echo "y20 == y19 ($(git rev-parse --short HEAD)): the same source, y20 differs in the config alone (kbuild-y20.sh)"
echo "Y20_HEAD=$(git rev-parse HEAD)"
echo "Y20_TREE=$(git rev-parse 'HEAD^{tree}')"
echo Y20_BRANCH_OK
