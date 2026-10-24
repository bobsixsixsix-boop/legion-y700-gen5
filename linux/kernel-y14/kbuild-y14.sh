#!/bin/bash
# y700: kernel build -y14 = y13's patch stack on upstream tb323fu-linux kernel-t52 (base v7.3 instead of v7.3-rc4).
#   Release 7.3.0-tb323fu-t52-y14. Derived from linux/kernel-y8/kbuild-y13.sh; NOTES.md next to this file has the why.
#
# The tree is no longer one long-lived working tree with an uncommitted stack (linux-t47, linear-stack detection):
#   /usr/local/src/linux-t52 = a worktree of the linux-t47 repository,
#     tag t52-base = v7.3 (c03c1a14507d) + upstream kernel-t52's 134 patches (0001-0141 without 0067-0071, 0115, 0140),
#     branch y14   = t52-base + our 22 patches, ONE COMMIT PER PATCH FILE, in linux/kernel-y14/patches/series order:
#                    y13's 21 (00y1-00y5 split out of the y1..y5 base, 0540, 0620-0622, 1030-1033, 1041-1043, 1046-1050)
#                    + 1051 (10-23) "media: iris: Preserve timestamps on error buffers" (radxa-pkg/libva-v4l2 d5df780
#                    patches/0004, source copy linux/kernel-y8/1051-*.patch): the error branch of iris_vb2_buffer_done()
#                    hands the firmware's timestamp to userspace instead of 0, so libva-v4l2 (785fd3d/d5df780 on) can
#                    map the error to its picture and show a gray frame instead of waiting 5 s for it (surface sync timeout).
#   The script only builds that exact tree: branch y14 checked out, no tracked file changed, both tree hashes as pinned
#   below, and the patch files in the repo (scp linux/kernel-y14/patches/* to /root/y14-patches/) replay to it. To change
#   the stack, commit on y14 (or rebuild it), re-export, re-pin the hash here - never patch the worktree by hand.
#   Upstream's 0131/0132 (t51, carried in y10..y13) are in the base now; our battmgr patch (00y2) was rebased onto 0132
#   instead of the other way round. 1044 (Oryon DC ZVA, y11) and 1045 (PCIe L1SS) are NOT in y14 (refused below).
#   The upstream directory is /usr/local/src/tb323fu-linux-t52 (kernel/ of the t52 tag: aw882xx, initramfs/build.sh,
#   config fragments); the old /usr/local/src/tb323fu-linux stays the t47..t51 one that y13 was built from.
# Config = y13's recipe unchanged: BASECFG (default /root/config-t49.release; /root/config-t52.release once the owner
#   lets us download the t52 release asset) - y8-trim.fragment + y8-power.fragment, olddefconfig, check_config.
#   On v7.3 the result differs from y13's config by exactly two lines (the 10-22 dry run), both new arm64 errata
#   options that olddefconfig turns on by default and that only act on Cortex-A510/A725 cores (MIDR match at boot,
#   nothing on Oryon):
#     CONFIG_ARM64_ERRATUM_3821522=y, CONFIG_ARM64_WORKAROUND_BROKEN_AMU_CONSTCNT=y (hidden, selected by 2457168/3821522)
#   The script checks that delta twice (pre-build and final config) and stops on any other difference. CMDLINE = y13's.
# Run (measured 10-23: 7 min full build from a clean tree, 1 min incremental, at Nice 19 on battery; low priority so
# other work on the tablet keeps its timing):
#   systemd-run --unit=y700-kbuild-y14 --collect -p Nice=19 -p CPUWeight=20 -p IOWeight=20 /bin/bash /root/kbuild-y14.sh
#                                                                                       -> log /root/y700-kernel-y14.log
#   CHECK_ONLY=1 /root/kbuild-y14.sh   stops after the tree checks, the grep assertions and the pre-build config checks
#                                     (no compile; log /root/y700-kernel-y14-check.log; leaves .config in the tree).
if [ "${CHECK_ONLY:-0}" = 1 ]; then exec > /root/y700-kernel-y14-check.log 2>&1; else exec > /root/y700-kernel-y14.log 2>&1; fi
set -ex
export LC_ALL=C   # stable sort for the config delta, English git/make messages in the log
command -v pahole   # BTF needs it
SRC=/usr/local/src/linux-t52; UP=/usr/local/src/tb323fu-linux-t52; MODS=/usr/local/src/y700-mods-y14
NAME=-tb323fu-t52-y14; REL=7.3.0-tb323fu-t52-y14; OUT=/usr/local/src/y700-kernel-y14; FR=/root/y8-fragments
PD=/root/y14-patches; Y13=/usr/local/src/y700-kernel-y13
BASECFG=${BASECFG:-/root/config-t49.release}
T52_TREE=ef2f8b3397ef66fa1bd694b87cf1f1272e4e7a37   # t52-base^{tree} (v7.3 + 134 upstream t52 patches)
Y14_TREE=3ebb70be1ebb2367ea80fe1b118712c8a002dbdf   # y14^{tree} (+ our 22 patches; commit 5a21a30d2c6b on 10-23 = 10-22's
                                                     #   4b29628178a5, tree 2f676d5be31b, + 1051)
# the series, in application order: y13's whole stack (0131/0132 are in t52-base) + 1051; 1044/1045 must not appear
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
1049-media-iris-psc-last-not-error.patch
1050-drm-msm-dpu-reject-undersized-gamma-lut.patch
1051-media-iris-preserve-timestamps-on-error-buffers.patch"
CMDLINE="fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 qcom_scm.download_mode=full baldur.end=hold consoleblank=120 no_console_suspend mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0 msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000"
case "$CMDLINE" in *allow_system_off*) echo "CMDLINE must stay y9's: 1043's knob defaults to N in C and must not look cmdline-dependent (Y10-NOTES.md)"; exit 1;; esac
[ -f "$BASECFG" ]
# the initramfs build.sh takes two files from OUTSIDE kernel/ ($repo = kernel/initramfs/../..): android/back-to-android
# and userspace/platform/src/keyhold.c. The t52 copy started as kernel/ only and the first full run (10-23 00:16) died
# there after the whole compile; both files were then added from the kernel-t52 tag (unchanged since t47, identical to
# /usr/local/src/tb323fu-linux's). Checked here, before anything is compiled.
echo "4649391b1c72aed99c7e23f393ae5aaa4a5965e4e2bccf326032e874abcde2a5  $UP/android/back-to-android
c5a97de46ea8d28f212ed0d0eba2ecd780c401cae69deb1f7bc5980e0969814c  $UP/userspace/platform/src/keyhold.c" | sha256sum -c
[ -x $UP/kernel/initramfs/build.sh ] && [ -d $UP/kernel/out-of-tree/aw882xx ]
cd $SRC
# ---- the tree must be exactly branch y14 (checked BEFORE anything is written into the tree)
[ "$(git branch --show-current)" = y14 ] || { echo "check out branch y14 in $SRC"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "tracked files changed in $SRC: build only committed y14 states"; exit 1; }
grep -q WORKAROUND_QCOM_ORYON_DC_ZVA arch/arm64/tools/cpucaps && { echo "tree carries 1044 (y11): not part of y14"; exit 1; }
grep -q ltr_max_latency_us drivers/pci/controller/dwc/pcie-qcom.c && { echo "tree carries 1045 (PCIe L1SS): not part of y14"; exit 1; }
[ "$(git rev-parse 'v7.3^{commit}')" = c03c1a14507dfaf8b856c2608f9ac216021fc222 ]
[ "$(git rev-list --count v7.3..t52-base)" = 134 ]
[ "$(git rev-parse 't52-base^{tree}')" = $T52_TREE ] || { echo "t52-base is not the tree prepared on 10-22"; exit 1; }
[ "$(git rev-list --count t52-base..HEAD)" = 22 ]
[ "$(git rev-parse 'HEAD^{tree}')" = $Y14_TREE ] || { echo "y14 is not the pinned tree: re-export the patches and re-pin Y14_TREE after review"; exit 1; }
# the repo's patch files (linux/kernel-y14/patches -> $PD) re-create exactly this tree (temporary index, worktree untouched)
for p in $(cat $PD/series); do [ -f "$PD/$p" ] || { echo "MISSING PATCH FILE: $PD/$p"; exit 1; }; done
[ "$(wc -l < $PD/series)" = 22 ]
[ "$(cat $PD/series)" = "$EXPECTED_SERIES" ] || { echo "$PD/series is not y13's stack + 1051:"; diff <(echo "$EXPECTED_SERIES") $PD/series || true; exit 1; }
rm -f /tmp/y14-kbuild-index
GIT_INDEX_FILE=/tmp/y14-kbuild-index git read-tree t52-base
for p in $(cat $PD/series); do GIT_INDEX_FILE=/tmp/y14-kbuild-index git apply --cached "$PD/$p"; done
[ "$(GIT_INDEX_FILE=/tmp/y14-kbuild-index git write-tree)" = $Y14_TREE ] || { echo "the patch files in $PD do not re-create y14"; exit 1; }
rm -f /tmp/y14-kbuild-index
git log --oneline t52-base..HEAD
# ---- grep assertions (as y13; the tree hash already pins the source, these say WHAT must be in it)
grep -q "mon_tunables = true" drivers/devfreq/scmi-qcom-memlat-devfreq.c   # 1042
# upstream 0131/0132 (in t52-base now)
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
# 1049/1050
grep -q "HFI_BUF_FW_FLAG_LAST | HFI_BUF_FW_FLAG_PSC_LAST" drivers/media/platform/qcom/iris/iris_hfi_gen2_response.c   # 1049
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
# known gap, kept for parity with y8..y13: the [A-Z0-9_] pattern above skips symbols with lower-case letters, so these
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
	# must-keep: "SYMBOL y|m reason" lines. y14: [A-Za-z0-9_], so FONT_TER16x32 / FONT_8x16 are checked too (y8..y13's
	# [A-Z0-9_] skipped them; both are set in y13 and in the y14 dry run)
	grep -E '^[A-Za-z0-9_]+ [ym] ' $FR/y8-must-keep.txt | while read -r sym st _; do
		# any set value counts (bool y, tristate m, or an int/string such as BOOTPARAM_*_PANIC=1)
		grep -qE "^CONFIG_$sym=" .config || { echo "MUST-KEEP LOST: $sym (wanted $st)"; echo lost >> /tmp/y14-check-bad; }
	done
	# the fragments must have stuck: not-set lines are not y/m, =m lines are m, values as given
	for f in $FR/y8-trim.fragment $FR/y8-power.fragment; do
		grep -E '^# CONFIG_[A-Z0-9_]+ is not set' "$f" | while read -r _ sym _; do
			grep -qE "^$sym=[ym]$" .config && { echo "REVIVED by olddefconfig: $sym"; echo rev >> /tmp/y14-check-bad; }
		done
		grep -E '^CONFIG_[A-Z0-9_]+=' "$f" | while read -r line; do
			grep -qx "$line" .config || { echo "NOT APPLIED: $line (now: $(grep "^${line%%=*}[= ]" .config || echo unset))"; echo na >> /tmp/y14-check-bad; }
		done
	done
	[ -e /tmp/y14-check-bad ] && bad=1
	rm -f /tmp/y14-check-bad
	return $bad
}
rm -f /tmp/y14-check-bad
check_config || { echo "CONFIG CHECK FAILED - see above"; exit 1; }
# ---- config delta against y13 (replaces y13's "must equal y12"): exactly the two v7.3 errata lines, nothing else.
# cfgcmp as in kbuild-y13 (comments and the two lines that name the build left out); the delta is printed in the log.
EXPECTED_DELTA="> CONFIG_ARM64_ERRATUM_3821522=y
> CONFIG_ARM64_WORKAROUND_BROKEN_AMU_CONSTCNT=y"
cfgcmp() { grep -vE "^CONFIG_(LOCALVERSION|INITRAMFS_SOURCE)=|^#" "$1"; }
cfgdelta() { diff <(cfgcmp "$1") <(cfgcmp "$2") | grep '^[<>]' | sort; }
delta=$(cfgdelta $Y13/config-t49-y13.pre-build .config)
echo "pre-build config delta vs y13:"; echo "$delta"
[ "$delta" = "$EXPECTED_DELTA" ] || { echo "PRE-BUILD CONFIG DELTA vs y13 IS NOT THE EXPECTED ONE (see above)"; exit 1; }
if [ "${CHECK_ONLY:-0}" = 1 ]; then echo CHECK_ONLY_OK; exit 0; fi
mkdir -p $OUT
cp .config $OUT/config-t52-y14.pre-build
$M Image dtbs modules headers_install
rm -rf $MODS; $M INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
# aw882xx from the t52 copy (same source as t49's, 10-22 diff); clean, then build and install in two separate makes
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
cp arch/arm64/boot/Image $OUT/Image-t52-y14; gzip -9 -n -c arch/arm64/boot/Image > $OUT/Image-t52-y14.gz
cp .config $OUT/config-t52-y14; git diff t52-base HEAD > $OUT/y700-y14.patch
delta=$(cfgdelta $Y13/config-t49-y13 $OUT/config-t52-y14)
echo "final config delta vs y13:"; echo "$delta"
[ "$delta" = "$EXPECTED_DELTA" ] || { echo "FINAL CONFIG DELTA vs y13 IS NOT THE EXPECTED ONE (see above)"; exit 1; }
strings $OUT/Image-t52-y14 | grep -m1 "Linux version"
# the knob is in the image: the built-in parameter name (__param section) and the report format string (rodata)
strings $OUT/Image-t52-y14 | grep -q "cpuidle_psci_domain.allow_system_off"
strings $OUT/Image-t52-y14 | grep -q "allow_system_off=%c, system domain state %s (%s)"
ls -la $OUT/Image-t52-y14 $Y13/Image-t49-y13
sha256sum $OUT/Image-t52-y14*
echo KFULL_OK
