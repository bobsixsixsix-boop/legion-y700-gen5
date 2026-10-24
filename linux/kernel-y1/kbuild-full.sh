#!/bin/bash
# y700: full t47 kernel build (clang 18) with the y700 patches (ath12k wcn7860_mlo, qcom_battmgr),
# all modules + aw882xx in a shared-modules squashfs, firmware in the initramfs -> Image.gz
exec > /root/y700-kernel-full.log 2>&1
set -ex
SRC=/usr/local/src/linux-t47; UP=/usr/local/src/tb323fu-linux; MODS=/usr/local/src/y700-mods
NAME=-tb323fu-t47-y1; OUT=/usr/local/src/y700-kernel; mkdir -p $OUT
cd $SRC
M="make LLVM=/opt/llvm-18/bin/ LOCALVERSION= -j8"
cp /root/config-t47.release .config
scripts/config --file .config --set-str LOCALVERSION "$NAME" --set-str INITRAMFS_SOURCE ""
$M olddefconfig
$M Image dtbs modules headers_install
rm -rf $MODS; $M INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules modules_install
rel=$($M -s kernelrelease)
rm -f $MODS/lib/modules/$rel/build $MODS/lib/modules/$rel/source; depmod -b $MODS $rel
ls $MODS/lib/modules/$rel/extra/
$UP/kernel/initramfs/build.sh -k $SRC -b /bin/busybox -m $MODS/lib/modules/$rel -f / -a /etc/tb323fu/android-boot.sha256 -l $OUT/initramfs.list $OUT/initramfs.cpio.gz
scripts/config --file .config --set-str INITRAMFS_SOURCE "$OUT/initramfs.cpio.gz"
$M olddefconfig
$M Image
cp arch/arm64/boot/Image $OUT/Image-t47-y1; gzip -9 -n -c arch/arm64/boot/Image > $OUT/Image-t47-y1.gz
cp .config $OUT/config-t47-y1; git diff > $OUT/y700.patch
strings $OUT/Image-t47-y1 | grep -m1 "Linux version"
sha256sum $OUT/Image-t47-y1*
echo KFULL_OK
