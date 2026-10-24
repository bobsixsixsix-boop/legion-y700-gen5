#!/system/bin/sh
# KernelSU late_start service：开机后拉起 vrr-bridge。日志 /data/adb/y700/vrr-bridge.log
MODDIR=${0%/*}
mkdir -p /data/adb/y700
# 等 system_server 起来再启动，避免 logcat 还没准备好
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 5
nohup sh $MODDIR/vrr-bridge.sh >/dev/null 2>&1 &
