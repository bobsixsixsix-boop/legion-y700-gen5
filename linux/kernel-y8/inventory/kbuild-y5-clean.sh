#!/bin/bash
# y700: build kernel y5 from a CLEAN tree, i.e. reproduce 7.3.0-rc4-tb323fu-t49-y5 without the hand-patched
# /usr/local/src/linux-t47 working copy. Everything the build depends on is pinned here:
#   base      torvalds/linux v7.3-rc4 = 93f51579e7df248780214094418f205253383cc5 (kernel/PROVENANCE.md of tb323fu-linux)
#   series    tb323fu-linux kernel/patches/0001..0130, 129 files (0115 does not exist; git am, the t47 = t49 series)
#   ours      y700-y5.patch (this directory): the 13-file y700 diff (battmgr, ath12k, iris VA-API, SSBS, GMU)
#   config    config-t49-y5 (this directory): upstream config-tb323fu-t49 + LOCALVERSION, as olddefconfig left it
#   toolchain clang 18 (/opt/llvm-18; clang 21 drops BTI and the modules Oops), pahole for BTF
#   extras    aw882xx out-of-tree module and the initramfs from tb323fu-linux (same checkout as the series)
# The tree is a git worktree of REPO (any repository that contains the base commit: the existing
# /usr/local/src/linux-t47 does, so no network is needed) at WORK. Stages:
#   prepare   worktree at the base, git am the series, apply y700-y5.patch, copy the config, olddefconfig;
#             asserts: the series lands on the same tree as linux-t47's HEAD (if that commit is in REPO),
#             `git diff` equals y700-y5.patch, the config equals config-t49-y5 apart from the INITRAMFS_* lines
#   build     the same steps as kbuild-y5.sh (modules, aw882xx, initramfs, Image), kernelrelease asserted
#   PREPARE_ONLY=1 ./kbuild-y5-clean.sh   stops after prepare (what was run on the tablet 2026-10-14)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=93f51579e7df248780214094418f205253383cc5
REPO=${REPO:-/usr/local/src/linux-t47}
UP=${UP:-/usr/local/src/tb323fu-linux}
WORK=${WORK:-/usr/local/src/linux-y5-clean}
OUT=${OUT:-/usr/local/src/y700-kernel-y5-clean}; MODS=${MODS:-/usr/local/src/y700-mods-y5-clean}
NAME=-tb323fu-t49-y5; REL=7.3.0-rc4-tb323fu-t49-y5
LLVM=${LLVM:-/opt/llvm-18/bin/}
Y5=$HERE/y700-y5.patch; CFG=$HERE/config-t49-y5
M="make LLVM=$LLVM LOCALVERSION= -j${JOBS:-8}"
# git am needs a committer identity in the fresh worktree (the patches keep their own authors)
export GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-y700-kbuild} GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-y700-kbuild@localhost}

# ---- toolchain and inputs
[ -f "$Y5" ] && [ -f "$CFG" ] || { echo "missing $Y5 or $CFG"; exit 1; }
"${LLVM}clang" --version | grep -q 'clang version 18\.' || { echo "clang 18 required at $LLVM"; exit 1; }
command -v pahole >/dev/null || { echo "pahole (dwarves) required for BTF"; exit 1; }
# the series is numbered 0001..0130 with 0115 absent (129 files; see kernel/PROVENANCE.md): check the ends, not the count
first=$(ls "$UP"/kernel/patches/*.patch | head -1); last=$(ls "$UP"/kernel/patches/*.patch | tail -1)
[[ $(basename "$first") == 0001-* && $(basename "$last") == 0130-* ]] || { echo "unexpected series in $UP/kernel/patches: $(basename "$first") .. $(basename "$last")"; exit 1; }
git -C "$REPO" cat-file -e "$BASE^{commit}" || { echo "$REPO does not contain the base commit $BASE"; exit 1; }

# ---- prepare: clean worktree at the base
if [ -e "$WORK" ]; then echo "$WORK exists; remove it (git -C $REPO worktree remove --force $WORK) to start clean"; exit 1; fi
git -C "$REPO" worktree add --detach "$WORK" "$BASE"
cd "$WORK"
git am --no-gpg-sign "$UP"/kernel/patches/*.patch
# the series must give the tree linux-t47 is built from (its HEAD is the series' last patch)
if ref=$(git -C "$REPO" rev-parse --verify -q HEAD) && git cat-file -e "$ref^{commit}"; then
	if git diff --quiet "$ref"; then echo "series == $REPO HEAD tree ($ref): OK"
	else echo "series differs from $REPO HEAD tree:"; git diff --stat "$ref"; exit 1; fi
fi
git apply --check "$Y5" && git apply "$Y5"
# the working-tree diff must be exactly the archived y700 patch (modulo index lines)
if diff <(git diff | grep -v '^index ') <(grep -v '^index ' "$Y5") >/dev/null; then echo "git diff == y700-y5.patch: OK"
else echo "git diff differs from y700-y5.patch:"; diff <(git diff | grep -v '^index ') <(grep -v '^index ' "$Y5") | head -40; exit 1; fi
cp "$CFG" .config
scripts/config --file .config --set-str LOCALVERSION "$NAME" --set-str INITRAMFS_SOURCE ""
$M olddefconfig
# config-t49-y5 was saved with INITRAMFS_SOURCE set (the final Image build), which pulls in the
# INITRAMFS_ROOT_UID/GID and INITRAMFS_COMPRESSION_* lines; with the source empty olddefconfig drops them.
# Everything else must be identical.
cfgcmp() { grep -vE '^(# )?CONFIG_INITRAMFS_' "$1"; }
if diff <(cfgcmp .config) <(cfgcmp "$CFG") >/dev/null; then echo ".config == config-t49-y5 (apart from INITRAMFS_*): OK"
else echo ".config differs from config-t49-y5 after olddefconfig:"; diff <(cfgcmp .config) <(cfgcmp "$CFG") | head -40; exit 1; fi
[ "$($M -s kernelrelease)" = "$REL" ] || { echo "kernelrelease is $($M -s kernelrelease), expected $REL"; exit 1; }
echo PREPARE_OK
[ "${PREPARE_ONLY:-0}" = 1 ] && exit 0

# ---- build (kbuild-y5.sh, verbatim apart from the paths)
mkdir -p "$OUT"
$M Image dtbs modules headers_install
rm -rf "$MODS"; $M INSTALL_MOD_PATH="$MODS" INSTALL_MOD_STRIP=1 modules_install
$M M="$UP/kernel/out-of-tree/aw882xx" clean
$M M="$UP/kernel/out-of-tree/aw882xx" CONFIG_SND_SOC_AW882XX=m modules
$M M="$UP/kernel/out-of-tree/aw882xx" CONFIG_SND_SOC_AW882XX=m INSTALL_MOD_PATH="$MODS" INSTALL_MOD_STRIP=1 modules_install
for ko in $(find "$MODS/lib/modules/$REL" -name '*.ko'); do
	case "$(modinfo -F vermagic "$ko")" in "$REL "*) ;; *) echo "BAD VERMAGIC $ko"; exit 1;; esac
done
rm -f "$MODS/lib/modules/$REL/build" "$MODS/lib/modules/$REL/source"; depmod -b "$MODS" "$REL"
"$UP/kernel/initramfs/build.sh" -k "$WORK" -b /bin/busybox -m "$MODS/lib/modules/$REL" -f / -a /etc/tb323fu/android-boot.sha256 -l "$OUT/initramfs.list" "$OUT/initramfs.cpio.gz"
scripts/config --file .config --set-str INITRAMFS_SOURCE "$OUT/initramfs.cpio.gz"
$M olddefconfig
$M Image
cp arch/arm64/boot/Image "$OUT/Image-t49-y5"; gzip -9 -n -c arch/arm64/boot/Image > "$OUT/Image-t49-y5.gz"
cp .config "$OUT/config-t49-y5"; git diff > "$OUT/y700-y5.patch"
strings "$OUT/Image-t49-y5" | grep -m1 "Linux version"
sha256sum "$OUT"/Image-t49-y5*
echo KFULL_OK
