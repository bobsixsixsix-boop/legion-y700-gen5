#!/bin/bash
# y16 prep: branch y16 in /usr/local/src/linux-t52 = branch y15 exactly as kept (77a55c5a723e) plus ONE commit, 1058
# (qcom_scm: disable SDI when download mode is switched off; linux/kernel-y16/NOTES.md); then export every commit under
# its file name to /root/y16-export/ and compare the export with the input files.
# Run as root on the tablet:  bash /root/y16-branch.sh 2>&1 | tee /root/y16-branch.log
# Input:  /root/y16-patches/ = linux/kernel-y16/patches/* (28 patches + series). The first 27 are y15's files byte for
#         byte (linux/kernel-y15/patches); 1058 is a format-patch export of the change written on Win11 against y15's
#         qcom_scm.c (blob 3eaa4c9ccf3c).
# Output: branch y16 = t52-base + 28 commits, CHECKED OUT in linux-t52 (kbuild-y16.sh builds that); /root/y16-export/
#         (28 patches + series); the lines Y16_HEAD=... and Y16_TREE=... - paste the tree into kbuild-y16.sh after review.
# y15 is only read (never checked out by this script, moved or rewritten): y16 is created at y15's pinned HEAD and gets
#   1058 through git am.
# Reproducible: fixed committer identity and date; am keeps the author, author date and message, so Y16_REDO=1
#   recreates the very same commit (same Y16_HEAD).
# Safe to rerun:
#   - y16 exists and is complete (28 commits on t52-base, y16~1 is y15, its last commit names 1058): nothing is
#     rebuilt, the branch is checked and re-exported;
#   - y16 exists but is not that (an earlier run stopped in am): refused; Y16_REDO=1 aborts a half-done am, deletes
#     y16 and builds it again;
#   - every writing git command runs with gc.auto=0 and maintenance.auto=0: linux-t52 is a worktree sharing
#     linux-t47's object store (never "git gc --prune=now" there).
set -euo pipefail
W=/usr/local/src/linux-t52; PD=/root/y16-patches; EXP=/root/y16-export
[ "$(id -u)" = 0 ] || { echo "run as root (linux-t52 and /root/y16-patches are root's)"; exit 1; }
cd $W
export GIT_COMMITTER_NAME=y700-kbuild GIT_COMMITTER_EMAIL=y700-kbuild@localhost
export GIT_COMMITTER_DATE="Sun, 01 Nov 2026 01:00:00 +0900"
G="git -c gc.auto=0 -c maintenance.auto=0"
T52_TREE=ef2f8b3397ef66fa1bd694b87cf1f1272e4e7a37
Y15_HEAD=77a55c5a723e99fc847feb6afcbb706427c4106b; Y15_TREE=9a591ab91e1e80714587b233ad7459b07928c26e
N1058=1058-firmware-qcom-scm-disable-SDI-when-download-mode-is-switched-off.patch
EXPECTED_SERIES="00y1-media-iris-decode-order-display-delay-and-deblock-controls.patch
00y2-power-supply-qcom_battmgr-status-power_now-and-charge-units-on-kaanapali.patch
00y3-wifi-ath12k-wcn7860-no-mlo-unless-asked.patch
00y4-wifi-ath12k-wcn7860-5g-160-knob.patch
00y5-wifi-ath12k-no-backup-beacon-miss-timer-for-stations.patch
0540-arm64-signal-reapply-the-ssbs-policy-on-sigreturn-sm8850.patch
0620-drm-msm-a6xx-hfi-irq-clears-only-the-cm3-fault.patch
0621-drm-msm-a6xx-bound-the-gmu-wait-for-a-fault-devcoredump.patch
0622-drm-msm-a6xx-mask-the-hfi-interrupt-before-booting-the-gmu.patch
1030-media-iris-send-the-stream-POC-type.patch
1031-media-iris-stop-AV1-tier-overwriting-HEVC-tier.patch
1032-media-iris-send-the-decoder-the-colour-info-the-firmware-reported.patch
1033-media-iris-send-the-decoder-the-bitstream-resolution-the-firmware-reported.patch
1041-ath12k-sta-ps-vif-cfg.patch
1042-memlat-android-tuning.patch
1043-cpuidle-psci-domain-allow_system_off.patch
1046-drm-msm-a6xx-honor-perfmode_bw-threshold-on-a8x.patch
1047-drm-msm-a6xx-fix-secondary-rail-vote-in-arc-votes.patch
1048-drm-msm-a6xx-fix-rpmh-dependency-votes.patch
1050-drm-msm-dpu-reject-undersized-gamma-lut.patch
1051-media-iris-preserve-timestamps-on-error-buffers.patch
1052-media-iris-recycle-decoder-buffers-for-non-display-pictures.patch
1053-soc-qcom-smp2p-reset-inbound-state-only-on-restart.patch
1054-HID-uhid-read-the-output-queue-under-qlock.patch
1055-wifi-ath12k-fix-single-pdev-frequency-ranges.patch
1056-arm64-dts-qcom-baldur-wifi-root-port-t-power-on-80us.patch
1057-media-iris-vpu4x-size-the-AV1-line-buffer-for-10-bit-output.patch
$N1058"
# ---- the input files: complete, LF only, the expected series
[ -f $PD/series ] || { echo "no $PD/series: copy linux/kernel-y16/patches/* to $PD/"; exit 1; }
CR=$'\r'	# outside $(...), and grep -U: both keep the CR on Git Bash too, no-ops on Linux
crs=$(grep -lU "$CR" $PD/series $PD/*.patch || true)
[ -z "$crs" ] || { echo "CR bytes in: $crs - re-copy linux/kernel-y16/patches/* (LF) with scp and compare sha256; do not edit them on the tablet"; exit 1; }
[ "$(cat $PD/series)" = "$EXPECTED_SERIES" ] || { echo "$PD/series is not y15's + 1058:"; diff <(echo "$EXPECTED_SERIES") $PD/series || true; exit 1; }
for n in $(cat $PD/series); do [ -f "$PD/$n" ] || { echo "MISSING PATCH FILE: $PD/$n"; exit 1; }; done
# the 27 carried files are y15's input files byte for byte (the sums of prep/y15-branch.sh), plus 1058 and the series
# Published copy: these are the sums of the maintainer's working files. The published patch files differ in their
# mail headers (author e-mail, Date in UTC, Originally from: lines), so recompute them (cd $PD && sha256sum series
# *.patch) and paste the result here before a rerun; the tree the branch ends at does not depend on those headers.
# The commit pins (Y15_HEAD here and in kbuild-y16.sh and kbuild-y17.sh; Y14_HEAD and C1049-C1051 in y15-branch.sh and
# kbuild-y15.sh) are the maintainer's commits and cannot be reproduced: y14 was built without a fixed committer date,
# and the published headers differ. Re-pin them to your own branches. Only the *_TREE values (and the qcom_scm.c blob
# pin) carry over.
SUMS="c79ae88e7a0a296ff7a4636b2299965d45eaf254ddab6cba164e38fa964b01b8  series
75270b6557f2d65c512c7cd8f8a8a9cdb3a7ae730259fac28ea42d9c89ff87b4  00y1-media-iris-decode-order-display-delay-and-deblock-controls.patch
10f53aa4353ac096f373f5667231765249573caafffa3d3d30be87554325e6b8  00y2-power-supply-qcom_battmgr-status-power_now-and-charge-units-on-kaanapali.patch
1f0bf26e3b716b0f25fa1ff7ec499652fcf648d942cb99eb529b8a8f749920e1  00y3-wifi-ath12k-wcn7860-no-mlo-unless-asked.patch
9c7a78cab22713d470766b36b146d6019182e8480983067f5ad0ef36bc8233f9  00y4-wifi-ath12k-wcn7860-5g-160-knob.patch
1a45b57cd9788f293847b7473c69d975aea62ad66be408bf4f7e054db28ed0a3  00y5-wifi-ath12k-no-backup-beacon-miss-timer-for-stations.patch
c691752db5aa6cbb9cb17bb0b0a5aa3c1b45906b5123344fc3b35670776a476b  0540-arm64-signal-reapply-the-ssbs-policy-on-sigreturn-sm8850.patch
3c407a9dbacebbd8951399848b06d2311fe1ca856ad7c26ff05345a54bb54e72  0620-drm-msm-a6xx-hfi-irq-clears-only-the-cm3-fault.patch
3a89931a42ae088e579cf00cdda255fe6e30c1df082ef8047cb79537c51769f8  0621-drm-msm-a6xx-bound-the-gmu-wait-for-a-fault-devcoredump.patch
a4679841af5d464fa0ff182deda5786b56d338ed7fccdbf8e3b35ef0d9a4a159  0622-drm-msm-a6xx-mask-the-hfi-interrupt-before-booting-the-gmu.patch
5a3e5632207fe1e35674a7dbe4e259c5a0d3ab32ddb4e5d8767c6fd9f8998f92  1030-media-iris-send-the-stream-POC-type.patch
f5613fb36eacb36b605cb6a93fc0d0611d0db162502accc089b7720fef46c47a  1031-media-iris-stop-AV1-tier-overwriting-HEVC-tier.patch
953cc0a5f48d41e50387e5b60aad002c949f3469cfdaceeb1c5dae432ea8ab8e  1032-media-iris-send-the-decoder-the-colour-info-the-firmware-reported.patch
297c5c56344b61402c16dd2668b91f65a1720a7ec7d7dca4239c93fa10ca5343  1033-media-iris-send-the-decoder-the-bitstream-resolution-the-firmware-reported.patch
0f7d8a41a4db73aed489e38a027e4154b2a2e1538241538f4f7cfbb397bf01e0  1041-ath12k-sta-ps-vif-cfg.patch
2df0d675fc0e88dfde493a2e99c22f08b1b164bdcc0aed161cea0ff15de163a7  1042-memlat-android-tuning.patch
9b1ccfcafc3fbae17a0b8f0c243ede5c507df4e4af436021e90f1887df0e6d96  1043-cpuidle-psci-domain-allow_system_off.patch
bed783ff07e4ad1a7ebaa0a2d9b566aa67e52e01611db1996c51d384067b0f55  1046-drm-msm-a6xx-honor-perfmode_bw-threshold-on-a8x.patch
bc1181717ef829d440562e81c8e817fa591ef656597d0836c0b9404444689b67  1047-drm-msm-a6xx-fix-secondary-rail-vote-in-arc-votes.patch
7c6962aa5a969d9c3e42993330141076d06eb172528528e893775bc1a661eeb9  1048-drm-msm-a6xx-fix-rpmh-dependency-votes.patch
b8a59bab5fa9bcfb016cdb9057dca3e4fc5200bfc4e8c17f4947d01a8e3ef4a2  1050-drm-msm-dpu-reject-undersized-gamma-lut.patch
84a19ac1a0c1d0d2a4984426808a9a1bdef7bcb5dd459adafc248d54fd1fa1c5  1051-media-iris-preserve-timestamps-on-error-buffers.patch
6ef812c7ccd616caae2f50dc305537a41a225834c3e3fa2a584f8b8dfd6f2fd4  1052-media-iris-recycle-decoder-buffers-for-non-display-pictures.patch
b34192b7aed9168c0cf9e67094329de899ae41802bf2706ce715f66495b2ff11  1053-soc-qcom-smp2p-reset-inbound-state-only-on-restart.patch
7896671574942d4824042e4fb3f4acb8eae433fcfdda05ac79d208cd82ee5c51  1054-HID-uhid-read-the-output-queue-under-qlock.patch
bf8f943402ad49e6061c5dd82f0e4933a69ce0554b43c2ac9b249daa300d8516  1055-wifi-ath12k-fix-single-pdev-frequency-ranges.patch
829a9a65eb24bfed93a67ea5308503d7f3160e0e53d5beb2810f387ba1f05fc5  1056-arm64-dts-qcom-baldur-wifi-root-port-t-power-on-80us.patch
0750bdad09fb525fa904cb641d68fa52d5075517eda6df355e64d2538f71c333  1057-media-iris-vpu4x-size-the-AV1-line-buffer-for-10-bit-output.patch
09f38a3a9e6f1380545e101adf55a69562f4033d4a687882dbc4004733a74e9c  $N1058"
(cd $PD && echo "$SUMS" | sha256sum --check --quiet --strict) || { echo "the input files are not the ones reviewed on Win11 (failures above)"; exit 1; }
echo "the 28 patches and the series match their pinned sha256"
head -1 "$PD/$N1058" | grep -q '^From [0-9a-f]\{40\} ' || { echo "$N1058 is not a format-patch mbox"; exit 1; }
grep -qxF "y700 patch file: $N1058" "$PD/$N1058" || { echo "$N1058 does not name itself (y700 patch file: line)"; exit 1; }
# ---- y15 exactly as kept (only read here)
[ "$(git rev-parse -q --verify 'refs/heads/y15^{commit}')" = $Y15_HEAD ] || { echo "branch y15 is not $Y15_HEAD"; git log --oneline -1 y15 || true; exit 1; }
[ "$(git rev-parse 'y15^{tree}')" = $Y15_TREE ] || { echo "y15's tree is not $Y15_TREE"; exit 1; }
[ "$(git rev-parse 't52-base^{tree}')" = $T52_TREE ] || { echo "t52-base is not the tree prepared on 10-22"; exit 1; }
[ "$(git rev-list --count t52-base..y15)" = 27 ]
# ---- the worktree: no half-done am/cherry-pick/rebase, nothing changed (the paths are per worktree)
busy() { [ -d "$(git rev-parse --git-path rebase-apply)" ] || [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path sequencer)" ] || git rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null; }
if busy; then
	if [ "${Y16_REDO:-0}" = 1 ]; then
		echo "Y16_REDO=1: aborting the am in progress"
		$G am --abort 2>/dev/null || true
		busy && { echo "still an am/cherry-pick/rebase in progress: resolve it by hand"; exit 1; }
	else
		echo "an am / cherry-pick / rebase is in progress in $W (an earlier run stopped). Rerun with Y16_REDO=1 (aborts"
		echo "a half-done am, deletes y16, builds it again) or by hand: git am --abort; git status"
		exit 1
	fi
fi
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "tracked files changed in $W:"; git status --short --untracked-files=no | head; exit 1; }
b=$(git branch --show-current || true)
echo "linux-t52 is on ${b:-a detached HEAD} at $(git rev-parse --short HEAD), clean"
# ---- branch y16
complete() {
	[ "$(git rev-list --count t52-base..y16)" = 28 ] || return 1
	[ "$(git rev-parse 'y16~1')" = $Y15_HEAD ] || return 1
	git log -1 --format=%B y16 | grep -qxF "y700 patch file: $N1058"
}
if git rev-parse -q --verify refs/heads/y16 >/dev/null; then
	if [ "${Y16_REDO:-0}" = 1 ]; then
		echo "Y16_REDO=1: deleting branch y16 ($(git rev-parse --short y16)) to build it again"
		[ "$(git branch --show-current)" = y16 ] && $G switch -q --detach $Y15_HEAD
		$G branch -D y16
	elif complete; then
		echo "branch y16 exists and is complete: not rebuilt, only checked and re-exported"
		[ "$(git branch --show-current)" = y16 ] || $G switch -q y16
	else
		echo "branch y16 exists but is not a complete y16 ($(git rev-list --count t52-base..y16) commits on t52-base):"
		git log --oneline "$Y15_HEAD..y16" || true
		echo "rerun with Y16_REDO=1 to delete and rebuild it (branch y15 is not affected)"
		exit 1
	fi
fi
if ! git rev-parse -q --verify refs/heads/y16 >/dev/null; then
	$G switch -q -c y16 $Y15_HEAD
	echo "y16 created at y15 $(git log -1 --format='%h %s' HEAD)"
	$G am -q --no-gpg-sign "$PD/$N1058"
	echo "am   $(git log -1 --format='%h %an: %s') <- $N1058"
fi
# ---- what y16 is
[ "$(git branch --show-current)" = y16 ]
[ -z "$(git status --porcelain --untracked-files=no)" ]
complete || { echo "y16 is not y15 + 1058"; exit 1; }
git log --format='%h %an | %s' "$Y15_HEAD~1..y16"
echo "files y16 changes against y15:"; git diff --stat $Y15_HEAD y16
[ "$(git diff --name-only $Y15_HEAD y16)" = drivers/firmware/qcom/qcom_scm.c ]
[ "$(git rev-parse "$Y15_HEAD:drivers/firmware/qcom/qcom_scm.c")" = 3eaa4c9ccf3cc7db30257a41a4c2df027349ed52 ]   # the blob 1058 was written against
# ---- export every commit under its series name; 1058 must name its file
rm -rf $EXP; mkdir -p $EXP; cp $PD/series $EXP/series
i=0
for c in $(git rev-list --reverse t52-base..y16); do
	i=$((i + 1)); name=$(sed -n "${i}p" $EXP/series)
	git format-patch -q -1 --stdout $c > "$EXP/$name"
done
[ $i = 28 ]
grep -qxF "y700 patch file: $N1058" "$EXP/$N1058"
# compare with the input as prep/y15-branch.sh does: line 1 (From <sha> ...), the index lines, the version trailer and
# the function-name text after a hunk header's closing "@@" may differ; nothing else may
norm() { awk 'NR > 1 && !/^index [0-9a-f]+\.\.[0-9a-f]+( [0-7]+)?$/ {if (/^@@ -/) $0 = substr($0, 1, index(substr($0, 3), "@@") + 3); l[++n] = $0} END {e = n; for (i = n; i > 0; i--) if (l[i] == "-- ") {e = i - 1; break}; for (i = 1; i <= e; i++) print l[i]}' "$1"; }
same=0; ident=0
while read -r name; do
	if cmp -s "$PD/$name" "$EXP/$name"; then ident=$((ident + 1)); continue; fi
	if [ "$(norm "$PD/$name")" = "$(norm "$EXP/$name")" ]; then
		same=$((same + 1)); echo "equal but for line 1 / index / trailer: $name"
	else
		echo "EXPORT DIFFERS FROM INPUT: $name"; diff <(norm "$PD/$name") <(norm "$EXP/$name") | head -30; exit 1
	fi
done < $EXP/series
echo "EXPORT_MATCHES_INPUT: $ident byte-identical, $same equal but for line 1 / index lines / version trailer (expected 19 + 9: y15's 19 + 8, and 1058)"
# the export replays to y16's tree on t52-base (temporary index; worktree untouched)
export GIT_INDEX_FILE=/tmp/y16-export-index
rm -f $GIT_INDEX_FILE
git read-tree t52-base
while read -r name; do git apply --cached "$EXP/$name"; done < $EXP/series
new=$(git rev-parse 'y16^{tree}')
[ "$(git write-tree)" = "$new" ] && echo "EXPORT_REPLAY_OK $new" || { echo EXPORT_REPLAY_MISMATCH; exit 1; }
rm -f $GIT_INDEX_FILE; unset GIT_INDEX_FILE
[ "$(git rev-parse y15)" = $Y15_HEAD ] && echo "y15 untouched: $Y15_HEAD"
echo "Y16_HEAD=$(git rev-parse y16)"
echo "Y16_TREE=$new"
echo Y16_BRANCH_OK
