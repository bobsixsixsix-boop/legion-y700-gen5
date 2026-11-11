#!/bin/bash
# y700: kernel build -y19 = y18 (kept 11-04 16:56) WITHOUT upstream 0153 (pen tilt axes): the owner vetoed the pen patch
#   the same evening ("1不做"). Everything else is y18's (linux/kernel-y19/NOTES.md; the eight are explained in
#   linux/kernel-y18/NOTES.md):
#   - tree: branch y19 = y16 (82bf9859f5f6) + 0144, 0147, 0148, 0149, 0150, 0151, 0152 = y18~1 (0153 was y18's last
#     commit; y19-branch.sh re-applies the seven with y18-branch.sh's fixed committer identity and date, so the commits
#     ARE y18's own and y19 == y18~1 is asserted below while branch y18 exists). nt36xxx.c is t52-base's again.
#     Pinned: Y19_TREE.
#   - config: exactly y18's (CMDLINE = y9's minus no_console_suspend, BOOTPARAM_HUNG_TASK_PANIC=0): the config delta
#     against y18's pre-build and final configs must be EMPTY; against y17's it is still y18's four lines.
#   Initramfs exactly as y17 and y18 (t54's build.sh, then /init = /root/y17-init and /bin/e2fsck = e2fsck.static).
#   Release 7.3.0-tb323fu-t52-y19. Derived from linux/kernel-y18/kbuild-y18.sh.
#
#   /usr/local/src/linux-t52 on branch y19 (bash /root/y19-branch.sh makes it: linux/kernel-y19/prep/); the patch files
#   are the repo's linux/kernel-y19/patches in /root/y19-patches/ (y16's 28 + the seven). The y18 build output ($Y18
#   below) is what this build is compared with (configs, patch archive, Image); y17's y700-y17.patch still says what the
#   28 carried patches are.
# Run (after y18 an incremental build: nt36536's module, the release string and the link, about a minute at Nice 19):
#   systemd-run --unit=y700-kbuild-y19 --collect -p Nice=19 -p CPUWeight=20 -p IOWeight=20 /bin/bash /root/kbuild-y19.sh
#                                                                                       -> log /root/y700-kernel-y19.log
#   CHECK_ONLY=1 bash /root/kbuild-y19.sh   stops after the input checks (fragments, init, e2fsck.static), the tree
#                                         checks, the grep assertions and the pre-build config checks (no compile; log
#                                         /root/y700-kernel-y19-check.log; leaves .config). Its last log line is set -x's
#                                         "+ exit 0": grep the log for CHECK_ONLY_OK, do not tail -1 it.
if [ "${CHECK_ONLY:-0}" = 1 ]; then LOG=/root/y700-kernel-y19-check.log; else LOG=/root/y700-kernel-y19.log; fi
Y19_TREE=e007de00615d2baa0bd258582fab3e24f3094d15   # y19^{tree}: the Y19_TREE= line of /root/y19-branch.log, pasted after reviewing that log (y18's tree was c2c65206c1be)
exec > $LOG 2>&1
set -ex
export LC_ALL=C   # stable sort for the config delta, English git/make messages in the log
command -v pahole   # BTF needs it
command -v python3  # the built-in DTB check after the final link
SRC=/usr/local/src/linux-t52; UP=/usr/local/src/tb323fu-linux-t54
MODS=/usr/local/src/y700-mods-y19
NAME=-tb323fu-t52-y19; REL=7.3.0-tb323fu-t52-y19; OUT=/usr/local/src/y700-kernel-y19; FR=/root/y8-fragments
PD=/root/y19-patches; Y17=/usr/local/src/y700-kernel-y17; Y18=/usr/local/src/y700-kernel-y18
# y17's two inputs from outside the kernel tree (unchanged for y18 and y19)
Y17_INIT=/root/y17-init
Y17_INIT_SHA=b450a91a698592773f22f091c3061992d8df4c02240ca35365d9a7b5e37990ce   # sha256 of the repo's linux/kernel-y17/init
E2S=/usr/sbin/e2fsck.static; E2S_VER=1.47.2-3ubuntu4   # package e2fsck-static, installed 11-01
BASECFG=${BASECFG:-/root/config-t49.release}
T52_TREE=ef2f8b3397ef66fa1bd694b87cf1f1272e4e7a37   # t52-base^{tree} (v7.3 + 134 upstream t52 patches), as for y14/y15
Y16_HEAD=82bf9859f5f6f4f52bd24ef03376ce0dc965a165   # branch y16 (tree ea8ec0f24f3d), the kernel kept on 11-01 as y16 and y17: y19~7
# the series, in application order: y16's 28, then the seven (0153, the pen tilt patch, was vetoed 11-04); 1044/1045 must
# not appear, nor any pen patch
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
0144-drm-panel-nt36523-baldur-report-the-panel-physical-size.patch
0147-usb-typec-ucsi-Leave-the-mux-to-the-altmode-driver-f.patch
0148-arm64-configs-baldur-drop-no_console_suspend-from-th.patch
0149-usb-dwc3-qcom-Leave-DP-only-mode-from-the-mux-callba.patch
0150-drm-msm-dp-Track-the-PHY-power-and-link-clock-state.patch
0151-drm-msm-dp-Release-the-PHY-init-when-the-link-is-not.patch
0152-mmc-sd-Keep-the-card-when-its-extension-registers-fa.patch"
# y9's command line (y10-y17) and y18's = y19's: the same minus no_console_suspend (0148)
Y17_CMDLINE="fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 qcom_scm.download_mode=full baldur.end=hold consoleblank=120 no_console_suspend mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0 msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000"
CMDLINE="fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 qcom_scm.download_mode=full baldur.end=hold consoleblank=120 mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0 msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000"
[ "${Y17_CMDLINE/ no_console_suspend/}" = "$CMDLINE" ] || { echo "CMDLINE must be y9's minus exactly no_console_suspend"; exit 1; }
case "$CMDLINE" in *allow_system_off*) echo "CMDLINE must stay y9's: 1043's knob defaults to N in C and must not look cmdline-dependent (Y10-NOTES.md)"; exit 1;; esac
case "$CMDLINE" in *no_console_suspend*) echo "no_console_suspend is dropped since y18 (0148)"; exit 1;; esac
[ -f "$BASECFG" ]
# the fragments are the repo's linux/kernel-y8 files of 11-04 (must-keep and power: the hung-task lines reworded for y18)
FRSUMS="0078ce47b61284b71a9d6d81afb7742bd93c479a2ba844b11634b9ebf244e748  y8-must-keep.txt
4ee2c6a5b79f56218671c3cfdc6f4c8c75ed321c5da89b5e9357e0b9e3e0c903  y8-power.fragment
d1829f44670f9506326ea9dc26ce52af976c40c25bcb0746e00dc0f1717e92ee  y8-trim.fragment"
(cd $FR && echo "$FRSUMS" | sha256sum --check --quiet --strict) || { echo "$FR is not the repo's linux/kernel-y8 of 11-04: scp the three files and compare sha256"; exit 1; }
# y18's build output is the reference for y19's (configs, patch archive, Image: all must still be there); y17's
# y700-y17.patch still says what the 28 carried patches are and its configs pin y18's four-line delta a second time
# (one test per file: set -e does not stop on a failing test before && - kbuild-y16.sh's chains had that hole)
for f in config-t52-y17.pre-build config-t52-y17 y700-y17.patch Image-t52-y17; do [ -f $Y17/$f ]; done
for f in config-t52-y18.pre-build config-t52-y18 y700-y18.patch Image-t52-y18; do [ -f $Y18/$f ]; done
# everything this build reads from the t54 copy, by sha256 (relative to $UP; build products that make M= leaves in
# out-of-tree/ are not listed and do not matter). kernel-t55..t58 change nothing under kernel/initramfs,
# kernel/out-of-tree or kernel/dts but the initramfs README (checked on Win11, 11-04), so the t54 copy stays the source
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
[ -x $UP/kernel/initramfs/build.sh ]; [ -x $UP/kernel/initramfs/init ]; [ -d $UP/kernel/out-of-tree/aw882xx ]
# ---- y17's init (pinned) and the static e2fsck: Ubuntu's file unchanged, AArch64, no interpreter, no shared libraries
echo "$Y17_INIT_SHA  $Y17_INIT" | sha256sum --check --quiet --strict || { echo "$Y17_INIT is not the repo's linux/kernel-y17/init"; exit 1; }
grep -qx "e2fsck=/bin/e2fsck" $Y17_INIT   # where the list line below puts it
[ "$(dpkg-query -W -f '${Status} ${Version}' e2fsck-static)" = "install ok installed $E2S_VER" ]
dpkg -L e2fsck-static | grep -qx $E2S
[ -z "$(dpkg --verify e2fsck-static)" ] || { echo "e2fsck-static's files changed since install (dpkg --verify)"; exit 1; }
readelf -lW $E2S | grep -q "INTERP" && { echo "$E2S has a program interpreter: not static"; exit 1; }
readelf -dW $E2S | grep -q "NEEDED" && { echo "$E2S needs shared libraries"; exit 1; }
readelf -hW $E2S | grep -qE "Machine: +AArch64"
$E2S -V 2>&1 | grep -q "^e2fsck 1\.47\.2 "
cd $SRC
# ---- the tree must be exactly branch y19 (checked BEFORE anything is written into the tree)
[ "$(git branch --show-current)" = y19 ] || { echo "check out branch y19 in $SRC (bash /root/y19-branch.sh makes it)"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "tracked files changed in $SRC: build only committed y19 states"; exit 1; }
grep -q WORKAROUND_QCOM_ORYON_DC_ZVA arch/arm64/tools/cpucaps && { echo "tree carries 1044 (y11): not part of y19"; exit 1; }
grep -q ltr_max_latency_us drivers/pci/controller/dwc/pcie-qcom.c && { echo "tree carries 1045 part 2 (ltr_max_latency_us): only its DT part (1056) is in y19"; exit 1; }
[ "$(git rev-parse 'v7.3^{commit}')" = c03c1a14507dfaf8b856c2608f9ac216021fc222 ]
[ "$(git rev-list --count v7.3..t52-base)" = 134 ]
[ "$(git rev-parse 't52-base^{tree}')" = $T52_TREE ] || { echo "t52-base is not the tree prepared on 10-22"; exit 1; }
[ "$(git rev-list --count t52-base..HEAD)" = 35 ]
[ "$(git rev-parse HEAD~7)" = $Y16_HEAD ] || { echo "y19 is not y16 ($Y16_HEAD) plus seven commits"; exit 1; }
[ "$(git rev-parse 'HEAD^{tree}')" = $Y19_TREE ] || { echo "y19 is not the pinned tree: re-run y19-branch.sh and re-pin Y19_TREE after review"; exit 1; }
# y19 is y18 without its last commit (0153): the same seven commits, fixed committer identity and date (y19-branch.sh)
! git rev-parse -q --verify 'refs/heads/y18^{commit}' >/dev/null || [ "$(git rev-parse HEAD)" = "$(git rev-parse 'y18~1')" ] || { echo "y19 is not y18~1: the seven are not y18's commits"; exit 1; }
# the 28 carried commits are untouched: t52-base..y16 is exactly the source y17 was built from
git diff t52-base $Y16_HEAD | cmp -s - $Y17/y700-y17.patch || { echo "t52-base..y16 is no longer the source of y17 (y700-y17.patch)"; exit 1; }
# the repo's patch files (linux/kernel-y19/patches -> $PD) re-create exactly this tree (temporary index, worktree untouched)
for p in $(cat $PD/series); do [ -f "$PD/$p" ] || { echo "MISSING PATCH FILE: $PD/$p"; exit 1; }; done
[ "$(wc -l < $PD/series)" = 35 ]
[ "$(cat $PD/series)" = "$EXPECTED_SERIES" ] || { echo "$PD/series is not y16's + the seven:"; diff <(echo "$EXPECTED_SERIES") $PD/series || true; exit 1; }
rm -f /tmp/y19-kbuild-index
GIT_INDEX_FILE=/tmp/y19-kbuild-index git read-tree t52-base
for p in $(cat $PD/series); do GIT_INDEX_FILE=/tmp/y19-kbuild-index git apply --cached "$PD/$p"; done
[ "$(GIT_INDEX_FILE=/tmp/y19-kbuild-index git write-tree)" = $Y19_TREE ] || { echo "the patch files in $PD do not re-create y19"; exit 1; }
rm -f /tmp/y19-kbuild-index
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
# ==== y18/y19 assertions BEGIN (the seven upstream t58 patches are in the tree; no pen patch: 0153 vetoed 11-04,
# 0143/0145/0146 never taken)
# 0144: the baldur CSOT panel descriptor says 118 x 190 mm (the glass), not 168 x 268
P=drivers/gpu/drm/panel/panel-novatek-nt36523.c
bd=$(sed -n '/^static const struct panel_desc baldur_csot_desc = {/,/^};/p' $P); echo "$bd" | grep -E "_mm = "
grep -qx "$(printf '\t.width_mm = 118,')" <<<"$bd"
grep -qx "$(printf '\t.height_mm = 190,')" <<<"$bd"
grep -qE "\.(width|height)_mm = (168|268)," <<<"$bd" && { echo "0144 missing: baldur_csot_desc still says 168 x 268 mm"; exit 1; }
# 0147: ucsi leaves the mux to the altmode driver when the partner is in an alt mode
grep -qF '!UCSI_CONSTAT(con, PARTNER_FLAG_ALT_MODE))' drivers/usb/typec/ucsi/ucsi.c
# 0148: the in-tree fragment has no no_console_suspend either (our CMDLINE is set below from $CMDLINE, checked twice)
grep -q "no_console_suspend" arch/arm64/configs/baldur.fragment && { echo "0148 missing: arch/arm64/configs/baldur.fragment still has no_console_suspend"; exit 1; }
# 0149: dwc3-qcom switches the pipe clock from the mux callback; the old update helper is gone; TYPEC dependency
X=drivers/usb/dwc3/dwc3-qcom.c
grep -qx "$(printf '\tdepends on TYPEC || TYPEC=n')" drivers/usb/dwc3/Kconfig
grep -q "dwc3_qcom_update_pipe_clk" $X && { echo "0149 missing: dwc3_qcom_update_pipe_clk is still in dwc3-qcom.c"; exit 1; }
grep -q "IS_ENABLED(CONFIG_TYPEC)" $X
# 0150: dp_ctrl tracks the PHY power and the link clocks
grep -qx "$(printf '\tbool phy_powered;')" drivers/gpu/drm/msm/dp/dp_ctrl.c
grep -q "^static int msm_dp_ctrl_phy_power_off(struct msm_dp_ctrl_private \*ctrl)" drivers/gpu/drm/msm/dp/dp_ctrl.c
# 0151: the PHY init is released on unplug when the link is not powered, and in disable when the display is not on
grep -qF 'if (dp->link->sink_count == 0 || !dp->msm_dp_display.power_on)' drivers/gpu/drm/msm/dp/dp_display.c
# 0152: sd_enable_cache() reads the Cache Enable bit back; init continues when ext regs / cache enable fail
grep -qF 'card->ext_perf.offset + 260, 1, reg_buf);' drivers/mmc/core/sd.c
grep -qF 'error %d reading SD ext regs, ignoring them' drivers/mmc/core/sd.c
grep -qF 'error %d reading the SD cache state, assuming it is off' drivers/mmc/core/sd.c
# no 0153 (vetoed 11-04): nt36xxx.c is t52-base's, the pen tilt still comes from bytes 73 and 74 as int32 (t52's code);
# no 0143 (format 0x02), no 0145 (range check, 0xF1)
N=drivers/input/touchscreen/nt36536/nt36xxx.c
git diff --quiet t52-base HEAD -- $N || { echo "nt36xxx.c differs from t52-base: a pen patch is in y19"; exit 1; }
grep -qxF "$(printf '\t\t\t\tpen_tilt_x = (int32_t)point_data[73];')" $N   # -F: [73] is a bracket expression otherwise
grep -qxF "$(printf '\t\t\t\tpen_tilt_y = (int32_t)point_data[74];')" $N
grep -qF -- "-(int8_t)point_data[74]" $N && { echo "0153 is in the tree: vetoed 11-04 (y18 had it)"; exit 1; }
grep -q "pen_format_id == 0x02" $N && { echo "0143 is in the tree: not taken (README upstream log 11-02)"; exit 1; }
grep -q "pen_x > ts->abs_x_max" $N && { echo "0145 is in the tree: not taken"; exit 1; }
grep -q "pen_format_id == 0xF1" $N && { echo "0145 is in the tree: not taken"; exit 1; }
# ==== y19 assertions END
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
# known gap, kept for parity with y8..y17: the [A-Z0-9_] pattern above skips symbols with lower-case letters, so these
# trim lines were never applied (ARM_CCI5xx_PMU is off anyway through its dependency; SENSORS_SHT4x stays =m). NOTES.md.
grep -nE '^(# )?CONFIG_[A-Z0-9_]*[a-z]' $FR/y8-trim.fragment $FR/y8-power.fragment || true
# y16's one config change: the watchdog sysfs attributes (bootstatus, state, timeout, identity of qcom_wdt)
scripts/config --file .config --enable WATCHDOG_SYSFS
# y18's one config change, kept in y19: hung tasks are reported (after DEFAULT_HUNG_TASK_TIMEOUT), no longer panicked (upstream t58)
scripts/config --file .config --set-val BOOTPARAM_HUNG_TASK_PANIC 0
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
	grep -q "no_console_suspend" .config && { echo "no_console_suspend is in the config (0148 drops it)"; bad=1; }
	# 1043 lives in the PSCI domain driver, which must stay built in (the knob is /sys/module/cpuidle_psci_domain/...)
	grep -qx "CONFIG_ARM_PSCI_CPUIDLE_DOMAIN=y" .config || { echo "ARM_PSCI_CPUIDLE_DOMAIN not built in"; bad=1; }
	grep -q "^CONFIG_PREEMPT_RT=y" .config && { echo "PREEMPT_RT is on: 1043's knob would be a no-op by design"; bad=1; }
	# y16: the watchdog sysfs is on, for the built-in qcom_wdt; 1058 is in the built-in qcom_scm (download_mode is
	# /sys/module/qcom_scm/parameters/download_mode)
	for o in CONFIG_WATCHDOG_SYSFS=y CONFIG_QCOM_WDT=y CONFIG_QCOM_SCM=y; do grep -qx "$o" .config || { echo "MISSING $o"; bad=1; }; done
	# y18/y19: hung tasks reported after 180 s (y8-power.fragment), not panicked; the detector, the soft-lockup panic and
	# the suspend watchdog stay (y8-must-keep.txt STABILITY lines)
	for o in CONFIG_DETECT_HUNG_TASK=y CONFIG_DEFAULT_HUNG_TASK_TIMEOUT=180 CONFIG_BOOTPARAM_HUNG_TASK_PANIC=0 \
		CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=1 CONFIG_DPM_WATCHDOG=y; do grep -qx "$o" .config || { echo "MISSING $o"; bad=1; }; done
	# 0149's new dependency: USB_DWC3_QCOM needs TYPEC on or off, we have it on (UCSI port, the altmode mux)
	for o in CONFIG_TYPEC=y CONFIG_USB_DWC3_QCOM=y CONFIG_DRM_MSM_DP=y CONFIG_MMC=y; do grep -qx "$o" .config || { echo "MISSING $o"; bad=1; }; done
	# must-keep: "SYMBOL y|m reason" lines ([A-Za-z0-9_] since y14, so FONT_TER16x32 / FONT_8x16 are checked too)
	grep -E '^[A-Za-z0-9_]+ [ym] ' $FR/y8-must-keep.txt | while read -r sym st _; do
		# any set value counts (bool y, tristate m, or an int such as BOOTPARAM_SOFTLOCKUP_PANIC=1 or
		# BOOTPARAM_HUNG_TASK_PANIC=0; the two int values are asserted above)
		grep -qE "^CONFIG_$sym=" .config || { echo "MUST-KEEP LOST: $sym (wanted $st)"; echo lost >> /tmp/y19-check-bad; }
	done
	# the fragments must have stuck: not-set lines are not y/m, =m lines are m, values as given
	for f in $FR/y8-trim.fragment $FR/y8-power.fragment; do
		grep -E '^# CONFIG_[A-Z0-9_]+ is not set' "$f" | while read -r _ sym _; do
			grep -qE "^$sym=[ym]$" .config && { echo "REVIVED by olddefconfig: $sym"; echo rev >> /tmp/y19-check-bad; }
		done
		grep -E '^CONFIG_[A-Z0-9_]+=' "$f" | while read -r line; do
			grep -qx "$line" .config || { echo "NOT APPLIED: $line (now: $(grep "^${line%%=*}[= ]" .config || echo unset))"; echo na >> /tmp/y19-check-bad; }
		done
	done
	[ -e /tmp/y19-check-bad ] && bad=1
	rm -f /tmp/y19-check-bad
	return $bad
}
rm -f /tmp/y19-check-bad
check_config || { echo "CONFIG CHECK FAILED - see above"; exit 1; }
grep -qx "CONFIG_LOCALVERSION=\"$NAME\"" .config
# ---- config delta against y18: EMPTY (y19 changes no config); against y17: exactly y18's two changes (cfgcmp leaves
# out comments and the two lines that name the build; sorted with LC_ALL=C, "<" before ">")
cfgcmp() { grep -vE "^CONFIG_(LOCALVERSION|INITRAMFS_SOURCE)=|^#" "$1"; }
cfgdelta() { diff <(cfgcmp "$1") <(cfgcmp "$2") | grep '^[<>]' | sort; }
EXPECTED_DELTA="< CONFIG_BOOTPARAM_HUNG_TASK_PANIC=1
< CONFIG_CMDLINE=\"$Y17_CMDLINE\"
> CONFIG_BOOTPARAM_HUNG_TASK_PANIC=0
> CONFIG_CMDLINE=\"$CMDLINE\""
delta=$(cfgdelta $Y18/config-t52-y18.pre-build .config)
echo "pre-build config delta vs y18 (expected: nothing):"; echo "$delta"
[ -z "$delta" ] || { echo "PRE-BUILD CONFIG DELTA vs y18 IS NOT EMPTY (see above)"; exit 1; }
delta=$(cfgdelta $Y17/config-t52-y17.pre-build .config)
echo "pre-build config delta vs y17 (expected: the hung-task panic and the CMDLINE):"; echo "$delta"
[ "$delta" = "$EXPECTED_DELTA" ] || { echo "PRE-BUILD CONFIG DELTA vs y17 IS NOT THE EXPECTED TWO LINES (see above)"; exit 1; }
# ---- 1056 needs the built-in DTB: it must be on, and the DTB it names must be the one that includes baldur-wifi.dtsi
grep -qx "CONFIG_ARM64_BUILTIN_FDT=y" .config
fdt=$(sed -n 's/^CONFIG_ARM64_BUILTIN_FDT_NAME="\(.*\)"$/\1/p' .config); [ -n "$fdt" ]
DTB=arch/arm64/boot/dts/$fdt
grep -q '^#include "baldur-wifi.dtsi"' arch/arm64/boot/dts/${fdt%.dtb}.dts
if [ "${CHECK_ONLY:-0}" = 1 ]; then echo CHECK_ONLY_OK; exit 0; fi
mkdir -p $OUT
cp .config $OUT/config-t52-y19.pre-build
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
# ---- as y17: the staging copy patched (y17's init, the static e2fsck, one list line) and the cpio made again from the list
[ -x $SRC/usr/gen_init_cpio ]   # build.sh used it (-k $SRC)
cp $Y17_INIT $OUT/initramfs.d/init
cp $E2S $OUT/initramfs.d/e2fsck
grep -q "^file /bin/e2fsck " $OUT/initramfs.list && { echo "build.sh already lists /bin/e2fsck: look before adding it"; exit 1; }
echo "file /bin/e2fsck $OUT/initramfs.d/e2fsck 0755 0 0" >> $OUT/initramfs.list
$SRC/usr/gen_init_cpio $OUT/initramfs.list | gzip -9 > $OUT/initramfs.cpio.gz
# what the cpio carries: /init = y17's, /bin/e2fsck = e2fsck.static (unpacked and compared)
rm -rf /tmp/y19-cpio; mkdir /tmp/y19-cpio
(cd /tmp/y19-cpio && zcat $OUT/initramfs.cpio.gz | busybox cpio -i -d init bin/e2fsck)
cmp /tmp/y19-cpio/init $Y17_INIT
cmp /tmp/y19-cpio/bin/e2fsck $E2S
[ -x /tmp/y19-cpio/init ]; [ -x /tmp/y19-cpio/bin/e2fsck ]
rm -rf /tmp/y19-cpio
scripts/config --file .config --set-str INITRAMFS_SOURCE "$OUT/initramfs.cpio.gz"
$M olddefconfig
grep -qx "CONFIG_CMDLINE=\"$CMDLINE\"" .config
$M Image
# ---- 1056 in the built-in DTB, and that DTB inside the final Image
scripts/dtc/dtc -q -I dtb -O dts $DTB | grep -B3 -A1 "t-power-on-us"
[ "$(scripts/dtc/dtc -q -I dtb -O dts $DTB | grep -c "t-power-on-us = <0x50>;")" = 1 ]
python3 -I -c 'import sys; d = open(sys.argv[1], "rb").read(); sys.exit(0 if len(d) > 1024 and d in open(sys.argv[2], "rb").read() else 1)' $DTB arch/arm64/boot/Image
# ---- the patched cpio is the one in the Image (a .cpio.gz INITRAMFS_SOURCE is copied in as is, usr/Makefile)
python3 -I -c 'import sys; d = open(sys.argv[1], "rb").read(); sys.exit(0 if len(d) > 1024 and d in open(sys.argv[2], "rb").read() else 1)' $OUT/initramfs.cpio.gz arch/arm64/boot/Image
cp $DTB $OUT/
cp arch/arm64/boot/Image $OUT/Image-t52-y19; gzip -9 -n -c arch/arm64/boot/Image > $OUT/Image-t52-y19.gz
cp .config $OUT/config-t52-y19; git diff t52-base HEAD > $OUT/y700-y19.patch
# the source differs from y17's by exactly the seven (eight files) and from y18's by nt36xxx.c alone; the 28 are y17's
# (checked above against the branch)
cmp -s $OUT/y700-y19.patch $Y17/y700-y17.patch && { echo "y700-y19.patch equals y17's: the seven are not in the build"; exit 1; }
cmp -s $OUT/y700-y19.patch $Y18/y700-y18.patch && { echo "y700-y19.patch equals y18's: 0153 is still in the build"; exit 1; }
grep -q "nt36xxx.c" $OUT/y700-y19.patch && { echo "y700-y19.patch touches nt36xxx.c: a pen patch is in the build"; exit 1; }
[ "$(git diff --name-only $Y16_HEAD HEAD | wc -l)" = 8 ]
delta=$(cfgdelta $Y18/config-t52-y18 $OUT/config-t52-y19)
echo "final config delta vs y18 (expected: nothing):"; echo "$delta"
[ -z "$delta" ] || { echo "FINAL CONFIG DELTA vs y18 IS NOT EMPTY (see above)"; exit 1; }
delta=$(cfgdelta $Y17/config-t52-y17 $OUT/config-t52-y19)
echo "final config delta vs y17 (expected: the hung-task panic and the CMDLINE):"; echo "$delta"
[ "$delta" = "$EXPECTED_DELTA" ] || { echo "FINAL CONFIG DELTA vs y17 IS NOT THE EXPECTED TWO LINES (see above)"; exit 1; }
strings $OUT/Image-t52-y19 | grep -m1 "Linux version"
strings $OUT/Image-t52-y19 | grep -q "^Linux version $REL "
# the 1043 knob is in the image: the built-in parameter name (__param section) and the report format string (rodata)
strings $OUT/Image-t52-y19 | grep -q "cpuidle_psci_domain.allow_system_off"
strings $OUT/Image-t52-y19 | grep -q "allow_system_off=%c, system domain state %s (%s)"
# 1058's log line format (rodata)
strings $OUT/Image-t52-y19 | grep -qF "download mode off, SDI disable: %d"
# 0152's new message (mmc core is built in) and the DP PHY message 0150 keeps (msm dp is built in)
strings $OUT/Image-t52-y19 | grep -qF "error %d reading SD ext regs, ignoring them"
strings $OUT/Image-t52-y19 | grep -qF "DP PHY power on failed. ret=%d"
# the built-in command line is y19's; y9's (with no_console_suspend) is nowhere in the image. The bare word stays in
# every kernel: printk's __setup("no_console_suspend") lives in .init.setup
strings $OUT/Image-t52-y19 | grep -qF "$CMDLINE"
strings $OUT/Image-t52-y19 | grep -qF "consoleblank=120 no_console_suspend" && { echo "y9's CMDLINE with no_console_suspend is in the Image"; exit 1; }
ls -la $OUT/Image-t52-y19 $Y18/Image-t52-y18 $Y17/Image-t52-y17
# the same initramfs as y17 and y18; nt36536 is a module (=m), so dropping 0153 changes nt36536's .ko under $MODS and not
# the Image: against y18's Image only the release string differs (the Image is therefore no evidence about 0153: the
# source and y700-y19.patch checks above are), against y17's the seven change a few KB either way. More than 1 MB would
# mean something else came along.
grow=$(( $(stat -c %s $OUT/Image-t52-y19) - $(stat -c %s $Y18/Image-t52-y18) )); echo "Image growth vs y18: $grow bytes"
[ $grow -gt -1048576 ]; [ $grow -lt 1048576 ]
grow=$(( $(stat -c %s $OUT/Image-t52-y19) - $(stat -c %s $Y17/Image-t52-y17) )); echo "Image growth vs y17: $grow bytes"
[ $grow -gt -1048576 ]; [ $grow -lt 1048576 ]
sha256sum $OUT/Image-t52-y19* $OUT/${DTB##*/}
echo KFULL_OK
