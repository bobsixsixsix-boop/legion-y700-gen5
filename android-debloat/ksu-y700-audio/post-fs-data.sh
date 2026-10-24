#!/system/bin/sh
# y700: audioserver 是 class core，在 "on boot" 才启动，post-fs-data 阶段写属性来得及。
# 背景见 android-debloat/audio-crash/README.md：杜比音效与 OPPO audioserver 偶发 FMQ 互等，
# 只能靠 TimeCheck 超时自杀重启来恢复；这个 OPPO 构建默认合计约 14 s，改回 AOSP 默认 5 s + 2 s。
RP=/data/adb/ksu/bin/resetprop
[ -x $RP ] || RP=setprop
$RP audio.timecheck.timeout_duration_ms 5000
$RP audio.timecheck.second_chance_duration_ms 2000
