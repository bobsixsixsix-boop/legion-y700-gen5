#!/system/bin/sh
# y700: KernelSU 3.x has no built-in module mounting (needs a metamodule) and
# overlayfs refuses /data (case-insensitive f2fs) as a lower dir, so copy the
# files to tmpfs and overlay them onto /system_ext before PackageManager scans.
MODDIR=${0%/*}
T=/dev/y700_dax
mkdir -p $T && cp -a $MODDIR/system_ext $T/ && chcon -R u:object_r:system_file:s0 $T/system_ext || exit 0
for d in priv-app etc/permissions etc/sysconfig; do
	mount -t overlay -o ro,lowerdir=$T/system_ext/$d:/system_ext/$d overlay /system_ext/$d
done
