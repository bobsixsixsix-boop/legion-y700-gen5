#!/system/bin/sh
# KernelSU late_start service：开机后拉起 vrr-bridge。日志 /data/adb/y700/vrr-bridge.log
MODDIR=${0%/*}
mkdir -p /data/adb/y700
# vrr-bridge.sh 读的白名单，没有它就对所有应用降频。全新安装（恢复出厂后 /data/adb 是空的）时放一份模块自带的；已有的（可能手改过）不覆盖
[ -f /data/adb/y700/vrr-apps.txt ] || cp "$MODDIR/vrr-apps.txt" /data/adb/y700/
# 等 system_server 起来再启动，避免 logcat 还没准备好
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 5
nohup sh $MODDIR/vrr-bridge.sh >/dev/null 2>&1 &
