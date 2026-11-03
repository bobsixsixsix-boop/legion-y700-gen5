#!/bin/bash
# y700: kernel build -y15 = y14 WITHOUT 1049, plus 1052-1057, on y14's base (upstream tb323fu-linux kernel-t52, v7.3).
#   Release 7.3.0-tb323fu-t52-y15. Derived from linux/kernel-y14/kbuild-y14.sh; NOTES.md next to this file has the why.
#
#   /usr/local/src/linux-t52 = a worktree of the linux-t47 repository (never "git gc --prune=now" there),
#     tag t52-base = v7.3 (c03c1a14507d) + upstream kernel-t52's 134 patches (unchanged since y14),
#     branch y15   = t52-base + our 27 patches, ONE COMMIT PER PATCH FILE, in linux/kernel-y15/patches/series order,
#                    made by prep/y15-branch.sh (branch y14 is only read, never moved):
#                    y14's first 19 commits (00y1 .. 1048, the same commits), 1050 and 1051 cherry-picked over the
#                    dropped 1049, then
#                    1052 iris: recycle decoder buffers for non-display pictures (radxa-pkg/libva-v4l2 v1.1.1
#                         patches/0005, Xilin Wu): a clean NOSHOW capture buffer is requeued inside the driver instead
#                         of reaching userspace as an empty error buffer; supersedes 1049 (its new empty-payload
#                         condition exempts every LAST buffer, which covers 1049's PSC_LAST case);
#                    1053 smp2p: reset inbound state only on restart (armada 0569);
#                    1054 uhid: read the output queue under qlock (armada 1008);
#                    1055 ath12k: single-pdev frequency ranges (armada 1021 = lore 20260715065218);
#                    1056 baldur-wifi DT: the Wi-Fi root port gets t-power-on-us = <80> (part 1 of 1045 only);
#                    1057 iris vpu4x: the AV1 LINE buffer gets the 10-bit per-pipe DPB/OPB part (written here, after
#                         av1-10bit-probe.sh on y14: START "insufficient resources" for some 10-bit AV1 sizes).
#   The script only builds that exact tree: branch y15 checked out, no tracked file changed, its tree = Y15_TREE below
#   (pinned by hand after y15-branch.sh printed it and its export was reviewed - the script refuses to run while the
#   placeholder is there), and the patch files in the repo (scp linux/kernel-y15/patches/* to /root/y15-patches/)
#   replay to it. To change the stack, rebuild y15 (Y15_REDO=1 bash /root/y15-branch.sh), re-pin - never patch the
#   worktree by hand. 1044 (Oryon DC ZVA) and 1045's part 2 (pcie_qcom.ltr_max_latency_us) are NOT in y15 (refused).
# Config = y14's recipe unchanged (same BASECFG, fragments, CMDLINE). None of the six new patches adds a Kconfig symbol,
#   so the config must equal y14's apart from the line that names the build: checked pre-build against
#   $Y14/config-t52-y14.pre-build and at the end against $Y14/config-t52-y14 (cfgcmp as in y13/y14, delta must be empty).
# The device tree is built into the Image (upstream 0021: CONFIG_ARM64_BUILTIN_FDT, the bootloader's DTB is ignored), so
#   1056 reaches the hardware only through the rebuilt built-in DTB: after the final link the script decompiles the DTB
#   that CONFIG_ARM64_BUILTIN_FDT_NAME names (exactly one t-power-on-us = <0x50>) and checks that its bytes are inside
#   arch/arm64/boot/Image (python3); the DTB is copied to $OUT.
# Run (y14, 10-23: 7 min full build from a clean tree, 1 min incremental, at Nice 19 on battery):
#   systemd-run --unit=y700-kbuild-y15 --collect -p Nice=19 -p CPUWeight=20 -p IOWeight=20 /bin/bash /root/kbuild-y15.sh
#                                                                                       -> log /root/y700-kernel-y15.log
#   CHECK_ONLY=1 bash /root/kbuild-y15.sh   stops after the tree checks, the grep assertions and the pre-build config
#                                         checks (no compile; log /root/y700-kernel-y15-check.log; leaves .config).
if [ "${CHECK_ONLY:-0}" = 1 ]; then LOG=/root/y700-kernel-y15-check.log; else LOG=/root/y700-kernel-y15.log; fi
Y15_TREE="9a591ab91e1e80714587b233ad7459b07928c26e"
# ^ y15^{tree}: the Y15_TREE= line that prep/y15-branch.sh printed (after Y15_BRANCH_OK), pasted here after review
case "$Y15_TREE" in
*[!0-9a-f]*|"") echo "Y15_TREE is still the placeholder: run /root/y15-branch.sh, review it, paste its Y15_TREE value into this script" | tee $LOG; exit 1 ;;
esac
[ ${#Y15_TREE} = 40 ] || { echo "Y15_TREE '$Y15_TREE' is not a full 40-digit tree hash" | tee $LOG; exit 1; }
exec > $LOG 2>&1
set -ex
export LC_ALL=C   # stable sort for the config delta, English git/make messages in the log
command -v pahole   # BTF needs it
command -v python3  # the built-in DTB check after the final link
SRC=/usr/local/src/linux-t52; UP=/usr/local/src/tb323fu-linux-t52; MODS=/usr/local/src/y700-mods-y15
NAME=-tb323fu-t52-y15; REL=7.3.0-tb323fu-t52-y15; OUT=/usr/local/src/y700-kernel-y15; FR=/root/y8-fragments
PD=/root/y15-patches; Y14=/usr/local/src/y700-kernel-y14
BASECFG=${BASECFG:-/root/config-t49.release}
T52_TREE=ef2f8b3397ef66fa1bd694b87cf1f1272e4e7a37   # t52-base^{tree} (v7.3 + 134 upstream t52 patches), as for y14
Y14_HEAD=5a21a30d2c6bb32ec395e57f5b61c6f92f65d63d   # branch y14 (tree 3ebb70be1ebb): y15's first 19 commits are its first 19
# the series, in application order: y14's minus 1049, then 1052-1057; 1044/1045 must not appear
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
1057-media-iris-vpu4x-size-the-AV1-line-buffer-for-10-bit-output.patch"
CMDLINE="fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 qcom_scm.download_mode=full baldur.end=hold consoleblank=120 no_console_suspend mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0 msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000"
case "$CMDLINE" in *allow_system_off*) echo "CMDLINE must stay y9's: 1043's knob defaults to N in C and must not look cmdline-dependent (Y10-NOTES.md)"; exit 1;; esac
[ -f "$BASECFG" ]
# y14's configs are the reference for y15's (both must still be there)
[ -f $Y14/config-t52-y14.pre-build ] && [ -f $Y14/config-t52-y14 ]
# the initramfs build.sh takes two files from OUTSIDE kernel/ (kbuild-y14.sh: added from the kernel-t52 tag on 10-23)
echo "4649391b1c72aed99c7e23f393ae5aaa4a5965e4e2bccf326032e874abcde2a5  $UP/android/back-to-android
c5a97de46ea8d28f212ed0d0eba2ecd780c401cae69deb1f7bc5980e0969814c  $UP/userspace/platform/src/keyhold.c" | sha256sum -c
[ -x $UP/kernel/initramfs/build.sh ] && [ -d $UP/kernel/out-of-tree/aw882xx ]
cd $SRC
# ---- the tree must be exactly branch y15 (checked BEFORE anything is written into the tree)
[ "$(git branch --show-current)" = y15 ] || { echo "check out branch y15 in $SRC (bash /root/y15-branch.sh makes it)"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "tracked files changed in $SRC: build only committed y15 states"; exit 1; }
grep -q WORKAROUND_QCOM_ORYON_DC_ZVA arch/arm64/tools/cpucaps && { echo "tree carries 1044 (y11): not part of y15"; exit 1; }
grep -q ltr_max_latency_us drivers/pci/controller/dwc/pcie-qcom.c && { echo "tree carries 1045 part 2 (ltr_max_latency_us): only its DT part (1056) is in y15"; exit 1; }
[ "$(git rev-parse 'v7.3^{commit}')" = c03c1a14507dfaf8b856c2608f9ac216021fc222 ]
[ "$(git rev-list --count v7.3..t52-base)" = 134 ]
[ "$(git rev-parse 't52-base^{tree}')" = $T52_TREE ] || { echo "t52-base is not the tree prepared on 10-22"; exit 1; }
[ "$(git rev-list --count t52-base..HEAD)" = 27 ]
[ "$(git rev-parse HEAD~8)" = "$(git rev-parse "$Y14_HEAD~3")" ] || { echo "y15's first 19 commits are not y14's (00y1 .. 1048)"; exit 1; }
[ "$(git rev-parse 'HEAD^{tree}')" = $Y15_TREE ] || { echo "y15 is not the pinned tree: re-export the patches and re-pin Y15_TREE after review"; exit 1; }
# the repo's patch files (linux/kernel-y15/patches -> $PD) re-create exactly this tree (temporary index, worktree untouched)
for p in $(cat $PD/series); do [ -f "$PD/$p" ] || { echo "MISSING PATCH FILE: $PD/$p"; exit 1; }; done
[ "$(wc -l < $PD/series)" = 27 ]
[ "$(cat $PD/series)" = "$EXPECTED_SERIES" ] || { echo "$PD/series is not y14 - 1049 + 1052..1057:"; diff <(echo "$EXPECTED_SERIES") $PD/series || true; exit 1; }
rm -f /tmp/y15-kbuild-index
GIT_INDEX_FILE=/tmp/y15-kbuild-index git read-tree t52-base
for p in $(cat $PD/series); do GIT_INDEX_FILE=/tmp/y15-kbuild-index git apply --cached "$PD/$p"; done
[ "$(GIT_INDEX_FILE=/tmp/y15-kbuild-index git write-tree)" = $Y15_TREE ] || { echo "the patch files in $PD do not re-create y15"; exit 1; }
rm -f /tmp/y15-kbuild-index
git log --oneline t52-base..HEAD
# ---- grep assertions carried from y14 (the tree hash already pins the source, these say WHAT must be in it)
grep -q "mon_tunables = true" drivers/devfreq/scmi-qcom-memlat-devfreq.c   # 1042
# upstream 0131/0132 (in t52-base)
grep -q "a DSPP can only be added to the pipeline on a modeset" drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c
grep -q "stop setting allow_modeset and move this check to the DPU" drivers/gpu/drm/msm/msm_atomic.c && { echo "0131 missing: the FIXME loop is still in msm_atomic_check"; exit 1; }
grep -q "qcom_battmgr_set_charge_current_limit" drivers/power/supply/qcom_battmgr.c
grep -q "POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT_MAX\] = BATT_CHG_CTRL_LIM_MAX" drivers/power/supply/qcom_battmgr.c
# 1043 with the properties RESEARCH.md 3.3 asks for (default N, RT guard, 0106 quirk kept, 0118 kept)
D=drivers/cpuidle/cpuidle-psci-domain.c
grep -q "module_param_cb(allow_system_off, &allow_system_off_ops, &allow_system_off, 0644);" $D
grep -q "^static bool allow_system_off;" $D                      # default N: no "= true"
grep -q "^static struct generic_pm_domain \*psci_system_pd;" $D
grep -q 'of_machine_is_compatible("lenovo,baldur")' $D           # 0106 quirk still sets the flag at probe
grep -q "psci_system_pd = pd;" $D
grep -q "WRITE_ONCE(psci_system_pd->flags, flags);" $D
grep -q "KERNEL_PARAM_OPS_FL_NOARG" $D                            # bool-like: a bare cmdline token means =1 (as 0118)
[ "$(grep -c "IS_ENABLED(CONFIG_PREEMPT_RT)" $D)" -ge 2 ]         # 0106's RT line + 1043's early return
grep -q "allow_cluster_off" $D                                    # 0118 untouched (two lines: set -e ignores a failing
grep -q "return -EBUSY;" $D                                       #   first member of an && list, and a "!" pipeline)
grep -q "genpd_lock" $D && { echo "1043 must not take the genpd lock (none is exported)"; exit 1; }
# 1046-1048
G=drivers/gpu/drm/msm/adreno/a6xx_gmu.c
grep -q "static inline int adreno_is_a6xx(struct adreno_gpu \*gpu)" drivers/gpu/drm/msm/adreno/adreno_gpu.h   # 1046
grep -q "if (adreno_is_a6xx(adreno_gpu) ||" $G                                                              # 1046
grep -q "if (!adreno_is_a7xx(adreno_gpu) ||" $G && { echo "1046 did not land: A8xx still votes perfmode everywhere"; exit 1; }
grep -q "if (sec\[j\] >= pri\[pindex\]) {" $G                                                              # 1047
[ "$(grep -c "a6xx_gmu_rpmh_dep_votes_init(&gpu->pdev->dev, gmu->dep_arc_votes," $G)" = 1 ]               # 1048
grep -q "a6xx_gmu_rpmh_dep_votes_init(gmu->dev, gmu->dep_arc_votes," $G && { echo "1048 did not land"; exit 1; }
# 1050
grep -q "invalid gamma LUT size %zu, expected %zu" drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c                         # 1050
[ "$(grep -c "DPU_GAMMA_LUT_SIZE \* sizeof(struct drm_color_lut)" drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c)" = 2 ]   # 1050 once
# 1051: the V4L2_BUF_FLAG_ERROR branch of iris_vb2_buffer_done() passes the firmware's timestamp on, no longer 0
I=drivers/media/platform/qcom/iris/iris_buffer.c
[ "$(grep -c "if (buf->flags & V4L2_BUF_FLAG_ERROR) {" $I)" = 1 ]
eb=$(sed -n '/if (buf->flags & V4L2_BUF_FLAG_ERROR) {/,/^\t}/p' $I); echo "$eb"
grep -q "state = VB2_BUF_STATE_ERROR;" <<<"$eb"                   # the range really is the error branch
grep -q "vb2->timestamp = buf->timestamp;" <<<"$eb"                # 1051
grep -q "vb2->timestamp = 0;" <<<"$eb" && { echo "1051 missing: the error branch still clears the timestamp"; exit 1; }
grep -q "vb2->timestamp = 0;" $I && { echo "1051: iris_buffer.c still zeroes a timestamp somewhere"; exit 1; }
# ==== y15 assertions BEGIN (run on Win11 against the simulation trees, kernel-y15/NOTES.md: pass on y15, stop on y14
# and on y15 with any one of 1052-1056 reverted; only files of the y14 subset are read between BEGIN and END; 1057's
# block was checked the same way afterwards, on y14 and y14 + 1057 copies of iris_vpu_buffer.c)
R=drivers/media/platform/qcom/iris/iris_hfi_gen2_response.c
# 1049 is dropped: 1052 rewrites the same condition and supersedes it
grep -q "HFI_BUF_FW_FLAG_LAST | HFI_BUF_FW_FLAG_PSC_LAST" $R && { echo "1049 is in the tree: y15 drops it (1052 supersedes it)"; exit 1; }
# 1052: a clean NOSHOW decoder buffer is requeued in the driver; the NOSHOW -> ERROR flag mapping is gone (one other
# ERROR mapping stays); LAST buffers (LAST and PSC_LAST both set V4L2_BUF_FLAG_LAST) are exempt from the empty check;
# requeueing is held back while a CAPTURE STOP response is pending
grep -q "return iris_hfi_gen2_requeue_output_buffer(inst, buf);" $R
grep -q "picture_type & HFI_GEN2_PICTURE_NOSHOW) {" $R
grep -qF "!(buf->flags & V4L2_BUF_FLAG_LAST)) {" $R
grep -qF "!(hfi_buffer->flags & HFI_BUF_FW_FLAG_LAST)) {" $R && { echo "1052 missing: the empty-payload check still reads the HFI flag"; exit 1; }
[ "$(grep -c "driver_flags |= V4L2_BUF_FLAG_ERROR;" $R)" = 1 ]
grep -qE "^[[:space:]]+bool[[:space:]]+output_stopping;" drivers/media/platform/qcom/iris/iris_hfi_gen2.h
[ "$(grep -c "inst_hfi_gen2->output_stopping = " drivers/media/platform/qcom/iris/iris_hfi_gen2_command.c)" = 2 ]
# 1053: qcom_smp2p_check_ssr() returns before the inbound loop unless a restart was detected
S=drivers/soc/qcom/smp2p.c
ssr=$(sed -n '/^static bool qcom_smp2p_check_ssr(/,/^}/p' $S); echo "$ssr"
grep -A1 "restart = restart_done != smp2p->ssr_ack;" <<<"$ssr" | grep -q "if (!restart)"
grep -A1 "if (!restart)" <<<"$ssr" | grep -q "return false;"
# 1054: uhid_char_read() snapshots the slot under qlock and copies from the snapshot
U=drivers/hid/uhid.c
grep -qF "ev = uhid->head == uhid->tail ? NULL : uhid->outq[uhid->tail];" $U
grep -qF "copy_to_user(buffer, ev, len)" $U
grep -qF "copy_to_user(buffer, uhid->outq[uhid->tail], len)" $U && { echo "1054 missing: the lockless outq read is still there"; exit 1; }
# 1055 (the two assertions linux/wifi/5GHZ-ARMADA-594-EVAL.md asks for, plus the 5 GHz index and no WMI-flag index left)
W=drivers/net/wireless/ath/ath12k/reg.c
grep -q "cap.band\[NL80211_BAND_2GHZ\].phy_id" $W
grep -q "single_pdev_only))" $W
grep -q "cap.band\[NL80211_BAND_5GHZ\].phy_id" $W
grep -q "cap.band\[WMI_HOST_WLAN_" $W && { echo "1055 missing: cap.band[] still indexed with a WMI flag"; exit 1; }
# 1056: t-power-on-us = <80> on the Wi-Fi root port (&pcie_port0, outside its wifi@0 child), once in the file; and
# pcie-qcom (v7.3, e9769bb17269) reads the property and programs it
B=arch/arm64/boot/dts/qcom/baldur-wifi.dtsi
[ "$(grep -c "t-power-on-us" $B)" = 1 ]
awk '/^&pcie_port0 [{]/ {f = 1} f && /^\tt-power-on-us = <80>;$/ {n++} f && /^}/ {f = 0} END {exit (n != 1)}' $B
grep -q 'of_property_read_u32(node, "t-power-on-us", &port->l1ss_t_power_on);' drivers/pci/controller/dwc/pcie-qcom.c
grep -q "dw_pcie_program_t_power_on(pcie->pci, port->l1ss_t_power_on);" drivers/pci/controller/dwc/pcie-qcom.c
# 1057 (added after the Win11 simulation, checked against the y14 subset copy only): the vpu4x AV1 line size takes
# ten_bit and adds the 10-bit per-pipe DPB/OPB part sized for 128x128 superblocks; the shared helper is no longer
# called directly from iris_vpu4x_dec_line_size()
V=drivers/media/platform/qcom/iris/iris_vpu_buffer.c
grep -q "^static u32 hfi_vpu4x_buffer_line_av1d(u32 frame_width, u32 frame_height, bool is_opb,$" $V
grep -q "size_dpb_opb(frame_height, AV1D_LCU_MAX_SIZE_PELS, true)" $V
v4l=$(sed -n '/^static u32 iris_vpu4x_dec_line_size(/,/^}/p' $V); echo "$v4l"   # the older VPUs keep the shared call
grep -q "return hfi_vpu4x_buffer_line_av1d(width, height, is_opb, num_vpp_pipes," <<<"$v4l"
grep -q "hfi_buffer_line_av1d(" <<<"$v4l" && { echo "1057 missing: vpu4x AV1 still uses the shared line size"; exit 1; }
# ==== y15 assertions END
# ---- config
M="make LLVM=/opt/llvm-18/bin/ LOCALVERSION= -j8"   # LOCALVERSION= also keeps setlocalversion from adding "+" (HEAD is no tag)
cp $BASECFG .config
scripts/config --file .config --set-str LOCALVERSION "$NAME" --set-str INITRAMFS_SOURCE "" --set-str CMDLINE "$CMDLINE"
# fragments: every line is applied explicitly (olddefconfig respects explicit values unless a `select` wins)
apply_fragment() {
	grep -E '^(# CONFIG_[A-Z0-9_]+ is not set|CONFIG_[A-Z0-9_]+=)' "$1" | while read -r line; do
		case "$line" in
		"# CONFIG_"*" is not set") s=${line#\# }; s=${s% is not set}; scripts/config --file .config --disable "${s#CONFIG_}" ;;
		*=y) scripts/config --file .config --enable "${line%=y}" ;;
		*=m) scripts/config --file .config --module "${line%=m}" ;;
		*=\"*) s=${line%%=*}; v=${line#*=}; v=${v#\"}; v=${v%\"}; scripts/config --file .config --set-str "${s#CONFIG_}" "$v" ;;
		*=*) s=${line%%=*}; scripts/config --file .config --set-val "${s#CONFIG_}" "${line#*=}" ;;
		esac
	done
}
apply_fragment $FR/y8-trim.fragment
apply_fragment $FR/y8-power.fragment
# known gap, kept for parity with y8..y14: the [A-Z0-9_] pattern above skips symbols with lower-case letters, so these
# trim lines were never applied (ARM_CCI5xx_PMU is off anyway through its dependency; SENSORS_SHT4x stays =m). NOTES.md.
grep -nE '^(# )?CONFIG_[A-Z0-9_]*[a-z]' $FR/y8-trim.fragment $FR/y8-power.fragment || true
$M olddefconfig
# ---- checks after olddefconfig (both directions; any deviation stops the build so it can be looked at)
check_config() {
	bad=0
	# t49 features that must survive (y7 list minus binderfs, plus binder off)
	for o in CONFIG_NTSYNC=m CONFIG_ZRAM_BACKEND_ZSTD=y CONFIG_EXFAT_FS=m CONFIG_LRU_GEN_ENABLED=y CONFIG_DEBUG_INFO_BTF=y \
		CONFIG_DEBUG_INFO_BTF_MODULES=n CONFIG_ANDROID_BINDER_IPC=n; do
		if [ "${o#*=}" = n ]; then grep -q "^${o%=n}=" .config && { echo "UNEXPECTED ${o%=n} set"; bad=1; }
		elif ! grep -qx "$o" .config; then echo "MISSING $o"; bad=1; fi
	done
	grep -qx "CONFIG_CMDLINE=\"$CMDLINE\"" .config || { echo "CMDLINE not as intended"; bad=1; }
	# 1043 lives in the PSCI domain driver, which must stay built in (the knob is /sys/module/cpuidle_psci_domain/...)
	grep -qx "CONFIG_ARM_PSCI_CPUIDLE_DOMAIN=y" .config || { echo "ARM_PSCI_CPUIDLE_DOMAIN not built in"; bad=1; }
	grep -q "^CONFIG_PREEMPT_RT=y" .config && { echo "PREEMPT_RT is on: 1043's knob would be a no-op by design"; bad=1; }
	# must-keep: "SYMBOL y|m reason" lines ([A-Za-z0-9_] since y14, so FONT_TER16x32 / FONT_8x16 are checked too)
	grep -E '^[A-Za-z0-9_]+ [ym] ' $FR/y8-must-keep.txt | while read -r sym st _; do
		# any set value counts (bool y, tristate m, or an int/string such as BOOTPARAM_*_PANIC=1)
		grep -qE "^CONFIG_$sym=" .config || { echo "MUST-KEEP LOST: $sym (wanted $st)"; echo lost >> /tmp/y15-check-bad; }
	done
	# the fragments must have stuck: not-set lines are not y/m, =m lines are m, values as given
	for f in $FR/y8-trim.fragment $FR/y8-power.fragment; do
		grep -E '^# CONFIG_[A-Z0-9_]+ is not set' "$f" | while read -r _ sym _; do
			grep -qE "^$sym=[ym]$" .config && { echo "REVIVED by olddefconfig: $sym"; echo rev >> /tmp/y15-check-bad; }
		done
		grep -E '^CONFIG_[A-Z0-9_]+=' "$f" | while read -r line; do
			grep -qx "$line" .config || { echo "NOT APPLIED: $line (now: $(grep "^${line%%=*}[= ]" .config || echo unset))"; echo na >> /tmp/y15-check-bad; }
		done
	done
	[ -e /tmp/y15-check-bad ] && bad=1
	rm -f /tmp/y15-check-bad
	return $bad
}
rm -f /tmp/y15-check-bad
check_config || { echo "CONFIG CHECK FAILED - see above"; exit 1; }
grep -qx "CONFIG_LOCALVERSION=\"$NAME\"" .config
# ---- config delta against y14: none (cfgcmp leaves out comments and the two lines that name the build)
cfgcmp() { grep -vE "^CONFIG_(LOCALVERSION|INITRAMFS_SOURCE)=|^#" "$1"; }
cfgdelta() { diff <(cfgcmp "$1") <(cfgcmp "$2") | grep '^[<>]' | sort; }
delta=$(cfgdelta $Y14/config-t52-y14.pre-build .config)
echo "pre-build config delta vs y14 (expected: none):"; echo "$delta"
[ -z "$delta" ] || { echo "PRE-BUILD CONFIG DIFFERS FROM y14's (see above)"; exit 1; }
# ---- 1056 needs the built-in DTB: it must be on, and the DTB it names must be the one that includes baldur-wifi.dtsi
grep -qx "CONFIG_ARM64_BUILTIN_FDT=y" .config
fdt=$(sed -n 's/^CONFIG_ARM64_BUILTIN_FDT_NAME="\(.*\)"$/\1/p' .config); [ -n "$fdt" ]
DTB=arch/arm64/boot/dts/$fdt
grep -q '^#include "baldur-wifi.dtsi"' arch/arm64/boot/dts/${fdt%.dtb}.dts
if [ "${CHECK_ONLY:-0}" = 1 ]; then echo CHECK_ONLY_OK; exit 0; fi
mkdir -p $OUT
cp .config $OUT/config-t52-y15.pre-build
$M Image dtbs modules headers_install
rm -rf $MODS; $M INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
# aw882xx from the t52 copy; clean, then build and install in two separate makes
# (the y4 lesson: with -j8 one make ran the install before the build and shipped a stale aw882xx.ko)
$M M=$UP/kernel/out-of-tree/aw882xx clean
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m modules
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
rel=$($M -s kernelrelease); [ "$rel" = $REL ]
for ko in $(find $MODS/lib/modules/$rel -name '*.ko'); do   # every module must carry this kernel's vermagic
	case "$(modinfo -F vermagic $ko)" in "$rel "*) ;; *) echo "BAD VERMAGIC $ko"; exit 1;; esac
done
[ "$(modinfo -F version $MODS/lib/modules/$rel/kernel/drivers/net/wireless/ath/ath12k/ath12k.ko)" = y700-1041 ]   # 1041 is in-tree
rm -f $MODS/lib/modules/$rel/build $MODS/lib/modules/$rel/source; depmod -b $MODS $rel
ls $MODS/lib/modules/$rel/updates/
$UP/kernel/initramfs/build.sh -k $SRC -b /bin/busybox -m $MODS/lib/modules/$rel -f / -a /etc/tb323fu/android-boot.sha256 -l $OUT/initramfs.list $OUT/initramfs.cpio.gz
scripts/config --file .config --set-str INITRAMFS_SOURCE "$OUT/initramfs.cpio.gz"
$M olddefconfig
grep -qx "CONFIG_CMDLINE=\"$CMDLINE\"" .config
$M Image
# ---- 1056 in the built-in DTB, and that DTB inside the final Image
scripts/dtc/dtc -q -I dtb -O dts $DTB | grep -B3 -A1 "t-power-on-us"
[ "$(scripts/dtc/dtc -q -I dtb -O dts $DTB | grep -c "t-power-on-us = <0x50>;")" = 1 ]
python3 -I -c 'import sys; d = open(sys.argv[1], "rb").read(); sys.exit(0 if len(d) > 1024 and d in open(sys.argv[2], "rb").read() else 1)' $DTB arch/arm64/boot/Image
cp $DTB $OUT/
cp arch/arm64/boot/Image $OUT/Image-t52-y15; gzip -9 -n -c arch/arm64/boot/Image > $OUT/Image-t52-y15.gz
cp .config $OUT/config-t52-y15; git diff t52-base HEAD > $OUT/y700-y15.patch
delta=$(cfgdelta $Y14/config-t52-y14 $OUT/config-t52-y15)
echo "final config delta vs y14 (expected: none):"; echo "$delta"
[ -z "$delta" ] || { echo "FINAL CONFIG DIFFERS FROM y14's (see above)"; exit 1; }
strings $OUT/Image-t52-y15 | grep -m1 "Linux version"
# the 1043 knob is in the image: the built-in parameter name (__param section) and the report format string (rodata)
strings $OUT/Image-t52-y15 | grep -q "cpuidle_psci_domain.allow_system_off"
strings $OUT/Image-t52-y15 | grep -q "allow_system_off=%c, system domain state %s (%s)"
ls -la $OUT/Image-t52-y15 $Y14/Image-t52-y14
sha256sum $OUT/Image-t52-y15* $OUT/${DTB##*/}
echo KFULL_OK
