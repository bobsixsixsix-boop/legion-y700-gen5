#!/bin/bash
# y15 prep: branch y15 in /usr/local/src/linux-t52 = y14 WITHOUT 1049, plus 1052-1057, ONE COMMIT PER PATCH FILE; then
# export every commit under its file name to /root/y15-export/ and compare the export with the input files.
# Run as root on the tablet:  bash /root/y15-branch.sh 2>&1 | tee /root/y15-branch.log
# Input:  /root/y15-patches/ = linux/kernel-y15/patches/* (27 patches + series). The 21 carried files are y14's export
#         byte for byte; 1052-1056 are format-patch exports of the Win11 simulation (see NOTES.md), 1053's
#         y700 paragraph corrected by hand afterwards (message only; SUMS below pins the final files); 1057 is a
#         format-patch export of the AV1 10-bit line-buffer fix written on Win11 (NOTES.md "1057").
# Output: branch y15 = t52-base + 27 commits, CHECKED OUT in linux-t52 (kbuild-y15.sh builds that); /root/y15-export/
#         (27 patches + series); the lines Y15_HEAD=... and Y15_TREE=... - paste the tree into kbuild-y15.sh after review.
# How 1049 is dropped: a cherry-pick replay, not "git rebase --onto aca532577^ aca532577 y15". y15 starts at 1049's parent
#   (y14~3, commit 19 of 22), gets 1050 and 1051 cherry-picked by their FULL hashes, then the six new files through
#   git am. Why not the rebase: it first needs a y15 that equals y14 and then rewrites it in place, and with
#   rebase.updateRefs set anywhere in the config it would also move every other branch pointing into the rewritten
#   range - y14 itself points at 1051. The replay names the exact commits (checked by subject first), only READS y14
#   (it is never checked out, moved or rewritten), and a conflict stops at a named commit. The tree is the same: the
#   script checks that y15~6 (after the cherry-picks) == y14's tree with 1049 reverted.
# Reproducible: fixed committer identity and date; cherry-pick and am keep the author, author date and message, so
#   Y15_REDO=1 recreates the very same commits (same Y15_HEAD).
# Safe to rerun:
#   - y15 exists and is complete (27 commits on t52-base, its first 19 are y14's, the last six name their files):
#     nothing is rebuilt, the branch is checked and re-exported;
#   - y15 exists but is partial (an earlier run stopped in a cherry-pick or am): refused, with the commands to clean up;
#     Y15_REDO=1 aborts the half-done cherry-pick/am (a leftover cherry-pick sequencer included), deletes y15 and
#     builds it again;
#   - branch y14 is never written. Every writing git command runs with gc.auto=0 and maintenance.auto=0: linux-t52 is a
#     worktree sharing linux-t47's object store (never "git gc --prune=now" there).
set -euo pipefail
W=/usr/local/src/linux-t52; PD=/root/y15-patches; EXP=/root/y15-export
[ "$(id -u)" = 0 ] || { echo "run as root (linux-t52 and /root/y15-patches are root's)"; exit 1; }
cd $W
export GIT_COMMITTER_NAME=y700-kbuild GIT_COMMITTER_EMAIL=y700-kbuild@localhost
export GIT_COMMITTER_DATE="Wed, 28 Oct 2026 12:00:00 +0900"
G="git -c gc.auto=0 -c maintenance.auto=0"
T52_TREE=ef2f8b3397ef66fa1bd694b87cf1f1272e4e7a37
Y14_HEAD=5a21a30d2c6bb32ec395e57f5b61c6f92f65d63d; Y14_TREE=3ebb70be1ebb2367ea80fe1b118712c8a002dbdf
C1049=aca532577178d2d7153eb26246b3a072108a7b6a
C1050=4b29628178a5edac4925a7d27930a294c1bb7508
C1051=5a21a30d2c6bb32ec395e57f5b61c6f92f65d63d
NEW="1052-media-iris-recycle-decoder-buffers-for-non-display-pictures.patch
1053-soc-qcom-smp2p-reset-inbound-state-only-on-restart.patch
1054-HID-uhid-read-the-output-queue-under-qlock.patch
1055-wifi-ath12k-fix-single-pdev-frequency-ranges.patch
1056-arm64-dts-qcom-baldur-wifi-root-port-t-power-on-80us.patch
1057-media-iris-vpu4x-size-the-AV1-line-buffer-for-10-bit-output.patch"
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
$NEW"
# ---- the input files: complete, LF only, the expected series
[ -f $PD/series ] || { echo "no $PD/series: copy linux/kernel-y15/patches/* to $PD/"; exit 1; }
CR=$'\r'	# outside $(...), and grep -U: both keep the CR on Git Bash too (the Win11 test run), no-ops on Linux
crs=$(grep -lU "$CR" $PD/series $PD/*.patch || true)
[ -z "$crs" ] || { echo "CR bytes in: $crs - re-copy linux/kernel-y15/patches/* (LF) with scp and compare sha256; do not edit them on the tablet"; exit 1; }
[ "$(cat $PD/series)" = "$EXPECTED_SERIES" ] || { echo "$PD/series is not y14 - 1049 + 1052..1057:"; diff <(echo "$EXPECTED_SERIES") $PD/series || true; exit 1; }
for n in $(cat $PD/series); do [ -f "$PD/$n" ] || { echo "MISSING PATCH FILE: $PD/$n"; exit 1; }; done
# the files reviewed on Win11 (kernel-y15/NOTES.md): the 21 carried ones are y14's files byte for byte
# Published copy: these are the sums of the maintainer's working files. The published patch files differ in their
# mail headers (author e-mail, Date in UTC, Originally from: lines), so recompute them (cd $PD && sha256sum series
# *.patch) and paste the result here before a rerun; the tree the branch ends at does not depend on those headers.
# The commit pins (Y14_HEAD and C1049-C1051 here, also in kbuild-y15.sh; Y15_HEAD in y16-branch.sh, kbuild-y16.sh and
# kbuild-y17.sh) are the maintainer's commits and cannot be reproduced: y14 was built without a fixed committer date,
# and the published headers differ. Re-pin them to your own branches. Only the *_TREE values (and the qcom_scm.c blob
# pin) carry over.
SUMS="772ec0a7503f1fda5a022ce504ed2865382b3f97d788b58b21943bbba7430f3c  series
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
0750bdad09fb525fa904cb641d68fa52d5075517eda6df355e64d2538f71c333  1057-media-iris-vpu4x-size-the-AV1-line-buffer-for-10-bit-output.patch"
(cd $PD && echo "$SUMS" | sha256sum --check --quiet --strict) || { echo "the input files are not the ones reviewed on Win11 (failures above)"; exit 1; }
echo "the 27 patches and the series match their pinned sha256"
for n in $NEW; do
	head -1 "$PD/$n" | grep -q '^From [0-9a-f]\{40\} ' || { echo "$n is not a format-patch mbox"; exit 1; }
	grep -qxF "y700 patch file: $n" "$PD/$n" || { echo "$n does not name itself (y700 patch file: line)"; exit 1; }
done
# ---- y14 exactly as pinned (only read here)
[ "$(git rev-parse -q --verify 'refs/heads/y14^{commit}')" = $Y14_HEAD ] || { echo "branch y14 is not $Y14_HEAD"; git log --oneline -1 y14 || true; exit 1; }
[ "$(git rev-parse 'y14^{tree}')" = $Y14_TREE ] || { echo "y14's tree is not $Y14_TREE"; exit 1; }
[ "$(git rev-parse 't52-base^{tree}')" = $T52_TREE ] || { echo "t52-base is not the tree prepared on 10-22"; exit 1; }
[ "$(git rev-list --count t52-base..y14)" = 22 ]
# the three short hashes resolve uniquely, to the pinned commits, at y14~2 / y14~1 / y14, with the expected subjects
want() {	# <short> <full> <position on y14> <subject>
	local full
	full=$(git rev-parse -q --verify "$1^{commit}") || { echo "$1 does not resolve to exactly one commit (ambiguous or missing)"; exit 1; }
	[ "$full" = "$2" ] || { echo "$1 resolves to $full, expected $2"; exit 1; }
	[ "$(git rev-parse "$3")" = "$2" ] || { echo "$3 is not $1"; exit 1; }
	[ "$(git log -1 --format=%s "$2")" = "$4" ] || { echo "$1 has subject '$(git log -1 --format=%s "$2")', expected '$4'"; exit 1; }
	echo "ok  $1 = $3: $4"
}
want aca532577 $C1049 y14~2 "media: iris: don't flag an empty PSC_LAST buffer as an error"
want 4b2962817 $C1050 y14~1 "drm/msm/dpu: reject gamma LUT blobs of the wrong size"
want 5a21a30d2 $C1051 y14 "media: iris: Preserve timestamps on error buffers"
# ---- the worktree: no half-done cherry-pick/am, nothing changed
# The sequencer directory counts too: "cherry-pick $C1050 $C1051" stopped at 1050, resolved by hand and finished with
# "git commit", has no CHERRY_PICK_HEAD any more but keeps sequencer/ (1051 still to do); git switch then refuses
# ("cannot switch branch while cherry-picking", git 2.55 in the Win11 sim4) and a new cherry-pick would fail "already
# in progress", on every Y15_REDO=1. The paths are per worktree (--git-path resolves that).
busy() { [ -d "$(git rev-parse --git-path rebase-apply)" ] || [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path sequencer)" ] || git rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null; }
if busy; then
	if [ "${Y15_REDO:-0}" = 1 ]; then
		echo "Y15_REDO=1: aborting the cherry-pick/am in progress"
		$G am --abort 2>/dev/null || true
		$G cherry-pick --abort 2>/dev/null || true
		$G cherry-pick --quit 2>/dev/null || true	# a leftover sequencer/ only: clears the state, HEAD stays (y15 is rebuilt below)
		busy && { echo "still a cherry-pick/am/rebase in progress: resolve it by hand"; exit 1; }
	else
		echo "a cherry-pick / am / rebase is in progress in $W (an earlier run stopped). Either rerun with Y15_REDO=1"
		echo "(aborts it, deletes y15, builds y15 again) or by hand: git am --abort; git cherry-pick --abort (a leftover"
		echo "sequencer without CHERRY_PICK_HEAD: git cherry-pick --quit); git status"
		exit 1
	fi
fi
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "tracked files changed in $W:"; git status --short --untracked-files=no | head; exit 1; }
b=$(git branch --show-current || true)
echo "linux-t52 is on ${b:-a detached HEAD} at $(git rev-parse --short HEAD), clean"
# ---- branch y15
complete() {
	[ "$(git rev-list --count t52-base..y15)" = 27 ] || return 1
	[ "$(git rev-parse 'y15~8')" = "$(git rev-parse "$C1049^")" ] || return 1
	local i=5 n
	for n in $NEW; do
		git log -1 --format=%B "y15~$i" | grep -qxF "y700 patch file: $n" || return 1
		i=$((i - 1))
	done
}
if git rev-parse -q --verify refs/heads/y15 >/dev/null; then
	if [ "${Y15_REDO:-0}" = 1 ]; then
		echo "Y15_REDO=1: deleting branch y15 ($(git rev-parse --short y15)) to build it again"
		[ "$(git branch --show-current)" = y15 ] && $G switch -q --detach "$C1049^"
		$G branch -D y15
	elif complete; then
		echo "branch y15 exists and is complete: not rebuilt, only checked and re-exported"
		[ "$(git branch --show-current)" = y15 ] || $G switch -q y15
	else
		echo "branch y15 exists but is not a complete y15 ($(git rev-list --count t52-base..y15) commits on t52-base):"
		git log --oneline "$C1049^..y15" || true
		echo "rerun with Y15_REDO=1 to delete and rebuild it (branch y14 is not affected)"
		exit 1
	fi
fi
if ! git rev-parse -q --verify refs/heads/y15 >/dev/null; then
	$G switch -q -c y15 "$C1049^"
	echo "y15 created at 1049's parent $(git log -1 --format='%h %s' HEAD)"
	# 1050, 1051: author, author date and message kept (no -x: their export must equal y14's files apart from line 1)
	$G cherry-pick --no-gpg-sign $C1050 $C1051
	for n in $NEW; do
		$G am -q --no-gpg-sign "$PD/$n"
		echo "am   $(git log -1 --format='%h %an: %s') <- $n"
	done
fi
# ---- what y15 is
[ "$(git branch --show-current)" = y15 ]
[ -z "$(git status --porcelain --untracked-files=no)" ]
[ "$(git rev-list --count t52-base..y15)" = 27 ]
[ "$(git rev-parse 'y15~8')" = "$(git rev-parse "$C1049^")" ] || { echo "y15's first 19 commits are not y14's"; exit 1; }
git log --format='%h %an | %s' "$C1049^..y15"
# y15~6 (after the two cherry-picks) == y14 with 1049 reverted (temporary index; worktree untouched)
export GIT_INDEX_FILE=/tmp/y15-branch-index
rm -f $GIT_INDEX_FILE
git read-tree y14
git diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$C1049^" $C1049 | git apply -R --cached
if [ "$(git write-tree)" = "$(git rev-parse 'y15~6^{tree}')" ]; then echo "Y14_MINUS_1049_OK: y15~6 == y14 with 1049 reverted"; else echo "Y14_MINUS_1049_MISMATCH"; exit 1; fi
rm -f $GIT_INDEX_FILE; unset GIT_INDEX_FILE
echo "files y15 changes against y14:"; git diff --stat y14 y15 | tail -10
[ "$(git diff --name-only y14 y15 | wc -l)" = 8 ]
R=drivers/media/platform/qcom/iris/iris_hfi_gen2_response.c
grep -q "HFI_BUF_FW_FLAG_LAST | HFI_BUF_FW_FLAG_PSC_LAST" $R && { echo "1049's line is still in $R"; exit 1; }
grep -q "return iris_hfi_gen2_requeue_output_buffer(inst, buf);" $R
grep -q "return hfi_vpu4x_buffer_line_av1d(width, height, is_opb, num_vpp_pipes," drivers/media/platform/qcom/iris/iris_vpu_buffer.c
# ---- export every commit under its series name; from 1050 on each commit must name its file
rm -rf $EXP; mkdir -p $EXP; cp $PD/series $EXP/series
i=0
for c in $(git rev-list --reverse t52-base..y15); do
	i=$((i + 1)); name=$(sed -n "${i}p" $EXP/series)
	if [ $i -ge 20 ]; then
		git log -1 --format=%B $c | grep -qxF "y700 patch file: $name" || { echo "commit $c (#$i) does not name $name"; exit 1; }
	fi
	git format-patch -q -1 --stdout $c > "$EXP/$name"
done
[ $i = 27 ]
# compare with the input: the first line (From <sha> ...), the index lines (abbreviated blob hashes), the version
# trailer (everything from the last "-- " line on) and the function-name text after a hunk header's closing "@@" may
# differ; nothing else may. The hunk text: the kernel's .gitattributes sets "*.[ch] diff=cpp", the Win11 subset copy the
# 1052-1057 files were made in has no .gitattributes, so git names a different line there (10-29, 1054:
# "try_again:" vs "static ssize_t uhid_char_read(...)"); the line numbers in the header are still compared, and the
# replay below checks that the export rebuilds y15's tree.
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
echo "EXPORT_MATCHES_INPUT: $ident byte-identical, $same equal but for line 1 / index lines / version trailer (expected 19 + 8)"
# the export replays to y15's tree on t52-base (temporary index; worktree untouched)
export GIT_INDEX_FILE=/tmp/y15-export-index
rm -f $GIT_INDEX_FILE
git read-tree t52-base
while read -r name; do git apply --cached "$EXP/$name"; done < $EXP/series
new=$(git rev-parse 'y15^{tree}')
[ "$(git write-tree)" = "$new" ] && echo "EXPORT_REPLAY_OK $new" || { echo EXPORT_REPLAY_MISMATCH; exit 1; }
rm -f $GIT_INDEX_FILE; unset GIT_INDEX_FILE
[ "$(git rev-parse y14)" = $Y14_HEAD ] && echo "y14 untouched: $Y14_HEAD"
echo "Y15_HEAD=$(git rev-parse y15)"
echo "Y15_TREE=$new"
echo Y15_BRANCH_OK
