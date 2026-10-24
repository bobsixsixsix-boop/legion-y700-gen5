#!/bin/bash
# y700: kernel build -y8 = y7 (y6 + 1033) + 1041 ath12k station power save + 1040 Android memlat tunables,
#   config = t49 release config - y8-trim.fragment (538 unused drivers/features off, 10 to modules)
#   + y8-power.fragment (uclamp, TEO, lazy RCU, no SCHED_CACHE/FW_LOADER_DEBUG/STM, hung-task 180 s),
#   cmdline without the three no-op parameters (icc-rpmh.qos_disable x2, keep_bootcon) and with the
#   panel idle-refresh thresholds of the power-saver preset (msm.idle_refresh_ms60/ms30).
# Same tree as y5..y7 (/usr/local/src/linux-t47), so the patch stack is incremental. /root/y8-patches/ =
# linux/kernel-y8/{1040,1041}-*.patch; /root/y8-fragments/ = y8-trim.fragment, y8-power.fragment, y8-must-keep.txt.
# NOTE: 1041 was applied to the tree's mac.c by hand on 2026-10-15 (module-only build, see README): the
# series detection below sees it as already applied and only adds 1040.
exec > /root/y700-kernel-y8.log 2>&1
set -ex
command -v pahole   # BTF needs it
SRC=/usr/local/src/linux-t47; UP=/usr/local/src/tb323fu-linux; MODS=/usr/local/src/y700-mods-y8
NAME=-tb323fu-t49-y8; OUT=/usr/local/src/y700-kernel-y8; FR=/root/y8-fragments; mkdir -p $OUT
CMDLINE="fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 qcom_scm.download_mode=full baldur.end=hold consoleblank=120 no_console_suspend mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0 msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000"
cd $SRC
git apply --reverse --check /root/va-iris.patch 2>/dev/null || git apply /root/va-iris.patch   # already applied is fine
series="$(ls /root/y4-patches/0540-*-sm8850.patch /root/y4-patches/0620-*.patch /root/y4-patches/0621-*.patch \
	/root/y4-patches/0622-*.patch /root/y6-patches/1030-*.patch /root/y6-patches/1031-*.patch /root/y6-patches/1032-*.patch \
	/root/y7-patches/1033-*.patch /root/y8-patches/1041-*.patch /root/y8-patches/1040-*.patch)"
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
cp .config $OUT/config-t49-y8.pre-build
$M Image dtbs modules headers_install
rm -rf $MODS; $M INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
# clean, then build and install in two separate makes (the y4 lesson: with -j8 one make ran the install
# before the build and shipped a stale aw882xx.ko)
$M M=$UP/kernel/out-of-tree/aw882xx clean
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m modules
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
rel=$($M -s kernelrelease); [ "$rel" = 7.3.0-rc4-tb323fu-t49-y8 ]
for ko in $(find $MODS/lib/modules/$rel -name '*.ko'); do   # every module must carry this kernel's vermagic
	case "$(modinfo -F vermagic $ko)" in "$rel "*) ;; *) echo "BAD VERMAGIC $ko"; exit 1;; esac
done
[ "$(modinfo -F version $MODS/lib/modules/$rel/kernel/drivers/net/wireless/ath/ath12k/ath12k.ko)" = y700-1041 ]   # 1041 is in-tree now
rm -f $MODS/lib/modules/$rel/build $MODS/lib/modules/$rel/source; depmod -b $MODS $rel
ls $MODS/lib/modules/$rel/updates/
$UP/kernel/initramfs/build.sh -k $SRC -b /bin/busybox -m $MODS/lib/modules/$rel -f / -a /etc/tb323fu/android-boot.sha256 -l $OUT/initramfs.list $OUT/initramfs.cpio.gz
scripts/config --file .config --set-str INITRAMFS_SOURCE "$OUT/initramfs.cpio.gz"
$M olddefconfig
grep -qx "CONFIG_CMDLINE=\"$CMDLINE\"" .config
$M Image
cp arch/arm64/boot/Image $OUT/Image-t49-y8; gzip -9 -n -c arch/arm64/boot/Image > $OUT/Image-t49-y8.gz
cp .config $OUT/config-t49-y8; git diff > $OUT/y700-y8.patch
strings $OUT/Image-t49-y8 | grep -m1 "Linux version"
ls -la $OUT/Image-t49-y8 /usr/local/src/y700-kernel-y7/Image-t49-y7
sha256sum $OUT/Image-t49-y8*
echo KFULL_OK
