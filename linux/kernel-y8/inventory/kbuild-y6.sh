#!/bin/bash
# y700: kernel build -y6 = y5 (t47 patches 0001-0130 + y1 battmgr/ath12k + iris VA-API controls + battmgr I x V
#   + no ath12k bmiss timer + armada 0540 SSBS-on-sigreturn (SM8850) + 0620-0622 GMU HFI fixes, upstream t49 config)
#   + armada 1030/1031 iris fixes: send the stream's H.264 POC type, stop the AV1 tier setter overwriting the HEVC tier
#   (a decoder whose bitstream port is restarted after a source change looped on source changes: Steam Remote Play green).
#   + y700 1032: send back the colour info the firmware reported (without it every restart still re-raised the
#   source change on SM8850, whatever the stream; found with kprobes, see iris-restart-test.c).
# Same tree as y5 (/usr/local/src/linux-t47), so this is an incremental build. /root/y6-patches/ = linux/kernel-next/103*.patch.
exec > /root/y700-kernel-y6.log 2>&1
set -ex
command -v pahole   # BTF needs it
SRC=/usr/local/src/linux-t47; UP=/usr/local/src/tb323fu-linux; MODS=/usr/local/src/y700-mods-y6
NAME=-tb323fu-t49-y6; OUT=/usr/local/src/y700-kernel-y6; mkdir -p $OUT
cd $SRC
git apply --reverse --check /root/va-iris.patch 2>/dev/null || git apply /root/va-iris.patch   # already applied is fine
for p in /root/y4-patches/0540-*-sm8850.patch /root/y4-patches/0620-*.patch /root/y4-patches/0621-*.patch /root/y4-patches/0622-*.patch \
	/root/y6-patches/1030-*.patch /root/y6-patches/1031-*.patch /root/y6-patches/1032-*.patch; do
	git apply --reverse --check "$p" 2>/dev/null || git apply "$p"
done
git status --short
M="make LLVM=/opt/llvm-18/bin/ LOCALVERSION= -j8"
cp /root/config-t49.release .config
scripts/config --file .config --set-str LOCALVERSION "$NAME" --set-str INITRAMFS_SOURCE ""
$M olddefconfig
for o in CONFIG_NTSYNC=m CONFIG_ZRAM_BACKEND_ZSTD=y CONFIG_EXFAT_FS=m CONFIG_LRU_GEN_ENABLED=y CONFIG_DEBUG_INFO_BTF=y \
	CONFIG_DEBUG_INFO_BTF_MODULES=n CONFIG_ANDROID_BINDERFS=y; do   # t49 features must survive olddefconfig
	if [ "${o#*=}" = n ]; then
		if grep -q "^${o%=n}=" .config; then echo "UNEXPECTED ${o%=n} set"; exit 1; fi
	elif ! grep -qx "$o" .config; then
		echo "MISSING $o"; exit 1
	fi
done
$M Image dtbs modules headers_install
rm -rf $MODS; $M INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
# clean, then build and install in two separate makes: with -j8 one `make modules modules_install` ran the
# install before the build, so y4's first image shipped the stale -y3 aw882xx.ko (vermagic mismatch, the y4
# kernel refused it and there was no sound card)
$M M=$UP/kernel/out-of-tree/aw882xx clean
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m modules
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
rel=$($M -s kernelrelease); [ "$rel" = 7.3.0-rc4-tb323fu-t49-y6 ]
for ko in $(find $MODS/lib/modules/$rel -name '*.ko'); do   # every module must carry this kernel's vermagic
	case "$(modinfo -F vermagic $ko)" in "$rel "*) ;; *) echo "BAD VERMAGIC $ko"; exit 1;; esac
done
rm -f $MODS/lib/modules/$rel/build $MODS/lib/modules/$rel/source; depmod -b $MODS $rel
ls $MODS/lib/modules/$rel/updates/
$UP/kernel/initramfs/build.sh -k $SRC -b /bin/busybox -m $MODS/lib/modules/$rel -f / -a /etc/tb323fu/android-boot.sha256 -l $OUT/initramfs.list $OUT/initramfs.cpio.gz
scripts/config --file .config --set-str INITRAMFS_SOURCE "$OUT/initramfs.cpio.gz"
$M olddefconfig
$M Image
cp arch/arm64/boot/Image $OUT/Image-t49-y6; gzip -9 -n -c arch/arm64/boot/Image > $OUT/Image-t49-y6.gz
cp .config $OUT/config-t49-y6; git diff > $OUT/y700-y6.patch
strings $OUT/Image-t49-y6 | grep -m1 "Linux version"
sha256sum $OUT/Image-t49-y6*
echo KFULL_OK
