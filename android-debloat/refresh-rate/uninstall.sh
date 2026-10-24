#!/usr/bin/env bash
# 用法: ./uninstall.sh <adb序列号>
# 删掉 /data/system/refresh_rate_config.xml，系统回到 /my_product/etc 那份；发重载广播，必要时重启。
set -eu
S=$1; A="adb -s $S"
$A shell "su -c 'rm -f /data/system/refresh_rate_config.xml; ls -l /data/system/refresh_rate_config.xml 2>&1'" </dev/null
$A shell "su -c 'am broadcast -a oplus.intent.action.ROM_UPDATE_CONFIG_SUCCESS --esal ROM_UPDATE_CONFIG_LIST sys_refresh_rate_config'" </dev/null | tail -1
