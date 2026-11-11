#!/bin/bash
# y18 prep: branch y18 in /usr/local/src/linux-t52 = branch y16 exactly as kept (82bf9859f5f6, the kernel of y16 and y17)
# plus EIGHT commits from upstream tb323fu-linux kernel-t58 (linux/kernel-y18/NOTES.md): 0144 (panel physical size),
# 0147-0151 (USB-C DisplayPort alt mode and sleep), 0152 (microSD: keep the card when its extension registers fail),
# 0153 (pen tilt axes; the y700 copy has its hunk context cut against t52's nt36xxx.c, the two changed lines are
# upstream's); then export every commit under its file name to /root/y18-export/ and compare the export with the input.
# Run as root on the tablet:  bash /root/y18-branch.sh 2>&1 | tee /root/y18-branch.log
# Input:  /root/y18-patches/ = linux/kernel-y18/patches/* (36 patches + series). The first 28 are y16's files byte for
#         byte (linux/kernel-y16/patches); 0144, 0147-0152 are kernel-t58's kernel/patches/ files byte for byte; 0153 is
#         the y700 rebase (its header says so).
# Output: branch y18 = t52-base + 36 commits, CHECKED OUT in linux-t52 (kbuild-y18.sh builds that); /root/y18-export/
#         (36 patches + series); the lines Y18_HEAD=... and Y18_TREE=... - paste the tree into kbuild-y18.sh after review.
# y16 is only read (never checked out by this script, moved or rewritten): y18 is created at y16's pinned HEAD and gets
#   the eight through git am.
# Reproducible: fixed committer identity and date; am keeps the author, author date and message, so Y18_REDO=1
#   recreates the very same commits (same Y18_HEAD).
# Safe to rerun:
#   - y18 exists and is complete (36 commits on t52-base, y18~8 is y16, its last commit names 0153): nothing is
#     rebuilt, the branch is checked and re-exported;
#   - y18 exists but is not that (an earlier run stopped in am): refused; Y18_REDO=1 aborts a half-done am, deletes
#     y18 and builds it again;
#   - every writing git command runs with gc.auto=0 and maintenance.auto=0: linux-t52 is a worktree sharing
#     linux-t47's object store (never "git gc --prune=now" there).
set -euo pipefail
W=/usr/local/src/linux-t52; PD=/root/y18-patches; EXP=/root/y18-export
[ "$(id -u)" = 0 ] || { echo "run as root (linux-t52 and /root/y18-patches are root's)"; exit 1; }
cd $W
export GIT_COMMITTER_NAME=y700-kbuild GIT_COMMITTER_EMAIL=y700-kbuild@localhost
export GIT_COMMITTER_DATE="Wed, 04 Nov 2026 17:00:00 +0900"
G="git -c gc.auto=0 -c maintenance.auto=0"
T52_TREE=ef2f8b3397ef66fa1bd694b87cf1f1272e4e7a37
Y16_HEAD=82bf9859f5f6f4f52bd24ef03376ce0dc965a165; Y16_TREE=ea8ec0f24f3d4a11f274b4840d1626c2ed042ec1
NEW="0144-drm-panel-nt36523-baldur-report-the-panel-physical-size.patch
0147-usb-typec-ucsi-Leave-the-mux-to-the-altmode-driver-f.patch
0148-arm64-configs-baldur-drop-no_console_suspend-from-th.patch
0149-usb-dwc3-qcom-Leave-DP-only-mode-from-the-mux-callba.patch
0150-drm-msm-dp-Track-the-PHY-power-and-link-clock-state.patch
0151-drm-msm-dp-Release-the-PHY-init-when-the-link-is-not.patch
0152-mmc-sd-Keep-the-card-when-its-extension-registers-fa.patch
0153-input-nt36536-report-the-pen-tilt-in-the-screen-s-ax.patch"
N0153=0153-input-nt36536-report-the-pen-tilt-in-the-screen-s-ax.patch
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
1058-firmware-qcom-scm-disable-SDI-when-download-mode-is-switched-off.patch
$NEW"
# ---- the input files: complete, LF only, the expected series
[ -f $PD/series ] || { echo "no $PD/series: copy linux/kernel-y18/patches/* to $PD/"; exit 1; }
CR=$'\r'	# outside $(...), and grep -U: both keep the CR on Git Bash too, no-ops on Linux
crs=$(grep -lU "$CR" $PD/series $PD/*.patch || true)
[ -z "$crs" ] || { echo "CR bytes in: $crs - re-copy linux/kernel-y18/patches/* (LF) with scp and compare sha256; do not edit them on the tablet"; exit 1; }
[ "$(cat $PD/series)" = "$EXPECTED_SERIES" ] || { echo "$PD/series is not y16's + the eight:"; diff <(echo "$EXPECTED_SERIES") $PD/series || true; exit 1; }
for n in $(cat $PD/series); do [ -f "$PD/$n" ] || { echo "MISSING PATCH FILE: $PD/$n"; exit 1; }; done
# the 28 carried files are y16's input files byte for byte (the sums of prep/y16-branch.sh); 0144, 0147-0152 are
# kernel-t58's (git show kernel-t58:kernel/patches/<name> on Win11, 11-04); 0153 is the y700 rebase; plus the series
# Published copy: these are the sums of the maintainer's working files. The published patch files differ in their
# mail headers (author e-mail, Date in UTC, Originally from: lines), so recompute them (cd $PD && sha256sum series
# *.patch) and paste the result here before a rerun; the tree the branch ends at does not depend on those headers.
# The commit pins (Y16_HEAD here and in kbuild-y18.sh) are the maintainer's commits and cannot be reproduced (the
# published headers differ); re-pin them to your own branches. Only the *_TREE values carry over.
SUMS="6cb3e44358256ceaca2fcc4bfb923c90f74e1fc626304b87de64bdb83f5c3e89  series
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
09f38a3a9e6f1380545e101adf55a69562f4033d4a687882dbc4004733a74e9c  1058-firmware-qcom-scm-disable-SDI-when-download-mode-is-switched-off.patch
57c3723e43a47e88fb2abddfc9cd5e73c582cb95134f8b524c9ff71bdfa0b326  0144-drm-panel-nt36523-baldur-report-the-panel-physical-size.patch
f35784e9010fab3e058c6d1824c4f11c64479d004dbbcbc0f823abf68afdf21a  0147-usb-typec-ucsi-Leave-the-mux-to-the-altmode-driver-f.patch
c946fa1d5b1302938f3cc957c260e8cc583eb3c8737cc2fe7bec22c761190b3a  0148-arm64-configs-baldur-drop-no_console_suspend-from-th.patch
fb3f6ce16e9f81a38c7ef16362ffa1c569cec99d3c7547ecbcdcd8e42c638afa  0149-usb-dwc3-qcom-Leave-DP-only-mode-from-the-mux-callba.patch
03f6d92dd65c8f0fe50c8d9185838501d8f792ce669d6a34a3bd034966ebe6c2  0150-drm-msm-dp-Track-the-PHY-power-and-link-clock-state.patch
3c06f42319c69716876de7b894b545beb53558d89d30497e754b73380554cbe9  0151-drm-msm-dp-Release-the-PHY-init-when-the-link-is-not.patch
5fc19deafa742e073d8e29da79abc253ba9d500d9452e283444c334f8170a912  0152-mmc-sd-Keep-the-card-when-its-extension-registers-fa.patch
9fea2649b7aff336e044982ceafde6aef48c3dc109c3e8c467b13f5021626ec4  $N0153"
(cd $PD && echo "$SUMS" | sha256sum --check --quiet --strict) || { echo "the input files are not the ones reviewed on Win11 (failures above)"; exit 1; }
echo "the 36 patches and the series match their pinned sha256"
for n in $NEW; do head -1 "$PD/$n" | grep -q '^From [0-9a-f]\{40\} ' || { echo "$n is not a format-patch mbox"; exit 1; }; done
grep -qxF "y700 patch file: $N0153" "$PD/$N0153" || { echo "$N0153 does not name itself (y700 patch file: line)"; exit 1; }
# no pen patch but 0153, and 0153 must not bring 0143/0145/0146 along (README "上游 tb323fu-linux 跟进" 11-02: not taken)
grep -q "pen_format_id == 0x02" "$PD/$N0153" && { echo "$N0153 carries 0143"; exit 1; }
grep -q "abs_x_max" "$PD/$N0153" && { echo "$N0153 was cut against 0145: not the y700 rebase"; exit 1; }
# ---- y16 exactly as kept (only read here)
[ "$(git rev-parse -q --verify 'refs/heads/y16^{commit}')" = $Y16_HEAD ] || { echo "branch y16 is not $Y16_HEAD"; git log --oneline -1 y16 || true; exit 1; }
[ "$(git rev-parse 'y16^{tree}')" = $Y16_TREE ] || { echo "y16's tree is not $Y16_TREE"; exit 1; }
[ "$(git rev-parse 't52-base^{tree}')" = $T52_TREE ] || { echo "t52-base is not the tree prepared on 10-22"; exit 1; }
[ "$(git rev-list --count t52-base..y16)" = 28 ]
# ---- the worktree: no half-done am/cherry-pick/rebase, nothing changed (the paths are per worktree)
busy() { [ -d "$(git rev-parse --git-path rebase-apply)" ] || [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path sequencer)" ] || git rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null; }
if busy; then
	if [ "${Y18_REDO:-0}" = 1 ]; then
		echo "Y18_REDO=1: aborting the am in progress"
		$G am --abort 2>/dev/null || true
		busy && { echo "still an am/cherry-pick/rebase in progress: resolve it by hand"; exit 1; }
	else
		echo "an am / cherry-pick / rebase is in progress in $W (an earlier run stopped). Rerun with Y18_REDO=1 (aborts"
		echo "a half-done am, deletes y18, builds it again) or by hand: git am --abort; git status"
		exit 1
	fi
fi
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "tracked files changed in $W:"; git status --short --untracked-files=no | head; exit 1; }
b=$(git branch --show-current || true)
echo "linux-t52 is on ${b:-a detached HEAD} at $(git rev-parse --short HEAD), clean"
# ---- branch y18
complete() {
	[ "$(git rev-list --count t52-base..y18)" = 36 ] || return 1
	[ "$(git rev-parse 'y18~8')" = $Y16_HEAD ] || return 1
	git log -1 --format=%B y18 | grep -qxF "y700 patch file: $N0153"
}
if git rev-parse -q --verify refs/heads/y18 >/dev/null; then
	if [ "${Y18_REDO:-0}" = 1 ]; then
		echo "Y18_REDO=1: deleting branch y18 ($(git rev-parse --short y18)) to build it again"
		[ "$(git branch --show-current)" = y18 ] && $G switch -q --detach $Y16_HEAD
		$G branch -D y18
	elif complete; then
		echo "branch y18 exists and is complete: not rebuilt, only checked and re-exported"
		[ "$(git branch --show-current)" = y18 ] || $G switch -q y18
	else
		echo "branch y18 exists but is not a complete y18 ($(git rev-list --count t52-base..y18) commits on t52-base):"
		git log --oneline "$Y16_HEAD..y18" || true
		echo "rerun with Y18_REDO=1 to delete and rebuild it (branch y16 is not affected)"
		exit 1
	fi
fi
if ! git rev-parse -q --verify refs/heads/y18 >/dev/null; then
	$G switch -q -c y18 $Y16_HEAD
	echo "y18 created at y16 $(git log -1 --format='%h %s' HEAD)"
	for n in $NEW; do
		$G am -q --no-gpg-sign "$PD/$n"
		echo "am   $(git log -1 --format='%h %an: %s') <- $n"
	done
fi
# ---- what y18 is
[ "$(git branch --show-current)" = y18 ]
[ -z "$(git status --porcelain --untracked-files=no)" ]
complete || { echo "y18 is not y16 + the eight"; exit 1; }
git log --format='%h %an | %s' "$Y16_HEAD~1..y18"
echo "files y18 changes against y16:"; git diff --stat $Y16_HEAD y18
[ "$(git diff --name-only $Y16_HEAD y18 | LC_ALL=C sort | tr '\n' ' ')" = "arch/arm64/configs/baldur.fragment drivers/gpu/drm/msm/dp/dp_ctrl.c drivers/gpu/drm/msm/dp/dp_display.c drivers/gpu/drm/panel/panel-novatek-nt36523.c drivers/input/touchscreen/nt36536/nt36xxx.c drivers/mmc/core/sd.c drivers/usb/dwc3/Kconfig drivers/usb/dwc3/dwc3-qcom.c drivers/usb/typec/ucsi/ucsi.c " ]
# the eight never touch a file the 28 touch (checked 11-04 with a temporary index, kept as a guard: the 28 stay y16's)
[ -z "$(LC_ALL=C comm -12 <(git diff --name-only t52-base $Y16_HEAD | LC_ALL=C sort) <(git diff --name-only $Y16_HEAD y18 | LC_ALL=C sort))" ]
# ---- export every commit under its series name; 0153 must name its file
rm -rf $EXP; mkdir -p $EXP; cp $PD/series $EXP/series
i=0
for c in $(git rev-list --reverse t52-base..y18); do
	i=$((i + 1)); name=$(sed -n "${i}p" $EXP/series)
	git format-patch -q -1 --stdout $c > "$EXP/$name"
done
[ $i = 36 ]
grep -qxF "y700 patch file: $N0153" "$EXP/$N0153"
# compare with the input as prep/y16-branch.sh does, but a hunk header counts as just "@@": its line numbers and
# function-name text may differ (upstream cut 0144, 0147-0152 against t55-t57 trees that carry 0142/0143/0145/0146, so
# their hunks sit a few lines lower there), as may line 1 (From <sha> ...), the index lines and the version trailer;
# nothing else may (the replay below proves the export still makes y18's tree). Folded mail header lines (a long
# Subject: upstream's git and the tablet's wrap at different words) are unfolded before comparing.
norm() { awk 'NR == 1 {hdr = 1} NR > 1 && !/^index [0-9a-f]+\.\.[0-9a-f]+( [0-7]+)?$/ {if (/^@@ -/) $0 = "@@"; if (hdr && /^ /) {l[n] = l[n] $0; next}; if ($0 == "") hdr = 0; l[++n] = $0} END {e = n; for (i = n; i > 0; i--) if (l[i] == "-- ") {e = i - 1; break}; for (i = 1; i <= e; i++) print l[i]}' "$1"; }
same=0; ident=0
while read -r name; do
	if cmp -s "$PD/$name" "$EXP/$name"; then ident=$((ident + 1)); continue; fi
	if [ "$(norm "$PD/$name")" = "$(norm "$EXP/$name")" ]; then
		same=$((same + 1)); echo "equal but for line 1 / index / trailer: $name"
	else
		echo "EXPORT DIFFERS FROM INPUT: $name"; diff <(norm "$PD/$name") <(norm "$EXP/$name") | head -30; exit 1
	fi
done < $EXP/series
echo "EXPORT_MATCHES_INPUT: $ident byte-identical, $same equal but for line 1 / index lines / version trailer (y16's 28 were 19 + 9)"
# the export replays to y18's tree on t52-base (temporary index; worktree untouched)
export GIT_INDEX_FILE=/tmp/y18-export-index
rm -f $GIT_INDEX_FILE
git read-tree t52-base
while read -r name; do git apply --cached "$EXP/$name"; done < $EXP/series
new=$(git rev-parse 'y18^{tree}')
[ "$(git write-tree)" = "$new" ] && echo "EXPORT_REPLAY_OK $new" || { echo EXPORT_REPLAY_MISMATCH; exit 1; }
rm -f $GIT_INDEX_FILE; unset GIT_INDEX_FILE
[ "$(git rev-parse y16)" = $Y16_HEAD ] && echo "y16 untouched: $Y16_HEAD"
echo "Y18_HEAD=$(git rev-parse y18)"
echo "Y18_TREE=$new"
echo Y18_BRANCH_OK
