#!/bin/bash
# y700: kernel build -y11 = y10 + 1044 Qualcomm Oryon DC ZVA erratum workaround (linux/power/cx-collapse/RESEARCH.md
#   2.4 H2 and 3.2 E2: the decisive A/B article, built ONLY after a positive E2; see 1044's commit message).
#   y10 = y9 + 1043 allow_system_off knob; y9 = y8 + 1042 memlat; y8 = y7 + 1041 ath12k PS.
#   config = exactly y10's, plus CONFIG_QCOM_ORYON_ERRATUM_DC_ZVA=y (1044 adds the symbol, default y).
#   CMDLINE = y10's (the erratum is build-time via Kconfig and boot-time via qcom_oryon_dc_zva=off; the primary image
#   has the workaround ON). This script ALSO builds a twin image Image-t49-y11-dczva-off (same kernel + modules + the
#   same forced cmdline with qcom_oryon_dc_zva=off appended) for the A/B: workaround on must stop the x1e-crash reset,
#   workaround off must reset again (dczva-stress.c / dczva-selftest.c).
# Same tree as y5..y10 (/usr/local/src/linux-t47), incremental stack. /root/y8-patches/ =
# linux/kernel-y8/{1041,1042,1043,1044}-*.patch (scp 1044 there before running this); /root/y8-fragments/ =
# y8-trim.fragment, y8-power.fragment, y8-must-keep.txt.
# NOTE: the series is in APPLICATION order and never passed through ls (the y8 1040/1041 sort lesson).
# 1044 touches arch/arm64/{kernel/{cpu_errata,traps}.c,include/asm/{cputype,esr}.h,lib/{clear_page,memset,mte}.S,
# tools/cpucaps,Kconfig} and Documentation/arch/arm64/silicon-errata.rst; of these only arch/arm64/Kconfig is also
# touched by tb323fu-linux 0021/0022 (far from the errata menu). 1044 does NOT touch cpuidle-psci-domain.c, so it is
# independent of 0106/0118/1043. Checked with y11-selfcheck.sh before the build and the grep assertions below.
exec > /root/y700-kernel-y11.log 2>&1
set -ex
command -v pahole   # BTF needs it
SRC=/usr/local/src/linux-t47; UP=/usr/local/src/tb323fu-linux; MODS=/usr/local/src/y700-mods-y11
NAME=-tb323fu-t49-y11; OUT=/usr/local/src/y700-kernel-y11; FR=/root/y8-fragments; mkdir -p $OUT
CMDLINE="fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 qcom_scm.download_mode=full baldur.end=hold consoleblank=120 no_console_suspend mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0 msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000"
case "$CMDLINE" in *allow_system_off*) echo "CMDLINE must stay y9's/y10's: 1043's knob defaults to N in C (Y10-NOTES.md)"; exit 1;; esac
CMDLINE_OFF="$CMDLINE qcom_oryon_dc_zva=off"   # twin image for the A/B (workaround compiled in but disabled at boot)
cd $SRC
git apply --reverse --check /root/va-iris.patch 2>/dev/null || git apply /root/va-iris.patch   # already applied is fine
series="$(printf '%s\n' /root/y4-patches/0540-*-sm8850.patch /root/y4-patches/0620-*.patch /root/y4-patches/0621-*.patch \
	/root/y4-patches/0622-*.patch /root/y6-patches/1030-*.patch /root/y6-patches/1031-*.patch /root/y6-patches/1032-*.patch \
	/root/y7-patches/1033-*.patch /root/y8-patches/1041-*.patch /root/y8-patches/1042-*.patch \
	/root/t51-patches/0131-*.patch /root/t51-patches/0132-*.patch /root/y8-patches/1043-*.patch \
	/root/y8-patches/1044-*.patch)"
for p in $series; do [ -f "$p" ] || { echo "MISSING PATCH FILE: $p (an unexpanded glob = the file is not in place)"; exit 1; }; done
[ "$(echo "$series" | wc -l)" = 14 ]
# 10-16: the tree may carry y12's 1046-1048 (A8xx GMU vote fixes, built after y10 on this same tree); the detection below
# would then put 1044 on top of them silently. Refuse (before applying anything): reverse-apply 1048, 1047, 1046 first,
# or insert them into this series BEFORE 1044 (kbuild-y12.sh header) - then this check stands down.
case "$series" in *1046-*) ;; *) grep -q "if (adreno_is_a6xx(adreno_gpu) ||" drivers/gpu/drm/msm/adreno/a6xx_gmu.c && { echo "tree carries y12's 1046-1048: git apply -R 1048, 1047, 1046 first (or insert them BEFORE 1044 in this series)"; exit 1; } ;; esac
# A linear stack: the newest patch that reverse-applies marks how far the tree is; apply only the ones after it.
top=0; i=$(echo "$series" | wc -l)
for p in $(echo "$series" | tac); do
	if git apply --reverse --check "$p" 2>/dev/null; then top=$i; break; fi
	i=$((i - 1))
done
echo "tree has the first $top of $(echo "$series" | wc -l) patches"
i=0
for p in $series; do
	i=$((i + 1))
	[ $i -le $top ] || git apply "$p"
done
git status --short
grep -q "mon_tunables = true" drivers/devfreq/scmi-qcom-memlat-devfreq.c   # 1042 really applied
# 1043 really applied (same shape y10 asserts: default N, RT guard, 0106 quirk kept, 0118 kept, bool-like NOARG)
D=drivers/cpuidle/cpuidle-psci-domain.c
grep -q "module_param_cb(allow_system_off, &allow_system_off_ops, &allow_system_off, 0644);" $D
grep -q "^static bool allow_system_off;" $D
grep -q "KERNEL_PARAM_OPS_FL_NOARG" $D
[ "$(grep -c "IS_ENABLED(CONFIG_PREEMPT_RT)" $D)" -ge 2 ]
grep -q "return -EBUSY;" $D
# 1044 really applied, with the properties RESEARCH.md 3.2 / the commit message ask for
grep -q "^WORKAROUND_QCOM_ORYON_DC_ZVA$" arch/arm64/tools/cpucaps                      # cpucap added
grep -qE "QCOM_CPU_PART_ORYON_V3[[:space:]]+0x002" arch/arm64/include/asm/cputype.h    # part 0x002 (kaanapali Oryon)
grep -q "MIDR_QCOM_ORYON_V3" arch/arm64/include/asm/cputype.h
grep -q "config QCOM_ORYON_ERRATUM_DC_ZVA" arch/arm64/Kconfig
grep -q "ESR_ELx_SYS64_ISS_CRM_DC_ZVA" arch/arm64/include/asm/esr.h
grep -q 'early_param("qcom_oryon_dc_zva"' arch/arm64/kernel/cpu_errata.c               # boot-time off switch
grep -q "qcom_oryon_dc_zva_cpus" arch/arm64/kernel/cpu_errata.c
grep -q "sysreg_clear_set(sctlr_el1, SCTLR_EL1_DZE, 0);" arch/arm64/kernel/cpu_errata.c
sed -n '/cpu_enable_qcom_oryon_dc_zva_trap(const/,/^}/p' arch/arm64/kernel/cpu_errata.c | grep -q "isb();" && { echo "1044: cpu_enable should not call isb() (none needed: the eret to EL0 syncs; keep the x1e-sleep shape)"; exit 1; }
grep -q "read_sysreg(dczid_el0) & 0xf" arch/arm64/kernel/traps.c                        # BS mask spelled 0xf (x1e-sleep shape)
grep -q "DCZID_EL0_BS_MASK" arch/arm64/kernel/traps.c && { echo "1044: traps.c should mask DCZID_EL0.BS with & 0xf (the generated _MASK exists too; keep one spelling, the one y11-selfcheck asserts)"; exit 1; }
grep -q "qcom_oryon_dc_zva_emulated" arch/arm64/kernel/traps.c                          # debugfs counter = "active" flag
for f in clear_page memset mte; do grep -q "alternative_if ARM64_WORKAROUND_QCOM_ORYON_DC_ZVA" arch/arm64/lib/$f.S || { echo "1044: $f.S not gated on the cpucap"; exit 1; }; done
M="make LLVM=/opt/llvm-18/bin/ LOCALVERSION= -j8"
cp /root/config-t49.release .config
scripts/config --file .config --set-str LOCALVERSION "$NAME" --set-str INITRAMFS_SOURCE "" --set-str CMDLINE "$CMDLINE"
scripts/config --file .config --enable QCOM_ORYON_ERRATUM_DC_ZVA   # 1044's build-time switch (default y; assert it below)
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
$M olddefconfig
# ---- checks after olddefconfig (both directions; any deviation stops the build so it can be looked at)
check_config() {
	bad=0
	for o in CONFIG_NTSYNC=m CONFIG_ZRAM_BACKEND_ZSTD=y CONFIG_EXFAT_FS=m CONFIG_LRU_GEN_ENABLED=y CONFIG_DEBUG_INFO_BTF=y \
		CONFIG_DEBUG_INFO_BTF_MODULES=n CONFIG_ANDROID_BINDER_IPC=n; do
		if [ "${o#*=}" = n ]; then grep -q "^${o%=n}=" .config && { echo "UNEXPECTED ${o%=n} set"; bad=1; }
		elif ! grep -qx "$o" .config; then echo "MISSING $o"; bad=1; fi
	done
	grep -qx "CONFIG_CMDLINE=\"$CMDLINE\"" .config || { echo "CMDLINE not as intended"; bad=1; }
	grep -qx "CONFIG_ARM_PSCI_CPUIDLE_DOMAIN=y" .config || { echo "ARM_PSCI_CPUIDLE_DOMAIN not built in"; bad=1; }
	grep -q "^CONFIG_PREEMPT_RT=y" .config && { echo "PREEMPT_RT is on: 1043's knob would be a no-op"; bad=1; }
	grep -qx "CONFIG_QCOM_ORYON_ERRATUM_DC_ZVA=y" .config || { echo "QCOM_ORYON_ERRATUM_DC_ZVA not =y: 1044 would be a no-op"; bad=1; }
	grep -qx "CONFIG_DEBUG_FS=y" .config || { echo "DEBUG_FS off: no /sys/kernel/debug/qcom_oryon_dc_zva_emulated (y11-verify.sh needs it)"; bad=1; }
	grep -qx "CONFIG_CMDLINE_FORCE=y" .config || { echo "CMDLINE_FORCE off: the baked-in cmdline is not what boots, the -dczva-off twin would switch nothing"; bad=1; }
	grep -E '^[A-Z0-9_]+ [ym] ' $FR/y8-must-keep.txt | while read -r sym st _; do
		grep -qE "^CONFIG_$sym=" .config || { echo "MUST-KEEP LOST: $sym (wanted $st)"; echo lost >> /tmp/y8-check-bad; }
	done
	for f in $FR/y8-trim.fragment $FR/y8-power.fragment; do
		grep -E '^# CONFIG_[A-Z0-9_]+ is not set' "$f" | while read -r _ sym _; do
			grep -qE "^$sym=[ym]$" .config && { echo "REVIVED by olddefconfig: $sym"; echo rev >> /tmp/y8-check-bad; }
		done
		grep -E '^CONFIG_[A-Z0-9_]+=' "$f" | while read -r line; do
			grep -qx "$line" .config || { echo "NOT APPLIED: $line (now: $(grep "^${line%%=*}[= ]" .config || echo unset))"; echo na >> /tmp/y8-check-bad; }
		done
	done
	[ -e /tmp/y8-check-bad ] && bad=1
	rm -f /tmp/y8-check-bad
	return $bad
}
check_config || { echo "CONFIG CHECK FAILED - see above"; exit 1; }
cp .config $OUT/config-t49-y11.pre-build
$M Image dtbs modules headers_install
grep -q "ARM64_WORKAROUND_QCOM_ORYON_DC_ZVA" arch/arm64/include/generated/asm/cpucap-defs.h   # 1044's cpucap got its number
rm -rf $MODS; $M INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
# clean, then build and install the out-of-tree amp driver in two separate makes (the y4 stale-aw882xx.ko lesson)
$M M=$UP/kernel/out-of-tree/aw882xx clean
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m modules
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
rel=$($M -s kernelrelease); [ "$rel" = 7.3.0-rc4-tb323fu-t49-y11 ]
for ko in $(find $MODS/lib/modules/$rel -name '*.ko'); do
	case "$(modinfo -F vermagic $ko)" in "$rel "*) ;; *) echo "BAD VERMAGIC $ko"; exit 1;; esac
done
[ "$(modinfo -F version $MODS/lib/modules/$rel/kernel/drivers/net/wireless/ath/ath12k/ath12k.ko)" = y700-1041 ]
rm -f $MODS/lib/modules/$rel/build $MODS/lib/modules/$rel/source; depmod -b $MODS $rel
ls $MODS/lib/modules/$rel/updates/
$UP/kernel/initramfs/build.sh -k $SRC -b /bin/busybox -m $MODS/lib/modules/$rel -f / -a /etc/tb323fu/android-boot.sha256 -l $OUT/initramfs.list $OUT/initramfs.cpio.gz
scripts/config --file .config --set-str INITRAMFS_SOURCE "$OUT/initramfs.cpio.gz"
$M olddefconfig
grep -qx "CONFIG_CMDLINE=\"$CMDLINE\"" .config
$M Image
cp arch/arm64/boot/Image $OUT/Image-t49-y11; gzip -9 -n -c arch/arm64/boot/Image > $OUT/Image-t49-y11.gz
cp .config $OUT/config-t49-y11; git diff > $OUT/y700-y11.patch
# ---- twin image with the workaround disabled at boot (same kernel + initramfs, only the forced cmdline differs) ----
scripts/config --file .config --set-str CMDLINE "$CMDLINE_OFF"
$M olddefconfig
grep -qx "CONFIG_CMDLINE=\"$CMDLINE_OFF\"" .config
$M Image
cp arch/arm64/boot/Image $OUT/Image-t49-y11-dczva-off; gzip -9 -n -c arch/arm64/boot/Image > $OUT/Image-t49-y11-dczva-off.gz
scripts/config --file .config --set-str CMDLINE "$CMDLINE"   # restore the primary cmdline in .config
$M olddefconfig; grep -qx "CONFIG_CMDLINE=\"$CMDLINE\"" .config
# ---- the erratum must be in the image: the cpucap description string (rodata) and the cmdline param name ----
strings $OUT/Image-t49-y11 | grep -m1 "Linux version"
strings $OUT/Image-t49-y11 | grep -q "Qualcomm Oryon DC ZVA erratum"
strings $OUT/Image-t49-y11 | grep -q "qcom_oryon_dc_zva"
# the A/B pair really differs only in the baked-in switch: the primary must NOT carry it, the twin must
if strings $OUT/Image-t49-y11 | grep -q "qcom_oryon_dc_zva=off"; then echo "primary image carries the off switch?!"; exit 1; fi   # ("! cmd" would not stop set -e)
strings $OUT/Image-t49-y11-dczva-off | grep -q "qcom_oryon_dc_zva=off"
strings $OUT/Image-t49-y11-dczva-off | grep -q "Qualcomm Oryon DC ZVA erratum"   # same erratum code compiled into the twin
ls -la $OUT/Image-t49-y11 $OUT/Image-t49-y11-dczva-off /usr/local/src/y700-kernel-y10/Image-t49-y10
sha256sum $OUT/Image-t49-y11*
echo KFULL_OK
