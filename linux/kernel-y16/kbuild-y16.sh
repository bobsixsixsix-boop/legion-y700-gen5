#!/bin/bash
# y700: kernel build -y16 = y15 (kept 10-29) plus 1058, on y15's base (upstream tb323fu-linux kernel-t52, v7.3), with
#   CONFIG_WATCHDOG_SYSFS=y and the initramfs of upstream kernel-t54. Release 7.3.0-tb323fu-t52-y16. Derived from
#   linux/kernel-y15/kbuild-y15.sh; NOTES.md next to this file has the why (README "10-31 21:04 死机").
#
#   /usr/local/src/linux-t52 = a worktree of the linux-t47 repository (never "git gc --prune=now" there),
#     tag t52-base = v7.3 (c03c1a14507d) + upstream kernel-t52's 134 patches (unchanged since y14),
#     branch y16   = branch y15 (77a55c5a723e: t52-base + our 27 patches, ONE COMMIT PER PATCH FILE) plus one commit,
#                    1058 qcom_scm: disable SDI when download mode is switched off after probe (written here: on 10-31
#                         a firmware-handled reset stayed in dump mode although download_mode was off),
#                    made by prep/y16-branch.sh (branch y15 is only read, never moved).
#   The script only builds that exact tree: branch y16 checked out, no tracked file changed, its tree = Y16_TREE below
#   (pinned by hand after y16-branch.sh printed it and its export was reviewed - the script refuses to run while the
#   placeholder is there), and the patch files in the repo (scp linux/kernel-y16/patches/* to /root/y16-patches/)
#   replay to it. To change the stack, rebuild y16 (Y16_REDO=1 bash /root/y16-branch.sh), re-pin - never patch the
#   worktree by hand. 1044 (Oryon DC ZVA) and 1045's part 2 (pcie_qcom.ltr_max_latency_us) stay out (refused for y15).
# Config = y15's recipe (same BASECFG, fragments, CMDLINE; qcom_scm.download_mode=full stays, so the first minutes after
#   boot keep SDI and their dumps until y700-dumpmode-off switches download mode off, NOTES.md) plus
#   CONFIG_WATCHDOG_SYSFS=y (/sys/class/watchdog/watchdog0/bootstatus and friends: what tells a watchdog reset apart
#   afterwards). 1058 adds no Kconfig symbol, so the config must equal y15's apart from the lines that name the build
#   and exactly that one line: checked pre-build against $Y15/config-t52-y15.pre-build and at the end against
#   $Y15/config-t52-y15.
# Initramfs: upstream kernel-t54's (UP = /usr/local/src/tb323fu-linux-t54, the same subset as the t52 copy: kernel/ plus
#   android/back-to-android and userspace/platform/src/keyhold.c, from the kernel-t54 tag tarball, NOTES.md). What this
#   build reads from it equals t52's apart from kernel/initramfs/init (a9b1d5f: say so when the state root does not mount
#   read-only, instead of silently not reading boot-next / boot-default / boot-menu); every file it reads is pinned by
#   sha256 below, and init is compared with what lands in the initramfs.
# The device tree is built into the Image (upstream 0021) and unchanged since y15: the y15 check of 1056 in the built-in
#   DTB is kept as it was.
# Run (y14, 10-23: 7 min full build from a clean tree, 1 min incremental, at Nice 19 on battery):
#   systemd-run --unit=y700-kbuild-y16 --collect -p Nice=19 -p CPUWeight=20 -p IOWeight=20 /bin/bash /root/kbuild-y16.sh
#                                                                                       -> log /root/y700-kernel-y16.log
#   CHECK_ONLY=1 bash /root/kbuild-y16.sh   stops after the tree checks, the grep assertions and the pre-build config
#                                         checks (no compile; log /root/y700-kernel-y16-check.log; leaves .config).
if [ "${CHECK_ONLY:-0}" = 1 ]; then LOG=/root/y700-kernel-y16-check.log; else LOG=/root/y700-kernel-y16.log; fi
Y16_TREE="ea8ec0f24f3d4a11f274b4840d1626c2ed042ec1"
# ^ y16^{tree}: the Y16_TREE= line that prep/y16-branch.sh printed (after Y16_BRANCH_OK), pasted here after review
case "$Y16_TREE" in
*[!0-9a-f]*|"") echo "Y16_TREE is still the placeholder: run /root/y16-branch.sh, review it, paste its Y16_TREE value into this script" | tee $LOG; exit 1 ;;
esac
[ ${#Y16_TREE} = 40 ] || { echo "Y16_TREE '$Y16_TREE' is not a full 40-digit tree hash" | tee $LOG; exit 1; }
exec > $LOG 2>&1
set -ex
export LC_ALL=C   # stable sort for the config delta, English git/make messages in the log
command -v pahole   # BTF needs it
command -v python3  # the built-in DTB check after the final link
SRC=/usr/local/src/linux-t52; UP=/usr/local/src/tb323fu-linux-t54
MODS=/usr/local/src/y700-mods-y16
NAME=-tb323fu-t52-y16; REL=7.3.0-tb323fu-t52-y16; OUT=/usr/local/src/y700-kernel-y16; FR=/root/y8-fragments
PD=/root/y16-patches; Y15=/usr/local/src/y700-kernel-y15
BASECFG=${BASECFG:-/root/config-t49.release}
T52_TREE=ef2f8b3397ef66fa1bd694b87cf1f1272e4e7a37   # t52-base^{tree} (v7.3 + 134 upstream t52 patches), as for y14/y15
Y15_HEAD=77a55c5a723e99fc847feb6afcbb706427c4106b   # branch y15 (tree 9a591ab91e1e), the kernel kept on 10-29: y16~1
# the series, in application order: y15's 27, then 1058; 1044/1045 must not appear
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
1058-firmware-qcom-scm-disable-SDI-when-download-mode-is-switched-off.patch"
CMDLINE="fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 qcom_scm.download_mode=full baldur.end=hold consoleblank=120 no_console_suspend mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0 msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000"
case "$CMDLINE" in *allow_system_off*) echo "CMDLINE must stay y9's: 1043's knob defaults to N in C and must not look cmdline-dependent (Y10-NOTES.md)"; exit 1;; esac
[ -f "$BASECFG" ]
# y15's configs are the reference for y16's (both must still be there)
[ -f $Y15/config-t52-y15.pre-build ] && [ -f $Y15/config-t52-y15 ]
# everything this build reads from the t54 copy, by sha256 (relative to $UP; build products that make M= leaves in
# out-of-tree/ are not listed and do not matter). On Win11 (NOTES.md) the same list for the t52 copy differs only in
# kernel/initramfs/init (a9b1d5f) and kernel/initramfs/test-root-selection.sh (its test; not built in); back-to-android
# and keyhold.c keep the sums kbuild-y15.sh pinned
UPSUMS="4649391b1c72aed99c7e23f393ae5aaa4a5965e4e2bccf326032e874abcde2a5  android/back-to-android
e4550a4e56734be48d0eb6f3a427bf1388279bd9ac680b204e02f4c0155858fd  kernel/initramfs/README.md
7a0ea7e25c22ed51c458080a63b1a9e2f779803c1a4d2998209144ae7fcdddfc  kernel/initramfs/build.sh
e8f08081e7ae50992b281097831fd782579adcc0f0f987e0811b6a109942dc39  kernel/initramfs/gpu-probe.c
a075367ca68f50ec01a99ff698aad679ad9a5cf0a9b939f2779dcc2c9e0363e2  kernel/initramfs/init
6b6f196ea078c7dfc678fd682d46ddbced2155d1faba627c798e5688e0b151a4  kernel/initramfs/spec.list
3cc67fae09dab04fc5e0d6936e6db91f842039f0981dd739698bbaa73dc7b790  kernel/initramfs/test-root-selection.sh
938308d68b6e2867d1844de42ed1123e5e5e189a73ed27f6575d2574e6d18660  kernel/out-of-tree/aw882xx/Kconfig
8278e9faef7e6ed3953c08c573b75a2a5742fa98d3ade098a4b1b7f86bf0baa0  kernel/out-of-tree/aw882xx/Makefile
6122b124d92df9d6068fc24f4be1f1a9bbaea05631d223da7292e4836cbf8a12  kernel/out-of-tree/aw882xx/README.md
9984aa3094d3c5439b875a4e8b810bd8cf4a33c4de530815c1bbbfb96ef6c058  kernel/out-of-tree/aw882xx/aw882xx.c
4fb25f639c19dd286473c7723829e07dffe9165be29cb65a5df9895143804cb9  kernel/out-of-tree/aw882xx/aw882xx.h
092684a90dfbb52aa8a3a6aa5f27d4e90c2d62b1a7b0eef6b2ab028d8bae76b2  kernel/out-of-tree/aw882xx/aw882xx_bin_parse.c
1be78435ee4aa03afa5d62c681e36d49b129d36df8ff85f1255bbdf94a26b3b3  kernel/out-of-tree/aw882xx/aw882xx_bin_parse.h
2dcf1fa84423ce5f2d709fce52ba9d2add615cd811bc60e11a5ed990ff43817a  kernel/out-of-tree/aw882xx/aw882xx_calib.c
4838036272cc0e2c89aed3e000c39f47cb55f1bfbf40e6802bf8d85685eb1339  kernel/out-of-tree/aw882xx/aw882xx_calib.h
1706533f6892d53f28420846d4d521fb1fd5ab5b06599d569a64401ed1e68ba7  kernel/out-of-tree/aw882xx/aw882xx_data_type.h
6be03c6760b25d93b54b236345040fb67ce4a33cc1cde66ad09be47372a562fd  kernel/out-of-tree/aw882xx/aw882xx_device.c
bd5f83a861d0f4423cad0108daf94a0cf9d84fc6ebc92be8baa6ce0b4702c330  kernel/out-of-tree/aw882xx/aw882xx_device.h
27d51c26677377f7b99f42b97f14ffa0cfbb78201a9641cd6f534055ce337a59  kernel/out-of-tree/aw882xx/aw882xx_dsp.c
5d75fbbd7d6ad8b86d732d8748ff394181139585e6b6f1a730f6fdeae03398d0  kernel/out-of-tree/aw882xx/aw882xx_dsp.h
5442546f52e6725cbbcec7305bfc710bc21634ae026f966d2c2144b391179290  kernel/out-of-tree/aw882xx/aw882xx_init.c
401326f0cb59377eb22e509a6813b709716d52a91f82761e3418c255b28a50d3  kernel/out-of-tree/aw882xx/aw882xx_log.h
e326bc07fde1e97121990fcc014d6cfc96f1fd768245c67061c80f135c23be80  kernel/out-of-tree/aw882xx/aw882xx_monitor.c
9bb8db975b03bf7c43c17ddd1e98bf2d83627adcb5847c12c1e3bb99f11f834e  kernel/out-of-tree/aw882xx/aw882xx_monitor.h
a3eb146ec73e018d518c13559d26963db663c8fb3e1668ed92c86b05705057b4  kernel/out-of-tree/aw882xx/aw882xx_pid_1852_reg.h
841d33d5a3eb9bfbe446dab60364327ffce7a72412cc43aff94841a3d8dadd23  kernel/out-of-tree/aw882xx/aw882xx_pid_2013_reg.h
3b1dd105fbbad8fb5124bf3499a818e5f58292451b96545eb7f2c53e1d5fc255  kernel/out-of-tree/aw882xx/aw882xx_pid_2032_reg.h
4d856c65f902b8ef1e66271a008ebe42b23ba03f0b902b091c704a93359b204a  kernel/out-of-tree/aw882xx/aw882xx_pid_2055_reg.h
162f4a69b61db296185f13046260e8776181257507e8a89a4d36bb890638951b  kernel/out-of-tree/aw882xx/aw882xx_pid_2055a_reg.h
5c18c9c31b8c38de0110fe892051a75fc278dadade6bd2b29cb17cf490294757  kernel/out-of-tree/aw882xx/aw882xx_pid_2071_reg.h
8c77e5c53de400a6f3afc6afd9228a1f2821769fc601bf1a9b807dcd3fead539  kernel/out-of-tree/aw882xx/aw882xx_pid_2113_reg.h
43b13c4a6d84b56a925693080b6cdb667ce7f945df5007f7c2507bba7c7b6ca9  kernel/out-of-tree/aw882xx/aw882xx_pid_2308_reg.h
57295f5c54fec3afbb56981349875495d3295a3cbdb0ffca002ca930bbe0b2b4  kernel/out-of-tree/aw882xx/aw882xx_spin.c
01fc2ee8ce384a0200ea8d7dd0e3d029716e5242db6a4fd034b882daa87a131b  kernel/out-of-tree/aw882xx/aw882xx_spin.h
c5a97de46ea8d28f212ed0d0eba2ecd780c401cae69deb1f7bc5980e0969814c  userspace/platform/src/keyhold.c"
(cd $UP && echo "$UPSUMS" | sha256sum --check --quiet --strict) || { echo "$UP is not the kernel-t54 subset reviewed on Win11"; exit 1; }
grep -q "does not mount read-only, boot-next, boot-default and boot-menu not read" $UP/kernel/initramfs/init   # a9b1d5f
[ -x $UP/kernel/initramfs/build.sh ] && [ -x $UP/kernel/initramfs/init ] && [ -d $UP/kernel/out-of-tree/aw882xx ]
cd $SRC
# ---- the tree must be exactly branch y16 (checked BEFORE anything is written into the tree)
[ "$(git branch --show-current)" = y16 ] || { echo "check out branch y16 in $SRC (bash /root/y16-branch.sh makes it)"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "tracked files changed in $SRC: build only committed y16 states"; exit 1; }
grep -q WORKAROUND_QCOM_ORYON_DC_ZVA arch/arm64/tools/cpucaps && { echo "tree carries 1044 (y11): not part of y16"; exit 1; }
grep -q ltr_max_latency_us drivers/pci/controller/dwc/pcie-qcom.c && { echo "tree carries 1045 part 2 (ltr_max_latency_us): only its DT part (1056) is in y16"; exit 1; }
[ "$(git rev-parse 'v7.3^{commit}')" = c03c1a14507dfaf8b856c2608f9ac216021fc222 ]
[ "$(git rev-list --count v7.3..t52-base)" = 134 ]
[ "$(git rev-parse 't52-base^{tree}')" = $T52_TREE ] || { echo "t52-base is not the tree prepared on 10-22"; exit 1; }
[ "$(git rev-list --count t52-base..HEAD)" = 28 ]
[ "$(git rev-parse HEAD~1)" = $Y15_HEAD ] || { echo "y16 is not y15 ($Y15_HEAD) plus one commit"; exit 1; }
[ "$(git rev-parse 'HEAD^{tree}')" = $Y16_TREE ] || { echo "y16 is not the pinned tree: re-export the patches and re-pin Y16_TREE after review"; exit 1; }
# the repo's patch files (linux/kernel-y16/patches -> $PD) re-create exactly this tree (temporary index, worktree untouched)
for p in $(cat $PD/series); do [ -f "$PD/$p" ] || { echo "MISSING PATCH FILE: $PD/$p"; exit 1; }; done
[ "$(wc -l < $PD/series)" = 28 ]
[ "$(cat $PD/series)" = "$EXPECTED_SERIES" ] || { echo "$PD/series is not y15's + 1058:"; diff <(echo "$EXPECTED_SERIES") $PD/series || true; exit 1; }
rm -f /tmp/y16-kbuild-index
GIT_INDEX_FILE=/tmp/y16-kbuild-index git read-tree t52-base
for p in $(cat $PD/series); do GIT_INDEX_FILE=/tmp/y16-kbuild-index git apply --cached "$PD/$p"; done
[ "$(GIT_INDEX_FILE=/tmp/y16-kbuild-index git write-tree)" = $Y16_TREE ] || { echo "the patch files in $PD do not re-create y16"; exit 1; }
rm -f /tmp/y16-kbuild-index
git log --oneline t52-base..HEAD
# ---- grep assertions carried from y14/y15 (the tree hash already pins the source, these say WHAT must be in it)
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
# ==== y16 assertions BEGIN (run on Win11 against y15's qcom_scm.c and y15's + 1058, NOTES.md: pass on y16, stop on y15)
# 1058: set_download_mode() disables SDI, and logs the result, when download mode is set to off after probe; probe's
# own SDI call (download mode already off at probe, or DT qcom,sdi-enabled) is unchanged
Q=drivers/firmware/qcom/qcom_scm.c
sdm=$(sed -n '/^static int set_download_mode(/,/^}/p' $Q); echo "$sdm"
grep -qx "$(printf '\tif (scm) {')" <<<"$sdm"
grep -qx "$(printf '\t\tqcom_scm_set_download_mode(scm, download_mode);')" <<<"$sdm"
grep -A1 "if (download_mode == QCOM_DLOAD_NODUMP) {" <<<"$sdm" | grep -q "ret = qcom_scm_disable_sdi();"
grep -qF 'dev_info(scm->dev, "download mode off, SDI disable: %d\n", ret);' <<<"$sdm"
grep -qF 'if (of_property_read_bool(pdev->dev.of_node, "qcom,sdi-enabled") || !download_mode)' $Q
[ "$(grep -c "qcom_scm_disable_sdi();" $Q)" = 2 ]   # probe's call and 1058's
# ==== y16 assertions END
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
# known gap, kept for parity with y8..y15: the [A-Z0-9_] pattern above skips symbols with lower-case letters, so these
# trim lines were never applied (ARM_CCI5xx_PMU is off anyway through its dependency; SENSORS_SHT4x stays =m). NOTES.md.
grep -nE '^(# )?CONFIG_[A-Z0-9_]*[a-z]' $FR/y8-trim.fragment $FR/y8-power.fragment || true
# y16's one config change: the watchdog sysfs attributes (bootstatus, state, timeout, identity of qcom_wdt)
scripts/config --file .config --enable WATCHDOG_SYSFS
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
	# y16: the watchdog sysfs is on, for the built-in qcom_wdt; 1058 is in the built-in qcom_scm (download_mode is
	# /sys/module/qcom_scm/parameters/download_mode)
	for o in CONFIG_WATCHDOG_SYSFS=y CONFIG_QCOM_WDT=y CONFIG_QCOM_SCM=y; do grep -qx "$o" .config || { echo "MISSING $o"; bad=1; }; done
	# must-keep: "SYMBOL y|m reason" lines ([A-Za-z0-9_] since y14, so FONT_TER16x32 / FONT_8x16 are checked too)
	grep -E '^[A-Za-z0-9_]+ [ym] ' $FR/y8-must-keep.txt | while read -r sym st _; do
		# any set value counts (bool y, tristate m, or an int/string such as BOOTPARAM_*_PANIC=1)
		grep -qE "^CONFIG_$sym=" .config || { echo "MUST-KEEP LOST: $sym (wanted $st)"; echo lost >> /tmp/y16-check-bad; }
	done
	# the fragments must have stuck: not-set lines are not y/m, =m lines are m, values as given
	for f in $FR/y8-trim.fragment $FR/y8-power.fragment; do
		grep -E '^# CONFIG_[A-Z0-9_]+ is not set' "$f" | while read -r _ sym _; do
			grep -qE "^$sym=[ym]$" .config && { echo "REVIVED by olddefconfig: $sym"; echo rev >> /tmp/y16-check-bad; }
		done
		grep -E '^CONFIG_[A-Z0-9_]+=' "$f" | while read -r line; do
			grep -qx "$line" .config || { echo "NOT APPLIED: $line (now: $(grep "^${line%%=*}[= ]" .config || echo unset))"; echo na >> /tmp/y16-check-bad; }
		done
	done
	[ -e /tmp/y16-check-bad ] && bad=1
	rm -f /tmp/y16-check-bad
	return $bad
}
rm -f /tmp/y16-check-bad
check_config || { echo "CONFIG CHECK FAILED - see above"; exit 1; }
grep -qx "CONFIG_LOCALVERSION=\"$NAME\"" .config
# ---- config delta against y15: exactly the watchdog sysfs line (cfgcmp leaves out comments and the two lines that
# name the build)
cfgcmp() { grep -vE "^CONFIG_(LOCALVERSION|INITRAMFS_SOURCE)=|^#" "$1"; }
cfgdelta() { diff <(cfgcmp "$1") <(cfgcmp "$2") | grep '^[<>]' | sort; }
delta=$(cfgdelta $Y15/config-t52-y15.pre-build .config)
echo "pre-build config delta vs y15 (expected: > CONFIG_WATCHDOG_SYSFS=y):"; echo "$delta"
[ "$delta" = "> CONFIG_WATCHDOG_SYSFS=y" ] || { echo "PRE-BUILD CONFIG DELTA VS y15 IS NOT JUST WATCHDOG_SYSFS (see above)"; exit 1; }
# ---- 1056 needs the built-in DTB: it must be on, and the DTB it names must be the one that includes baldur-wifi.dtsi
grep -qx "CONFIG_ARM64_BUILTIN_FDT=y" .config
fdt=$(sed -n 's/^CONFIG_ARM64_BUILTIN_FDT_NAME="\(.*\)"$/\1/p' .config); [ -n "$fdt" ]
DTB=arch/arm64/boot/dts/$fdt
grep -q '^#include "baldur-wifi.dtsi"' arch/arm64/boot/dts/${fdt%.dtb}.dts
if [ "${CHECK_ONLY:-0}" = 1 ]; then echo CHECK_ONLY_OK; exit 0; fi
mkdir -p $OUT
cp .config $OUT/config-t52-y16.pre-build
$M Image dtbs modules headers_install
rm -rf $MODS; $M INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
# aw882xx from the t54 copy (its out-of-tree/ = t52's, pinned above); clean, then build and install in two separate
# makes (the y4 lesson: with -j8 one make ran the install before the build and shipped a stale aw882xx.ko)
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
# t54's init is the /init of this initramfs (build.sh copies it as is; the list names the kept staging copy)
grep -qx "file /init $OUT/initramfs.d/init 0755 0 0" $OUT/initramfs.list
cmp $OUT/initramfs.d/init $UP/kernel/initramfs/init
scripts/config --file .config --set-str INITRAMFS_SOURCE "$OUT/initramfs.cpio.gz"
$M olddefconfig
grep -qx "CONFIG_CMDLINE=\"$CMDLINE\"" .config
$M Image
# ---- 1056 in the built-in DTB, and that DTB inside the final Image
scripts/dtc/dtc -q -I dtb -O dts $DTB | grep -B3 -A1 "t-power-on-us"
[ "$(scripts/dtc/dtc -q -I dtb -O dts $DTB | grep -c "t-power-on-us = <0x50>;")" = 1 ]
python3 -I -c 'import sys; d = open(sys.argv[1], "rb").read(); sys.exit(0 if len(d) > 1024 and d in open(sys.argv[2], "rb").read() else 1)' $DTB arch/arm64/boot/Image
cp $DTB $OUT/
cp arch/arm64/boot/Image $OUT/Image-t52-y16; gzip -9 -n -c arch/arm64/boot/Image > $OUT/Image-t52-y16.gz
cp .config $OUT/config-t52-y16; git diff t52-base HEAD > $OUT/y700-y16.patch
delta=$(cfgdelta $Y15/config-t52-y15 $OUT/config-t52-y16)
echo "final config delta vs y15 (expected: > CONFIG_WATCHDOG_SYSFS=y):"; echo "$delta"
[ "$delta" = "> CONFIG_WATCHDOG_SYSFS=y" ] || { echo "FINAL CONFIG DELTA VS y15 IS NOT JUST WATCHDOG_SYSFS (see above)"; exit 1; }
strings $OUT/Image-t52-y16 | grep -m1 "Linux version"
# the 1043 knob is in the image: the built-in parameter name (__param section) and the report format string (rodata)
strings $OUT/Image-t52-y16 | grep -q "cpuidle_psci_domain.allow_system_off"
strings $OUT/Image-t52-y16 | grep -q "allow_system_off=%c, system domain state %s (%s)"
# 1058's log line format (rodata)
strings $OUT/Image-t52-y16 | grep -qF "download mode off, SDI disable: %d"
ls -la $OUT/Image-t52-y16 $Y15/Image-t52-y15
sha256sum $OUT/Image-t52-y16* $OUT/${DTB##*/}
echo KFULL_OK
