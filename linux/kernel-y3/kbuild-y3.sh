#!/bin/bash
# y700: t47 kernel build -y3 = y2 (y1 patches + iris VA-API controls) + battmgr POWER_NOW always I x V
# controls for VA-API (libva-v4l2), from code002-2/sm8750-video-accel, rebased onto t47 (/root/va-iris.patch)
exec > /root/y700-kernel-y3.log 2>&1
set -ex
SRC=/usr/local/src/linux-t47; UP=/usr/local/src/tb323fu-linux; MODS=/usr/local/src/y700-mods-y3
NAME=-tb323fu-t47-y3; OUT=/usr/local/src/y700-kernel-y3; mkdir -p $OUT
cd $SRC
git apply --reverse --check /root/va-iris.patch 2>/dev/null || git apply /root/va-iris.patch   # already applied is fine
git status --short
M="make LLVM=/opt/llvm-18/bin/ LOCALVERSION= -j8"
cp /root/config-t47.release .config
scripts/config --file .config --set-str LOCALVERSION "$NAME" --set-str INITRAMFS_SOURCE ""
$M olddefconfig
$M Image dtbs modules headers_install
rm -rf $MODS; $M INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
$M M=$UP/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules modules_install
rel=$($M -s kernelrelease); [ "$rel" = 7.3.0-rc4-tb323fu-t47-y3 ]
rm -f $MODS/lib/modules/$rel/build $MODS/lib/modules/$rel/source; depmod -b $MODS $rel
ls $MODS/lib/modules/$rel/updates/
$UP/kernel/initramfs/build.sh -k $SRC -b /bin/busybox -m $MODS/lib/modules/$rel -f / -a /etc/tb323fu/android-boot.sha256 -l $OUT/initramfs.list $OUT/initramfs.cpio.gz
scripts/config --file .config --set-str INITRAMFS_SOURCE "$OUT/initramfs.cpio.gz"
$M olddefconfig
$M Image
cp arch/arm64/boot/Image $OUT/Image-t47-y3; gzip -9 -n -c arch/arm64/boot/Image > $OUT/Image-t47-y3.gz
cp .config $OUT/config-t47-y3; git diff > $OUT/y700-y3.patch
strings $OUT/Image-t47-y3 | grep -m1 "Linux version"
sha256sum $OUT/Image-t47-y3*
echo KFULL_OK
