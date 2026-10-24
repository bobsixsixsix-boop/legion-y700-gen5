#!/bin/bash
# y700: kernel build -y10 = y9 + upstream kernel-t51's 0131/0132 + 1043 allow_system_off knob (linux/power/cx-collapse/
#   RESEARCH.md 3.3, the "flag version"). y9 = y8 + 1042 Android memlat tunables; y8 = y7 (y6 + 1033) + 1041 ath12k PS;
#   config = t49 release config - y8-trim.fragment + y8-power.fragment, exactly as y9.
#   CMDLINE = y9's, UNCHANGED: 1043's knob defaults to N in C (fail-safe without any cmdline), so pinning
#   cpuidle_psci_domain.allow_system_off=0 next to allow_cluster_off=0 would only suggest the knob depends on the cmdline
#   (Y10-NOTES.md "有意不做"; RESEARCH.md 3.3 fix 3 proposed the pin, the 10-16 review reversed it). The script refuses a
#   CMDLINE that mentions allow_system_off. cx-exp.sh flips both knobs at run time; a reset reverts both to off.
#   0131 (dpu: no modeset for colour management once the CRTC has its DSPP - night light stops blanking the panel) and
#   0132 (battmgr: constant_charge_current[_max] sysfs; helper 0.4.2's 9 V bypass needs it) are tb323fu-linux
#   kernel-t51's two new patches, kept in linux/kernel-y8/t51/. 0132 is the y700 REBASE: its sm8350_bat_prop_map hunk
#   collides with the y3 battmgr I*V patch already in the tree (same content, context adjusted); the upstream original
#   sits next to it as *.upstream. 0131 applies as published.
# Same tree as y5..y9 (/usr/local/src/linux-t47), so the patch stack is incremental. /root/y8-patches/ =
# linux/kernel-y8/{1041,1042,1043}-*.patch (scp 1043 there before running this); /root/t51-patches/ =
# linux/kernel-y8/t51/{0131,0132}-*.patch (NOT the *.upstream file); /root/y8-fragments/ = y8-trim.fragment,
# y8-power.fragment, y8-must-keep.txt.
# NOTE: the series is written in APPLICATION order and never passed through ls (ls sorts its arguments: in the
# y8 build 1040 sorted before 1041, the detection saw 1041 applied and skipped 1040 - hence the rename to 1042).
# 1043 edits drivers/cpuidle/cpuidle-psci-domain.c, a file upstream patches 0106 and 0118 (in the tree since t47) edit
# too: its hunk contexts are those of the 0118-patched file, so it applies only after them. Checked with
# y10-selfcheck.sh before the build and with grep assertions below (the 1040 lesson: assert that a patch really landed).
exec > /root/y700-kernel-y10.log 2>&1
set -ex
command -v pahole   # BTF needs it
SRC=/usr/local/src/linux-t47; UP=/usr/local/src/tb323fu-linux; MODS=/usr/local/src/y700-mods-y10
NAME=-tb323fu-t49-y10; OUT=/usr/local/src/y700-kernel-y10; FR=/root/y8-fragments; mkdir -p $OUT
CMDLINE="fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 qcom_scm.download_mode=full baldur.end=hold consoleblank=120 no_console_suspend mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0 msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000"
case "$CMDLINE" in *allow_system_off*) echo "CMDLINE must stay y9's: 1043's knob defaults to N in C and must not look cmdline-dependent (Y10-NOTES.md)"; exit 1;; esac
cd $SRC
git apply --reverse --check /root/va-iris.patch 2>/dev/null || git apply /root/va-iris.patch   # already applied is fine
series="$(printf '%s\n' /root/y4-patches/0540-*-sm8850.patch /root/y4-patches/0620-*.patch /root/y4-patches/0621-*.patch \
	/root/y4-patches/0622-*.patch /root/y6-patches/1030-*.patch /root/y6-patches/1031-*.patch /root/y6-patches/1032-*.patch \
	/root/y7-patches/1033-*.patch /root/y8-patches/1041-*.patch /root/y8-patches/1042-*.patch \
	/root/t51-patches/0131-*.patch /root/t51-patches/0132-*.patch /root/y8-patches/1043-*.patch)"
# (0131/0132 sit after 1042 = the y9 top, so on a y9 tree the detection below applies exactly them + 1043)
for p in $series; do [ -f "$p" ] || { echo "MISSING PATCH FILE: $p (an unexpanded glob = the file is not in place)"; exit 1; }; done
[ "$(echo "$series" | wc -l)" = 13 ]
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
# t51's 0131/0132 really applied (the 1040 lesson)
grep -q "a DSPP can only be added to the pipeline on a modeset" drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c
grep -q "stop setting allow_modeset and move this check to the DPU" drivers/gpu/drm/msm/msm_atomic.c && { echo "0131 did not land: the FIXME loop is still in msm_atomic_check"; exit 1; }
grep -q "qcom_battmgr_set_charge_current_limit" drivers/power/supply/qcom_battmgr.c
grep -q "POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT_MAX\] = BATT_CHG_CTRL_LIM_MAX" drivers/power/supply/qcom_battmgr.c
# 1043 really applied, with the properties RESEARCH.md 3.3 asks for (default N, RT guard, 0106 quirk kept, 0118 kept)
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
M="make LLVM=/opt/llvm-18/bin/ LOCALVERSION= -j8"
cp /root/config-t49.release .config
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
	# must-keep: "SYMBOL y|m reason" lines
	grep -E '^[A-Z0-9_]+ [ym] ' $FR/y8-must-keep.txt | while read -r sym st _; do
		# any set value counts (bool y, tristate m, or an int/string such as BOOTPARAM_*_PANIC=1)
		grep -qE "^CONFIG_$sym=" .config || { echo "MUST-KEEP LOST: $sym (wanted $st)"; echo lost >> /tmp/y8-check-bad; }
	done
	# the fragments must have stuck: not-set lines are not y/m, =m lines are m, values as given
	for f in $FR/y8-trim.fragment $FR/y8-power.fragment; do
		grep -E '^# CONFIG_[A-Z0-9_]+ is not set' "$f" | while read -r _ sym _; do
			grep -qE "^$sym=[ym]$" .config && { echo "REVIVED by olddefconfig: $sym (allowed only if listed in known-revived)"; echo rev >> /tmp/y8-check-bad; }
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
cp .config $OUT/config-t49-y10.pre-build
$M Image dtbs modules headers_install
rm -rf $MODS; $M INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
# clean, then build and install in two separate makes (the y4 lesson: with -j8 one make ran the install
# before the build and shipped a stale aw882xx.ko)
$M M=$UP/kernel/out-of-tree/aw882xx clean
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m modules
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
rel=$($M -s kernelrelease); [ "$rel" = 7.3.0-rc4-tb323fu-t49-y10 ]
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
cp arch/arm64/boot/Image $OUT/Image-t49-y10; gzip -9 -n -c arch/arm64/boot/Image > $OUT/Image-t49-y10.gz
cp .config $OUT/config-t49-y10; git diff > $OUT/y700-y10.patch
strings $OUT/Image-t49-y10 | grep -m1 "Linux version"
# the knob is in the image: the built-in parameter name (__param section) and the report format string (rodata)
strings $OUT/Image-t49-y10 | grep -q "cpuidle_psci_domain.allow_system_off"
strings $OUT/Image-t49-y10 | grep -q "allow_system_off=%c, system domain state %s (%s)"
ls -la $OUT/Image-t49-y10 /usr/local/src/y700-kernel-y9/Image-t49-y9
sha256sum $OUT/Image-t49-y10*
echo KFULL_OK
