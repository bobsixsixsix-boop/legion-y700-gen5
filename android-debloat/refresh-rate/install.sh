#!/usr/bin/env bash
# 用法: ./install.sh <生成好的xml> <adb序列号>
# 把覆盖配置装到 /data/system/refresh_rate_config.xml（system:system 0660，沿用 user_override 文件的 SELinux 标签），
# 然后发 RUS 重载广播（oplus.intent.action.ROM_UPDATE_CONFIG_SUCCESS，filter 名 sys_refresh_rate_config），
# 最后打印 logcat 里 RefreshRateConfig 的解析结果。不重启也应生效；若日志里没反应就重启。
set -eu
xml=$1; S=$2; A="adb -s $S"
MSYS_NO_PATHCONV=1 $A push "$xml" /data/local/tmp/refresh_rate_config.xml >/dev/null
$A logcat -c </dev/null
# toybox 的 chcon 没有 --reference，先用 ls -Z 读出 user_override 文件的标签再套上
$A shell "su -c 'ctx=\$(ls -Z /data/system/refresh_rate_config_user_override.xml | cut -d\" \" -f1); cp /data/local/tmp/refresh_rate_config.xml /data/system/refresh_rate_config.xml && chown system:system /data/system/refresh_rate_config.xml && chmod 0660 /data/system/refresh_rate_config.xml && chcon \$ctx /data/system/refresh_rate_config.xml && rm /data/local/tmp/refresh_rate_config.xml && ls -lZ /data/system/refresh_rate_config.xml'" </dev/null
$A shell "su -c 'am broadcast -a oplus.intent.action.ROM_UPDATE_CONFIG_SUCCESS --esal ROM_UPDATE_CONFIG_LIST sys_refresh_rate_config'" </dev/null | tail -1
sleep 3
$A shell "logcat -d | grep -E 'RefreshRateConfig|RomUpdateHelper|sys_refresh_rate_config' | tail -20" </dev/null
