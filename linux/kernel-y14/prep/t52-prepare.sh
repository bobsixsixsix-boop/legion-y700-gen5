#!/bin/bash
# y14 prep step 1: a NEW worktree of the linux-t47 repository at v7.3, upstream tb323fu-linux kernel-t52 series on top.
# Touches nothing in /usr/local/src/linux-t47's working tree (a worktree has its own index and HEAD).
set -euo pipefail
REPO=/usr/local/src/linux-t47
WORK=/usr/local/src/linux-t52
P=/root/t52-upstream-patches
export GIT_COMMITTER_NAME=y700-kbuild GIT_COMMITTER_EMAIL=y700-kbuild@localhost
G="git -c gc.auto=0 -c maintenance.auto=0"
[ -e "$WORK" ] && { echo "$WORK exists"; exit 1; }
[ "$(ls $P/*.patch | wc -l)" = 134 ] || { echo "expected 134 patches in $P"; exit 1; }
[ "$(git -C $REPO rev-parse 'v7.3^{commit}')" = c03c1a14507dfaf8b856c2608f9ac216021fc222 ]
time nice -n 10 $G -C $REPO worktree add --detach "$WORK" 'v7.3^{commit}'
cd "$WORK"
time nice -n 10 $G am --no-gpg-sign $P/*.patch
$G tag t52-base
git log --oneline -3
git status --short | head
echo T52_PREPARE_OK
