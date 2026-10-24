#!/bin/bash
# y700: t47 kernel build -y4 = y3 (y1 battmgr/ath12k + iris VA-API controls + battmgr I x V + no ath12k bmiss timer)
#   + armada-os/armada 0540 arm64 SSBS-on-sigreturn (Wine/Proton threads otherwise run with store bypass disabled;
#     SM8850's Oryon part 0x002 added to the default-on list) + 0620/0621/0622 Adreno GMU HFI race fixes.
# Patches are copied to /root/y4-patches/ first (from linux/kernel-y4/ in this repo).
exec > /root/y700-kernel-y4.log 2>&1
set -ex
SRC=/usr/local/src/linux-t47; UP=/usr/local/src/tb323fu-linux; MODS=/usr/local/src/y700-mods-y4
NAME=-tb323fu-t47-y4; OUT=/usr/local/src/y700-kernel-y4; mkdir -p $OUT
cd $SRC
git apply --reverse --check /root/va-iris.patch 2>/dev/null || git apply /root/va-iris.patch   # already applied is fine
for p in /root/y4-patches/0540-*-sm8850.patch /root/y4-patches/0620-*.patch /root/y4-patches/0621-*.patch /root/y4-patches/0622-*.patch; do
	git apply --reverse --check "$p" 2>/dev/null || git apply "$p"
done
git status --short
M="make LLVM=/opt/llvm-18/bin/ LOCALVERSION= -j8"
cp /root/config-t47.release .config
scripts/config --file .config --set-str LOCALVERSION "$NAME" --set-str INITRAMFS_SOURCE ""
$M olddefconfig
$M Image dtbs modules headers_install
rm -rf $MODS; $M INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
# clean, then build and install in two separate makes: with -j8 one `make modules modules_install` ran the
# install before the build, so y4's first image shipped the stale -y3 aw882xx.ko (vermagic mismatch, the y4
# kernel refused it and there was no sound card)
$M M=$UP/kernel/out-of-tree/aw882xx clean
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m modules
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
rel=$($M -s kernelrelease); [ "$rel" = 7.3.0-rc4-tb323fu-t47-y4 ]
for ko in $(find $MODS/lib/modules/$rel -name '*.ko'); do   # every module must carry this kernel's vermagic
	case "$(modinfo -F vermagic $ko)" in "$rel "*) ;; *) echo "BAD VERMAGIC $ko"; exit 1;; esac
done
rm -f $MODS/lib/modules/$rel/build $MODS/lib/modules/$rel/source; depmod -b $MODS $rel
ls $MODS/lib/modules/$rel/updates/
$UP/kernel/initramfs/build.sh -k $SRC -b /bin/busybox -m $MODS/lib/modules/$rel -f / -a /etc/tb323fu/android-boot.sha256 -l $OUT/initramfs.list $OUT/initramfs.cpio.gz
scripts/config --file .config --set-str INITRAMFS_SOURCE "$OUT/initramfs.cpio.gz"
$M olddefconfig
$M Image
cp arch/arm64/boot/Image $OUT/Image-t47-y4; gzip -9 -n -c arch/arm64/boot/Image > $OUT/Image-t47-y4.gz
cp .config $OUT/config-t47-y4; git diff > $OUT/y700-y4.patch
strings $OUT/Image-t47-y4 | grep -m1 "Linux version"
sha256sum $OUT/Image-t47-y4*
echo KFULL_OK
