#!/system/bin/sh
# y700: KernelSU 3.x 没有 metamodule 就不挂载模块，所以自己在 post-fs-data
# （PackageManager 扫描之前）用空 tmpfs 盖住 hide.list 里列出的目录。
# 去掉某一行或删除本模块，重启后对应应用恢复。
# 注意：mount 的 context= 参数在这台机器上会被拒（Permission denied），所以挂上后再 chcon。
MODDIR=${0%/*}
LOG=$MODDIR/last.log
: > $LOG
grep -v '^#' $MODDIR/hide.list | while read -r p; do
	[ -n "$p" ] || continue
	if [ -d "$p" ]; then
		if mount -t tmpfs -o mode=0755,size=4k tmpfs "$p"; then
			chcon u:object_r:system_file:s0 "$p"
			echo "hidden $p" >> $LOG
		else
			echo "FAILED $p" >> $LOG
		fi
	else
		echo "missing $p" >> $LOG
	fi
done
