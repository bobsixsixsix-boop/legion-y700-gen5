#!/bin/bash
# continuation of kbuild-full.sh after the aw882xx install step
exec >> /root/y700-kernel-full.log 2>&1
set -ex
SRC=/usr/local/src/linux-t47; UP=/usr/local/src/tb323fu-linux; MODS=/usr/local/src/y700-mods
OUT=/usr/local/src/y700-kernel; rel=7.3.0-rc4-tb323fu-t47-y1
cd $SRC; M="make LLVM=/opt/llvm-18/bin/ LOCALVERSION= -j8"
ko=$UP/kernel/out-of-tree/aw882xx/snd-soc-aw882xx.ko
[ "$(modinfo -F vermagic $ko | cut -d" " -f1)" = "$rel" ]
install -D -m 0644 $ko $MODS/lib/modules/$rel/extra/snd-soc-aw882xx.ko
/opt/llvm-18/bin/llvm-strip --strip-debug $MODS/lib/modules/$rel/extra/snd-soc-aw882xx.ko
depmod -b $MODS $rel; grep -c aw882xx $MODS/lib/modules/$rel/modules.dep
$UP/kernel/initramfs/build.sh -k $SRC -b /bin/busybox -m $MODS/lib/modules/$rel -f / -a /etc/tb323fu/android-boot.sha256 -l $OUT/initramfs.list $OUT/initramfs.cpio.gz
scripts/config --file .config --set-str INITRAMFS_SOURCE "$OUT/initramfs.cpio.gz"
$M olddefconfig
$M Image
cp arch/arm64/boot/Image $OUT/Image-t47-y1; gzip -9 -n -c arch/arm64/boot/Image > $OUT/Image-t47-y1.gz
cp .config $OUT/config-t47-y1; git diff > $OUT/y700.patch
strings $OUT/Image-t47-y1 | grep -m1 "Linux version"
sha256sum $OUT/Image-t47-y1*
echo KFULL_OK
